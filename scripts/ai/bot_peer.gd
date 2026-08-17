class_name JamBotPeer
extends Node

# Phase 1B: an AI participant mounted as an ORDINARY peer. It observes replicated
# state, decides once per editable window, and submits ops through the room's
# normal dispatch path — local prediction + server validation, exactly like a
# human. No privileged mutation path exists: the server may reject it, the lock
# horizon may slip it, role gates silence it. Bot location must not matter — the
# same node mounts in-process (fill-the-empty-seats) or in a headless client
# (--bot), and the integration suite asserts the peer semantics.
#
# Determinism: decisions are keyed to musical time only. The per-window seed is
# derived from (session_seed, room_epoch, role, target_loop) — no wall clock, no
# global RNG — so the same session seed replays the same musicianship at any
# transport speed.

const BotObservation := preload("res://scripts/ai/bot_observation.gd")
const Analysis := preload("res://scripts/core/jam_analysis.gd")
const IntentPolicy := preload("res://scripts/ai/intent_policy.gd")
const RuleBassPolicy := preload("res://scripts/ai/rule_bass_policy.gd")
const DecisionLog := preload("res://scripts/ai/decision_log.gd")
const History := preload("res://scripts/core/jam_history.gd")

const TRACK_DRUMS := 0
const TRACK_BASS := 1
const TRACK_CHORDS := 2
const STEPS_PER_LOOP := 64
const LOCK_HORIZON_STEPS := 2

var room # duck-typed: loop_index, model_for(), dispatch(), net (optional), transport (optional)
var role := TRACK_BASS
var session_seed := 1
var source := DecisionLog.SOURCE_RULE_BOT
var decision_log # JamDecisionLog or null — windows go unrecorded without one
# Shadow mode (Phase 2.5): observe + decide + LOG, never dispatch. Mounts on a
# peer that does NOT own the seat, so a human plays bass while the policy's
# proposals are recorded against the identical observations — the raw material
# for human-vs-policy comparison and preference data.
var shadow := false

# observability
var decisions := 0
var holds := 0
var edits := 0
var ops_sent := 0
var authored := {} # "(epoch)/(role)/(target_loop)" -> true

const TRACK_KEYS := ["drums", "bass", "chords"]

var _last_seen_loop := -1
var _last_version := -1
var _windows_since_change := 0
var _track_versions := {} # track -> last seen version_id (all tracks, for attribution)
var _last_change_by := {"drums": "none", "bass": "none", "chords": "none"}
var _pending_commit_key = null # DecisionKey of the last edit awaiting its version bump
var _op_seq := 0 # client-assigned op sequence IDs (log-side only for now)
var _history := History.new() # per-loop committed snapshots for temporal features


func _process(_delta: float) -> void:
	if room == null:
		return
	var loop: int = room.loop_index
	if loop >= 0 and loop != _last_seen_loop:
		_last_seen_loop = loop
		on_loop(loop)


## One decision opportunity per loop: author (or deliberately HOLD) the next
## editable window. Public so tests drive musical time directly.
func on_loop(loop: int) -> void:
	# History records what is actually AUDIBLE this loop (active states), with
	# all three version counters so per-track change ages can be measured.
	_history.push(loop, {
		"drums": room.model_for(TRACK_DRUMS).active.to_dict(),
		"bass": room.model_for(TRACK_BASS).active.to_dict(),
		"chords": room.model_for(TRACK_CHORDS).active.to_dict(),
	}, [
		room.model_for(TRACK_DRUMS).version_id,
		room.model_for(TRACK_BASS).version_id,
		room.model_for(TRACK_CHORDS).version_id,
	])

	# Change attribution: only the participant knows which ops were its own. A
	# bass bump is "self" iff we authored the edit awaiting resolution; every
	# other track's bump (and every bump in shadow mode) is "other".
	for t in 3:
		var m = room.model_for(t)
		if not _track_versions.has(t):
			_track_versions[t] = m.version_id
		elif m.version_id != _track_versions[t]:
			_track_versions[t] = m.version_id
			_last_change_by[TRACK_KEYS[t]] = "self" if t == role and _pending_commit_key != null else "other"

	var net = room.net
	if net != null and net.active and not net.can_edit(role) and not shadow:
		return # not our seat in this room — also enforced server-side (shadow only watches)

	var model = room.model_for(role)
	if model.version_id != _last_version:
		# The window that caused this change has resolved: log what actually
		# committed, and give the new line a window to breathe (staleness reset).
		if decision_log != null and _pending_commit_key != null:
			decision_log.write(DecisionLog.build_commit(
				_pending_commit_key, model.active.to_dict(), model.version_id, loop))
		_pending_commit_key = null
		_last_version = model.version_id
		_windows_since_change = 0

	# Watermark: at most one authored decision per (epoch, role, target). An
	# epoch bump (rehost/reset) legitimately reopens the same target loops.
	var epoch: int = net.room_epoch if net != null else 0
	var target := loop + 1
	var mark := "%d/%d/%d" % [epoch, role, target]
	if authored.has(mark):
		return
	authored[mark] = true

	var key := DecisionLog.make_key(epoch, role, target, model.version_id)
	# Built BEFORE dispatching — ops mutate the pending buffer, and the
	# observation (features included) must not contain the bot's own edit.
	var obs := BotObservation.build_bass(
		room.model_for(TRACK_BASS), room.model_for(TRACK_DRUMS), room.model_for(TRACK_CHORDS),
		target, _windows_since_change, _history, _last_change_by.duplicate())
	var seed_value := DecisionLog.derive_seed(session_seed, epoch, role, target)

	var t0 := Time.get_ticks_usec()
	var ops := RuleBassPolicy.decide(obs, seed_value)
	var logged_ops := []
	for op in ops:
		_op_seq += 1
		if not shadow:
			room.dispatch(op.track, op.op, op.args)
		var entry: Dictionary = op.duplicate(true)
		entry["seq"] = _op_seq
		logged_ops.append(entry)
	var t1 := Time.get_ticks_usec()

	decisions += 1
	_windows_since_change += 1
	if ops.is_empty():
		holds += 1
	else:
		edits += 1
		if not shadow:
			ops_sent += ops.size()
			_pending_commit_key = key # shadow proposals never commit — nothing to resolve

	if decision_log != null:
		var interp := Analysis.interpret(obs)
		# 3B shadow: the intent the interpretation-aware policy WOULD choose,
		# logged next to the frozen baseline's ops — never realized here.
		var extra := {"interpretation": interp, "intent": IntentPolicy.decide(obs, interp)}
		if shadow:
			extra["shadow"] = true
		decision_log.write(DecisionLog.build_frame(
			key, source, RuleBassPolicy.POLICY_NAME, RuleBassPolicy.POLICY_VERSION,
			seed_value, obs, logged_ops, t0, t1, _deadline_margin_steps(), obs.features, extra))


## Steps of headroom left before the lock horizon of the loop being authored
## against. Negative or tiny margins in logs flag decisions that risked N+2.
func _deadline_margin_steps() -> float:
	var tr = room.get("transport")
	if tr == null:
		return -1.0
	var step_in_loop := fmod(tr.position_steps(), float(STEPS_PER_LOOP))
	return float(STEPS_PER_LOOP - LOCK_HORIZON_STEPS) - step_in_loop
