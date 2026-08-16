extends Node

# Permanent adversarial integration tests — the G1/G2 experiments, memorialized.
# These four have already caught real bugs (a reordering lag simulator; a lookahead
# too small for the timing budget). They exist so nobody defeats those invariants
# while "simplifying" transport or networking later.
#
# Run (needs a window: audio tests require a real audio driver mixing):
#   godot_console --path . res://tests/integration/integration_tests.tscn
# Exit code = number of failed tests.
#
# 1. AudioTimingUnderMainThreadHitches — pre-queued clicks stay sample-exact while
#    the main thread stalls 5-25 ms every frame.
# 2. NetworkDelayDoesNotAffectScheduledSamplePlacement — jittered SUBMISSION times
#    (the thing network delay actually shifts) leave onset placement invariant.
# 3. ReliableCommandsPreserveOrderUnderLatency — an order-sensitive burst through
#    the FIFO lag sim (60±20 ms, 20% modeled loss) arrives content-exact.
#    Consistency ≠ intent preservation; this asserts intent.
# 4. PeersPromoteSameVersionAtSameBoundary — host and client promote the same
#    version at the same musical loop under latency.
# 5. BotPeerPlaysBassAsOrdinaryPeer — the Phase 1B rule bot, mounted on the real
#    client under the same impaired link: one decision per window, zero rejects,
#    peers converge, every window (HOLDs included) logged.

const NetSession := preload("res://scripts/net/net_session.gd")
const BotPeer := preload("res://scripts/ai/bot_peer.gd")
const DecisionLog := preload("res://scripts/ai/decision_log.gd")
const BotObservation := preload("res://scripts/ai/bot_observation.gd")
const RuleBassPolicy := preload("res://scripts/ai/rule_bass_policy.gd")
const CommitModel := preload("res://scripts/core/commit_model.gd")
const DrumPattern := preload("res://scripts/core/drum_pattern.gd")
const BassLine := preload("res://scripts/core/bass_line.gd")
const ChordTrack := preload("res://scripts/core/chord_track.gd")
const TrackOps := preload("res://scripts/core/track_ops.gd")
const Transport := preload("res://scripts/audio/transport.gd")

const TEST_PORT := 7788
const STUB_BPM := 448.0 # 4x speed: a 4-bar loop every ~2.1 s keeps boundary tests short

var tests_failed := 0
var _checks_failed := 0
var _hitching := false

# session under test (tests 3 & 4 share one)
var s_room: RoomStub
var c_room: RoomStub
var s_net
var c_net


func _ready() -> void:
	# The suite needs a real audio driver but must NOT depend on the compositor
	# serving frames: an occluded window (or locked screen) blocks vsync'd swaps
	# at ~1 fps, which wrecks wall-clock-paced submissions and clock sync while
	# audio keeps mixing. Free-run the loop at a sane cap instead.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 120
	seed(424242) # deterministic lag-sim jitter/loss
	await _run_test("AudioTimingUnderMainThreadHitches", _test_audio_timing_under_hitches)
	await _run_test("NetworkDelayDoesNotAffectScheduledSamplePlacement", _test_delay_invariant_placement)
	var session_ok := await _setup_session()
	if session_ok:
		await _run_test("ReliableCommandsPreserveOrderUnderLatency", _test_order_under_latency)
		await _run_test("PeersPromoteSameVersionAtSameBoundary", _test_same_boundary_promotion)
		await _run_test("BotPeerPlaysBassAsOrdinaryPeer", _test_bot_peer_ordinary)
	else:
		print("ITEST FAIL: session setup (host/join/clock-lock) — skipping network tests")
		tests_failed += 3
	await _run_test("ExternalBotProcessIsTheSamePlayer", _test_external_bot_process)
	print("ITESTS DONE: %d failed" % tests_failed)
	get_tree().quit(tests_failed)


func _run_test(test_name: String, fn: Callable) -> void:
	print("[itest] " + test_name)
	_checks_failed = 0
	await fn.call()
	if _checks_failed == 0:
		print("ITEST PASS: " + test_name)
	else:
		print("ITEST FAIL: %s (%d checks)" % [test_name, _checks_failed])
		tests_failed += 1


func check(cond: bool, label: String) -> void:
	if not cond:
		_checks_failed += 1
		printerr("  CHECK FAIL: " + label)


func await_until(cond: Callable, timeout_s: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		await get_tree().process_frame
	return cond.call()


func _process(_delta: float) -> void:
	if _hitching:
		OS.delay_msec(randi_range(5, 25)) # the adversary: stall the main thread

# ---------------------------------------------------------------- audio tests

func _make_stream_player() -> Array:
	var stream = ClassDB.instantiate("JamAudioStream")
	var click := PackedFloat32Array()
	click.resize(256)
	for i in 256:
		click[i] = 1.0 - float(i) / 256.0
	stream.set_voice_table(0, click)
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = -30.0
	add_child(player)
	player.play()
	return [stream, player]


## Drains the (intended, actual) diagnostics ring and summarizes the events >= base.
func _onset_summary(stream, base: int) -> Dictionary:
	var pairs: PackedInt64Array = stream.drain_onsets()
	var actuals: Array = []
	var placement_errors := 0
	for i in range(0, pairs.size(), 2):
		if pairs[i] >= base:
			actuals.append(pairs[i + 1])
			if pairs[i + 1] != pairs[i]:
				placement_errors += 1
	actuals.sort()
	var deltas := {}
	for i in range(1, actuals.size()):
		var d: int = actuals[i] - actuals[i - 1]
		deltas[d] = deltas.get(d, 0) + 1
	return {"count": actuals.size(), "placement_errors": placement_errors, "deltas": deltas}


func _test_audio_timing_under_hitches() -> void:
	if not ClassDB.class_exists("JamAudioStream"):
		check(false, "JamAudioStream extension present")
		return
	var sp := _make_stream_player()
	var stream = sp[0]
	check(await await_until(func(): return stream.get_sample_cursor() > 0, 3.0), "native stream is mixing")
	stream.drain_onsets()
	var base: int = stream.get_sample_cursor() + 11025 # 0.25 s ahead
	var n := 32
	var spacing := 3000
	for i in n:
		stream.schedule_trigger(base + i * spacing, 0, 0.2, 1.0, false)
	_hitching = true
	var done := await await_until(
		func(): return stream.get_sample_cursor() > base + n * spacing + 8000, 8.0)
	_hitching = false
	check(done, "click train window elapsed")
	var s := _onset_summary(stream, base)
	check(s.count == n, "all %d clicks launched (got %d)" % [n, s.count])
	check(s.placement_errors == 0, "every onset placed at its intended sample")
	check(s.deltas.size() == 1 and s.deltas.has(spacing), "all onset deltas exactly %d (got %s)" % [spacing, s.deltas])
	check(stream.get_late_count() == 0, "zero late events under hitching")
	sp[1].queue_free()


func _test_delay_invariant_placement() -> void:
	if not ClassDB.class_exists("JamAudioStream"):
		check(false, "JamAudioStream extension present")
		return
	var sp := _make_stream_player()
	var stream = sp[0]
	check(await await_until(func(): return stream.get_sample_cursor() > 0, 3.0), "native stream is mixing")
	stream.drain_onsets()
	var mix: float = stream.get_mix_rate()
	var cursor0: int = stream.get_sample_cursor()
	var t0 := Time.get_ticks_msec()
	var base: int = cursor0 + int(0.5 * mix)
	var n := 24
	var spacing := 4000
	# Submit each trigger at a JITTERED wall time 120-300 ms before it is due —
	# submission time is exactly what network delay shifts. FIFO order preserved
	# (stamps must be non-decreasing), release times vary per event.
	var prev_submit := t0
	for i in n:
		var due_wall: float = t0 + float(base - cursor0 + i * spacing) * 1000.0 / mix
		var submit_at: float = maxf(prev_submit, due_wall - randf_range(120.0, 300.0))
		prev_submit = submit_at
		while Time.get_ticks_msec() < submit_at:
			await get_tree().process_frame
		stream.schedule_trigger(base + i * spacing, 0, 0.2, 1.0, false)
	var done := await await_until(
		func(): return stream.get_sample_cursor() > base + n * spacing + 8000, 8.0)
	check(done, "click train window elapsed")
	var s := _onset_summary(stream, base)
	check(s.count == n, "all %d clicks launched (got %d)" % [n, s.count])
	check(s.placement_errors == 0, "jittered submission did not move any onset")
	check(s.deltas.size() == 1 and s.deltas.has(spacing), "all onset deltas exactly %d (got %s)" % [spacing, s.deltas])
	check(stream.get_late_count() == 0, "zero late events")
	sp[1].queue_free()


# ---------------------------------------------------------------- network tests

## A minimal room implementing the surface NetSession needs, reusing the REAL
## domain code: commit models, TrackOps, JamTransport (legacy clock — no audio
## dependency), and the same commit-at-boundary logic.
class RoomStub extends Node:
	const CommitModelC := preload("res://scripts/core/commit_model.gd")
	const DrumPatternC := preload("res://scripts/core/drum_pattern.gd")
	const BassLineC := preload("res://scripts/core/bass_line.gd")
	const ChordTrackC := preload("res://scripts/core/chord_track.gd")
	const TrackOpsC := preload("res://scripts/core/track_ops.gd")
	const TransportC := preload("res://scripts/audio/transport.gd")

	var drums
	var bass
	var chords
	var transport
	var net
	var loop_index := -1
	var commit_log := {} # track -> Array of {version, loop}

	func _init(bpm: float) -> void:
		drums = CommitModelC.new(DrumPatternC.new())
		bass = CommitModelC.new(BassLineC.new())
		chords = CommitModelC.new(ChordTrackC.new())
		transport = TransportC.new()
		transport.bpm = bpm

	func _ready() -> void:
		add_child(transport)
		transport.sixteenth.connect(_on_sixteenth)
		transport.start()

	func model_for(track: int):
		match track:
			0: return drums
			1: return bass
			_: return chords

	func _factory(track: int) -> Callable:
		match track:
			0: return Callable(DrumPatternC, "new")
			1: return Callable(BassLineC, "new")
			_: return Callable(ChordTrackC, "new")

	func apply_edit(track: int, op: String, args: Dictionary) -> void:
		TrackOpsC.apply(model_for(track), track, op, args, loop_index)

	func apply_track_state(track: int, state: Dictionary) -> void:
		model_for(track).apply_state(state, _factory(track))

	func queue_ui_refresh() -> void:
		pass

	## Same dispatch semantics as JamRoom: local prediction + intent to server.
	func dispatch(track: int, op: String, args: Dictionary) -> void:
		if not net.can_edit(track):
			return
		apply_edit(track, op, args)
		if net.active:
			if net.is_server:
				net.broadcast_track(track)
			else:
				net.send_cmd(track, op, args)

	func _on_sixteenth(abs_step: int) -> void:
		var new_loop := int(abs_step / 64.0)
		if new_loop == loop_index:
			return
		loop_index = new_loop
		for t in [0, 1, 2]:
			if model_for(t).try_commit_at_loop(new_loop):
				if not commit_log.has(t):
					commit_log[t] = []
				commit_log[t].append({"version": model_for(t).version_id, "loop": new_loop})
				if net.active and net.is_server:
					net.broadcast_track(t)


## Two real ENet peers in one process via branch-scoped MultiplayerAPIs.
func _setup_session() -> bool:
	var s_branch := Node.new()
	s_branch.name = "S"
	add_child(s_branch)
	var c_branch := Node.new()
	c_branch.name = "C"
	add_child(c_branch)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), s_branch.get_path())
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), c_branch.get_path())

	s_room = RoomStub.new(STUB_BPM)
	s_branch.add_child(s_room)
	c_room = RoomStub.new(STUB_BPM)
	c_branch.add_child(c_room)

	s_net = NetSession.new()
	s_net.name = "Net"
	s_net.room = s_room
	s_net.listen_port = TEST_PORT
	s_branch.add_child(s_net)
	s_room.net = s_net

	c_net = NetSession.new()
	c_net.name = "Net"
	c_net.room = c_room
	c_net.listen_port = TEST_PORT
	c_branch.add_child(c_net)
	c_room.net = c_net

	if not s_net.host():
		return false
	if not c_net.join("127.0.0.1"):
		return false
	# connection + role assignment + clock sync through real ENet on localhost
	return await await_until(func(): return c_net._clock_locked, 6.0)


const IMPAIRED := {"base": 60.0, "jitter": 20.0, "loss": 0.2}


func _impair(n) -> void:
	n.lag_sim = true
	n.lag_base_ms = IMPAIRED.base
	n.lag_jitter_ms = IMPAIRED.jitter
	n.lag_loss_pct = IMPAIRED.loss


func _bass_line_of(room: RoomStub):
	return room.bass.pending if room.bass.has_pending() else room.bass.active


func _test_order_under_latency() -> void:
	_impair(s_net)
	_impair(c_net)
	# Order-sensitive burst: clear, 8 places, 2 retunes. Any reordering mangles it.
	var expected := {0: 0, 2: 2, 4: 1, 6: 1, 8: 3, 10: 0, 12: 2, 14: 3}
	c_room.dispatch(1, "clear", {})
	for i in 8:
		c_room.dispatch(1, "place", {"step": i * 2, "degree": (i * 2) % 5})
	c_room.dispatch(1, "place", {"step": 4, "degree": 1})
	c_room.dispatch(1, "place", {"step": 14, "degree": 3})
	check(_bass_line_of(c_room).notes == expected, "client prediction is the intended line")
	var arrived := await await_until(
		func(): return _bass_line_of(s_room).notes == expected, 5.0)
	check(arrived, "ORDER: server line content-matches client intent under 60±20ms/20%%loss (got %s)" % [_bass_line_of(s_room).notes])
	# and the echo path must not have mangled the client either
	var echoed := await await_until(
		func(): return _bass_line_of(c_room).notes == expected, 5.0)
	check(echoed, "client line still intent-exact after server echoes")


func _test_same_boundary_promotion() -> void:
	# Let any pending from the previous test commit first.
	var settled := await await_until(
		func(): return not s_room.bass.has_pending() and not c_room.bass.has_pending(), 8.0)
	check(settled, "prior pendings settled")
	var v0: int = s_room.bass.version_id
	check(c_room.bass.version_id == v0, "versions equal before burst (s=%d c=%d)" % [v0, c_room.bass.version_id])

	# Burst just AFTER a boundary: an edit inside the final ~RTT of a loop may
	# legitimately slip one loop (the lock-horizon edge, not yet ported); this
	# test asserts the common case, not that edge.
	var cl: int = c_room.loop_index
	await await_until(func(): return c_room.loop_index > cl, 5.0)

	var expected := {0: 0, 4: 1, 8: 2, 12: 3}
	c_room.dispatch(1, "clear", {})
	for i in 4:
		c_room.dispatch(1, "place", {"step": i * 4, "degree": i})

	var promoted := await await_until(
		func(): return s_room.bass.version_id == v0 + 1 and c_room.bass.version_id == v0 + 1 \
			and not s_room.bass.has_pending() and not c_room.bass.has_pending(), 10.0)
	check(promoted, "both peers promoted to v%d" % (v0 + 1))
	check(s_room.bass.active.notes == expected, "server active content is the committed intent")
	check(c_room.bass.active.notes == expected, "client active content is the committed intent")

	var s_loop := _commit_loop_for(s_room, 1, v0 + 1)
	var c_loop := _commit_loop_for(c_room, 1, v0 + 1)
	check(s_loop >= 0 and c_loop >= 0, "both peers logged the promotion (s=%d c=%d)" % [s_loop, c_loop])
	check(s_loop == c_loop, "BOUNDARY: both peers promoted at the same loop (s=%d c=%d)" % [s_loop, c_loop])


func _commit_loop_for(room: RoomStub, track: int, version: int) -> int:
	for entry in room.commit_log.get(track, []):
		if entry.version == version:
			return entry.loop
	return -1


## Phase 1B gate: the rule bot mounted on the REAL client peer, under the same
## impaired link as tests 3/4 (60±20 ms, 20% modeled loss). It must behave as an
## ordinary — and containable — network participant: one decision per window,
## a role it doesn't own is never touched, the server rejects nothing, both
## peers converge, and every window (HOLDs included) lands in the decision log.
func _test_bot_peer_ordinary() -> void:
	var rejects_before: int = s_net.rejects
	var dlog = DecisionLog.new()
	check(dlog.open({"session_id": "itest_bot", "session_seed": 5,
		"room_epoch": c_net.room_epoch}, "user://test_decision_logs") == OK, "decision log opens")
	var bot = BotPeer.new()
	bot.room = c_room
	bot.session_seed = 5
	bot.decision_log = dlog
	add_child(bot)
	# A bot pointed at a seat it does NOT own (drums are the host's): must never act.
	var squatter = BotPeer.new()
	squatter.room = c_room
	squatter.role = 0
	add_child(squatter)

	var start_loop: int = c_room.loop_index
	var reached := await await_until(func(): return c_room.loop_index >= start_loop + 7, 40.0)
	check(reached, "seven decision windows elapsed")
	bot.set_process(false) # freeze decisions so the last edit can settle
	squatter.set_process(false)

	check(bot.decisions >= 6, "bot decided once per window (got %d)" % bot.decisions)
	check(bot.decisions == bot.authored.size(), "no window authored twice")
	check(bot.edits >= 1, "bot made at least one edit (got %d)" % bot.edits)
	check(bot.holds >= 1, "bot deliberately held at least once (got %d)" % bot.holds)
	check(squatter.decisions == 0, "bot without the role never acts")
	check(s_net.rejects == rejects_before, "server accepted every bot op (rejects %d -> %d)"
		% [rejects_before, s_net.rejects])

	var converged := await await_until(func(): return not s_room.bass.has_pending() \
		and not c_room.bass.has_pending() \
		and s_room.bass.version_id == c_room.bass.version_id \
		and s_room.bass.active.equals(c_room.bass.active), 15.0)
	check(converged, "host and client converge on the same committed bass line and version")
	var density: int = s_room.bass.active.notes.size()
	check(density >= 1 and density <= 6, "converged line lands at a sane density (got %d)" % density)

	dlog.close()
	var frames := 0
	var zero_ops := 0
	for e in DecisionLog.read_events(dlog.path):
		if e.type == "decision":
			frames += 1
			if e.ops.is_empty():
				zero_ops += 1
	check(frames == bot.decisions, "one logged frame per decision window (%d/%d)" % [frames, bot.decisions])
	check(zero_ops == bot.holds, "every HOLD logged as a zero-op frame (%d/%d)" % [zero_ops, bot.holds])
	DirAccess.remove_absolute(dlog.path)
	bot.queue_free()
	squatter.queue_free()


## Phase 1C gate — deliberately boring: same BotPeer code + different process
## boundary = same behavior. A REAL game instance (`--join --bot-seed --bpm`) is
## spawned as a separate OS process and must join over actual ENet, take the
## BASS seat, author windows the host commits, and leave a decision log whose
## every frame REPLAYS: logged observation + logged seed through the policy
## reproduces the logged ops exactly. That proves process location is irrelevant
## to the policy, not merely that both mounts happen to function.
func _test_external_bot_process() -> void:
	# RPC paths are RELATIVE TO THE MULTIPLAYER ROOT, and this peer lives in
	# another process: the game instance (unscoped, root = /root) sends and
	# expects "JamRoom/Net". So the host's scoped API must root at a WRAPPER
	# whose subtree contains JamRoom/Net — then both sides' relative paths
	# agree. The in-process tests never feel this because their branches are
	# scoped symmetrically ("Net" on both sides).
	var branch := Node.new()
	branch.name = "S3"
	add_child(branch)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), branch.get_path())
	var jam_mirror := Node.new()
	jam_mirror.name = "JamRoom"
	branch.add_child(jam_mirror)
	var host_room := RoomStub.new(STUB_BPM)
	branch.add_child(host_room)
	var host_net = NetSession.new()
	host_net.name = "Net"
	host_net.room = host_room
	host_net.listen_port = 7777 # the game's default join port
	jam_mirror.add_child(host_net)
	host_room.net = host_net
	if not host_net.host():
		check(false, "external-bot host failed (port 7777 busy?)")
		return

	var log_dir := "user://decision_logs"
	var before := {}
	if DirAccess.dir_exists_absolute(log_dir):
		for f in DirAccess.get_files_at(log_dir):
			before[f] = true

	var pid := OS.create_process(OS.get_executable_path(),
		["--path", ProjectSettings.globalize_path("res://"), "--",
		"--join=127.0.0.1", "--bot-seed=777", "--bpm=%d" % int(STUB_BPM)])
	check(pid > 0, "external bot process launched")

	var joined := await await_until(func(): return host_net.multiplayer.get_peers().size() >= 1, 20.0)
	check(joined, "external bot joined over real ENet")
	var v0: int = host_room.bass.version_id
	var progressed := await await_until(func(): return host_room.bass.version_id >= v0 + 2, 90.0)
	check(progressed, "host committed two bass versions authored by the external bot")
	var density: int = host_room.bass.active.notes.size()
	check(density >= 1 and density <= 6, "external bot drove the line to sane density (got %d)" % density)
	OS.kill(pid)

	var log_file := ""
	for f in DirAccess.get_files_at(log_dir):
		if not before.has(f):
			log_file = f
	check(not log_file.is_empty(), "external bot wrote a decision log")
	if log_file.is_empty():
		return
	var frames := 0
	var holds := 0
	var edits := 0
	var replays_ok := true
	for e in DecisionLog.read_events(log_dir + "/" + log_file):
		if e.type != "decision":
			continue
		frames += 1
		if e.ops.is_empty():
			holds += 1
		else:
			edits += 1
		var replayed := RuleBassPolicy.decide(BotObservation.from_json(e.observation), int(e.rng_seed))
		var logged: Array = []
		for op in e.ops:
			logged.append({"track": int(op.track), "op": String(op.op),
				"args": {"step": int(op.args.step), "degree": int(op.args.degree)}})
		if logged != replayed:
			replays_ok = false
	check(frames >= 3, "external bot authored multiple windows (got %d)" % frames)
	check(holds >= 1 and edits >= 1, "external bot both held and edited (%d holds, %d edits)" % [holds, edits])
	check(replays_ok, "REPLAY: every logged observation + seed reproduces the logged ops")
	DirAccess.remove_absolute(log_dir + "/" + log_file)
	branch.queue_free()
