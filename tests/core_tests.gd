extends SceneTree

# Headless unit tests for the pure core (Jammin validation rule: every slice ends
# with validation). Run with:
#   godot --headless --path . --script res://tests/core_tests.gd
# Exit code 0 = all green. Uses preload only (no global class cache dependency).

const DrumPattern := preload("res://scripts/core/drum_pattern.gd")
const PatternEditor := preload("res://scripts/core/drum_pattern_editor.gd")
const CommitModel := preload("res://scripts/core/commit_model.gd")
const BassLine := preload("res://scripts/core/bass_line.gd")
const ChordTrack := preload("res://scripts/core/chord_track.gd")
const Harmony := preload("res://scripts/core/harmony.gd")

var passed := 0
var failed := 0


func _initialize() -> void:
	_test_pattern_editor()
	_test_commit_model()
	_test_bass_line()
	_test_chord_track()
	_test_harmony()
	print("TESTS: %d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func check(cond: bool, label: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: " + label)


func _test_pattern_editor() -> void:
	var p := DrumPattern.new()
	check(PatternEditor.toggle_hit(p, 2, 5), "toggle adds a hit")
	check(PatternEditor.toggle_hit(p, 0, 8), "toggle adds a second hit")
	check(p.hits.size() == 2, "two hits stored")
	check(p.hits[0].voice == 0 and p.hits[1].voice == 2, "hits sorted by (voice, step)")
	PatternEditor.toggle_hit(p, 0, 2)
	check(p.hits[0].step == 2 and p.hits[1].step == 8, "same-voice hits sorted by step")
	check(not PatternEditor.toggle_hit(p, 2, 5), "toggle removes an existing hit")
	check(p.find_hit_index(2, 5) == -1, "removed hit is gone")
	check(not PatternEditor.toggle_hit(p, 0, 99), "out-of-range step rejected")
	check(not PatternEditor.toggle_hit(p, 9, 0), "out-of-range voice rejected")
	check(PatternEditor.toggle_accent(p, 0, 8), "accent set on existing hit")
	check(not PatternEditor.toggle_accent(p, 3, 0), "accent on missing hit is a no-op")
	var q = p.clone()
	check(q.equals(p) and p.equals(q), "clone equals original")
	PatternEditor.toggle_hit(q, 3, 0)
	check(not q.equals(p), "clone diverges independently")
	PatternEditor.clear_voice(p, 0)
	check(p.hits.is_empty(), "clear_voice removed that voice's hits")
	PatternEditor.toggle_hit(p, 1, 1)
	PatternEditor.clear_all(p)
	check(p.hits.is_empty(), "clear_all empties the pattern")


func _test_commit_model() -> void:
	var m = CommitModel.new(DrumPattern.new())
	check(not m.has_pending(), "starts with no pending")
	check(not m.try_commit_at_loop(5), "commit with no pending is a no-op")

	# Edit during loop 3 -> scheduled for loop 4.
	var pend = m.begin_or_get_pending(3)
	check(m.has_pending() and m.commit_loop_index == 4, "first edit schedules commit at N+1")
	PatternEditor.toggle_hit(pend, 0, 0)
	check(m.active.hits.is_empty(), "active untouched while pending edited")
	check(m.begin_or_get_pending(3) == pend, "later edits coalesce into the same buffer")
	check(not m.try_commit_at_loop(3), "commit not due yet at loop N")
	check(m.try_commit_at_loop(4), "commit lands at loop N+1")
	check(m.active.hits.size() == 1 and not m.has_pending(), "pending promoted to active")
	check(m.version_id == 1 and m.version_history.size() == 1, "previous active archived, version bumped")

	# Identical pending commits nothing.
	m.begin_or_get_pending(4)
	check(not m.try_commit_at_loop(5), "unchanged pending drops without a version")
	check(m.version_id == 1 and not m.has_pending(), "no version for identical pending")

	# Cancel discards.
	var pend2 = m.begin_or_get_pending(5)
	PatternEditor.toggle_hit(pend2, 1, 4)
	m.cancel_pending()
	check(not m.try_commit_at_loop(6) and m.active.hits.size() == 1, "cancel discards the buffer")

	# History cap.
	for i in 8:
		var b = m.begin_or_get_pending(10 + i)
		PatternEditor.toggle_hit(b, 2, i)
		check(m.try_commit_at_loop(11 + i), "repeated commits land (round %d)" % i)
	check(m.version_history.size() == CommitModel.MAX_VERSIONS, "version history capped")


func _test_bass_line() -> void:
	var b := BassLine.new()
	check(b.place_or_toggle(0, 2) == "placed", "place on empty step")
	check(b.place_or_toggle(0, 4) == "retuned", "different degree re-tunes")
	check(b.notes[0] == 4, "re-tune stored the new degree")
	check(b.place_or_toggle(0, 4) == "removed", "same degree removes")
	check(not b.notes.has(0), "removed note gone (monophonic dict)")
	check(b.place_or_toggle(99, 0) == "", "out-of-range step rejected")
	check(b.place_or_toggle(0, 9) == "", "out-of-range degree rejected")
	b.place_or_toggle(3, 1)
	var c = b.clone()
	c.place_or_toggle(5, 0)
	check(not c.equals(b) and b.notes.size() == 1, "clone diverges independently")
	b.clear()
	check(b.notes.is_empty(), "clear empties the line")


func _test_chord_track() -> void:
	var t := ChordTrack.new()
	check(t.slots == [-1, -1, -1, -1], "starts empty")
	t.cycle_slot(0, 1)
	check(t.slots[0] == 0, "cycle up from empty lands on degree 0")
	t.cycle_slot(0, -1)
	check(t.slots[0] == -1, "cycle back down returns to empty")
	t.cycle_slot(1, -1)
	check(t.slots[1] == 6, "cycle down from empty wraps to degree 6")
	var u = t.clone()
	u.cycle_slot(2, 1)
	check(not u.equals(t), "clone diverges independently")
	u.clear_slot(2)
	check(u.equals(t), "clear_slot restores equality")


func _test_harmony() -> void:
	check(Harmony.degree_to_midi(60, 0) == 60, "degree 0 is the root")
	check(Harmony.degree_to_midi(60, 4) == 67, "degree 4 is the fifth")
	check(Harmony.degree_to_midi(60, 7) == 72, "degree 7 is root + octave")
	check(Harmony.triad_midi(60, 0) == [60, 64, 67], "I triad in C is C-E-G")
	check(Harmony.triad_midi(60, 5) == [69, 72, 76], "vi triad in C is A-C-E")
	check(Harmony.note_name(60) == "C4", "MIDI 60 is C4")
	check(Harmony.note_name(36) == "C2", "MIDI 36 is C2 (bass root)")
	check(Harmony.ROMAN.size() == 7, "seven roman numerals")
