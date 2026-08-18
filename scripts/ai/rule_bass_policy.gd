class_name JamRuleBassPolicy
extends RefCounted

# Phase 1A: deliberately simple rule-based bass policy. state -> ops directly,
# NO intent layer (JamIntent arrives in Phase 3 and is verified against this
# baseline). Pure and deterministic: (observation, seed) fully determine the
# output — no wall clock, no global RNG, no engine access — so identical
# decisions fall out by construction on any peer, any transport speed.
#
# Output ops are exactly what a human bassist can send: TRACK_BASS "place"
# commands (place/retune/remove semantics per JamBassLine.place_or_toggle).
# The policy edits a DESIRED line, then diffs it against the observed line;
# the server validates the ops like anyone else's.

const POLICY_NAME := "rule_bass"
# v2: pure index remap for the V2 8-lane vocabulary — the policy still thinks
# in its original 5-tone space (R/3/5/7/O) and translates at the boundary, so
# its SOUNDING behavior is unchanged. The baseline stays frozen musically.
const POLICY_VERSION := 2

# Old internal lane -> V2 lane (R,3,5,7,O -> ladder indices 0,2,4,6,7) and a
# lossy inverse for foreign color notes (nearest chord tone downward).
const OLD_TO_NEW := [0, 2, 4, 6, 7]
const NEW_TO_OLD := [0, 0, 1, 1, 2, 2, 3, 4]

const TRACK_BASS := 1
const NUM_DEGREES := 5 # INTERNAL lanes: the original 5-tone space
const CHORD_TONES := [0, 2, 4] # (bass_degree - chord_degree) posmod 7 for root/third/fifth

const DENSITY_MIN := 3 # notes per 16-step bar
const DENSITY_MAX := 6
const STALE_WINDOWS := 3 # unchanged this many decision windows -> force a mutation
const MUTATE_PROB := 0.35 # healthy, non-stale line: chance to move one note (else HOLD)

# Candidate scoring weights (descriptive heuristics, not JamEvaluator — that
# separation arrives with Phase 2).
const W_HARMONIC := 0.35
const W_KICK := 0.25
const W_SPACING := 0.15
const W_ROOT_ANCHOR := 0.25


## (observation, seed) -> Array of {track, op, args}. Empty array = HOLD, which
## is a real decision and must still be logged as a zero-op DecisionFrame.
static func decide(obs: Dictionary, seed_value: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	# Boundary translation: observed V2 lanes -> internal 5-tone space (raw
	# kept so removals can emit the exact stored degree).
	var current := {}
	var raw := {}
	for k in obs.bass_notes:
		raw[int(str(k))] = int(obs.bass_notes[k])
		current[int(str(k))] = NEW_TO_OLD[clampi(int(obs.bass_notes[k]), 0, 7)]
	var windows: int = obs.windows_since_change

	# Rule 1: a line that just changed gets at least one window to breathe.
	if windows <= 0:
		return []

	var stale := windows >= STALE_WINDOWS
	var density := current.size()

	# Rule 2: a healthy, non-stale line is usually left alone — deliberately
	# leaving space is a decision, and it gets logged like any other.
	var must_act := stale or density < DENSITY_MIN or density > DENSITY_MAX
	if not must_act and rng.randf() >= MUTATE_PROB:
		return []

	var desired := current.duplicate()

	# Rule 3: steer density into the band.
	while desired.size() > DENSITY_MAX:
		_remove_worst(desired, obs)
	while desired.size() < DENSITY_MIN:
		if not _add_best(desired, obs, rng):
			break # board full (can't happen with DENSITY_MIN < 16, but stay total)

	# Rule 4: if density needed no steering, move one note so something audibly
	# changes (stale lines land here by construction — must_act skipped the hold
	# roll). Guaranteed real diff: the emptied slot can't be refilled.
	if desired == current and not desired.is_empty():
		var removed_step: int = _remove_worst(desired, obs)
		_add_best(desired, obs, rng, removed_step)

	return _diff_to_ops(current, desired, raw)


# ---------------------------------------------------------------- candidates

## Score a candidate (step, degree) against the observation. Deterministic.
static func score(obs: Dictionary, notes: Dictionary, step: int, degree: int) -> float:
	var s := 0.0

	# Harmonic fit: the bass bar repeats under every chord slot of the loop, so a
	# note is judged against ALL non-empty slots. Root of a chord beats third/fifth.
	var slots: Array = obs.chord_slots
	var sounding := 0
	var fit := 0.0
	for d in slots:
		if d < 0:
			continue
		sounding += 1
		var rel := posmod(degree - d, 7)
		if rel == 0:
			fit += 1.0
		elif rel in CHORD_TONES:
			fit += 0.6
	if sounding > 0:
		s += W_HARMONIC * fit / float(sounding)

	# Kick alignment: locking to the kick is the default bass instinct here.
	if step in obs.kick_steps:
		s += W_KICK

	# Spacing: crowding an occupied neighbor step reads as clutter at one bar.
	var steps: int = obs.steps_per_bar
	if notes.has(posmod(step - 1, steps)) or notes.has(posmod(step + 1, steps)):
		s -= W_SPACING

	# Downbeat anchor: step 0 strongly prefers the root of the loop's first chord.
	if step == 0 and slots.size() > 0 and slots[0] >= 0 and degree == posmod(slots[0], 7):
		s += W_ROOT_ANCHOR

	return s


## Add the best-scoring absent (step, degree); rng only tie-breaks among the
## near-best so different seeds phrase differently without ignoring the rules.
## Returns false if no free step. skip_step excludes the slot a mutation just
## emptied (forces the note to actually move).
static func _add_best(desired: Dictionary, obs: Dictionary, rng: RandomNumberGenerator, skip_step: int = -1) -> bool:
	var steps: int = obs.steps_per_bar
	var candidates: Array = []
	for step in steps:
		if desired.has(step) or step == skip_step:
			continue
		for degree in NUM_DEGREES:
			candidates.append({"step": step, "degree": degree, "s": score(obs, desired, step, degree)})
	if candidates.is_empty():
		return false
	candidates.sort_custom(func(a, b): return a.s > b.s if a.s != b.s else (a.step < b.step if a.step != b.step else a.degree < b.degree))
	var band_floor: float = candidates[0].s - 0.1
	var band := candidates.filter(func(c): return c.s >= band_floor)
	var pick: Dictionary = band[rng.randi_range(0, band.size() - 1)]
	desired[pick.step] = pick.degree
	return true


## Remove the worst-scoring existing note; returns its step.
static func _remove_worst(desired: Dictionary, obs: Dictionary) -> int:
	var worst_step := -1
	var worst := INF
	var steps: Array = desired.keys()
	steps.sort()
	for step in steps:
		var s := score(obs, desired, step, desired[step])
		if s < worst:
			worst = s
			worst_step = step
	desired.erase(worst_step)
	return worst_step


# ---------------------------------------------------------------- diffing

## Ops that transform `current` into `desired` under place_or_toggle semantics:
## absent->present = place, degree change = place (retune), present->absent =
## place SAME degree (toggle off). Emitted in ascending step order.
## raw: the OBSERVED V2 degrees per step — a removal must emit the exact
## stored degree (place-same = toggle off), which the lossy old-space round
## trip cannot reproduce for foreign color notes.
static func _diff_to_ops(current: Dictionary, desired: Dictionary, raw: Dictionary = {}) -> Array:
	var ops: Array = []
	var all_steps := {}
	for step in current:
		all_steps[step] = true
	for step in desired:
		all_steps[step] = true
	var ordered: Array = all_steps.keys()
	ordered.sort()
	for step in ordered:
		if desired.has(step) and not current.has(step):
			ops.append(_place(step, desired[step]))
		elif current.has(step) and not desired.has(step):
			ops.append(_place_raw(step, int(raw.get(step, OLD_TO_NEW[clampi(current[step], 0, 4)]))))
		elif current[step] != desired[step]:
			ops.append(_place(step, desired[step]))
	return ops


static func _place_raw(step: int, new_degree: int) -> Dictionary:
	return {"track": TRACK_BASS, "op": "place", "args": {"step": step, "degree": new_degree}}


static func _place(step: int, degree: int) -> Dictionary:
	# Boundary translation: internal 5-tone lane -> V2 lane on the wire.
	return {"track": TRACK_BASS, "op": "place",
		"args": {"step": step, "degree": OLD_TO_NEW[clampi(degree, 0, 4)]}}
