class_name JamDrumPatternEditor
extends RefCounted

# Pure pattern editing (Jammin D0): all mutations of a JamDrumPattern go through
# these static functions so the sorted-by-(voice, step) invariant and the
# one-hit-per-cell rule hold everywhere. No engine deps beyond RefCounted.
# Parameters are duck-typed (always a JamDrumPattern) so this file compiles even
# before the editor has built the global class cache (headless test runs).


## Toggle a hit at (voice, step). Returns true if a hit exists there afterwards.
static func toggle_hit(p, voice: int, step: int, velocity: float = 0.75) -> bool:
	if step < 0 or step >= p.num_steps or voice < 0 or voice >= p.NUM_VOICES:
		return false
	var i: int = p.find_hit_index(voice, step)
	if i >= 0:
		p.hits.remove_at(i)
		return false
	_insert_sorted(p, {"voice": voice, "step": step, "velocity": velocity, "accent": false})
	return true


## Toggle the accent flag on an existing hit. Returns the new accent state (false if no hit).
static func toggle_accent(p, voice: int, step: int) -> bool:
	var i: int = p.find_hit_index(voice, step)
	if i < 0:
		return false
	p.hits[i].accent = not p.hits[i].accent
	return p.hits[i].accent


static func clear_voice(p, voice: int) -> void:
	var kept: Array = []
	for h in p.hits:
		if h.voice != voice:
			kept.append(h)
	p.hits = kept


static func clear_all(p) -> void:
	p.hits = []


static func _insert_sorted(p, hit: Dictionary) -> void:
	var at: int = p.hits.size()
	for i in p.hits.size():
		var h: Dictionary = p.hits[i]
		if hit.voice < h.voice or (hit.voice == h.voice and hit.step < h.step):
			at = i
			break
	p.hits.insert(at, hit)
