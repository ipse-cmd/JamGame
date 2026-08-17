class_name JamBassLine
extends RefCounted

# Monophonic bass ring line (Jammin M-B0): the pattern stores only rhythm + a
# CHORD-RELATIVE tone index; sounding pitch is resolved at render time against
# the current bar's chord (Harmony.chord_tone_midi), so one stored motif follows
# the whole progression. One note per step by construction (Dictionary keyed by step).

const NUM_DEGREES := 5 # lanes = harmonic roles R / 3 / 5 / 7 / O against the bar's chord

var num_steps: int = 16
var notes: Dictionary = {} # step:int -> degree:int (0-based, 0..NUM_DEGREES-1)


# Untyped on purpose — class_name self-references need the editor's global class cache,
# which headless test runs don't have.
func clone():
	var b = get_script().new()
	b.num_steps = num_steps
	b.notes = notes.duplicate()
	return b


func equals(other) -> bool:
	return num_steps == other.num_steps and notes == other.notes


func to_dict() -> Dictionary:
	return {"num_steps": num_steps, "notes": notes.duplicate()}


func from_dict(d: Dictionary) -> void:
	num_steps = int(d.get("num_steps", 16))
	notes = d.get("notes", {}).duplicate()


## Jammin Enter semantics: place if empty, re-tune if different degree, remove if same.
## Returns "placed" | "retuned" | "removed" | "" (out of range).
func place_or_toggle(step: int, degree: int) -> String:
	if step < 0 or step >= num_steps or degree < 0 or degree >= NUM_DEGREES:
		return ""
	if notes.has(step):
		if notes[step] == degree:
			notes.erase(step)
			return "removed"
		notes[step] = degree
		return "retuned"
	notes[step] = degree
	return "placed"


func clear() -> void:
	notes = {}
