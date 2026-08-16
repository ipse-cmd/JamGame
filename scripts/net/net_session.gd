class_name JamNetSession
extends Node

# G1 network shell. Deliberately ugly and narrow. Rules (straight from Jammin):
#  * The wire carries MUSICAL DECISIONS (edit commands, replicated commit-model
#    state with server-assigned boundaries/versions) — never audio triggers.
#  * The server owns accepted musical state. Clients send intent; the server
#    validates STRICTLY (rejects, never repairs) and broadcasts state.
#  * Every machine renders audio locally: its own transport, its own 150 ms
#    lookahead, its own G2 native scheduler. Network jitter and audio jitter
#    are separate problems by construction.
#
# Includes an application-level lag simulator (F10): base latency ± jitter, with
# "loss" modeled as an ENet-style retransmit delay (reliable channels don't lose
# packets, they pay for them in time).

const PORT := 7777
const TRACK_DRUMS := 0
const TRACK_BASS := 1
const TRACK_CHORDS := 2
const CLOCK_PINGS := 6

var room # JamRoom backref

var active := false
var is_server := false
var status := "solo"
var roles := {} # track:int -> peer_id:int
var rejects := 0 # server: invalid commands refused

# client-side clock sync + agreement tracking
var rtt_ms := -1.0
var server_loop := -1
var server_versions := [-1, -1, -1]
var _ping_samples: Array = []
var _pings_left := 0
var _clock_locked := false

# lag simulator (per-peer, outgoing)
var lag_sim := false
var lag_base_ms := 60.0
var lag_jitter_ms := 20.0
var lag_loss_pct := 0.015
var _lag_queue: Array = []

var _snapshot_accum := 0.0


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func host() -> bool:
	if active:
		return false
	var peer := ENetMultiplayerPeer.new()
	if peer.create_server(PORT) != OK:
		status = "host failed (port %d busy?)" % PORT
		return false
	multiplayer.multiplayer_peer = peer
	active = true
	is_server = true
	status = "hosting"
	_assign_roles()
	return true


func join(ip: String) -> bool:
	if active:
		return false
	var peer := ENetMultiplayerPeer.new()
	if peer.create_client(ip, PORT) != OK:
		status = "join failed"
		return false
	multiplayer.multiplayer_peer = peer
	active = true
	is_server = false
	status = "connecting to %s..." % ip
	return true


func can_edit(track: int) -> bool:
	if not active:
		return true # solo: everything editable
	return roles.get(track, 1) == multiplayer.get_unique_id()


func owned_tracks() -> Array:
	if not active:
		return [TRACK_DRUMS, TRACK_BASS, TRACK_CHORDS]
	var mine: Array = []
	for t in roles:
		if roles[t] == multiplayer.get_unique_id():
			mine.append(t)
	return mine


func _process(delta: float) -> void:
	# Flush lag-simulated sends IN SEND ORDER (FIFO): ENet reliable channels are
	# ordered, so a "lost" (delayed) packet head-of-line blocks later ones — it
	# never lets them overtake. An earlier version released packets independently,
	# which reordered clear/place commands and mangled the musical intent.
	if not _lag_queue.is_empty():
		var now := Time.get_ticks_msec()
		while not _lag_queue.is_empty() and _lag_queue[0].t <= now:
			var item: Dictionary = _lag_queue.pop_front()
			callv("rpc_id", [item.p, item.m] + item.a)
	# server: periodic snapshot (agreement probe + late-join safety net)
	if active and is_server:
		_snapshot_accum += delta
		if _snapshot_accum >= 1.0:
			_snapshot_accum = 0.0
			_broadcast("snapshot", [_make_snapshot()])


# ---------------------------------------------------------------- sending

func _net_send(method: StringName, args: Array, peer_id: int) -> void:
	if lag_sim:
		var delay := lag_base_ms + randf_range(-lag_jitter_ms, lag_jitter_ms)
		if randf() < lag_loss_pct:
			delay += 250.0 # modeled ENet retransmit after a lost packet
		var release := Time.get_ticks_msec() + delay
		if not _lag_queue.is_empty():
			release = maxf(release, _lag_queue.back().t) # FIFO: never overtake an earlier packet
		_lag_queue.append({"t": release, "m": method, "a": args, "p": peer_id})
	else:
		callv("rpc_id", [peer_id, method] + args)


func _broadcast(method: StringName, args: Array) -> void:
	for p in multiplayer.get_peers():
		_net_send(method, args, p)


func send_cmd(track: int, op: String, args: Dictionary) -> void:
	if active and not is_server:
		_net_send("cmd_edit", [track, op, args], 1)


func broadcast_track(track: int) -> void:
	if active and is_server:
		_broadcast("state_track", [track, room.model_for(track).state_dict()])


# ---------------------------------------------------------------- server side

@rpc("any_peer", "call_remote", "reliable")
func cmd_edit(track: int, op: String, args: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _validate_cmd(sender, track, op, args):
		rejects += 1
		return
	room.apply_edit(track, op, args)
	broadcast_track(track)


## Strict validation: role gate + exact payload shape + ranges. Reject, never repair.
func _validate_cmd(sender: int, track: int, op: String, args: Dictionary) -> bool:
	if roles.get(track, 1) != sender:
		return false
	match [track, op]:
		[TRACK_DRUMS, "toggle"], [TRACK_DRUMS, "accent"]:
			return _int_in(args, "voice", 0, 3) and _int_in(args, "step", 0, 15) and args.size() == 2
		[TRACK_DRUMS, "clear_voice"]:
			return _int_in(args, "voice", 0, 3) and args.size() == 1
		[TRACK_BASS, "place"]:
			return _int_in(args, "step", 0, 15) and _int_in(args, "degree", 0, 4) and args.size() == 2
		[TRACK_CHORDS, "cycle"]:
			return _int_in(args, "bar", 0, 3) and args.has("delta") and (args.delta == 1 or args.delta == -1) and args.size() == 2
		[TRACK_CHORDS, "clear_slot"]:
			return _int_in(args, "bar", 0, 3) and args.size() == 1
		[TRACK_DRUMS, "clear_all"], [TRACK_DRUMS, "cancel"], \
		[TRACK_BASS, "clear"], [TRACK_BASS, "cancel"], \
		[TRACK_CHORDS, "clear"], [TRACK_CHORDS, "cancel"]:
			return args.is_empty()
	return false


static func _int_in(args: Dictionary, key: String, lo: int, hi: int) -> bool:
	if not args.has(key):
		return false
	var v = args[key]
	return typeof(v) == TYPE_INT and v >= lo and v <= hi


@rpc("any_peer", "call_remote", "reliable")
func clock_ping(client_usec: int) -> void:
	if not multiplayer.is_server():
		return
	_net_send("clock_pong", [client_usec, room.transport.position_steps()], multiplayer.get_remote_sender_id())


func _make_snapshot() -> Dictionary:
	return {
		"server_loop": room.loop_index,
		"server_steps": room.transport.position_steps(),
		"versions": [
			room.model_for(TRACK_DRUMS).version_id,
			room.model_for(TRACK_BASS).version_id,
			room.model_for(TRACK_CHORDS).version_id,
		],
		"roles": roles,
		"rejects": rejects,
	}


func _send_full_state_to(peer_id: int) -> void:
	for t in [TRACK_DRUMS, TRACK_BASS, TRACK_CHORDS]:
		_net_send("state_track", [t, room.model_for(t).state_dict()], peer_id)
	_net_send("snapshot", [_make_snapshot()], peer_id)


func _assign_roles() -> void:
	var clients := multiplayer.get_peers()
	clients.sort()
	roles = {TRACK_DRUMS: 1}
	roles[TRACK_BASS] = clients[0] if clients.size() >= 1 else 1
	roles[TRACK_CHORDS] = clients[1] if clients.size() >= 2 else 1


# ---------------------------------------------------------------- client side

@rpc("authority", "call_remote", "reliable")
func state_track(track: int, state: Dictionary) -> void:
	room.apply_track_state(track, state)


@rpc("authority", "call_remote", "reliable")
func snapshot(d: Dictionary) -> void:
	server_loop = int(d.server_loop)
	server_versions = d.versions
	roles = d.roles
	rejects = int(d.rejects)
	room.queue_ui_refresh()


@rpc("authority", "call_remote", "reliable")
func clock_pong(client_usec: int, server_steps: float) -> void:
	var now := Time.get_ticks_usec()
	var rtt_s := float(now - client_usec) / 1e6
	rtt_ms = rtt_s * 1000.0
	_ping_samples.append({"rtt": rtt_s, "steps": server_steps, "at": now})
	_pings_left -= 1
	if _pings_left > 0:
		_send_ping()
		return
	if _clock_locked:
		return # later pings only refresh the RTT display
	_clock_locked = true
	var best: Dictionary = _ping_samples[0]
	for s in _ping_samples:
		if s.rtt < best.rtt:
			best = s
	# Server's musical position right now ≈ sampled position + RTT/2 + time since receipt.
	var step_seconds: float = 60.0 / room.transport.bpm / 4.0
	var elapsed := float(Time.get_ticks_usec() - best.at) / 1e6
	var est: float = best.steps + (best.rtt / 2.0 + elapsed) / step_seconds
	room.transport.start_at(est)
	status = "synced (RTT %.0f ms)" % (best.rtt * 1000.0)


func _send_ping() -> void:
	_net_send("clock_ping", [Time.get_ticks_usec()], 1)


# ---------------------------------------------------------------- peer events

func _on_peer_connected(id: int) -> void:
	if is_server:
		_assign_roles()
		_send_full_state_to(id)
		status = "hosting · %d peer(s)" % multiplayer.get_peers().size()
	room.queue_ui_refresh()


func _on_peer_disconnected(_id: int) -> void:
	if is_server:
		_assign_roles()
		status = "hosting · %d peer(s)" % multiplayer.get_peers().size()
	room.queue_ui_refresh()


func _on_connected_to_server() -> void:
	status = "connected, syncing clock..."
	_ping_samples = []
	_pings_left = CLOCK_PINGS
	_clock_locked = false
	_send_ping()
	room.queue_ui_refresh()


func _on_connection_failed() -> void:
	multiplayer.multiplayer_peer = null
	active = false
	status = "join FAILED"
	room.queue_ui_refresh()


func _on_server_disconnected() -> void:
	multiplayer.multiplayer_peer = null
	active = false
	is_server = false
	roles = {}
	status = "server lost — back to solo"
	room.queue_ui_refresh()


# ---------------------------------------------------------------- observability

func debug_state() -> Dictionary:
	var local_versions := [
		room.model_for(TRACK_DRUMS).version_id,
		room.model_for(TRACK_BASS).version_id,
		room.model_for(TRACK_CHORDS).version_id,
	] if room != null else [-1, -1, -1]
	return {
		"active": active,
		"is_server": is_server,
		"status": status,
		"peers": multiplayer.get_peers().size() if active else 0,
		"roles": roles,
		"owned": owned_tracks(),
		"rtt_ms": rtt_ms,
		"server_loop": server_loop,
		"local_loop": room.loop_index if room != null else -1,
		"server_versions": server_versions,
		"local_versions": local_versions,
		"versions_agree": not active or is_server or server_versions == local_versions,
		"rejects": rejects,
		"lag_sim": lag_sim,
	}
