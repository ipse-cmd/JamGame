class_name JamSampleFactory
extends RefCounted

# Procedurally synthesizes the spike's drum/bass/pluck voices — no audio assets in the
# repo. Deterministic (fixed RNG seeds). The *_samples() functions return raw float PCM
# used as voice tables by the JamAudioStream GDExtension; the make_*() wrappers wrap the
# same PCM into AudioStreamWAV for the legacy (non-native) fallback path.

const MIX_RATE := 44100


static func kick_samples() -> PackedFloat32Array:
	var n := int(MIX_RATE * 0.35)
	var s := PackedFloat32Array()
	s.resize(n)
	var phase := 0.0
	for i in n:
		var t := float(i) / MIX_RATE
		var f: float = lerpf(160.0, 42.0, clampf(t / 0.08, 0.0, 1.0))
		phase += TAU * f / MIX_RATE
		var v := sin(phase) * exp(-t / 0.12)
		if i < 300:
			v += 0.25 * (1.0 - float(i) / 300.0) * sin(TAU * 1200.0 * t)
		s[i] = v
	return s


static func snare_samples() -> PackedFloat32Array:
	var n := int(MIX_RATE * 0.22)
	var s := PackedFloat32Array()
	s.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337
	for i in n:
		var t := float(i) / MIX_RATE
		var noise := rng.randf_range(-1.0, 1.0) * exp(-t / 0.045) * 0.8
		var tone := sin(TAU * 190.0 * t) * exp(-t / 0.06) * 0.5
		s[i] = noise + tone
	return s


static func hat_samples() -> PackedFloat32Array:
	var n := int(MIX_RATE * 0.09)
	var s := PackedFloat32Array()
	s.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var prev := 0.0
	for i in n:
		var t := float(i) / MIX_RATE
		var raw := rng.randf_range(-1.0, 1.0)
		var hp := raw - prev # crude one-pole high-pass
		prev = raw
		s[i] = hp * exp(-t / 0.022) * 0.9
	return s


static func perc_samples() -> PackedFloat32Array:
	var n := int(MIX_RATE * 0.25)
	var s := PackedFloat32Array()
	s.resize(n)
	var phase := 0.0
	for i in n:
		var t := float(i) / MIX_RATE
		var f: float = lerpf(185.0, 120.0, clampf(t / 0.15, 0.0, 1.0))
		phase += TAU * f / MIX_RATE
		s[i] = sin(phase) * exp(-t / 0.09)
	return s


## Bass note rendered at C2 (MIDI 36); other pitches come from playback rate.
static func bass_samples() -> PackedFloat32Array:
	return _tone_samples(65.406, 0.45, 0.18, [1.0, 0.35, 0.15])


## Chord pluck rendered at C4 (MIDI 60); other pitches come from playback rate.
static func pluck_samples() -> PackedFloat32Array:
	return _tone_samples(261.626, 0.6, 0.22, [1.0, 0.25, 0.12])


static func make_kick() -> AudioStreamWAV: return _to_wav(kick_samples())
static func make_snare() -> AudioStreamWAV: return _to_wav(snare_samples())
static func make_hat() -> AudioStreamWAV: return _to_wav(hat_samples())
static func make_perc() -> AudioStreamWAV: return _to_wav(perc_samples())
static func make_bass() -> AudioStreamWAV: return _to_wav(bass_samples())
static func make_pluck() -> AudioStreamWAV: return _to_wav(pluck_samples())


static func _tone_samples(freq: float, dur: float, decay_tau: float, partials: Array) -> PackedFloat32Array:
	var n := int(MIX_RATE * dur)
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t := float(i) / MIX_RATE
		var v := 0.0
		for p in partials.size():
			v += partials[p] * sin(TAU * freq * (p + 1) * t)
		var attack: float = clampf(t / 0.004, 0.0, 1.0)
		s[i] = v * attack * exp(-t / decay_tau) * 0.6
	return s


static func _to_wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		var v := int(clampf(samples[i], -1.0, 1.0) * 32767.0)
		bytes[i * 2] = v & 0xFF
		bytes[i * 2 + 1] = (v >> 8) & 0xFF
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.stereo = false
	wav.data = bytes
	return wav
