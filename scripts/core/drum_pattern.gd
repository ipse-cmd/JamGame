class_name JamDrumPattern
extends RefCounted

# Mirrors Unreal Jammin's FJamDrumPattern: a step count plus a flat, deterministically
# ordered hit list. Editing goes exclusively through JamDrumPatternEditor, which keeps
# hits sorted by (voice, step) and enforces at most one hit per voice+step.
# Hit shape: { voice: int, step: int, velocity: float, accent: bool }

const NUM_VOICES := 4 # Kick, Snare, Hat, Perc (bass is its own ring, as in the Jammin room)

var num_steps: int = 16
var hits: Array = []


# clone/equals avoid the JamDrumPattern class_name on purpose: self-references need the
# editor's global class cache, which headless test runs don't have.
func clone():
	var p = get_script().new()
	p.num_steps = num_steps
	p.hits = hits.duplicate(true)
	return p


func equals(other) -> bool:
	return num_steps == other.num_steps and hits == other.hits


func to_dict() -> Dictionary:
	return {"num_steps": num_steps, "hits": hits.duplicate(true)}


func from_dict(d: Dictionary) -> void:
	num_steps = int(d.get("num_steps", 16))
	hits = d.get("hits", []).duplicate(true)


func find_hit_index(voice: int, step: int) -> int:
	for i in hits.size():
		if hits[i].voice == voice and hits[i].step == step:
			return i
	return -1


func hit_at(voice: int, step: int) -> Dictionary:
	var i := find_hit_index(voice, step)
	return hits[i] if i >= 0 else {}
