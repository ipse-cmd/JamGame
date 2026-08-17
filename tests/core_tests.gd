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
const Groove := preload("res://scripts/core/jam_groove.gd")
const ChordComp := preload("res://scripts/core/chord_comp.gd")
const Renderer := preload("res://scripts/core/drum_renderer.gd")
const Templates := preload("res://scripts/core/drum_templates.gd")
const DrumState := preload("res://scripts/core/drum_state.gd")
const TrackOps := preload("res://scripts/core/track_ops.gd")
const BotObservation := preload("res://scripts/ai/bot_observation.gd")
const RuleBassPolicy := preload("res://scripts/ai/rule_bass_policy.gd")
const DecisionLog := preload("res://scripts/ai/decision_log.gd")
const BotPeer := preload("res://scripts/ai/bot_peer.gd")
const Features := preload("res://scripts/core/jam_features.gd")
const Analysis := preload("res://scripts/core/jam_analysis.gd")
const IntentPolicy := preload("res://scripts/ai/intent_policy.gd")
const Realizer := preload("res://scripts/ai/bass_realizer.gd")
const StylePrior := preload("res://scripts/ai/style_prior.gd")
const IntentBassPolicy := preload("res://scripts/ai/intent_bass_policy.gd")
const History := preload("res://scripts/core/jam_history.gd")
const HumanRecorder := preload("res://scripts/ai/human_recorder.gd")
const StepRing := preload("res://scripts/ui/step_ring.gd")
const ChordStrip := preload("res://scripts/ui/chord_strip.gd")
const RadialBloom := preload("res://scripts/ui/radial_bloom.gd")

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
	_test_groove_and_mixer()
	_test_chord_comp()
	_test_lock_horizon()
	_test_bot_observation()
	_test_rule_bass_policy()
	_test_decision_log()
	_test_bot_peer()
	_test_jam_features()
	_test_temporal_features()
	_test_observation_contract()
	_test_jam_analysis()
	_test_intent_policy()
	_test_bass_realizer()
	_test_style_prior()
	_test_pattern_bank()
	_test_intent_bass_policy()
	_test_pointer_picking()
	_test_human_recorder()
	_test_shadow_bot()
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

	# Direct set (radial picker path): idempotent, range-guarded.
	t.set_slot(2, 4)
	check(t.slots[2] == 4, "set_slot assigns directly")
	t.set_slot(2, 4)
	check(t.slots[2] == 4, "set_slot is idempotent")
	t.set_slot(2, 7)
	t.set_slot(2, -1)
	t.set_slot(9, 3)
	check(t.slots[2] == 4, "out-of-range set_slot is ignored (reject, never repair)")


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

	# JSON replay round-trip: an observation that went through the decision log
	# (string keys, floats) must reproduce the same ops after rehydration.
	models.bass.active.notes = {0: 0, 8: 0, 12: 4}
	var live_obs := _mk_obs(models, 9, 4)
	var wire: Dictionary = JSON.parse_string(JSON.stringify(live_obs))
	var rehydrated := BotObservation.from_json(wire)
	check(RuleBassPolicy.decide(rehydrated, seed_value) == RuleBassPolicy.decide(live_obs, seed_value),
		"JSON-round-tripped observation replays to identical ops")

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
	check(frame.source == DecisionLog.SOURCE_RULE_BOT and int(frame.rng_seed) == s
		and frame.decision_key == key, "frame carries source, seed (as string), and decision key")

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
	check(events[0].has("game_revision") and not str(events[0].game_revision).is_empty(),
		"header auto-stamps the game revision")
	check(events[1].type == "decision" and events[1].result == "hold", "hold frame round-trips")
	check(events[2].type == "commit" and int(events[2].at_loop) == 12, "commit event round-trips")
	check(int(events[1].decision_key.target_loop) == int(events[2].decision_key.target_loop),
		"decision and commit join on the decision key")
	DirAccess.remove_absolute(log.path)


## Duck-typed room + net for driving BotPeer without a scene tree or ENet.
class FakeNet extends RefCounted:
	var active := true
	var room_epoch := 1
	var editable := {}
	func can_edit(track: int) -> bool:
		return editable.get(track, false)


class FakeRoom extends RefCounted:
	const CommitModelC := preload("res://scripts/core/commit_model.gd")
	const DrumPatternC := preload("res://scripts/core/drum_pattern.gd")
	const BassLineC := preload("res://scripts/core/bass_line.gd")
	const ChordTrackC := preload("res://scripts/core/chord_track.gd")
	const TrackOpsC := preload("res://scripts/core/track_ops.gd")
	var drums
	var bass
	var chords
	var net = null
	var transport = null
	var loop_index := 0
	var dispatched: Array = []
	func _init() -> void:
		drums = CommitModelC.new(DrumPatternC.new())
		var line = BassLineC.new()
		line.notes = {0: 0, 8: 0, 12: 4}
		bass = CommitModelC.new(line)
		var track = ChordTrackC.new()
		track.slots = [0, 5, 3, 4]
		chords = CommitModelC.new(track)
	func model_for(track: int):
		match track:
			0: return drums
			1: return bass
			_: return chords
	func dispatch(track: int, op: String, args: Dictionary) -> void:
		dispatched.append({"track": track, "op": op, "args": args})
		TrackOpsC.apply(model_for(track), track, op, args, loop_index)
	func commit_boundary(loop: int) -> void:
		loop_index = loop
		for t in [0, 1, 2]:
			model_for(t).try_commit_at_loop(loop)


func _test_bot_peer() -> void:
	var room := FakeRoom.new()
	var net := FakeNet.new()
	net.editable = {1: true}
	room.net = net
	var bot = BotPeer.new()
	bot.room = room
	bot.session_seed = 5

	# Watermark: multiple observations of the same loop author ONE decision.
	bot.on_loop(0)
	bot.on_loop(0)
	check(bot.decisions == 1, "one decision per editable window, not per observation")
	check(bot.holds == 1 and room.dispatched.is_empty(),
		"first window after (initial) version is a guaranteed zero-op HOLD")

	# Successive loops open successive windows.
	room.commit_boundary(1)
	bot.on_loop(1)
	room.commit_boundary(2)
	bot.on_loop(2)
	check(bot.decisions == 3, "each loop opens exactly one new window")
	check(bot.decisions == bot.authored.size(), "authored watermark matches decision count")

	# Role gate: losing the seat silences the bot entirely.
	net.editable = {1: false}
	room.commit_boundary(3)
	var before: int = bot.decisions
	bot.on_loop(3)
	check(bot.decisions == before, "bot without the role authors nothing")
	net.editable = {1: true}

	# Epoch bump (rehost/reset) legitimately reopens the same target loop.
	bot.on_loop(3)
	check(bot.decisions == before + 1, "regained seat resumes deciding")
	net.room_epoch = 2
	bot.on_loop(3)
	check(bot.decisions == before + 2, "epoch bump reopens the watermark for the same loop")

	# Ops the bot dispatched only ever touch its own track.
	var foreign := false
	for d in room.dispatched:
		if d.track != 1:
			foreign = true
	check(not foreign, "bot only ever dispatches ops for its own role")

	# After its edit commits, the next window is a guaranteed breathe-HOLD, and
	# the resolution is logged as a commit event joined by decision key.
	var log = DecisionLog.new()
	check(log.open({"session_id": "botpeer", "session_seed": 5}, "user://test_decision_logs") == OK,
		"bot log opens")
	bot.decision_log = log
	var run_room := FakeRoom.new()
	run_room.net = net
	var run_bot = BotPeer.new()
	run_bot.room = run_room
	run_bot.session_seed = 5
	run_bot.decision_log = log
	for loop in range(0, 8):
		run_room.commit_boundary(loop)
		run_bot.on_loop(loop)
	log.close()
	check(run_bot.edits >= 1 and run_bot.holds >= 1, "bot both edits and holds over 8 windows")
	var events := DecisionLog.read_events(log.path)
	var frames := 0
	var zero_op_frames := 0
	var commits := 0
	var analyzed := 0
	for e in events:
		if e.type == "decision":
			frames += 1
			if e.ops.is_empty():
				zero_op_frames += 1
			if e.analysis != null and e.analysis.has("drum_density") \
					and e.observation.temporal.has("loops_since_bass_change"):
				analyzed += 1
		elif e.type == "commit":
			commits += 1
	check(frames == run_bot.decisions, "every decision window produced exactly one frame")
	check(zero_op_frames == run_bot.holds, "every HOLD is a recorded zero-op frame")
	check(commits >= 1, "committed edits produce commit resolution events")
	check(analyzed == frames, "every frame carries JamFeatures measurements")

	# Attribution (schema 4): the bot's own committed edit is "self"; an
	# externally bumped drum version is "other".
	var events2 := DecisionLog.read_events(log.path)
	var saw_commit := false
	var self_after_commit := false
	for e in events2:
		if e.type == "commit":
			saw_commit = true
		elif e.type == "decision" and saw_commit:
			self_after_commit = e.observation.last_change_by.bass == "self"
			break
	check(self_after_commit, "bot's own committed edit attributes as self")
	var first_frame := {}
	for e in events2:
		if e.type == "decision":
			first_frame = e
			break
	check(first_frame.interpretation.has("energy") and first_frame.interpretation.has("repetition_pressure"),
		"bot frames carry the interpretation vector")
	run_bot.decision_log = null # log already closed
	run_room.drums.version_id += 1 # someone else's edit arrives
	run_bot.on_loop(9)
	check(run_bot._last_change_by.drums == "other", "foreign version bump attributes as other")
	DirAccess.remove_absolute(log.path)
	bot.free()
	run_bot.free()


func _test_human_recorder() -> void:
	var room := FakeRoom.new()
	var net := FakeNet.new()
	net.editable = {1: true}
	room.net = net
	var rec = HumanRecorder.new()
	rec.room = room
	var log = DecisionLog.new()
	check(log.open({"session_id": "t_human"}, "user://test_decision_logs") == OK, "human log opens")
	rec.decision_log = log

	# Window opens at the boundary; ops accumulate; frame written at the close.
	rec.on_loop(0)
	check(rec.frames == 0, "open window is not yet a frame")
	room.dispatch(1, "place", {"step": 2, "degree": 1})
	rec._on_edit_dispatched(1, "place", {"step": 2, "degree": 1})
	rec._on_edit_dispatched(0, "toggle", {"voice": 0, "step": 3}) # not our role
	room.commit_boundary(1)
	rec.on_loop(1)
	rec.on_loop(2) # no edits in window 2 -> HOLD frame
	log.close()

	check(rec.frames == 2 and rec.edit_frames == 1 and rec.holds == 1 and rec.ops_captured == 1,
		"two windows: one edit frame, one zero-op HOLD; foreign-role ops ignored")
	var frames_read := []
	for e in DecisionLog.read_events(log.path):
		if e.type == "decision":
			frames_read.append(e)
	check(frames_read.size() == 2, "both windows recorded")
	var f0: Dictionary = frames_read[0]
	check(f0.source == DecisionLog.SOURCE_HUMAN and f0.policy_name == "human_ui",
		"human frames carry human source + policy tag")
	check(int(f0.decision_key.target_loop) == 1 and f0.ops.size() == 1
		and int(f0.ops[0].args.step) == 2 and int(f0.ops[0].args.degree) == 1,
		"raw ops grouped into their editable window")
	check(not f0.observation.bass_notes.has(2) and not f0.observation.bass_notes.has("2"),
		"observation is pre-edit: built at window open, before the human's op")
	check(f0.analysis.has("kick_bass_alignment") and f0.has("window_focused")
		and int(f0.input_events) == 0,
		"frames carry features and attention proxies")
	check(f0.interpretation.has("energy") and f0.interpretation.has("external_change_pressure"),
		"human frames carry the interpretation vector")
	var f1: Dictionary = frames_read[1]
	check(f1.ops.is_empty() and int(f1.decision_key.target_loop) == 2,
		"deliberate hold is a zero-op frame")
	check(int(f1.decision_key.state_version) > int(f0.decision_key.state_version),
		"post-commit window observes the bumped version")
	check(f1.observation.last_change_by.bass == "self",
		"the player's own committed edit attributes as self")
	check(f1.observation.last_change_by.drums == "none",
		"authored-but-uncommitted foreign track stays none")
	DirAccess.remove_absolute(log.path)

	# Not this player's seat -> nothing recorded.
	var squatter = HumanRecorder.new()
	squatter.room = room
	net.editable = {1: false}
	squatter.on_loop(3)
	squatter.on_loop(4)
	check(squatter.frames == 0, "recorder is silent for seats the player does not own")
	rec.free()
	squatter.free()


func _test_shadow_bot() -> void:
	var room := FakeRoom.new()
	var net := FakeNet.new()
	net.editable = {1: false} # the HUMAN owns bass; shadow only watches
	room.net = net
	var bot = BotPeer.new()
	bot.room = room
	bot.shadow = true
	bot.session_seed = 5
	var log = DecisionLog.new()
	check(log.open({"session_id": "t_shadow"}, "user://test_decision_logs") == OK, "shadow log opens")
	bot.decision_log = log

	for loop in 8:
		room.commit_boundary(loop)
		bot.on_loop(loop)
	log.close()

	check(room.dispatched.is_empty() and bot.ops_sent == 0, "shadow NEVER dispatches")
	check(bot.decisions == 8, "shadow still takes every window (role gate bypassed for observing)")
	check(bot.edits >= 1, "unresolved staleness keeps forcing proposals")
	var proposal_frames := 0
	var proposed_ops := 0
	var commits := 0
	for e in DecisionLog.read_events(log.path):
		if e.type == "decision":
			proposal_frames += 1
			proposed_ops += e.ops.size()
			check(e.get("shadow", false) == true, "every shadow frame is marked shadow")
		elif e.type == "commit":
			commits += 1
	check(proposal_frames == 8 and proposed_ops >= 1, "all windows logged, proposals included")
	check(commits == 0, "shadow proposals never resolve into commit events")
	DirAccess.remove_absolute(log.path)
	bot.free()


func _test_jam_features() -> void:
	# Starter room state, every number hand-computable:
	# drums: kick {0,8}, snare {4,12}, hat {0,2,..,14} -> 12 hits
	# bass: {0:0, 8:0, 12:4} -> midis 36,36,43; chords: I-vi-IV-V
	var models := _mk_models()
	var state := {
		"drums": models.drums.active.to_dict(),
		"bass": models.bass.active.to_dict(),
		"chords": models.chords.active.to_dict(),
	}
	var f := Features.extract(state)
	check(is_equal_approx(f.drum_density, 12.0 / 64.0), "drum density 12/64")
	check(is_equal_approx(f.kick_density, 2.0 / 16.0), "kick density 2/16")
	check(is_equal_approx(f.hat_density, 8.0 / 16.0), "hat density 8/16")
	check(is_equal_approx(f.perc_density, 0.0), "perc density 0")
	check(is_equal_approx(f.bass_density, 3.0 / 16.0), "bass density 3/16")

	# SEMANTIC family: two notes on R, one on O -> fractions and entropy over lanes.
	check(is_equal_approx(f.bass_root_fraction, 2.0 / 3.0) and is_equal_approx(f.bass_octave_fraction, 1.0 / 3.0),
		"lane fractions 2/3 R, 1/3 O")
	check(is_equal_approx(f.bass_third_fraction, 0.0) and is_equal_approx(f.bass_fifth_fraction, 0.0)
		and is_equal_approx(f.bass_seventh_fraction, 0.0), "unused lanes are 0")
	check(is_equal_approx(f.bass_lane_entropy,
		-(2.0 / 3.0 * log(2.0 / 3.0) + 1.0 / 3.0 * log(1.0 / 3.0)) / log(5.0)),
		"lane entropy normalized over 5 lanes")

	# SOUNDING family: motif R.R.O rendered over I|vi|IV|V through the same
	# resolver as playback -> 36,36,48 / 45,45,57 / 41,41,53 / 43,43,55.
	check(is_equal_approx(f.sounding_pitch_mean, 543.0 / 12.0), "sounding mean over all 4 bars")
	check(f.sounding_pitch_range == 21, "sounding range 36..57")
	check(is_equal_approx(f.sounding_mean_interval, 77.0 / 11.0), "sounding mean interval 7 semitones")
	check(f.sounding_max_interval == 16, "largest melodic leap O(vi) -> R(IV)")
	check(is_equal_approx(f.sounding_direction_change_rate, 6.0 / 10.0),
		"6 direction reversals over 10 interval pairs")
	check(is_equal_approx(f.kick_bass_alignment, 2.0 / 3.0), "2 of 3 bass onsets sit on kicks")
	check(f.chord_slot_count == 4 and f.active_roles == 3, "chord slots and active roles counted")

	# The doc's motivating case: R R R R is semantically static (root_fraction 1,
	# entropy 0) yet sounds moderate melodic motion under a moving progression.
	var pedal := Features.extract({
		"bass": {"num_steps": 16, "notes": {0: 0}},
		"chords": models.chords.active.to_dict(),
	})
	check(is_equal_approx(pedal.bass_root_fraction, 1.0) and is_equal_approx(pedal.bass_lane_entropy, 0.0),
		"all-root motif is semantically static")
	check(pedal.sounding_pitch_range == 9 and is_equal_approx(pedal.sounding_mean_interval, (9.0 + 4.0 + 2.0) / 3.0),
		"...but sounds C2 A2 F2 G2 under I|vi|IV|V")

	# Empty state: all zeros, no NaNs, nothing active.
	var empty := Features.extract({})
	check(is_equal_approx(empty.drum_density, 0.0) and is_equal_approx(empty.sounding_pitch_mean, 0.0)
		and is_equal_approx(empty.sounding_mean_interval, 0.0) and is_equal_approx(empty.bass_root_fraction, 0.0)
		and is_equal_approx(empty.bass_lane_entropy, 0.0) and empty.active_roles == 0,
		"empty state measures to zeros")

	# Similarity: identical -> 1; one drum toggle -> jaccard 12/13; disjoint bass -> 0.
	var same := Features.similarity(state, state)
	check(is_equal_approx(same.mean, 1.0), "identical states are similarity 1")
	var tweaked := {
		"drums": models.drums.active.clone(),
		"bass": models.bass.active.to_dict(),
		"chords": models.chords.active.to_dict(),
	}
	PatternEditor.toggle_hit(tweaked.drums, 3, 7)
	tweaked.drums = tweaked.drums.to_dict()
	var sim := Features.similarity(state, tweaked)
	check(is_equal_approx(sim.drums, 12.0 / 13.0), "one added hit -> drum jaccard 12/13")
	check(is_equal_approx(sim.bass, 1.0) and is_equal_approx(sim.chords, 1.0), "untouched tracks stay 1")
	var moved := {"bass": {"num_steps": 16, "notes": {1: 1, 5: 2}}}
	check(is_equal_approx(Features.similarity(state, moved).bass, 0.0), "disjoint bass lines are 0")

	# Measurements survive the JSON round-trip decision logs apply (string keys).
	var wire: Dictionary = JSON.parse_string(JSON.stringify(state))
	var f2 := Features.extract(wire)
	check(is_equal_approx(f2.kick_bass_alignment, f.kick_bass_alignment)
		and is_equal_approx(f2.sounding_pitch_mean, f.sounding_pitch_mean)
		and is_equal_approx(f2.bass_lane_entropy, f.bass_lane_entropy),
		"features identical on JSON-round-tripped state")


func _test_temporal_features() -> void:
	# Pure delta comparison on hand-built feature dicts.
	var deltas := Features.compare({"drum_density": 0.2, "bass_density": 0.25},
		{"drum_density": 0.5, "bass_density": 0.25})
	check(is_equal_approx(deltas.drum_density_delta, 0.3), "drum density delta +0.3")
	check(is_equal_approx(deltas.bass_density_delta, 0.0), "unchanged density delta 0")

	# History: same state sitting still vs a bass change — the distinction two
	# identical snapshots cannot express.
	var models := _mk_models()
	var state := {
		"drums": models.drums.active.to_dict(),
		"bass": models.bass.active.to_dict(),
		"chords": models.chords.active.to_dict(),
	}
	var h := History.new()
	h.push(0, state, [0, 0, 0])
	var t0 := h.temporal()
	check(t0.drum_event_jaccard_prev_1 == null and t0.bass_event_jaccard_prev_2 == null,
		"unobserved lookbacks are null, not fabricated")
	h.push(1, state, [0, 0, 0])
	h.push(2, state, [0, 0, 0])
	var t2 := h.temporal()
	check(is_equal_approx(t2.drum_density_delta, 0.0), "still state: zero deltas")
	check(is_equal_approx(t2.bass_event_jaccard_prev_1, 1.0)
		and is_equal_approx(t2.drum_event_jaccard_prev_2, 1.0), "still state: full overlap on lookbacks")
	check(t2.loops_since_bass_change == 2 and t2.loops_since_drum_change == 2,
		"no observed change: age = observed span (lower bound)")

	# A bass change at loop 3: age resets for bass only, overlap drops.
	var changed := {
		"drums": state.drums,
		"bass": {"num_steps": 16, "notes": {2: 1, 6: 3, 10: 2}},
		"chords": state.chords,
	}
	h.push(3, changed, [0, 1, 0])
	var t3 := h.temporal()
	check(t3.loops_since_bass_change == 0, "bass change observed: age 0")
	check(t3.loops_since_drum_change == 3, "drums untouched: age keeps growing")
	check(is_equal_approx(t3.bass_event_jaccard_prev_1, 0.0), "disjoint new line: bass overlap 0")
	check(is_equal_approx(t3.drum_event_jaccard_prev_1, 1.0), "drums still identical")
	h.push(4, changed, [0, 1, 0])
	check(h.temporal().loops_since_bass_change == 1, "bass age counts up from its change")

	# Monotonic guard: re-observing a loop adds no history.
	var n := h.entries.size()
	h.push(4, changed, [0, 1, 0])
	check(h.entries.size() == n, "re-pushing the same loop is ignored")

	# Previous committed pattern: the state just before the last observed change.
	check(h.state_before_change(1).bass == state.bass,
		"state_before_change returns the pre-change bass state")
	check(h.state_before_change(0) == {}, "no observed drum change -> no previous state")


func _test_observation_contract() -> void:
	var models := _mk_models()
	var h := History.new()
	for loop in 3:
		h.push(loop, {
			"drums": models.drums.active.to_dict(),
			"bass": models.bass.active.to_dict(),
			"chords": models.chords.active.to_dict(),
		}, [0, 0, 0])
	var obs := BotObservation.build_bass(models.bass, models.drums, models.chords, 3, 1, h)
	check(obs.observation_schema == 4, "observation carries its schema version")
	check(obs.features.has("kick_bass_alignment"), "observation carries snapshot features")
	check(obs.temporal.has("loops_since_bass_change") and obs.temporal.has("bass_event_jaccard_prev_1"),
		"observation carries temporal context")
	check(BotObservation.build_bass(models.bass, models.drums, models.chords, 3, 1).temporal == {},
		"no history -> temporal absent, not fabricated")

	# v4 fields: attribution defaults to "none" when the observer supplies none;
	# no observed change -> no previous pattern (absent, not fabricated).
	check(obs.last_change_by == {"drums": "none", "bass": "none", "chords": "none"},
		"attribution defaults to none, not fabricated")
	check(obs.bass_notes_prev == null, "still history -> no previous committed pattern")
	check(BotObservation.build_bass(models.bass, models.drums, models.chords, 3, 1,
		null, {"drums": "other", "bass": "self", "chords": "none"}).last_change_by.bass == "self",
		"observer-supplied attribution flows through")

	# A bass change enters history -> the observation exposes the PRE-change line.
	var old_notes: Dictionary = models.bass.active.notes.duplicate()
	var h2 := History.new()
	for loop in 3:
		h2.push(loop, {
			"drums": models.drums.active.to_dict(),
			"bass": models.bass.active.to_dict(),
			"chords": models.chords.active.to_dict(),
		}, [0, 0, 0])
	h2.push(3, {
		"drums": models.drums.active.to_dict(),
		"bass": {"num_steps": 16, "notes": {2: 1}},
		"chords": models.chords.active.to_dict(),
	}, [0, 1, 0])
	var obs2 := BotObservation.build_bass(models.bass, models.drums, models.chords, 4, 0, h2)
	check(obs2.bass_notes_prev == old_notes, "previous committed bass line surfaces after a change")
	var round_tripped := BotObservation.from_json(JSON.parse_string(JSON.stringify(obs2)))
	check(round_tripped.bass_notes_prev == old_notes,
		"bass_notes_prev rehydrates to int keys through JSON")

	# The serialization contract: encode -> decode -> encode is a byte-identical
	# fixed point (sidesteps float-precision comparison entirely).
	var s1 := JSON.stringify(obs)
	var o2: Dictionary = JSON.parse_string(s1)
	var s2 := JSON.stringify(o2)
	var s3 := JSON.stringify(JSON.parse_string(s2))
	check(s2 == s3, "observation JSON encode/decode reaches a byte-identical fixed point")

	# And the policy consumes the round-tripped structure identically.
	var seed_value := DecisionLog.derive_seed(9, 0, 1, 3)
	check(RuleBassPolicy.decide(BotObservation.from_json(o2), seed_value)
		== RuleBassPolicy.decide(obs, seed_value),
		"full-schema observation replays through the policy after JSON")


## Assemble a minimal schema-4 observation for interpretation tests: each scene
## isolates one contributor. drum_hits: [[voice, step], ...].
func _mk_analysis_obs(bass_notes: Dictionary, slots: Array, drum_hits: Array,
		temporal := {}, lcb := {}) -> Dictionary:
	var hits: Array = []
	var voice_steps := [[], [], [], []]
	for h in drum_hits:
		hits.append({"voice": h[0], "step": h[1], "velocity": 0.75, "accent": false})
		voice_steps[h[0]].append(h[1])
	var state := {
		"drums": {"num_steps": 16, "hits": hits},
		"bass": {"num_steps": 16, "notes": bass_notes},
		"chords": {"slots": slots},
	}
	return {
		"bass_notes": bass_notes,
		"chord_slots": slots,
		"kick_steps": voice_steps[0],
		"snare_steps": voice_steps[1],
		"hat_steps": voice_steps[2],
		"features": Features.extract(state),
		"temporal": temporal,
		"last_change_by": lcb if not lcb.is_empty() else {"drums": "none", "bass": "none", "chords": "none"},
	}


func _test_jam_analysis() -> void:
	# Scene: sparse roots + simple kick -> low everything.
	var calm := Analysis.interpret(_mk_analysis_obs(
		{0: 0, 8: 0}, [-1, -1, -1, -1], [[0, 0], [0, 8]]))
	check(calm.analysis_schema == 1, "interpretation carries its schema version")
	check(calm.energy < 0.35 and calm.rhythmic_tension < 0.1 and calm.harmonic_tension < 0.1
		and calm.density_tension < 0.1, "sparse roots on the beat: low everything")

	# Scene: dense root/fifth groove over I -> HIGH energy, LOW harmonic tension.
	var groove := Analysis.interpret(_mk_analysis_obs(
		{0: 0, 2: 2, 4: 0, 6: 2, 8: 0, 10: 2, 12: 0, 14: 2}, [0, 0, 0, 0],
		[[0, 0], [0, 4], [0, 8], [0, 12], [1, 4], [1, 12],
		 [2, 0], [2, 2], [2, 4], [2, 6], [2, 8], [2, 10], [2, 12], [2, 14]]))
	check(groove.energy > 0.6, "dense consonant groove is high energy")
	check(groove.harmonic_tension < 0.1, "...and harmonically calm")

	# Scene: sparse 7ths over V -> LOW energy, HIGH harmonic tension.
	var sevens := Analysis.interpret(_mk_analysis_obs(
		{0: 3, 8: 3}, [4, 4, 4, 4], [[0, 0]]))
	check(sevens.energy < 0.35, "sparse line stays low energy")
	check(sevens.harmonic_tension > 0.5, "7ths over V carry resolution pressure")
	# THE invariant: energy != tension (both orderings).
	check(groove.energy > sevens.energy and sevens.harmonic_tension > groove.harmonic_tension,
		"energy and harmonic tension move independently")

	# Scene: busy syncopated consonant phrase -> high rhythmic, low harmonic.
	var sync := Analysis.interpret(_mk_analysis_obs(
		{1: 0, 3: 2, 5: 0, 7: 2, 9: 0, 11: 2, 13: 0, 15: 2}, [0, 0, 0, 0],
		[[0, 0], [0, 8]]))
	check(sync.rhythmic_tension > 0.5, "all-offbeat placement reads as rhythmic tension")
	check(sync.harmonic_tension < 0.2, "...while staying consonant")
	check(sync.rhythmic_tension > groove.rhythmic_tension,
		"placement, not density, drives rhythmic tension")

	# Scene: everything just changed by OTHERS -> high external, ZERO repetition.
	var invaded := Analysis.interpret(_mk_analysis_obs(
		{0: 0}, [0, 5, 3, 4], [[0, 0]],
		{"loops_since_drum_change": 0, "loops_since_bass_change": 0, "loops_since_chord_change": 0},
		{"drums": "other", "bass": "other", "chords": "other"}))
	check(invaded.external_change_pressure > 0.7, "fresh external edits are a call to react")
	check(is_equal_approx(invaded.repetition_pressure, 0.0), "just-changed material has no repetition pressure")

	# Scene: same material forever -> ZERO change pressure, FULL repetition.
	var stale := Analysis.interpret(_mk_analysis_obs(
		{0: 0}, [0, 5, 3, 4], [[0, 0]],
		{"loops_since_drum_change": 8, "loops_since_bass_change": 8, "loops_since_chord_change": 8},
		{"drums": "other", "bass": "other", "chords": "other"}))
	check(is_equal_approx(stale.external_change_pressure, 0.0), "old changes no longer press")
	check(stale.repetition_pressure > 0.9, "unchanged material accumulates repetition pressure")
	# THE other invariant: change_pressure != repetition_pressure.
	check(invaded.external_change_pressure > stale.external_change_pressure
		and stale.repetition_pressure > invaded.repetition_pressure,
		"change pressure and repetition pressure move in opposition")
	var mid := Analysis.interpret(_mk_analysis_obs({0: 0}, [0, 5, 3, 4], [[0, 0]],
		{"loops_since_drum_change": 2, "loops_since_bass_change": 2, "loops_since_chord_change": 2}))
	check(mid.repetition_pressure > invaded.repetition_pressure
		and mid.repetition_pressure < stale.repetition_pressure,
		"repetition pressure rises monotonically with age")

	# Scene: the player just changed bass THEMSELVES -> self pressure, not external.
	var own := Analysis.interpret(_mk_analysis_obs(
		{0: 0}, [0, 5, 3, 4], [[0, 0]],
		{"loops_since_drum_change": 5, "loops_since_bass_change": 0, "loops_since_chord_change": 5},
		{"drums": "none", "bass": "self", "chords": "none"}))
	check(own.self_change_pressure > 0.9, "own fresh edit presses against re-editing")
	check(is_equal_approx(own.external_change_pressure, 0.0),
		"a self-change is NOT an external call to action")

	# Scene: chords changed under a stale bass -> external pressure AND
	# repetition pressure coexist (the human divergence from the 2.5 session).
	var recontext := Analysis.interpret(_mk_analysis_obs(
		{0: 0, 8: 0}, [6, 5, 3, 1], [[0, 0]],
		{"loops_since_drum_change": 6, "loops_since_bass_change": 6, "loops_since_chord_change": 0},
		{"drums": "none", "bass": "none", "chords": "other"}))
	check(recontext.external_change_pressure > 0.7, "harmony moved: call to react")
	check(recontext.repetition_pressure > 0.4, "...while the bass line is also going stale")

	# No information -> no pressure (empty temporal, default attribution).
	var blind := Analysis.interpret(_mk_analysis_obs({0: 0}, [0, 5, 3, 4], [[0, 0]]))
	check(is_equal_approx(blind.external_change_pressure, 0.0)
		and is_equal_approx(blind.self_change_pressure, 0.0)
		and is_equal_approx(blind.repetition_pressure, 0.0),
		"unobserved history is never interpreted as pressure")

	# Determinism through the serialization boundary: a real observation
	# interprets identically raw and JSON-round-tripped.
	var models := _mk_models()
	var h := History.new()
	for loop in 3:
		h.push(loop, {
			"drums": models.drums.active.to_dict(),
			"bass": models.bass.active.to_dict(),
			"chords": models.chords.active.to_dict(),
		}, [0, 0, 0])
	var obs := BotObservation.build_bass(models.bass, models.drums, models.chords, 3, 1, h)
	var wire: Dictionary = BotObservation.from_json(JSON.parse_string(JSON.stringify(obs)))
	check(JSON.stringify(Analysis.interpret(obs)) == JSON.stringify(Analysis.interpret(wire)),
		"interpretation is identical across the JSON boundary")


func _test_intent_policy() -> void:
	var base_obs := {"features": {"bass_density": 0.2}, "last_change_by": {"bass": "none"}}

	# THE flagship triplet — the 2.5 divergence converted into explicit
	# behavioral distinctions. Same repetition ballpark, three different intents.
	# Case A: stale, nothing changed -> VARY.
	var a := IntentPolicy.decide(base_obs, {"external_change_pressure": 0.05,
		"repetition_pressure": 0.70, "self_change_pressure": 0.0})
	check(a.intent == IntentPolicy.VARY and a.drivers.has("repetition_pressure"),
		"stale + quiet -> VARY (staleness is the only reason)")
	# Case B: chords changed underneath a stale bass -> RESPOND, not VARY.
	var b := IntentPolicy.decide(base_obs, {"external_change_pressure": 0.78,
		"repetition_pressure": 0.45, "self_change_pressure": 0.0})
	check(b.intent == IntentPolicy.RESPOND and b.drivers.has("external_change_pressure"),
		"external change outranks staleness -> RESPOND")
	# Case C: the bassist just edited itself -> HOLD, not another mutation.
	var c := IntentPolicy.decide(base_obs, {"external_change_pressure": 0.05,
		"repetition_pressure": 0.40, "self_change_pressure": 0.85})
	check(c.intent == IntentPolicy.HOLD and c.drivers.has("self_change_pressure"),
		"own fresh edit -> HOLD, don't fidget")

	# SIMPLIFY: crowding beats staleness once nothing external calls.
	check(IntentPolicy.decide(base_obs, {"density_tension": 0.7,
		"repetition_pressure": 0.7}).intent == IntentPolicy.SIMPLIFY,
		"crowded jam -> SIMPLIFY before VARY")

	# INTENSIFY: hot jam, bass under-participating.
	check(IntentPolicy.decide({"features": {"bass_density": 0.05}, "last_change_by": {}},
		{"energy": 0.8}).intent == IntentPolicy.INTENSIFY,
		"hot jam + absent bass -> INTENSIFY")
	check(IntentPolicy.decide({"features": {"bass_density": 0.4}, "last_change_by": {}},
		{"energy": 0.8}).intent == IntentPolicy.HOLD,
		"hot jam with bass already present is not a call to intensify")

	# REVERT: bass_notes_prev's first consumer — my own ADDITION crowded the jam.
	var revert_obs := {"features": {"bass_density": 0.4},
		"bass_notes": {0: 0, 8: 0, 12: 4}, "last_change_by": {"bass": "self"},
		"bass_notes_prev": {0: 0, 8: 0}}
	var r := IntentPolicy.decide(revert_obs,
		{"density_tension": 0.75, "self_change_pressure": 0.9})
	check(r.intent == IntentPolicy.REVERT, "own addition made it crowded -> REVERT, not HOLD")
	check(IntentPolicy.decide({"features": {}, "last_change_by": {"bass": "self"},
		"bass_notes_prev": null}, {"density_tension": 0.75, "self_change_pressure": 0.9}).intent
		== IntentPolicy.HOLD, "no previous pattern -> REVERT unavailable, falls to HOLD")
	# Ping-pong regressions from the first live duet (v2 guards): a MOVE keeps
	# the note count, so it can never trigger a revert of itself...
	var moved_obs: Dictionary = revert_obs.duplicate(true)
	moved_obs.bass_notes = {0: 0, 10: 4}
	check(IntentPolicy.decide(moved_obs, {"density_tension": 0.75, "self_change_pressure": 0.9}).intent
		== IntentPolicy.HOLD, "own MOVE in a dense room holds, never revert ping-pong")
	# ...and live external pressure means the change was a response: no retreat.
	check(IntentPolicy.decide(revert_obs, {"density_tension": 0.75,
		"self_change_pressure": 0.9, "external_change_pressure": 0.8}).intent
		== IntentPolicy.HOLD, "responding to the room is never immediately reverted")

	# Calm default and determinism.
	check(IntentPolicy.decide(base_obs, {}).intent == IntentPolicy.HOLD,
		"nothing pressing -> HOLD")
	check(JSON.stringify(IntentPolicy.decide(base_obs, {"repetition_pressure": 0.7}))
		== JSON.stringify(IntentPolicy.decide(base_obs, {"repetition_pressure": 0.7})),
		"intent decisions are deterministic")

	# Style hook: architected, inert. Unknown styles behave as DEFAULT but the
	# request is preserved for the log.
	var styled := IntentPolicy.decide(base_obs, {"repetition_pressure": 0.7}, "jazz")
	check(styled.intent == IntentPolicy.VARY and styled.style == "default"
		and styled.style_requested == "jazz",
		"unknown style falls back to default weights, request logged")


func _test_bass_realizer() -> void:
	var models := _mk_models()
	var sparse := BotObservation.build_bass(models.bass, models.drums, models.chords, 1, 1)
	# A dense, colorful line for SIMPLIFY/VARY to bite into.
	var dense_line := BassLine.new()
	dense_line.notes = {0: 0, 2: 1, 4: 0, 6: 3, 8: 0, 10: 3, 12: 4, 14: 1}
	var dense_model = CommitModel.new(dense_line)
	var dense := BotObservation.build_bass(dense_model, models.drums, models.chords, 1, 1)

	# Every candidate op, every intent, many seeds: legal by construction.
	var all_legal := true
	for intent in ["RESPOND", "SIMPLIFY", "INTENSIFY", "VARY", "REVERT"]:
		for s in 30:
			for obs in [sparse, dense]:
				var o: Dictionary = obs.duplicate(true)
				o.bass_notes_prev = {0: 0, 8: 0}
				for c in Realizer.candidates(o, intent, s):
					for op in c.ops:
						if not _valid_bass_op(op):
							all_legal = false
	check(all_legal, "every candidate op for every intent/seed passes hostile-peer validation")

	# Determinism: same (obs, intent, seed) -> identical realization.
	check(JSON.stringify(Realizer.realize(dense, "VARY", 42)) == JSON.stringify(Realizer.realize(dense, "VARY", 42)),
		"realization is deterministic")

	# Intent faithfulness, judged by SIMULATING the chosen ops.
	var simp := Realizer.realize(dense, "SIMPLIFY", 7)
	var simp_notes := _apply_ops(dense, simp.ops)
	check(simp_notes.size() < dense.bass_notes.size(), "SIMPLIFY thins the dense line")
	check(Realizer.realize(sparse, "SIMPLIFY", 7).ops.is_empty(),
		"SIMPLIFY on an already-sparse line holds (nothing to thin)")

	var intens := Realizer.realize(sparse, "INTENSIFY", 7)
	check(_apply_ops(sparse, intens.ops).size() == sparse.bass_notes.size() + 1,
		"INTENSIFY adds exactly one note")

	# VARY wants an in-band line: on the 8-note dense line the evaluator
	# correctly refuses (every variation keeps a crowded line crowded).
	var mid_line := BassLine.new()
	mid_line.notes = {0: 0, 4: 2, 6: 3, 8: 0, 12: 4}
	var mid := BotObservation.build_bass(CommitModel.new(mid_line), models.drums, models.chords, 1, 1)
	var vary := Realizer.realize(mid, "VARY", 7)
	var vary_notes := _apply_ops(mid, vary.ops)
	check(vary_notes != mid.bass_notes and absi(vary_notes.size() - mid.bass_notes.size()) <= 1,
		"VARY changes the pattern without changing its weight class")
	# With the riff bank present, VARY on a crowded line escapes to a banked
	# in-band pattern instead of refusing (cell edits can't fix a bad line;
	# switching to a known-good riff can) — pinned as the improved behavior.
	var crowded_vary := Realizer.realize(dense, "VARY", 7)
	var crowded_result := _apply_ops(dense, crowded_vary.ops)
	check(crowded_vary.candidate == "bank_pattern" and crowded_result.size() <= 6,
		"VARY on an out-of-band line escapes to a banked in-band riff")

	# RESPOND from silence: the bandmate can enter an empty seat.
	var empty_line = CommitModel.new(BassLine.new())
	var silent := BotObservation.build_bass(empty_line, models.drums, models.chords, 1, 1)
	var resp := Realizer.realize(silent, "RESPOND", 7)
	check(not resp.ops.is_empty() and _apply_ops(silent, resp.ops).size() >= 1,
		"RESPOND on an empty line enters rather than holding forever")

	# REVERT restores the actual previous pattern — bass_notes_prev's realizer.
	var rev_obs: Dictionary = dense.duplicate(true)
	rev_obs.bass_notes_prev = {0: 0, 8: 0, 12: 4}
	var rev := Realizer.realize(rev_obs, "REVERT", 7)
	check(rev.candidate == "restore_prev" and _apply_ops(rev_obs, rev.ops) == {0: 0, 8: 0, 12: 4},
		"REVERT restores the previous committed line exactly")
	var no_prev: Dictionary = dense.duplicate(true)
	no_prev.bass_notes_prev = null
	check(Realizer.realize(no_prev, "REVERT", 7).ops.is_empty(),
		"REVERT without a previous pattern holds")
	check(rev.ops.size() <= Realizer.MAX_REVERT_OPS, "revert op count is capped")

	check(Realizer.realize(dense, "HOLD", 7).ops.is_empty(), "HOLD realizes to nothing")
	check(not Realizer.realize(dense, "VARY", 7).scores.is_empty(),
		"realization reports candidate scores (the 3E swap point)")


func _test_style_prior() -> void:
	var profile = StylePrior.load_profile("res://data/style_profiles/jazz.json")
	check(profile != null and profile.style_id == "jazz"
		and profile.roles.bass.confidence == "HIGH",
		"committed jazz profile loads with provenance")
	var bass: Dictionary = profile.roles.bass.profile

	var models := _mk_models()
	var mid_line := BassLine.new()
	mid_line.notes = {0: 0, 4: 2, 6: 3, 8: 0, 12: 4}
	var obs := BotObservation.build_bass(CommitModel.new(mid_line), models.drums, models.chords, 1, 1)

	# INVARIANT: w_style = 0 and missing profile are byte-identical to the
	# interaction-only decision; style never alters the candidate set.
	var plain := JSON.stringify(Realizer.realize(obs, "VARY", 7))
	check(JSON.stringify(Realizer.realize(obs, "VARY", 7, null, 0.35)) == plain,
		"missing profile -> style contributes exactly zero")
	check(JSON.stringify(Realizer.realize(obs, "VARY", 7, bass, 0.0)) == plain,
		"w_style = 0 -> byte-identical to pre-3E decisions")
	var names_plain: Array = []
	for c in Realizer.candidates(obs, "VARY", 7):
		names_plain.append(c.name)
	var styled := Realizer.realize(obs, "VARY", 7, bass, 0.35)
	var names_styled: Array = []
	for s in styled.scores:
		names_styled.append(s.name)
	check(names_styled == names_plain, "style scorer cannot alter candidate generation")
	check(JSON.stringify(Realizer.realize(obs, "VARY", 7, bass, 0.35)) == JSON.stringify(styled),
		"styled decisions are deterministic")
	for op in styled.ops:
		check(_valid_bass_op(op), "styled decisions emit only legal ops")
	check(styled.has("interaction_choice") and styled.has("style_disagreement"),
		"both rankings ride in every realization (the ablation is in the log)")

	# Smoothing + soft manifold: rare vocab stays finite; every dimension is
	# capped above (extreme typicality earns no extra) and floored below.
	var weird := {1: 3, 3: 3, 5: 3, 7: 3} # consecutive 7ths on offbeat 16ths
	var wfit = StylePrior.score_bass(bass, weird, [0, 5, 3, 4])
	check(wfit != null, "corpus-rare vocabulary scores finite, never -inf")
	var typical := {0: 0, 4: 0, 8: 0, 12: 0} # maximal corpus typicality: all roots on beats
	var tfit = StylePrior.score_bass(bass, typical, [0, 5, 3, 4])
	for f in [wfit, tfit]:
		for k in f:
			check(f[k] <= StylePrior.CAP_TYPICAL + 0.0001 and f[k] >= StylePrior.FLOOR - 0.0001,
				"style fit '%s' respects the soft-manifold cap and floor" % k)

	# Direction sanity from the corpus: jazz walking is on the beat and
	# stepwise — the prior must actually encode that.
	var onbeat = StylePrior.score_bass(bass, {0: 0, 4: 2, 8: 0, 12: 2}, [0, 5, 3, 4])
	var offbeat = StylePrior.score_bass(bass, {1: 0, 5: 2, 9: 0, 13: 2}, [0, 5, 3, 4])
	check(onbeat.beat_position_fit > offbeat.beat_position_fit,
		"corpus prior prefers on-beat placement (measured jazz, not opinion)")
	var stepwise = StylePrior.score_bass(bass, {0: 0, 4: 1, 8: 2, 12: 1}, [0, 0, 0, 0])
	var leapy = StylePrior.score_bass(bass, {0: 0, 4: 4, 8: 0, 12: 4}, [0, 0, 0, 0])
	check(stepwise.interval_fit > leapy.interval_fit,
		"corpus prior prefers stepwise motion over octave leaps")

	# Missing data contributes zero, not a substitute.
	check(StylePrior.score_bass({}, {0: 0}, [0, 5, 3, 4]) == null,
		"empty profile section -> null, no generic substitute")

	# The full policy carries provenance and stays JSON-replayable with style on.
	var real := IntentBassPolicy.realization(obs, 7)
	check(real.style != null and real.style.style_id == "jazz"
		and real.style.bass_source.begins_with("FiloBass") and real.style.w_style > 0.0,
		"decisions log exact style provenance")
	var wire := BotObservation.from_json(JSON.parse_string(JSON.stringify(obs)))
	check(JSON.stringify(IntentBassPolicy.decide(wire, 7)) == JSON.stringify(IntentBassPolicy.decide(obs, 7)),
		"styled pipeline replays identically through the JSON boundary")


func _test_pattern_bank() -> void:
	# The committed bank: every variant legal and playable.
	var text := FileAccess.get_file_as_string("res://data/pattern_bank.json")
	var bank: Dictionary = JSON.parse_string(text)
	check(bank != null and bank.bank_schema == 1 and bank.motifs.size() >= 1,
		"pattern bank loads with schema")
	var all_legal := true
	for m in bank.motifs:
		for v in m.variants:
			var n: Dictionary = v.notes
			if n.size() < 2 or n.size() > 8:
				all_legal = false
			for k in n:
				if int(str(k)) < 0 or int(str(k)) > 15 or int(n[k]) < 0 or int(n[k]) > 4:
					all_legal = false
	check(all_legal, "every banked variant is a legal, playable line")

	# Bank candidates: applying the ops lands EXACTLY on a banked variant.
	var models := _mk_models()
	var line := BassLine.new()
	line.notes = {0: 0, 8: 0, 12: 4} # the starter groove — a known motif member
	var obs := BotObservation.build_bass(CommitModel.new(line), models.drums, models.chords, 1, 1)
	var found_pattern := false
	for c in Realizer.candidates(obs, "VARY", 3):
		if not c.has("pattern_id"):
			continue
		found_pattern = true
		var result := _apply_ops(obs, c.ops)
		var is_banked := false
		for m in bank.motifs:
			for v in m.variants:
				var vn := {}
				for k in v.notes:
					vn[int(str(k))] = int(v.notes[k])
				if vn == result:
					is_banked = true
		check(is_banked, "bank candidate '%s' lands exactly on its banked variant" % c.pattern_id)
		check(c.ops.size() <= Realizer.MAX_PATTERN_OPS, "bank candidate respects the op cap")
	check(found_pattern, "the starter groove offers motif/bank candidates under VARY")

	# Provenance: the winning pattern's id rides in the realization.
	var real := Realizer.realize(obs, "VARY", 3)
	if real.candidate in ["motif_variant", "bank_pattern"]:
		check(real.pattern_id != null, "chosen pattern carries its bank id for the log")


func _test_intent_bass_policy() -> void:
	var models := _mk_models()
	var h := History.new()
	for loop in 3:
		h.push(loop, {
			"drums": models.drums.active.to_dict(),
			"bass": models.bass.active.to_dict(),
			"chords": models.chords.active.to_dict(),
		}, [0, 0, 0])
	var obs := BotObservation.build_bass(models.bass, models.drums, models.chords, 3, 1, h)

	# Quiet room, nothing pressing -> the pipeline holds.
	check(IntentBassPolicy.decide(obs, 11).is_empty(), "calm room: pipeline holds")

	# External harmony change -> the pipeline acts, and replays through JSON.
	var resp_obs: Dictionary = obs.duplicate(true)
	resp_obs.last_change_by = {"drums": "none", "bass": "none", "chords": "other"}
	resp_obs.temporal = obs.temporal.duplicate(true)
	resp_obs.temporal["loops_since_chord_change"] = 0
	var ops: Array = IntentBassPolicy.decide(resp_obs, 11)
	check(not ops.is_empty(), "external harmony change: pipeline acts")
	for op in ops:
		check(_valid_bass_op(op), "pipeline ops are legal")
	var wire := BotObservation.from_json(JSON.parse_string(JSON.stringify(resp_obs)))
	check(JSON.stringify(IntentBassPolicy.decide(wire, 11)) == JSON.stringify(ops),
		"full pipeline replays identically through the JSON boundary")

	# The explained decision carries the whole why.
	var real := IntentBassPolicy.realization(resp_obs, 11)
	check(real.intent == "RESPOND" and real.has("candidate") and real.has("scores")
		and real.drivers.has("external_change_pressure"),
		"realization explains intent, drivers, candidate, and scores")

	# Own fresh edit -> hold (bandmate does not fidget).
	var self_obs: Dictionary = obs.duplicate(true)
	self_obs.last_change_by = {"drums": "none", "bass": "self", "chords": "none"}
	self_obs.temporal = obs.temporal.duplicate(true)
	self_obs.temporal["loops_since_bass_change"] = 0
	check(IntentBassPolicy.decide(self_obs, 11).is_empty(), "own fresh edit: pipeline holds")

	# Mounted on a BotPeer: an ordinary peer that listens first, then acts.
	var room := FakeRoom.new()
	var net := FakeNet.new()
	net.editable = {1: true}
	room.net = net
	var bot = BotPeer.new()
	bot.room = room
	bot.policy = IntentBassPolicy
	bot.log_realization = true
	bot.session_seed = 9
	var log = DecisionLog.new()
	check(log.open({"session_id": "t_intentbot"}, "user://test_decision_logs") == OK, "intent bot log opens")
	bot.decision_log = log
	for loop in 12:
		room.commit_boundary(loop)
		bot.on_loop(loop)
	log.close()
	check(bot.holds >= 4, "intent bot listens before it plays")
	check(bot.edits >= 1, "room-wide staleness eventually draws the intent bot in")
	for d in room.dispatched:
		check(_valid_bass_op({"track": d.track, "op": d.op, "args": d.args}), "intent bot dispatches only legal ops")
	var saw := false
	for e in DecisionLog.read_events(log.path):
		if e.type == "decision":
			check(e.policy_name == "intent_bass", "frames carry the intent policy name")
			if not e.ops.is_empty():
				saw = true
				check(e.realization.intent != "HOLD" and e.realization.has("candidate"),
					"edit frames carry the full realization explanation")
	check(saw, "at least one explained edit frame was logged")
	DirAccess.remove_absolute(log.path)
	bot.free()


func _test_pointer_picking() -> void:
	# Ring hit-testing is the exact inverse of the draw layout: the centroid of
	# every wedge must pick back to its own (lane, step).
	var ring = StepRing.new()
	ring.size = Vector2(440, 440)
	ring.num_steps = 16
	ring.lane_names = ["R", "3", "5", "7", "O"]
	var center: Vector2 = ring.size / 2.0
	var outer := minf(ring.size.x, ring.size.y) / 2.0 - 6.0
	var inner := outer * 0.38
	var thickness := (outer - inner) / 5.0
	var ok := true
	for lane in 5:
		for step in 16:
			var r := inner + (lane + 0.5) * thickness
			# Wedge s is CENTERED on -PI/2 + s*step_angle (step 0 at 12 o'clock).
			var ang := -PI / 2.0 + step * TAU / 16.0
			if ring.pick(center + Vector2.from_angle(ang) * r) != Vector2i(lane, step):
				ok = false
	check(ok, "every wedge centroid picks back to its own (lane, step)")
	check(ring.pick(center + Vector2(0, -(inner + thickness * 0.5))) == Vector2i(0, 0),
		"12 o'clock IS step 0 (clock-face convention)")
	check(ring.pick(center) == Vector2i(-1, -1), "center hole picks nothing")
	check(ring.pick(Vector2.ZERO) == Vector2i(-1, -1), "corner outside the ring picks nothing")
	ring.free()

	# Chord strip: slot centroids pick their bar, the margins pick nothing.
	var strip = ChordStrip.new()
	strip.size = Vector2(895, 116)
	var n: int = strip.active_slots.size()
	var slot_w: float = (strip.size.x - 10.0 * (n + 1)) / float(n)
	for i in n:
		var p := Vector2(10.0 + i * (slot_w + 10.0) + slot_w / 2.0, (26.0 + strip.size.y - 10.0) / 2.0)
		check(strip.pick_bar(p) == i, "slot %d centroid picks bar %d" % [i, i])
	check(strip.pick_bar(Vector2(2, 60)) == -1 and strip.pick_bar(Vector2(400, 5)) == -1,
		"margins pick no bar")
	strip.free()

	# Radial bloom gesture resolution (pure static math): dead zone -> center or
	# cancel, each option's own direction -> that option, far away -> cancel.
	check(RadialBloom.resolve(Vector2(200, 200), Vector2(200, 200), 5, true) == -1,
		"dead zone with a center action resolves to center")
	check(RadialBloom.resolve(Vector2(200, 200), Vector2(200, 200), 5, false) == -2,
		"dead zone without a center action cancels")
	for i in 5:
		var ang := -PI / 2.0 + TAU * float(i) / 5.0
		var p: Vector2 = Vector2(200, 200) + Vector2.from_angle(ang) * RadialBloom.RADIUS
		check(RadialBloom.resolve(Vector2(200, 200), p, 5, true) == i, "option %d direction resolves" % i)
	check(RadialBloom.resolve(Vector2(200, 200), Vector2(600, 600), 5, true) == -2,
		"releasing far outside cancels")

	# Chord "set" flows through the shared op layer like every other edit.
	var model := CommitModel.new(ChordTrack.new())
	TrackOps.apply(model, TrackOps.TRACK_CHORDS, "set", {"bar": 1, "degree": 5}, 0)
	check(model.pending != null and model.pending.slots[1] == 5 and model.active.slots[1] == -1,
		"set edits the pending buffer, active untouched until commit")


func _test_groove_and_mixer() -> void:
	# Base is a literal no-op — the straight reference.
	check(Groove.offset_beats(0, 7) == 0.0 and is_equal_approx(Groove.apply_velocity(0.8, 0, 7), 0.8),
		"Base groove is a no-op")
	# Shake: offbeat 16ths delayed, on-beats straight; offsets wrap their period.
	check(Groove.offset_beats(1, 0) == 0.0, "Shake leaves the beat straight")
	check(is_equal_approx(Groove.offset_beats(1, 1), 0.0494 * 0.7), "Shake delays the offbeat (x amount)")
	check(Groove.offset_beats(1, 17) == Groove.offset_beats(1, 1), "offsets cycle their period")
	# Samples conversion at a known tempo.
	var expected := int(round(0.0494 * 0.7 * (60.0 / 112.0) * 44100.0))
	check(Groove.offset_samples(1, 1, 112.0, 44100.0) == expected, "offset converts to samples correctly")
	# Velocity lens: lerp toward the per-step multiplier by VELOCITY_AMOUNT.
	check(is_equal_approx(Groove.apply_velocity(1.0, 1, 1), lerpf(1.0, 0.148, 0.2)),
		"velocity shaped toward the template multiplier")
	# Trip's rushed offsets stay far inside the scheduler lookahead (pinned
	# max_negative_groove_offset constraint) even at slow tempos.
	var worst := absf(Groove.offset_beats(4, 1)) * (60.0 / 60.0)
	check(worst < 0.25, "worst negative groove offset < lookahead at 60 BPM")

	# Drum-state mixer/groove: replicate through the same dict as kit.
	var s := DrumState.new()
	s.set_mix(0, 1.8)
	s.set_mix(5, 9.0) # clamped
	s.groove = 3
	var rt := DrumState.new()
	rt.from_dict(JSON.parse_string(JSON.stringify(s.to_dict())))
	check(is_equal_approx(rt.mix[0], 1.8) and is_equal_approx(rt.mix[5], 2.0) and rt.groove == 3,
		"mix (clamped) and groove survive the replication round trip")


func _test_chord_comp() -> void:
	# Voicings: same pitch classes, different spread.
	var triad := [60, 64, 67]
	check(ChordComp.voice(triad, 0) == [60, 64, 67], "Close voicing is the triad as-is")
	check(ChordComp.voice(triad, 1) == [60, 67, 76], "Open drops the middle voice up an octave")
	check(ChordComp.voice(triad, 2) == [48, 64, 79], "Wide spreads root down, fifth up")

	# Patterns: hits only on legal steps; Pad strikes bar-top only.
	for p in ChordComp.PATTERNS:
		for h in p.hits:
			check(int(h.step) >= 0 and int(h.step) <= 15, "comp hit steps are legal")
	check(ChordComp.events_for_step(0, 0, 0, triad).size() == 1
		and ChordComp.events_for_step(0, 0, 8, triad).is_empty(),
		"Pad strikes the bar top and nothing else")
	var off := ChordComp.events_for_step(2, 0, 6, triad)
	check(off.size() == 1 and off[0].roll and is_equal_approx(off[0].vel, 0.7 * 0.7),
		"Offbeat comp strikes step 6 in the comping velocity band, rolled")
	var arp := ChordComp.events_for_step(4, 0, 4, triad)
	check(arp.size() == 1 and arp[0].midis == [67] and not arp[0].roll,
		"Arp emits single cycling voiced notes, unrolled")

	# Performance is commit-gated state on the chord track, like any edit.
	var m := CommitModel.new(ChordTrack.new())
	TrackOps.apply(m, TrackOps.TRACK_CHORDS, "comp", {"comp": 2, "voicing": 1}, 0)
	check(m.pending.comp == 2 and m.pending.voicing == 1 and m.active.comp == 0,
		"comp edits the pending buffer; active performs until the boundary")
	var t := ChordTrack.new()
	var u = t.clone()
	u.set_performance(3, 2)
	check(not t.equals(u), "performance changes are commit-relevant (equals sees them)")
	var rt2 := ChordTrack.new()
	rt2.from_dict(JSON.parse_string(JSON.stringify(u.to_dict())))
	check(rt2.comp == 3 and rt2.voicing == 2, "performance survives replication")


func _test_harmony() -> void:
	check(Harmony.degree_to_midi(60, 0) == 60, "degree 0 is the root")
	check(Harmony.degree_to_midi(60, 4) == 67, "degree 4 is the fifth")
	check(Harmony.degree_to_midi(60, 7) == 72, "degree 7 is root + octave")
	check(Harmony.triad_midi(60, 0) == [60, 64, 67], "I triad in C is C-E-G")
	check(Harmony.triad_midi(60, 5) == [69, 72, 76], "vi triad in C is A-C-E")
	check(Harmony.note_name(60) == "C4", "MIDI 60 is C4")
	check(Harmony.note_name(36) == "C2", "MIDI 36 is C2 (bass root)")
	check(Harmony.ROMAN.size() == 7, "seven roman numerals")

	# Chord-relative bass vocabulary: one stored motif (all five lanes) sounds
	# different pitch classes under each chord of V | vi | IV | V — the whole
	# semantic reinterpretation captured in one table.
	var expected := {
		4: ["G", "B", "D", "F", "G"], # V
		5: ["A", "C", "E", "G", "A"], # vi
		3: ["F", "A", "C", "E", "F"], # IV
	}
	for chord_deg in expected:
		for lane in 5:
			var midi := Harmony.chord_tone_midi(36, chord_deg, lane)
			check(Harmony.pitch_class_name(midi) == expected[chord_deg][lane],
				"chord %s lane %s sounds %s" % [Harmony.ROMAN[chord_deg], Harmony.BASS_TONE_NAMES[lane], expected[chord_deg][lane]])
	# Same lane, different bars -> different sounding MIDI (the bug this fixes).
	check(Harmony.chord_tone_midi(36, 4, 0) != Harmony.chord_tone_midi(36, 5, 0),
		"identical stored lane follows the progression")
	# O is the one lane that isn't "stack another diatonic third".
	for chord_deg in 7:
		check(Harmony.chord_tone_midi(36, chord_deg, 4) == Harmony.chord_tone_midi(36, chord_deg, 0) + 12,
			"octave lane = chord root + 12 (degree %d)" % chord_deg)
	# Empty chord slot resolves against the tonic, and the diatonic seventh needs
	# no explicit 7th-chord spelling: R/3/5/7 over an empty (tonic) bar = C E G B.
	check(Harmony.chord_tone_midi(36, -1, 0) == 36 and Harmony.chord_tone_midi(36, -1, 3) == 47,
		"empty slot falls back to tonic; diatonic seventh derived from the key")
