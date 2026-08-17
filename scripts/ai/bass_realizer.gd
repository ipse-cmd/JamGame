class_name JamBassRealizer
extends RefCounted

# Phase 3C: REALIZATION — turn an intent into several legal candidate edits,
# score them deterministically, and return the winner. The generator knows the
# op grammar; the evaluator knows what the intent is trying to achieve; NEITHER
# knows why the intent was chosen (that's 3B) or what is musically happening
# (that's 3A). Later, the evaluator is the swap point for style profiles (3D)
# and learned critics — candidates and the contract stay put.
#
# Determinism: everything is a pure function of (obs, intent, seed). Seeds only
# choose WITHIN a candidate (which step to strip, which tone to add); candidate
# order and evaluation are seed-free, so scoring is stable and ties resolve by
# generation order. Every emitted op passes the server's hostile-peer
# validation (bass place, step 0..15, degree 0..4).

const Features := preload("res://scripts/core/jam_features.gd")

const REALIZER_NAME := "bass_realizer"
const REALIZER_VERSION := 1

const TRACK_BASS := 1
const NUM_STEPS := 16
const TONE_R := 0
const TONE_3 := 1
const TONE_5 := 2
const TONE_7 := 3
const TONE_O := 4
const BEATS := [0, 4, 8, 12]
const DENSITY_MIN := 3 # same band the frozen baseline holds — a shared house style
const DENSITY_MAX := 6
const MAX_REVERT_OPS := 8


## Produce the chosen edit for an intent. Returns
## {intent, candidate, ops, scores: [{name, score}]} — ops empty = HOLD.
static func realize(obs: Dictionary, intent: String, seed_value: int) -> Dictionary:
	var cands := candidates(obs, intent, seed_value)
	var scores: Array = []
	var best = null
	for c in cands:
		var s := evaluate(obs, intent, c)
		scores.append({"name": c.name, "score": s})
		if best == null or s > best.score:
			best = {"name": c.name, "ops": c.ops, "score": s}
	if best == null:
		best = {"name": "hold", "ops": [], "score": 0.0}
	return {"intent": intent, "candidate": best.name, "ops": best.ops, "scores": scores}


## Candidate sets per intent. Every set includes "hold" — a bandmate may
## conclude the line already serves the intent. Sets are small and legal by
## construction; empty lines are handled (candidates that need notes skip).
static func candidates(obs: Dictionary, intent: String, seed_value: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var notes := _notes(obs)
	var kicks := _int_list(obs.get("kick_steps", []))
	var out: Array = [{"name": "hold", "ops": []}]
	match intent:
		"RESPOND":
			_add(out, "anchor_root", _anchor_root(notes))
			_add(out, "add_seventh", _place_on_empty(notes, rng, _offbeats_first(), TONE_7))
			_add(out, "align_kick", _align_kick(notes, kicks, rng))
			_add(out, "recolor", _retune_one(notes, rng))
		"SIMPLIFY":
			_add(out, "strip_offbeat", _strip_offbeats(notes, kicks, rng, 2))
			_add(out, "to_root_five", _to_root_five(notes, rng, 2))
			_add(out, "strip_to_band", _strip_to_band(notes, kicks, rng))
		"INTENSIFY":
			_add(out, "add_root_beat", _place_on_empty(notes, rng, BEATS, TONE_R))
			_add(out, "add_kick_double", _align_kick(notes, kicks, rng))
			_add(out, "add_octave_lift", _place_on_empty(notes, rng, [14, 15, 13], TONE_O))
		"VARY":
			_add(out, "move_note", _move_one(notes, rng))
			_add(out, "retune_note", _retune_one(notes, rng))
			_add(out, "breathe_or_add", _breathe_or_add(notes, rng))
		"REVERT":
			_add(out, "restore_prev", _restore(notes, obs.get("bass_notes_prev")))
	return out


## Deterministic rule evaluator (the 3D/3E swap point). Simulates the candidate
## against the observed state and scores with the SAME pure measurements the
## rest of the stack uses — no private music model.
static func evaluate(obs: Dictionary, intent: String, cand: Dictionary) -> float:
	if cand.ops.is_empty():
		return 0.0 # hold baseline: others must earn their edit
	var notes := _notes(obs)
	var new_notes := _simulate(notes, cand.ops)
	var kicks := _int_list(obs.get("kick_steps", []))
	var old_n := notes.size()
	var new_n := new_notes.size()

	var score := 0.0
	# House style: stay inside the density band (shared with the baseline).
	if new_n >= DENSITY_MIN and new_n <= DENSITY_MAX:
		score += 0.5
	else:
		score -= 0.4 * absf(float(new_n) - clampf(float(new_n), DENSITY_MIN, DENSITY_MAX))
	# Locking with the kick is generally good for a bass.
	score += 0.4 * _alignment(new_notes, kicks)

	match intent:
		"RESPOND":
			# Reconnect to the (changed) context: ground the downbeat, allow color.
			if new_notes.get(0, -1) == TONE_R:
				score += 0.5
			if _has_tone(new_notes, TONE_7) and not _has_tone(notes, TONE_7):
				score += 0.2
		"SIMPLIFY":
			score += 0.8 * float(old_n - new_n) # thinner is the point
			score += 0.3 * (_stable_fraction(new_notes) - _stable_fraction(notes))
		"INTENSIFY":
			score += 0.8 * float(new_n - old_n)
		"VARY":
			score += 1.0 * (1.0 - _jaccard(notes, new_notes)) # novelty is the point
		"REVERT":
			score += 1.0 # single purposeful candidate
	return score


# ------------------------------------------------------------- candidate ops

static func _anchor_root(notes: Dictionary) -> Array:
	if notes.get(0, -1) == TONE_R:
		return []
	return [_op(0, TONE_R)]


static func _place_on_empty(notes: Dictionary, rng: RandomNumberGenerator, preferred: Array, tone: int) -> Array:
	var empty: Array = []
	for s in preferred:
		if not notes.has(s):
			empty.append(s)
	if empty.is_empty():
		for s in NUM_STEPS:
			if not notes.has(s):
				empty.append(s)
	if empty.is_empty():
		return []
	return [_op(empty[rng.randi() % empty.size()], tone)]


static func _align_kick(notes: Dictionary, kicks: Array, rng: RandomNumberGenerator) -> Array:
	var open: Array = []
	for s in kicks:
		if not notes.has(s):
			open.append(s)
	if open.is_empty():
		return []
	return [_op(open[rng.randi() % open.size()], TONE_R)]


static func _retune_one(notes: Dictionary, rng: RandomNumberGenerator) -> Array:
	if notes.is_empty():
		return []
	var steps := _sorted_steps(notes)
	var s: int = steps[rng.randi() % steps.size()]
	var tones := [TONE_R, TONE_3, TONE_5, TONE_7, TONE_O]
	tones.erase(int(notes[s]))
	return [_op(s, tones[rng.randi() % tones.size()])]


static func _strip_offbeats(notes: Dictionary, kicks: Array, rng: RandomNumberGenerator, count: int) -> Array:
	# Weakest first: offbeat notes not sitting on a kick.
	var weak: Array = []
	for s in _sorted_steps(notes):
		if not BEATS.has(int(s)) and not kicks.has(int(s)):
			weak.append(s)
	if weak.is_empty():
		return []
	var ops: Array = []
	for i in mini(count, weak.size()):
		var idx := rng.randi() % weak.size()
		var s: int = weak.pop_at(idx)
		ops.append(_op(s, int(notes[s]))) # place same degree = remove
	return ops


static func _to_root_five(notes: Dictionary, rng: RandomNumberGenerator, count: int) -> Array:
	var colored: Array = []
	for s in _sorted_steps(notes):
		if int(notes[s]) == TONE_3 or int(notes[s]) == TONE_7:
			colored.append(s)
	if colored.is_empty():
		return []
	var ops: Array = []
	for i in mini(count, colored.size()):
		var idx := rng.randi() % colored.size()
		var s: int = colored.pop_at(idx)
		ops.append(_op(s, TONE_R if BEATS.has(int(s)) else TONE_5))
	return ops


static func _strip_to_band(notes: Dictionary, kicks: Array, rng: RandomNumberGenerator) -> Array:
	var excess := notes.size() - DENSITY_MAX
	if excess <= 0:
		return []
	var removable: Array = []
	for s in _sorted_steps(notes):
		if not kicks.has(int(s)):
			removable.append(s)
	var ops: Array = []
	for i in mini(mini(excess, 3), removable.size()):
		var idx := rng.randi() % removable.size()
		var s: int = removable.pop_at(idx)
		ops.append(_op(s, int(notes[s])))
	return ops


static func _move_one(notes: Dictionary, rng: RandomNumberGenerator) -> Array:
	if notes.is_empty():
		return []
	var steps := _sorted_steps(notes)
	var from: int = steps[rng.randi() % steps.size()]
	var empty: Array = []
	for s in NUM_STEPS:
		if not notes.has(s):
			empty.append(s)
	if empty.is_empty():
		return []
	var to: int = empty[rng.randi() % empty.size()]
	return [_op(from, int(notes[from])), _op(to, int(notes[from]))]


static func _breathe_or_add(notes: Dictionary, rng: RandomNumberGenerator) -> Array:
	if notes.size() >= DENSITY_MAX:
		return _strip_offbeats(notes, [], rng, 1)
	var tones := [TONE_R, TONE_5, TONE_O]
	return _place_on_empty(notes, rng, _offbeats_first(), tones[rng.randi() % tones.size()])


static func _restore(notes: Dictionary, prev) -> Array:
	if prev == null:
		return []
	var target := {}
	for k in prev:
		target[int(str(k))] = int(prev[k])
	var ops: Array = []
	for s in _sorted_steps(notes):
		if not target.has(int(s)):
			ops.append(_op(int(s), int(notes[s]))) # remove extras
	for s in target:
		if int(notes.get(s, -1)) != target[s]:
			ops.append(_op(s, target[s])) # re-place missing / retune changed
	if ops.size() > MAX_REVERT_OPS:
		ops.resize(MAX_REVERT_OPS) # partial revert beats a flood; next window continues
	return ops


# ---------------------------------------------------------------- utilities

static func _op(step: int, degree: int) -> Dictionary:
	return {"track": TRACK_BASS, "op": "place", "args": {"step": step, "degree": degree}}


static func _add(out: Array, name: String, ops: Array) -> void:
	if not ops.is_empty():
		out.append({"name": name, "ops": ops})


static func _notes(obs: Dictionary) -> Dictionary:
	var out := {}
	for k in obs.get("bass_notes", {}):
		out[int(str(k))] = int(obs.bass_notes[k])
	return out


static func _int_list(a: Array) -> Array:
	var out: Array = []
	for v in a:
		out.append(int(v))
	return out


static func _sorted_steps(notes: Dictionary) -> Array:
	var s := notes.keys()
	s.sort()
	return s


static func _offbeats_first() -> Array:
	return [6, 14, 2, 10, 3, 7, 11, 15, 1, 5, 9, 13]


static func _simulate(notes: Dictionary, ops: Array) -> Dictionary:
	var out := notes.duplicate()
	for o in ops:
		var s := int(o.args.step)
		var d := int(o.args.degree)
		if out.has(s):
			if int(out[s]) == d:
				out.erase(s) # place same degree = remove
			else:
				out[s] = d
		else:
			out[s] = d
	return out


static func _alignment(notes: Dictionary, kicks: Array) -> float:
	if notes.is_empty():
		return 0.0
	var on := 0
	for s in notes:
		if kicks.has(int(s)):
			on += 1
	return float(on) / float(notes.size())


static func _has_tone(notes: Dictionary, tone: int) -> bool:
	for s in notes:
		if int(notes[s]) == tone:
			return true
	return false


static func _stable_fraction(notes: Dictionary) -> float:
	if notes.is_empty():
		return 0.0
	var stable := 0
	for s in notes:
		if int(notes[s]) == TONE_R or int(notes[s]) == TONE_5 or int(notes[s]) == TONE_O:
			stable += 1
	return float(stable) / float(notes.size())


static func _jaccard(a: Dictionary, b: Dictionary) -> float:
	if a.is_empty() and b.is_empty():
		return 1.0
	var inter := 0
	for s in a:
		if b.has(s) and int(b[s]) == int(a[s]):
			inter += 1
	return float(inter) / float(a.size() + b.size() - inter)
