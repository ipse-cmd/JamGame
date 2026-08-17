class_name JamAudioEngine
extends Node

# Audio boundary for the room. Two modes:
#
#  NATIVE (G2+DaisySP): the JamAudioStream GDExtension running Jammin's real
#  voice rack — DaisySP synthesis with the original Unreal presets, pools, and
#  mix gains. The game thread submits triggers stamped with ABSOLUTE sample
#  numbers via schedule_*(); the native _mix() fires each voice at the exact
#  sample offset inside whatever block it renders. The native rack owns the
#  mix (Unreal base gains); velocities passed here are pure musical dynamics.
#
#  LEGACY (G0 fallback, native class absent): pooled AudioStreamPlayers over
#  procedural PCM tables, triggered immediately — frame-quantized timing, kept
#  only so the project still runs without a compiled extension.

enum Voice { KICK, SNARE, HAT, PERC, BASS, PLUCK }

const BASS_BASE_MIDI := 36 # bass table rendered at C2
const PLUCK_BASE_MIDI := 60 # pluck table rendered at C4
const ACCENT_FLOOR := 0.95 # accented hits never drop below this velocity (Jammin D2)

# Per-channel gains in dB, mirroring the Jammin mixer defaults (bass ducked — it drowned the kick).
var channel_db := {"kick": 0.0, "snare": -2.0, "hat": -8.0, "perc": -5.0, "bass": -6.0, "chords": -10.0}

var native := false
var stream = null # JamAudioStream when native
var mix_rate := 44100.0
var _rate_ratio := 1.0 # table rate (44100) / device mix rate — pitch-corrects table playback

var _player: AudioStreamPlayer
var _drum_pools: Array = [] # legacy
var _bass_player: AudioStreamPlayer # legacy
var _chord_pool: Dictionary # legacy

@onready var _drum_channel_names := ["kick", "snare", "hat", "perc"]


func _ready() -> void:
	native = ClassDB.class_exists("JamAudioStream")
	# --mute: this instance renders its clock but outputs silence — for local
	# bot clients sharing the host's speakers. In-process, so no dependence on
	# OS mixer per-app restore state (which keys on the shared app name).
	if "--mute" in OS.get_cmdline_user_args():
		AudioServer.set_bus_volume_db(0, -80.0)
	if native:
		_setup_native()
	else:
		push_warning("JamAudioStream extension not found — falling back to legacy frame-quantized audio.")
		_setup_legacy()


func _setup_native() -> void:
	stream = ClassDB.instantiate("JamAudioStream")
	_player = AudioStreamPlayer.new()
	_player.stream = stream
	add_child(_player)
	_player.play()
	mix_rate = stream.get_mix_rate()


# ---------------------------------------------------------------- kit variants

var _kit := [0, 0, 0, 0] # current kit variant per drum lane (native: passed per trigger)


## Select the (lane, variant) kit sound. Native: DaisySP drum voices take the
## variant on each Trigger (D9), so this just records it — the sound changes
## from the next hit. Legacy: swap the PCM table.
func set_kit_variant(lane: int, variant: int) -> void:
	if lane < 0 or lane >= 4:
		return
	_kit[lane] = variant
	if not native and lane < _drum_pools.size():
		var wav := JamSampleFactory._to_wav(JamSampleFactory.drum_samples(lane, variant))
		for p in _drum_pools[lane].players:
			p.stream = wav


func apply_kit(kit: Array) -> void:
	for lane in mini(kit.size(), 4):
		set_kit_variant(lane, int(kit[lane]))


## Room mixer (D10): per-pool user gains 0..2 on top of the rack's base mix.
## Native only — the legacy fallback keeps its fixed channel_db.
func apply_mix(mix: Array) -> void:
	if not native:
		return
	for pool in mini(mix.size(), 6):
		stream.set_pool_gain(pool, float(mix[pool]))


# ---------------------------------------------------------------- native scheduled API

func sample_cursor() -> int:
	return stream.get_sample_cursor() if native else 0


func schedule_drum(at_sample: int, voice: int, velocity: float, accent: bool) -> void:
	var vel := maxf(velocity, ACCENT_FLOOR) if accent else velocity
	stream.schedule_note(at_sample, voice, 0, clampf(vel, 0.05, 1.0), 0.25, _kit[voice])


## duration: gate length in seconds — the ADSR holds until it elapses, then
## releases. Overlapping release tails are legato, not a bug (pool of 4).
func schedule_bass(at_sample: int, midi: int, velocity: float, duration := 0.25) -> void:
	stream.schedule_note(at_sample, Voice.BASS, midi, clampf(velocity, 0.05, 1.0), duration, 0)


func schedule_chord(at_sample: int, midis: Array, velocity: float) -> void:
	for midi in midis:
		stream.schedule_note(at_sample, Voice.PLUCK, midi, clampf(velocity, 0.05, 1.0), 1.0, 0)


func diagnostics() -> Dictionary:
	if not native:
		return {"native": false}
	return {
		"native": true,
		"cursor": stream.get_sample_cursor(),
		"launched": stream.get_launched_count(),
		"late": stream.get_late_count(),
		"dropped": stream.get_dropped_count(),
	}


# ---------------------------------------------------------------- legacy immediate API

func _setup_legacy() -> void:
	var drum_streams := [
		JamSampleFactory.make_kick(),
		JamSampleFactory.make_snare(),
		JamSampleFactory.make_hat(),
		JamSampleFactory.make_perc(),
	]
	for v in drum_streams.size():
		_drum_pools.append(_make_pool(drum_streams[v], 3, channel_db[_drum_channel_names[v]]))
	_bass_player = AudioStreamPlayer.new()
	_bass_player.stream = JamSampleFactory.make_bass()
	add_child(_bass_player)
	_chord_pool = _make_pool(JamSampleFactory.make_pluck(), 8, channel_db["chords"])


func trigger_drum(voice: int, velocity: float, accent: bool) -> void:
	if voice < 0 or voice >= _drum_pools.size():
		return
	var vel := maxf(velocity, ACCENT_FLOOR) if accent else velocity
	_play_pooled(_drum_pools[voice], vel, 1.0)


func trigger_bass(midi: int, velocity: float) -> void:
	_bass_player.volume_db = channel_db["bass"] + linear_to_db(clampf(velocity, 0.05, 1.0))
	_bass_player.pitch_scale = pow(2.0, float(midi - BASS_BASE_MIDI) / 12.0)
	_bass_player.play()


func trigger_chord(midis: Array, velocity: float) -> void:
	for midi in midis:
		var p: AudioStreamPlayer = _next_player(_chord_pool)
		p.volume_db = _chord_pool.db + linear_to_db(clampf(velocity, 0.05, 1.0))
		p.pitch_scale = pow(2.0, float(midi - PLUCK_BASE_MIDI) / 12.0)
		p.play()


func _make_pool(pool_stream: AudioStream, count: int, db: float) -> Dictionary:
	var players: Array = []
	for i in count:
		var p := AudioStreamPlayer.new()
		p.stream = pool_stream
		add_child(p)
		players.append(p)
	return {"players": players, "idx": 0, "db": db}


func _next_player(pool: Dictionary) -> AudioStreamPlayer:
	var p: AudioStreamPlayer = pool.players[pool.idx]
	pool.idx = (pool.idx + 1) % pool.players.size()
	return p


func _play_pooled(pool: Dictionary, velocity: float, pitch: float) -> void:
	var p := _next_player(pool)
	p.volume_db = pool.db + linear_to_db(clampf(velocity, 0.05, 1.0))
	p.pitch_scale = pitch
	p.play()
