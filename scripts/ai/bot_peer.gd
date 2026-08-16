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
const RuleBassPolicy := preload("res://scripts/ai/rule_bass_policy.gd")
const DecisionLog := preload("res://scripts/ai/decision_log.gd")
const Features := preload("res://scripts/core/jam_features.gd")

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

# observability
var decisions := 0
var holds := 0
var edits := 0
var ops_sent := 0
var authored := {} # "(epoch)/(role)/(target_loop)" -> true

var _last_seen_loop := -1
var _last_version := -1
var _windows_since_change := 0
var _pending_commit_key = null # DecisionKey of the last edit awaiting its version bump
var _op_seq := 0 # client-assigned op sequence IDs (log-side only for now)


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
	var net = room.net
	if net != null and net.active and not net.can_edit(role):
		return # not our seat in this room — also enforced server-side

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
	var obs := BotObservation.build_bass(
		room.model_for(TRACK_BASS), room.model_for(TRACK_DRUMS), room.model_for(TRACK_CHORDS),
		target, _windows_since_change)
	var seed_value := DecisionLog.derive_seed(session_seed, epoch, role, target)
	# Measure the observed state BEFORE dispatching — ops mutate the pending
	# buffer, and analysis_before must not contain the bot's own edit.
	var analysis := Features.extract({
		"drums": BotObservation.state_at(room.model_for(TRACK_DRUMS), target).to_dict(),
		"bass": BotObservation.state_at(room.model_for(TRACK_BASS), target).to_dict(),
		"chords": BotObservation.state_at(room.model_for(TRACK_CHORDS), target).to_dict(),
	})

	var t0 := Time.get_ticks_usec()
	var ops := RuleBassPolicy.decide(obs, seed_value)
	var logged_ops := []
	for op in ops:
		_op_seq += 1
		room.dispatch(op.track, op.op, op.args)
		var entry: Dictionary = op.duplicate(true)
		entry["seq"] = _op_seq
		logged_ops.append(entry)
	var t1 := Time.get_ticks_usec()

	decisions += 1
	ops_sent += ops.size()
	_windows_since_change += 1
	if ops.is_empty():
		holds += 1
	else:
		edits += 1
		_pending_commit_key = key

	if decision_log != null:
		decision_log.write(DecisionLog.build_frame(
			key, source, RuleBassPolicy.POLICY_NAME, RuleBassPolicy.POLICY_VERSION,
			seed_value, obs, logged_ops, t0, t1, _deadline_margin_steps(), analysis))


## Steps of headroom left before the lock horizon of the loop being authored
## against. Negative or tiny margins in logs flag decisions that risked N+2.
func _deadline_margin_steps() -> float:
	var tr = room.get("transport")
	if tr == null:
		return -1.0
	var step_in_loop := fmod(tr.position_steps(), float(STEPS_PER_LOOP))
	return float(STEPS_PER_LOOP - LOCK_HORIZON_STEPS) - step_in_loop
