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
const Renderer := preload("res://scripts/core/drum_renderer.gd")
const Templates := preload("res://scripts/core/drum_templates.gd")
const DrumState := preload("res://scripts/core/drum_state.gd")
const TrackOps := preload("res://scripts/core/track_ops.gd")
const BotObservation := preload("res://scripts/ai/bot_observation.gd")
const RuleBassPolicy := preload("res://scripts/ai/rule_bass_policy.gd")
const DecisionLog := preload("res://scripts/ai/decision_log.gd")

var passed := 0
var failed := 0


func _initialize() -> void:
	_test_pattern_editor()
	_test_commit_model()
	_test_bass_line()
	_test_chord_track()
	_test_harmony()
	_test_drum_renderer()
	_test_drum_templates()
	_test_drum_state()
	_test_lock_horizon()
	_test_bot_observation()
	_test_rule_bass_policy()
	_test_decision_log()
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


static func _mk_hit(voice: int, step: int, vel := 0.5, accent := false) -> Dictionary:
	return {"voice": voice, "step": step, "velocity": vel, "accent": accent}


static func _voices_of(hits: Array) -> Array:
	var out: Array = []
	for h in hits:
		out.append(h.voice)
	return out


func _test_drum_renderer() -> void:
	var full := [_mk_hit(0, 5), _mk_hit(1, 5), _mk_hit(2, 5), _mk_hit(3, 5)]

	# passthrough + non-destructive
	var out := Renderer.render_step(full, 5, 16, [], 0, false)
	check(_voices_of(out) == [0, 1, 2, 3], "no modifiers: passthrough, sorted by voice")
	out[0].velocity = 9.9
	check(full[0].velocity == 0.5, "render works on a copy, base untouched")

	# drop light removes hats/perc only
	var drop_light := [{"type": "drop", "start_loop": 0, "duration": 1, "strength": 0.4}]
	check(_voices_of(Renderer.render_step(full, 5, 16, drop_light, 0, false)) == [0, 1],
		"light drop removes hat+perc, keeps kick+snare")
	# drop heavy keeps only downbeat kick
	var drop_heavy := [{"type": "drop", "start_loop": 0, "duration": 1, "strength": 1.0}]
	check(_voices_of(Renderer.render_step(full, 0, 16, drop_heavy, 0, false)) == [0],
		"heavy drop keeps only the downbeat kick")
	check(Renderer.render_step(full, 5, 16, drop_heavy, 0, false).is_empty(),
		"heavy drop silences non-downbeat steps")
	# expired window ignored
	check(_voices_of(Renderer.render_step(full, 5, 16, drop_light, 2, false)) == [0, 1, 2, 3],
		"expired modifier stops applying on its own")

	# intensify: boost, accent when strong, ghost hat on odd steps
	var intensify := [{"type": "intensify", "start_loop": 0, "duration": 1, "strength": 0.8}]
	var boosted := Renderer.render_step([_mk_hit(0, 5)], 5, 16, intensify, 0, false)
	check(is_equal_approx(boosted[0].velocity, 0.7), "intensify lerps velocity toward 1 (0.5->0.7 at s=0.8)")
	check(boosted[0].accent, "strong intensify accents")
	check(_voices_of(boosted) == [0, 2], "ghost hat added on odd step")
	check(is_equal_approx(boosted[1].velocity, 0.3 + 0.2 * 0.8), "ghost hat velocity scales with strength")
	check(_voices_of(Renderer.render_step([_mk_hit(0, 4)], 4, 16, intensify, 0, false)) == [0],
		"no ghost hat on even steps")
	var weak := [{"type": "intensify", "start_loop": 0, "duration": 1, "strength": 0.4}]
	check(not Renderer.render_step([_mk_hit(0, 4)], 4, 16, weak, 0, false)[0].accent,
		"weak intensify does not accent")
	var base_hat := Renderer.render_step([_mk_hit(2, 5, 0.9)], 5, 16, intensify, 0, false)
	check(base_hat.size() == 1, "base hat takes precedence over ghost hat")

	# fill: turnaround only, snare {12,14,15}, hat {13,14,15}
	var fill := [{"type": "fill", "start_loop": 0, "duration": 1, "strength": 1.0}]
	check(_voices_of(Renderer.render_step([], 12, 16, fill, 0, true)) == [1], "fill snare at N-4")
	check(_voices_of(Renderer.render_step([], 13, 16, fill, 0, true)) == [2], "fill hat at N-3")
	check(_voices_of(Renderer.render_step([], 14, 16, fill, 0, true)) == [1, 2], "fill snare+hat at N-2")
	check(_voices_of(Renderer.render_step([], 15, 16, fill, 0, true)) == [1, 2], "fill snare+hat at N-1")
	check(Renderer.render_step([], 11, 16, fill, 0, true).is_empty(), "no fill before N-4")
	check(Renderer.render_step([], 14, 16, fill, 0, false).is_empty(), "fill only on the turnaround bar")

	# order: drop thins first, fill still lands on the turnaround
	var both := drop_heavy + fill
	check(_voices_of(Renderer.render_step(full, 15, 16, both, 0, true)) == [1, 2],
		"drop -> fill order: fill hits land after heavy drop clears the step")


func _test_drum_templates() -> void:
	check(Templates.count() == 4, "four starter templates")
	check(Templates.name_of(5) == Templates.name_of(1), "template index wraps")
	var bb = Templates.build(0)
	check(bb.find_hit_index(0, 0) >= 0 and bb.find_hit_index(0, 8) >= 0, "backbeat kicks on 0 and 8")
	check(bb.find_hit_index(1, 4) >= 0 and bb.find_hit_index(1, 12) >= 0, "backbeat snares on 4 and 12")
	for t in Templates.count():
		for h in Templates.build(t).hits:
			if h.voice > 3:
				check(false, "template %d leaks a bass-lane hit" % t)
	var fof = Templates.build(1)
	for step in [0, 4, 8, 12]:
		check(fof.find_hit_index(0, step) >= 0, "four-on-floor kick at %d" % step)


func _test_drum_state() -> void:
	var s = DrumState.new()
	s.press_drop(3)
	check(s.modifiers.size() == 1 and is_equal_approx(s.modifiers[0].strength, 0.4), "first drop is light")
	s.press_drop(3)
	check(s.modifiers.size() == 1 and is_equal_approx(s.modifiers[0].strength, 1.0), "second drop escalates, no stacking")
	s.press_intensify(3)
	s.press_intensify(3)
	check(s.modifiers.size() == 2 and s.modifiers[1].duration == 2, "repeat intensify extends the window")
	s.press_fill(3, 1, 4)
	check(s.modifiers[2].duration == 1, "fill mid-loop covers this loop's turnaround")
	s.press_fill(3, 1, 4)
	check(s.modifiers.size() == 3, "fill press ignored while one is active")
	var s2 = DrumState.new()
	s2.press_fill(3, 3, 4)
	check(s2.modifiers[0].duration == 2, "fill on the final bar auto-stretches to the next turnaround")
	s.prune(5)
	check(s.modifiers.size() == 0, "prune removes expired windows (intensify ends at loop 5)")
	s.cycle_kit(0)
	s.cycle_kit(0)
	s.cycle_kit(0)
	check(s.kit[0] == 0, "kit cycling wraps after 3 variants")
	s.cycle_kit(2)
	var round_trip = DrumState.new()
	round_trip.from_dict(s.to_dict())
	check(round_trip.kit == s.kit and round_trip.modifiers == s.modifiers, "drum state dict round-trips")
	round_trip.cycle_kit(2)
	check(round_trip.kit != s.kit, "round-tripped state is independent")


func _test_lock_horizon() -> void:
	var m = CommitModel.new(DrumPattern.new())
	var pend = m.begin_or_get_pending(5, 2) # inside the lock horizon: commit at N+2
	PatternEditor.toggle_hit(pend, 0, 0)
	check(m.commit_loop_index == 7, "lock horizon schedules commit at N+2")
	check(not m.try_commit_at_loop(6), "commit not due at N+1 under the horizon")
	check(m.try_commit_at_loop(7), "commit lands at N+2")
	# template op through the domain layer
	var m2 = CommitModel.new(DrumPattern.new())
	TrackOps.apply(m2, 0, "template", {"index": 1}, 0)
	check(m2.pending.hits == Templates.build(1).hits, "template op replaces the pending pattern")


# ---------------------------------------------------------------- Phase 1A: AI player

## Room-shaped test fixture: starter groove (kick 0/8, snares, hats), starter
## bass line, I-vi-IV-V chords — the same musical state a bot joining the
## default room would observe.
func _mk_models() -> Dictionary:
	var starter := DrumPattern.new()
	for kick_step in [0, 8]:
		PatternEditor.toggle_hit(starter, 0, kick_step)
	for snare_step in [4, 12]:
		PatternEditor.toggle_hit(starter, 1, snare_step)
	for hat_step in range(0, 16, 2):
		PatternEditor.toggle_hit(starter, 2, hat_step, 0.6)
	var line := BassLine.new()
	line.notes = {0: 0, 8: 0, 12: 4}
	var track := ChordTrack.new()
	track.slots = [0, 5, 3, 4]
	return {
		"drums": CommitModel.new(starter),
		"bass": CommitModel.new(line),
		"chords": CommitModel.new(track),
	}


func _mk_obs(models: Dictionary, target_loop: int, windows: int) -> Dictionary:
	return BotObservation.build_bass(models.bass, models.drums, models.chords, target_loop, windows)


## Mirror of JamNetSession._validate_cmd for [TRACK_BASS, "place"]: the policy
## must emit nothing a hostile-peer check would reject.
func _valid_bass_op(op: Dictionary) -> bool:
	if op.track != 1 or op.op != "place":
		return false
	var a: Dictionary = op.args
	return a.size() == 2 \
		and a.has("step") and typeof(a.step) == TYPE_INT and a.step >= 0 and a.step <= 15 \
		and a.has("degree") and typeof(a.degree) == TYPE_INT and a.degree >= 0 and a.degree <= 4


## Apply policy ops to a fresh commit model seeded with the observed line;
## returns the resulting pending notes (what would commit at the boundary).
func _apply_ops(obs: Dictionary, ops: Array) -> Dictionary:
	var line := BassLine.new()
	line.notes = obs.bass_notes.duplicate()
	var m = CommitModel.new(line)
	for op in ops:
		TrackOps.apply(m, 1, op.op, op.args, obs.target_loop - 1)
	return m.pending.notes if m.has_pending() else m.active.notes


func _test_bot_observation() -> void:
	var models := _mk_models()
	var obs := _mk_obs(models, 5, 2)
	check(obs.kick_steps == [0, 8], "observation extracts kick steps")
	check(obs.snare_steps == [4, 12], "observation extracts snare steps")
	check(obs.bass_notes == {0: 0, 8: 0, 12: 4}, "observation carries the bass line")
	check(obs.chord_slots == [0, 5, 3, 4], "observation carries chord slots")
	check(obs.target_loop == 5 and obs.windows_since_change == 2, "identity fields pass through")
	obs.bass_notes.erase(0)
	check(models.bass.active.notes.has(0), "observation is a copy, not a live reference")

	# Future-facing: a pending that commits by the target loop is what the bot
	# will coexist with; a later-committing pending is not.
	var pend = models.bass.begin_or_get_pending(4) # commits at loop 5
	pend.place_or_toggle(2, 3)
	check(_mk_obs(models, 5, 0).bass_notes.has(2), "pending committing at target loop is observed")
	models.bass.commit_loop_index = 6
	check(not _mk_obs(models, 5, 0).bass_notes.has(2), "pending committing after target loop is ignored")
	models.bass.cancel_pending()


func _test_rule_bass_policy() -> void:
	var models := _mk_models()
	var seed_value := DecisionLog.derive_seed(1234, 0, 1, 7)

	# Determinism: same observation + same seed -> byte-identical ops, always.
	var obs := _mk_obs(models, 7, 4)
	var a := RuleBassPolicy.decide(obs, seed_value)
	var b := RuleBassPolicy.decide(_mk_obs(models, 7, 4), seed_value)
	check(a == b, "same state + same seed -> exactly same ops")

	# A just-changed line always gets a window to breathe.
	check(RuleBassPolicy.decide(_mk_obs(models, 7, 0), seed_value).is_empty(),
		"windows_since_change 0 -> guaranteed hold")

	# Every emitted op must survive the server's hostile-peer validation.
	var stale_ops := RuleBassPolicy.decide(obs, seed_value)
	check(not stale_ops.is_empty(), "stale line (windows >= 3) forces a mutation")
	var all_valid := true
	for op in stale_ops:
		if not _valid_bass_op(op):
			all_valid = false
	check(all_valid, "all policy ops pass server-side validation shape")

	# Stale mutation moves exactly one note: same density, different line.
	var mutated := _apply_ops(obs, stale_ops)
	check(mutated.size() == obs.bass_notes.size(), "stale mutation preserves density")
	check(mutated != obs.bass_notes, "stale mutation actually changes the line")

	# Density steering: an empty line is rebuilt into the band...
	models.bass.active.notes = {}
	var fill_ops := RuleBassPolicy.decide(_mk_obs(models, 7, 1), seed_value)
	var filled := _apply_ops(_mk_obs(models, 7, 1), fill_ops)
	check(filled.size() >= RuleBassPolicy.DENSITY_MIN and filled.size() <= RuleBassPolicy.DENSITY_MAX,
		"empty line rebuilt into the density band")
	# ...and an overcrowded line is thinned into it.
	var crowded := {}
	for step in 12:
		crowded[step] = step % 5
	models.bass.active.notes = crowded
	var thin_ops := RuleBassPolicy.decide(_mk_obs(models, 7, 1), seed_value)
	var thinned := _apply_ops(_mk_obs(models, 7, 1), thin_ops)
	check(thinned.size() <= RuleBassPolicy.DENSITY_MAX, "overcrowded line thinned into the band")

	# Zero-op HOLD is a real outcome: a healthy, non-stale line must sometimes be
	# left alone (and sometimes edited) across seeds — space-leaving is data.
	models.bass.active.notes = {0: 0, 8: 0, 12: 4}
	var holds := 0
	var edits := 0
	for s in 40:
		var ops := RuleBassPolicy.decide(_mk_obs(models, 7, 1),
			DecisionLog.derive_seed(s, 0, 1, 7))
		if ops.is_empty():
			holds += 1
		else:
			edits += 1
	check(holds > 0, "healthy line: some seeds deliberately hold (leave space)")
	check(edits > 0, "healthy line: some seeds still edit")

	# Musicality floor: from empty, the chosen notes are chord tones of the loop's
	# harmony (I-vi-IV-V in degrees 0..4 admits 0,2,3,4 but never degree 1).
	var tonal := true
	for step in filled:
		if filled[step] == 1:
			tonal = false
	check(tonal, "rebuilt line avoids the one non-chord-tone degree")


func _test_decision_log() -> void:
	# Seed derivation: stable, and every key component matters.
	var s := DecisionLog.derive_seed(42, 0, 1, 10)
	check(s == DecisionLog.derive_seed(42, 0, 1, 10), "derived seed is stable")
	check(s != DecisionLog.derive_seed(42, 0, 1, 11), "target loop changes the seed")
	check(s != DecisionLog.derive_seed(42, 1, 1, 10), "room epoch changes the seed")
	check(s != DecisionLog.derive_seed(42, 0, 0, 10), "role changes the seed")
	check(s != DecisionLog.derive_seed(43, 0, 1, 10), "session seed changes the seed")

	var key := DecisionLog.make_key(0, 1, 10, 3)
	var frame := DecisionLog.build_frame(key, DecisionLog.SOURCE_RULE_BOT,
		"rule_bass", 1, s, {"bass_notes": {}}, [], 100, 250, 61.5)
	check(frame.result == "hold" and frame.ops == [], "zero-op window is a first-class HOLD frame")
	var edit_frame := DecisionLog.build_frame(key, DecisionLog.SOURCE_RULE_BOT,
		"rule_bass", 1, s, {}, [{"track": 1, "op": "place", "args": {"step": 0, "degree": 0}}], 100, 250, 61.5)
	check(edit_frame.result == "edit", "op-bearing window is an edit frame")
	check(frame.source == DecisionLog.SOURCE_RULE_BOT and frame.rng_seed == s
		and frame.decision_key == key, "frame carries source, seed, and decision key")

	# JSONL round-trip: header + decision + commit survive write/read.
	var log := DecisionLog.new()
	var meta := {"session_id": "coretest", "session_seed": 42, "room_epoch": 0, "peer_id": 1}
	check(log.open(meta, "user://test_decision_logs") == OK, "log file opens")
	log.write(frame)
	log.write(DecisionLog.build_commit(key, {"notes": {}}, 4, 12))
	log.close()
	var events := DecisionLog.read_events(log.path)
	check(events.size() == 3, "log holds session header + decision + commit")
	check(events[0].type == "session" and events[0].session_seed == 42, "header carries session meta")
	check(events[1].type == "decision" and events[1].result == "hold", "hold frame round-trips")
	check(events[2].type == "commit" and int(events[2].at_loop) == 12, "commit event round-trips")
	check(int(events[1].decision_key.target_loop) == int(events[2].decision_key.target_loop),
		"decision and commit join on the decision key")
	DirAccess.remove_absolute(log.path)


func _test_harmony() -> void:
	check(Harmony.degree_to_midi(60, 0) == 60, "degree 0 is the root")
	check(Harmony.degree_to_midi(60, 4) == 67, "degree 4 is the fifth")
	check(Harmony.degree_to_midi(60, 7) == 72, "degree 7 is root + octave")
	check(Harmony.triad_midi(60, 0) == [60, 64, 67], "I triad in C is C-E-G")
	check(Harmony.triad_midi(60, 5) == [69, 72, 76], "vi triad in C is A-C-E")
	check(Harmony.note_name(60) == "C4", "MIDI 60 is C4")
	check(Harmony.note_name(36) == "C2", "MIDI 36 is C2 (bass root)")
	check(Harmony.ROMAN.size() == 7, "seven roman numerals")
