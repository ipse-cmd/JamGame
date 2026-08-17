class_name JamGroove
extends RefCounted

# Groove/swing lens, ported from the Unreal original (JamGrooveLibrary/
# JamGrooveProcessor): per-step timing offsets + velocity multipliers applied
# at RENDER time — the lens never rewrites the pattern. Template values are
# per-step means extracted from the project's Ableton groove captures
# (refs/Grooves/*.agr.json), capture noise zeroed. Base is a literal no-op so
# players always have a straight reference.
#
# Offsets are in quarter-note beats (0.25 = one full 16th); each template's
# offset and velocity arrays cycle with independent periods. TIMING_AMOUNT
# and VELOCITY_AMOUNT are the blend knobs (Unreal defaults). Deterministic
# pure math — every peer derives identical offsets from the replicated
# template index, preserving peers-derive-identical-audio.
#
# Negative offsets (Trip) pull events EARLIER than their nominal step: the
# scheduler's lookahead (~250 ms) is far larger than the worst offset
# (~0.05 beat ≈ 27 ms at 112 BPM), satisfying the pinned
# max_negative_groove_offset constraint (docs/design/style-era-notes.md).

const TIMING_AMOUNT := 0.7
const VELOCITY_AMOUNT := 0.2

const TEMPLATES := [
	{"id": "Base", "name": "Base (straight)",
		"offsets": [0.0], "vel": [1.0]},
	{"id": "Shake3", "name": "Shake (16th swing)",
		"offsets": [0.0, 0.0494], "vel": [1.0, 0.148, 0.920, 0.275]},
	{"id": "Shake6", "name": "Shake heavy (swing)",
		"offsets": [0.0, 0.0825], "vel": [1.0, 0.153, 0.952, 0.285]},
	{"id": "Push3", "name": "Push (lay-back)",
		"offsets": [0.0, 0.0494, 0.0495, 0.0493], "vel": [1.0, 0.148, 0.920, 0.275]},
	{"id": "Trip3", "name": "Trip (triplet lurch)",
		"offsets": [0.0, -0.0505, 0.0995, 0.0493], "vel": [1.0, 0.153, 0.952, 0.285]},
	{"id": "Clave3", "name": "Clave (3-3-2)",
		"offsets": [0.0, 0.0497, 0.0994, 0.0, 0.0497, 0.0992, 0.0, 0.0493],
		"vel": [0.777, 0.189, 0.110, 0.622, 0.252, 0.110, 1.0, 0.370]},
]


static func template_name(index: int) -> String:
	return TEMPLATES[clampi(index, 0, TEMPLATES.size() - 1)].name


## Timing offset for a step, in quarter-note beats (already blended by amount).
static func offset_beats(index: int, step: int, amount := TIMING_AMOUNT) -> float:
	var t: Dictionary = TEMPLATES[clampi(index, 0, TEMPLATES.size() - 1)]
	var offsets: Array = t.offsets
	return float(offsets[posmod(step, offsets.size())]) * clampf(amount, 0.0, 1.0)


## The same offset converted to samples at the given tempo and mix rate.
static func offset_samples(index: int, step: int, bpm: float, mix_rate: float,
		amount := TIMING_AMOUNT) -> int:
	var beats := offset_beats(index, step, amount)
	return int(round(beats * (60.0 / maxf(1.0, bpm)) * mix_rate))


## Velocity through the lens: lerp toward velocity * step multiplier.
static func apply_velocity(velocity: float, index: int, step: int,
		amount := VELOCITY_AMOUNT) -> float:
	var t: Dictionary = TEMPLATES[clampi(index, 0, TEMPLATES.size() - 1)]
	var vels: Array = t.vel
	var v := clampf(velocity, 0.0, 1.0)
	var target := clampf(v * float(vels[posmod(step, vels.size())]), 0.0, 1.0)
	return lerpf(v, target, clampf(amount, 0.0, 1.0))
