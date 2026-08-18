class_name JamFeatures
extends RefCounted

# Phase 2A: objectively defensible MEASUREMENTS of a jam state. A tiny pure
# functional library over plain state dicts (to_dict() shapes) — no nodes, no
# autoloads, no live room — so the same code measures live state, hypothetical
# candidate states, and logged/replicated snapshots.
#
# Deliberately descriptive only: hat_density = 0.75 is a fact; energy = 0.72 is
# a design interpretation. Interpretations (energy/tension) belong in a later
# JamAnalysis.interpret layer that CONSUMES these features — keep the
# measurement/opinion boundary hard.

# v2: bass lanes became chord-relative (R/3/5/7/O). Bass pitch measurements
# split into two families answering different questions — SEMANTIC (what kind
# of bass behavior was written: lane fractions, lane entropy) and SOUNDING
# (what that behavior produces under this progression: the pattern virtually
# rendered across all chord slots through the SAME Harmony resolver the
# scheduler uses, so analysis can never disagree with the audio).
# v3: V2 bass lanes — 8-lane fractions (second/fourth/sixth join), entropy
# normalized over 8 lanes.
const FEATURES_SCHEMA := 3

const VOICE_KICK := 0
const VOICE_SNARE := 1
const VOICE_HAT := 2
const VOICE_PERC := 3
const NUM_VOICES := 4

const BASS_ROOT_MIDI := 36 # C2, matching the room's bass ring

# Preload, not class_name lookup — headless test runs have no global class cache.
const Harmony := preload("res://scripts/core/harmony.gd")


## state: {"drums": JamDrumPattern.to_dict(), "bass": JamBassLine.to_dict(),
## "chords": JamChordTrack.to_dict()}. Every value is a plain measurement.
static func extract(state: Dictionary) -> Dictionary:
	var drums: Dictionary = state.get("drums", {"num_steps": 16, "hits": []})
	var bass: Dictionary = state.get("bass", {"num_steps": 16, "notes": {}})
	var chords: Dictionary = state.get("chords", {"slots": [-1, -1, -1, -1]})
	var steps := int(drums.get("num_steps", 16))
	var hits: Array = drums.get("hits", [])
	var slots: Array = chords.get("slots", [-1, -1, -1, -1])
	# Normalize note keys to int: JSON-round-tripped states carry string keys,
	# and lexicographic step order ("12" < "8") would scramble interval math.
	var raw_notes: Dictionary = bass.get("notes", {})
	var notes := {}
	for k in raw_notes:
		notes[int(str(k))] = int(raw_notes[k])

	var voice_counts := [0, 0, 0, 0]
	var kick_steps := {}
	for h in hits:
		var v := int(h.voice)
		if v >= 0 and v < NUM_VOICES:
			voice_counts[v] += 1
		if v == VOICE_KICK:
			kick_steps[int(h.step)] = true

	var ordered_steps: Array = notes.keys()
	ordered_steps.sort()

	# SEMANTIC family: distribution over harmonic roles, chord-independent.
	var lane_counts := [0, 0, 0, 0, 0, 0, 0, 0]
	for s in ordered_steps:
		var lane := int(notes[s])
		if lane >= 0 and lane < lane_counts.size():
			lane_counts[lane] += 1
	var lane_entropy := 0.0
	if not notes.is_empty():
		for c in lane_counts:
			if c > 0:
				var p := float(c) / float(notes.size())
				lane_entropy -= p * log(p)
		lane_entropy /= log(float(lane_counts.size())) # normalize to 0..1

	# SOUNDING family: the one-bar motif virtually rendered across every chord
	# slot, in time order — the complete phrase the bass + harmony actually
	# produce. R R R R over G|Am|F|G is semantically static but sounds G A F G.
	var midis: Array = []
	for bar in slots.size():
		for s in ordered_steps:
			midis.append(Harmony.chord_tone_midi(BASS_ROOT_MIDI, int(slots[bar]), int(notes[s])))
	var pitch_sum := 0
	var pitch_min := 0
	var pitch_max := 0
	var interval_sum := 0
	var interval_max := 0
	var direction_changes := 0
	var last_sign := 0
	for i in midis.size():
		pitch_sum += midis[i]
		pitch_min = midis[i] if i == 0 else mini(pitch_min, midis[i])
		pitch_max = midis[i] if i == 0 else maxi(pitch_max, midis[i])
		if i > 0:
			var d: int = midis[i] - midis[i - 1]
			interval_sum += absi(d)
			interval_max = maxi(interval_max, absi(d))
			# Repeated pitches carry the previous direction; only a real reversal counts.
			if d != 0:
				if last_sign != 0 and signi(d) != last_sign:
					direction_changes += 1
				last_sign = signi(d)
	var interval_count := maxi(0, midis.size() - 1)

	var on_kick := 0
	for s in ordered_steps:
		if kick_steps.has(int(s)):
			on_kick += 1

	var slot_count := 0
	for d in slots:
		if int(d) >= 0:
			slot_count += 1

	var active_roles := 0
	if not hits.is_empty():
		active_roles += 1
	if not notes.is_empty():
		active_roles += 1
	if slot_count > 0:
		active_roles += 1

	return {
		"features_schema": FEATURES_SCHEMA,
		"steps": steps,
		"drum_density": float(hits.size()) / float(steps * NUM_VOICES),
		"kick_density": float(voice_counts[VOICE_KICK]) / float(steps),
		"snare_density": float(voice_counts[VOICE_SNARE]) / float(steps),
		"hat_density": float(voice_counts[VOICE_HAT]) / float(steps),
		"perc_density": float(voice_counts[VOICE_PERC]) / float(steps),
		"bass_density": float(notes.size()) / float(int(bass.get("num_steps", 16))),
		"bass_root_fraction": _lane_fraction(lane_counts, 0, notes.size()),
		"bass_second_fraction": _lane_fraction(lane_counts, 1, notes.size()),
		"bass_third_fraction": _lane_fraction(lane_counts, 2, notes.size()),
		"bass_fourth_fraction": _lane_fraction(lane_counts, 3, notes.size()),
		"bass_fifth_fraction": _lane_fraction(lane_counts, 4, notes.size()),
		"bass_sixth_fraction": _lane_fraction(lane_counts, 5, notes.size()),
		"bass_seventh_fraction": _lane_fraction(lane_counts, 6, notes.size()),
		"bass_octave_fraction": _lane_fraction(lane_counts, 7, notes.size()),
		"bass_lane_entropy": lane_entropy,
		"sounding_pitch_mean": float(pitch_sum) / float(midis.size()) if not midis.is_empty() else 0.0,
		"sounding_pitch_range": pitch_max - pitch_min,
		"sounding_mean_interval": float(interval_sum) / float(interval_count) if interval_count > 0 else 0.0,
		"sounding_max_interval": interval_max,
		"sounding_direction_change_rate": float(direction_changes) / float(interval_count - 1) if interval_count > 1 else 0.0,
		"kick_bass_alignment": float(on_kick) / float(maxi(1, notes.size())),
		"chord_slot_count": slot_count,
		"active_roles": active_roles,
	}


## Numeric features that make sense as deltas between two snapshots.
const DELTA_KEYS := [
	"drum_density", "kick_density", "snare_density", "hat_density", "perc_density",
	"bass_density", "bass_root_fraction", "bass_second_fraction", "bass_third_fraction",
	"bass_fourth_fraction", "bass_fifth_fraction", "bass_sixth_fraction",
	"bass_seventh_fraction", "bass_octave_fraction", "bass_lane_entropy",
	"sounding_pitch_mean", "sounding_pitch_range", "sounding_mean_interval",
	"sounding_max_interval", "sounding_direction_change_rate",
	"kick_bass_alignment", "chord_slot_count", "active_roles",
]


## Pure temporal comparison: how the measurements moved between two snapshots.
## Still measurement, not opinion — "+0.27 drum density" is a fact; whether it
## is a build is interpretation.
static func compare(prev: Dictionary, cur: Dictionary) -> Dictionary:
	var out := {}
	for k in DELTA_KEYS:
		out[k + "_delta"] = float(cur.get(k, 0)) - float(prev.get(k, 0))
	return out


## Pattern similarity between two states, per track and combined — the
## measurement behind any repetition/novelty signal. Jaccard over event sets
## (1.0 = identical, 0.0 = disjoint; two empty sets are identical). Named
## "jaccard"/"match" wherever these surface: overlap is a measurement,
## "repetition" is a judgment that belongs to a later interpretation layer.
static func similarity(a: Dictionary, b: Dictionary) -> Dictionary:
	var drums := _jaccard(_drum_set(a), _drum_set(b))
	var bass := _jaccard(_bass_set(a), _bass_set(b))
	var slots_a: Array = a.get("chords", {}).get("slots", [])
	var slots_b: Array = b.get("chords", {}).get("slots", [])
	var chords := 0.0
	var n := maxi(slots_a.size(), slots_b.size())
	if n == 0:
		chords = 1.0
	else:
		var same := 0
		for i in n:
			var va = int(slots_a[i]) if i < slots_a.size() else -1
			var vb = int(slots_b[i]) if i < slots_b.size() else -1
			if va == vb:
				same += 1
		chords = float(same) / float(n)
	return {
		"drums": drums,
		"bass": bass,
		"chords": chords,
		"mean": (drums + bass + chords) / 3.0,
	}


static func _lane_fraction(lane_counts: Array, lane: int, total: int) -> float:
	return float(lane_counts[lane]) / float(total) if total > 0 else 0.0


static func _drum_set(state: Dictionary) -> Dictionary:
	var out := {}
	for h in state.get("drums", {}).get("hits", []):
		out["%d:%d" % [int(h.voice), int(h.step)]] = true
	return out


static func _bass_set(state: Dictionary) -> Dictionary:
	var out := {}
	var notes: Dictionary = state.get("bass", {}).get("notes", {})
	for s in notes:
		out["%d:%d" % [int(str(s)), int(notes[s])]] = true
	return out


static func _jaccard(a: Dictionary, b: Dictionary) -> float:
	if a.is_empty() and b.is_empty():
		return 1.0
	var inter := 0
	for k in a:
		if b.has(k):
			inter += 1
	return float(inter) / float(a.size() + b.size() - inter)
