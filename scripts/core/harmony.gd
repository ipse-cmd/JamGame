class_name JamHarmony
extends RefCounted

# Minimal diatonic harmony math (major key only for the G0 spike). Pure and
# deterministic: degree indices in, MIDI notes out. The full HarmonyLibrary /
# vibe catalog port comes later (Phase G3).

const MAJOR_SCALE := [0, 2, 4, 5, 7, 9, 11]
const ROMAN := ["I", "ii", "iii", "IV", "V", "vi", "vii°"]
const NOTE_NAMES := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


## MIDI note for a 0-based diatonic degree above root_midi (degree 7 = root + octave).
static func degree_to_midi(root_midi: int, degree: int) -> int:
	@warning_ignore("integer_division")
	var octave: int = degree / 7
	return root_midi + 12 * octave + MAJOR_SCALE[degree % 7]


## Diatonic triad (root, third, fifth) for a 0-based degree, as MIDI notes.
static func triad_midi(root_midi: int, degree: int) -> Array:
	return [
		degree_to_midi(root_midi, degree),
		degree_to_midi(root_midi, degree + 2),
		degree_to_midi(root_midi, degree + 4),
	]


static func note_name(midi: int) -> String:
	@warning_ignore("integer_division")
	var octave: int = midi / 12 - 1
	return NOTE_NAMES[midi % 12] + str(octave)


static func pitch_class_name(midi: int) -> String:
	return NOTE_NAMES[midi % 12]
