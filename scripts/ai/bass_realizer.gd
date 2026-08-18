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
const StylePrior := preload("res://scripts/ai/style_prior.gd")

const REALIZER_NAME := "bass_realizer"
const REALIZER_VERSION := 1

const TRACK_BASS := 1
const NUM_STEPS := 16
# Motif/riff bank: the player's own committed lines, harvested from human
# session logs (tools/corpus/harvest_riffs.py) — rights-clean, chord-relative
# by construction, quality-filtered by dwell. Bank candidates flow through
# the SAME evaluator + style prior as everything else; the bank proposes,
# it never decides.
const BANK_PATH := "res://data/pattern_bank.json"
const MAX_PATTERN_OPS := 8
# V2 lane indices (full diatonic ladder R 2 3 4 5 6 7 O). The candidate
# GENERATOR deliberately gains no 2/4/6-specific candidates — color tones
# enter only through the existing retune/recolor tone pool, and the style
# prior's corpus x2/x4/x6 distributions decide when they win (pre-registered
# experiment: docs/design/v2-lanes-experiment.md).
const TONE_R := 0
const TONE_2 := 1
const TONE_3 := 2
const TONE_4 := 3
const TONE_5 := 4
const TONE_6 := 5
const TONE_7 := 6
const TONE_O := 7
const ALL_TONES := [0, 1, 2, 3, 4, 5, 6, 7]
const BEATS := [0, 4, 8, 12]
const DENSITY_MIN := 3 # same band the frozen baseline holds — a shared house style
const DENSITY_MAX := 6
const MAX_REVERT_OPS := 8


## Produce the chosen edit for an intent, optionally biased by a style prior
## (3E). style_bass = a profile's bass section or null; w_style scales its
## capped, per-event-normalized fit. Invariants (pinned): null profile or
## w_style == 0 -> byte-identical to the interaction-only decision; the style
## scorer never creates ops and never alters the candidate set; BOTH rankings
## are computed from the SAME candidates and returned (the ablation is in
## every log line).
static func realize(obs: Dictionary, intent: String, seed_value: int,
		style_bass = null, w_style := 0.0, style_interaction = null) -> Dictionary:
	var cands := candidates(obs, intent, seed_value)
	var scores: Array = []
	var best = null # styled winner (== interaction winner when style is inert)
	var best_plain = null
	for c in cands:
		var interaction := evaluate(obs, intent, c)
		var final := interaction
		var entry := {"name": c.name, "score": interaction}
		if c.has("pattern_id"):
			entry["pattern_id"] = c.pattern_id
		if style_bass != null and w_style > 0.0 and not c.ops.is_empty():
			var style = StylePrior.score_bass(style_bass, _simulate(_notes(obs), c.ops),
				obs.get("chord_slots", []), obs.get("kick_steps", []), style_interaction)
			if style != null:
				entry["style"] = style
				final = interaction + w_style * style.combined
		entry["final"] = final
		scores.append(entry)
		if best == null or final > best.score:
			best = {"name": c.name, "ops": c.ops, "score": final,
				"pattern_id": c.get("pattern_id", null)}
		if best_plain == null or interaction > best_plain.score:
			best_plain = {"name": c.name, "score": interaction}
	if best == null:
		best = {"name": "hold", "ops": [], "score": 0.0}
		best_plain = {"name": "hold", "score": 0.0}
	return {
		"intent": intent,
		"candidate": best.name,
		"ops": best.ops,
		"pattern_id": best.get("pattern_id", null),
		"scores": scores,
		"interaction_choice": best_plain.name,
		"style_disagreement": best.name != best_plain.name,
	}


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
			_add_pattern(out, "bank_pattern", _bank_pattern(notes, rng))
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
			# Motif identity: if the current line belongs to a harvested motif,
			# VARY can mean "same idea, another variant" — repetition becomes
			# musical identity instead of random cell mutation.
			_add_pattern(out, "motif_variant", _motif_variant(notes, rng))
			_add_pattern(out, "bank_pattern", _bank_pattern(notes, rng))
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
	var tones := ALL_TONES.duplicate()
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
		if not [TONE_R, TONE_5, TONE_O].has(int(notes[s])):
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
	var ops := _diff_to(notes, _bank_notes(prev))
	if ops.size() > MAX_REVERT_OPS:
		ops.resize(MAX_REVERT_OPS) # partial revert beats a flood; next window continues
	return ops


## Ops transforming `notes` into exactly `target` (both int-keyed). Sorted
## iteration keeps the op sequence deterministic.
static func _diff_to(notes: Dictionary, target: Dictionary) -> Array:
	var ops: Array = []
	for s in _sorted_steps(notes):
		if not target.has(int(s)):
			ops.append(_op(int(s), int(notes[s]))) # remove extras
	for s in _sorted_steps(target):
		if int(notes.get(int(s), -1)) != int(target[s]):
			ops.append(_op(int(s), int(target[s]))) # place missing / retune changed
	return ops


# ---------------------------------------------------------------- riff bank

static var _bank = null
static var _bank_loaded := false


static func _pattern_bank():
	if not _bank_loaded:
		_bank_loaded = true
		var text := FileAccess.get_file_as_string(BANK_PATH)
		var parsed = JSON.parse_string(text) if text != "" else null
		_bank = parsed if parsed is Dictionary and parsed.has("motifs") else null
	return _bank


static func _bank_notes(raw: Dictionary) -> Dictionary:
	var out := {}
	for k in raw:
		out[int(str(k))] = int(raw[k])
	return out


## Same motif, another variant: only offered when the current line actually
## belongs to a harvested motif (>= 0.5 event overlap with one of its variants).
static func _motif_variant(notes: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var bank = _pattern_bank()
	if bank == null or notes.is_empty():
		return {}
	for m in bank.motifs:
		if m.variants.size() < 2:
			continue
		var member := false
		for v in m.variants:
			if _jaccard(notes, _bank_notes(v.notes)) >= 0.5:
				member = true
				break
		if not member:
			continue
		var options: Array = []
		for i in m.variants.size():
			var vn := _bank_notes(m.variants[i].notes)
			if vn != notes:
				var ops := _diff_to(notes, vn)
				if not ops.is_empty() and ops.size() <= MAX_PATTERN_OPS:
					options.append({"ops": ops, "id": "%s#%d" % [m.id, i]})
		if not options.is_empty():
			return options[rng.randi() % options.size()]
	return {}


## Any bank line reachable within the op cap — a known-good idea as a candidate.
static func _bank_pattern(notes: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var bank = _pattern_bank()
	if bank == null:
		return {}
	var options: Array = []
	for m in bank.motifs:
		for i in m.variants.size():
			var vn := _bank_notes(m.variants[i].notes)
			if vn == notes:
				continue
			var ops := _diff_to(notes, vn)
			if not ops.is_empty() and ops.size() <= MAX_PATTERN_OPS:
				options.append({"ops": ops, "id": "%s#%d" % [m.id, i]})
	if options.is_empty():
		return {}
	return options[rng.randi() % options.size()]


static func _add_pattern(out: Array, name: String, pick: Dictionary) -> void:
	if not pick.is_empty():
		out.append({"name": name, "ops": pick.ops, "pattern_id": pick.id})


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
		if [TONE_R, TONE_5, TONE_O].has(int(notes[s])):
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
