class_name JamHistory
extends RefCounted

# Phase 2B: a small ring of per-loop committed snapshots so temporal features
# can be measured. This class only STORES {loop, state, features, versions} —
# all computation lives in pure JamFeatures functions, so candidate scoring and
# offline replay measure with exactly the same code.
#
# Two states with identical snapshot features are musically different if one
# just changed and the other has sat still for six loops; this is where a
# policy gets to see that.

const Features := preload("res://scripts/core/jam_features.gd")

const CAPACITY := 9 # covers the 4-loop lookback with slack
const TRACK_NAMES := ["drum", "bass", "chord"]

var entries: Array = [] # oldest..newest {loop:int, state:Dictionary, features:Dictionary, versions:Array}
var _last_change_loop := [-1, -1, -1]
var _first_loop := -1


## Record the committed state audible AT `loop`. versions = [drums, bass,
## chords] version counters; a counter change marks that track's change loop.
func push(loop: int, state: Dictionary, versions: Array) -> void:
	if not entries.is_empty() and loop <= entries.back().loop:
		return # monotonic: re-observing a loop is not new history
	if _first_loop < 0:
		_first_loop = loop
	if not entries.is_empty():
		var prev_versions: Array = entries.back().versions
		for t in 3:
			if int(versions[t]) != int(prev_versions[t]):
				_last_change_loop[t] = loop
	entries.append({
		"loop": loop,
		"state": state,
		"features": Features.extract(state),
		"versions": versions.duplicate(),
	})
	while entries.size() > CAPACITY:
		entries.pop_front()


## Temporal measurements for the newest snapshot: deltas vs the previous loop,
## event-overlap vs 1/2/4 loops ago (null when that loop wasn't observed —
## honesty over fabrication), and per-track change ages. Change ages are lower
## bounds: a bot only knows what it has watched, so with no change observed the
## age is the observed span so far.
func temporal() -> Dictionary:
	if entries.is_empty():
		return {}
	var newest: Dictionary = entries.back()
	var out := {}

	var prev := _at_loop(newest.loop - 1)
	if prev.is_empty():
		for k in Features.DELTA_KEYS:
			out[k + "_delta"] = 0.0
	else:
		out.merge(Features.compare(prev.features, newest.features))

	for lookback in [1, 2, 4]:
		var old := _at_loop(newest.loop - lookback)
		var sim = null
		if not old.is_empty():
			sim = Features.similarity(old.state, newest.state)
		out["drum_event_jaccard_prev_%d" % lookback] = sim.drums if sim != null else null
		out["bass_event_jaccard_prev_%d" % lookback] = sim.bass if sim != null else null
		out["chord_slot_match_prev_%d" % lookback] = sim.chords if sim != null else null

	for t in 3:
		var since: int
		if _last_change_loop[t] >= 0:
			since = newest.loop - _last_change_loop[t]
		else:
			since = newest.loop - _first_loop
		out["loops_since_%s_change" % TRACK_NAMES[t]] = since

	return out


## The stored state just BEFORE track t's last observed change (the "previous
## committed pattern"), or {} when no change was observed or the pre-change
## entry has been evicted — absent, not fabricated. Storage read only.
func state_before_change(t: int) -> Dictionary:
	if _last_change_loop[t] < 0:
		return {}
	return _at_loop(_last_change_loop[t] - 1).get("state", {})


func _at_loop(loop: int) -> Dictionary:
	for e in entries:
		if e.loop == loop:
			return e
	return {}
