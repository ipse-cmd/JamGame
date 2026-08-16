class_name JamAudioEngine
extends Node

# Audio boundary for the room. Two modes:
#
#  NATIVE (G2): the JamAudioStream GDExtension. The game thread submits triggers
#  stamped with ABSOLUTE sample numbers via schedule_*(); the native _mix() places
#  each onset at the exact sample offset inside whatever block it renders. This is
#  the seam where Jammin's DaisySP engine eventually lands.
#
#  LEGACY (G0 fallback, native class absent): pooled AudioStreamPlayers triggered
#  immediately — frame-quantized timing, kept only so the project still runs
#  without a compiled extension.

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
	if native:
		_setup_native()
	else:
		push_warning("JamAudioStream extension not found — falling back to legacy frame-quantized audio.")
		_setup_legacy()


func _setup_native() -> void:
	stream = ClassDB.instantiate("JamAudioStream")
	stream.set_voice_table(Voice.KICK, JamSampleFactory.kick_samples())
	stream.set_voice_table(Voice.SNARE, JamSampleFactory.snare_samples())
	stream.set_voice_table(Voice.HAT, JamSampleFactory.hat_samples())
	stream.set_voice_table(Voice.PERC, JamSampleFactory.perc_samples())
	stream.set_voice_table(Voice.BASS, JamSampleFactory.bass_samples())
	stream.set_voice_table(Voice.PLUCK, JamSampleFactory.pluck_samples())
	_player = AudioStreamPlayer.new()
	_player.stream = stream
	add_child(_player)
	_player.play()
	mix_rate = stream.get_mix_rate()
	_rate_ratio = float(JamSampleFactory.MIX_RATE) / mix_rate


# ---------------------------------------------------------------- native scheduled API

func sample_cursor() -> int:
	return stream.get_sample_cursor() if native else 0


func schedule_drum(at_sample: int, voice: int, velocity: float, accent: bool) -> void:
	var vel := maxf(velocity, ACCENT_FLOOR) if accent else velocity
	var gain: float = db_to_linear(channel_db[_drum_channel_names[voice]]) * clampf(vel, 0.05, 1.0)
	stream.schedule_trigger(at_sample, voice, gain, _rate_ratio, false)


func schedule_bass(at_sample: int, midi: int, velocity: float) -> void:
	var gain: float = db_to_linear(channel_db["bass"]) * clampf(velocity, 0.05, 1.0)
	var pitch: float = _rate_ratio * pow(2.0, float(midi - BASS_BASE_MIDI) / 12.0)
	# choke=true: monophonic by design — a new bass note cuts the previous one.
	stream.schedule_trigger(at_sample, Voice.BASS, gain, pitch, true)


func schedule_chord(at_sample: int, midis: Array, velocity: float) -> void:
	var gain: float = db_to_linear(channel_db["chords"]) * clampf(velocity, 0.05, 1.0)
	for midi in midis:
		var pitch: float = _rate_ratio * pow(2.0, float(midi - PLUCK_BASE_MIDI) / 12.0)
		stream.schedule_trigger(at_sample, Voice.PLUCK, gain, pitch, false)


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
