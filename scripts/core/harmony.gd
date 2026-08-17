class_name JamHarmony
extends RefCounted

# Minimal diatonic harmony math (major key only for the G0 spike). Pure and
# deterministic: degree indices in, MIDI notes out. The full HarmonyLibrary /
# vibe catalog port comes later (Phase G3).

const MAJOR_SCALE := [0, 2, 4, 5, 7, 9, 11]
const ROMAN := ["I", "ii", "iii", "IV", "V", "vi", "vii°"]
const NOTE_NAMES := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

# Chord-relative bass vocabulary: lane index -> harmonic function. Lanes select
# a role against the CURRENT BAR'S CHORD, not a fixed pitch, so one stored
# pattern follows the whole progression.
const BASS_TONE_NAMES := ["R", "3", "5", "7", "O"]
const BASS_TONE_OCTAVE := 4 # the one lane that isn't "stack another diatonic third"


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


## Chord-relative bass tone. Tones 0..3 (R/3/5/7) stack diatonic thirds on the
## chord's scale degree — the seventh is DIATONIC (derived from the key, no G7
## spelling needed). Tone 4 (O) is the chord root an octave up, so the invariant
## chord_tone_midi(c, 4) == chord_tone_midi(c, 0) + 12 always holds. An empty
## chord slot (degree -1) resolves against the tonic.
static func chord_tone_midi(root_midi: int, chord_degree: int, tone: int) -> int:
	var deg := maxi(0, chord_degree)
	if tone == BASS_TONE_OCTAVE:
		return degree_to_midi(root_midi, deg) + 12
	return degree_to_midi(root_midi, deg + 2 * tone)


static func note_name(midi: int) -> String:
	@warning_ignore("integer_division")
	var octave: int = midi / 12 - 1
	return NOTE_NAMES[midi % 12] + str(octave)


static func pitch_class_name(midi: int) -> String:
	return NOTE_NAMES[midi % 12]
