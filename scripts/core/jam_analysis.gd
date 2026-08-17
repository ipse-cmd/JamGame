class_name JamAnalysis
extends RefCounted

# Phase 3A: the musical PERCEPTION layer. JamFeatures states facts
# (hat_density = 0.75); this layer holds the design opinions that turn facts
# into interpretation (energy = 0.72). Deliberately deterministic and
# interpretable — a pure function over a schema-4 JamObservation — so the same
# code serves UI meters, policy input, frame logging, and candidate scoring.
#
# The output is a VECTOR of contributors, never a single "tension" scalar:
# collapsing the vector is the consumer's decision (and losing it here would
# make a learned policy inherit our collapse). Two invariants the tests pin:
#   energy != tension            (a dense consonant groove is high-energy, calm)
#   change != repetition         (just-changed and never-changing are opposites)
#
# Contributors mean specific things:
#   energy                   how much musical activity/force exists
#   rhythmic_tension         WHERE events sit (offbeats, divergence), not how many
#   harmonic_tension         resolution pressure: bass tone color + chord function
#   density_tension          crowding — tracks dense SIMULTANEOUSLY, not activity
#   external_change_pressure someone else changed the jam recently (call to react)
#   self_change_pressure     I just changed my line (pressure NOT to re-change)
#   repetition_pressure      how long the material has gone without novelty
#
# external/self are separate outputs on purpose — folding them into one
# change_pressure would discard exactly what last_change_by (schema 4) bought.
# Known edge (documented, unimplemented): if own and foreign ops land in the
# same observed version transition, self/other is intrinsically ambiguous from
# the observer's view; "mixed" would be the honest fourth state if a test ever
# demonstrates it.

const ANALYSIS_SCHEMA := 1

# Normalization ceilings and weights: versioned design opinions, not facts.
const FULL_DRUM_DENSITY := 0.35 # hits/(steps*voices) considered "very busy"
const FULL_BASS_DENSITY := 0.5 # 8 of 16 steps
const FULL_MOTION_SEMITONES := 12.0
const CHANGE_HORIZON_LOOPS := 4.0 # a change this old no longer presses
const REPETITION_HORIZON_LOOPS := 8.0 # unchanged this long = full repetition

# Bass tone color (chord-relative lanes R 3 5 7 O): R/5 very stable, 3
# descriptive, 7 color/directional, O register not tension. Ordering matters,
# absolutes are tunable; lanes 2/4/6 will slot in without an API change.
const TONE_TENSION := [0.0, 0.25, 0.1, 0.7, 0.05]
# Diatonic function as resolution pressure (I ii iii IV V vi vii°) — not
# universal good/bad, just how strongly the harmony points somewhere.
const CHORD_TENSION := [0.0, 0.35, 0.3, 0.4, 0.65, 0.3, 0.9]

# External change weights per track: harmony and someone-touched-my-line are
# full calls to react; drum changes slightly less so for a bassist.
const EXTERNAL_WEIGHT := {"drum": 0.8, "bass": 1.0, "chord": 1.0}
# Repetition mix: the bassist cares most about its own line going stale.
const REPETITION_WEIGHT := {"bass": 0.5, "drum": 0.3, "chord": 0.2}


## Interpret a schema-4 observation (raw or from_json-rehydrated; string keys
## tolerated). Unobserved inputs (empty temporal, "none" attribution)
## contribute zero pressure — no information is never interpreted as pressure.
static func interpret(obs: Dictionary) -> Dictionary:
	var features: Dictionary = obs.get("features", {})
	var temporal: Dictionary = obs.get("temporal", {})
	if temporal == null:
		temporal = {}
	var lcb: Dictionary = obs.get("last_change_by", {})

	var notes := {}
	for k in obs.get("bass_notes", {}):
		notes[int(str(k))] = int(obs.bass_notes[k])
	var slots: Array = obs.get("chord_slots", [])

	# ---- energy: activity/force ----
	var f_drum := clampf(float(features.get("drum_density", 0.0)) / FULL_DRUM_DENSITY, 0.0, 1.0)
	var f_bass := clampf(float(features.get("bass_density", 0.0)) / FULL_BASS_DENSITY, 0.0, 1.0)
	var f_chords := clampf(float(features.get("chord_slot_count", 0)) / 4.0, 0.0, 1.0)
	var f_motion := clampf(float(features.get("sounding_mean_interval", 0.0)) / FULL_MOTION_SEMITONES, 0.0, 1.0)
	var energy := clampf(0.45 * f_drum + 0.3 * f_bass + 0.15 * f_chords + 0.10 * f_motion, 0.0, 1.0)

	# ---- rhythmic tension: placement, normalized per event ----
	var off_sum := 0.0
	var off_n := 0
	for list_key in ["kick_steps", "snare_steps", "hat_steps"]:
		for s in obs.get(list_key, []):
			off_sum += _offbeat_weight(int(s))
			off_n += 1
	for s in notes:
		off_sum += _offbeat_weight(int(s))
		off_n += 1
	var off_mean := off_sum / float(off_n) if off_n > 0 else 0.0
	var divergence := 0.0
	if not notes.is_empty() and not obs.get("kick_steps", []).is_empty():
		divergence = 1.0 - clampf(float(features.get("kick_bass_alignment", 0.0)), 0.0, 1.0)
	var rhythmic := clampf(0.7 * off_mean + 0.3 * divergence, 0.0, 1.0)

	# ---- harmonic tension: tone color + functional pressure ----
	var tone_mean := 0.0
	if not notes.is_empty():
		for s in notes:
			tone_mean += TONE_TENSION[clampi(notes[s], 0, TONE_TENSION.size() - 1)]
		tone_mean /= float(notes.size())
	var chord_mean := 0.0
	var chord_n := 0
	for d in slots:
		if int(d) >= 0:
			chord_mean += CHORD_TENSION[clampi(int(d), 0, CHORD_TENSION.size() - 1)]
			chord_n += 1
	chord_mean = chord_mean / float(chord_n) if chord_n > 0 else 0.0
	var harmonic := clampf(0.55 * tone_mean + 0.45 * chord_mean, 0.0, 1.0)

	# ---- density tension: pairwise crowding, not activity ----
	var density := clampf((f_drum * f_bass + f_bass * f_chords + f_drum * f_chords) / 3.0, 0.0, 1.0)

	# ---- change pressures: causal, from attribution + change ages ----
	var external := 0.0
	for t in ["drum", "bass", "chord"]:
		if lcb.get(t + "s", "none") == "other":
			var age = temporal.get("loops_since_%s_change" % t)
			if age != null:
				external = maxf(external,
					EXTERNAL_WEIGHT[t] * clampf(1.0 - float(age) / CHANGE_HORIZON_LOOPS, 0.0, 1.0))
	var self_pressure := 0.0
	if lcb.get("bass", "none") == "self":
		var bass_age = temporal.get("loops_since_bass_change")
		if bass_age != null:
			self_pressure = clampf(1.0 - float(bass_age) / CHANGE_HORIZON_LOOPS, 0.0, 1.0)

	# ---- repetition pressure: time without novelty (first, simple version) ----
	var repetition := 0.0
	for t in ["drum", "bass", "chord"]:
		var age = temporal.get("loops_since_%s_change" % t)
		if age != null:
			repetition += REPETITION_WEIGHT[t] * clampf(float(age) / REPETITION_HORIZON_LOOPS, 0.0, 1.0)
	repetition = clampf(repetition, 0.0, 1.0)

	return {
		"analysis_schema": ANALYSIS_SCHEMA,
		"energy": energy,
		"rhythmic_tension": rhythmic,
		"harmonic_tension": harmonic,
		"density_tension": density,
		"external_change_pressure": external,
		"self_change_pressure": self_pressure,
		"repetition_pressure": repetition,
	}


## Placement weight inside a 16-step bar: beats free, eighth offbeats mild,
## sixteenth offbeats strong. Independent of how MANY events there are.
static func _offbeat_weight(step: int) -> float:
	if step % 4 == 0:
		return 0.0
	if step % 2 == 0:
		return 0.5
	return 1.0
