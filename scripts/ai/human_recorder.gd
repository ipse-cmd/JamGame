class_name JamHumanRecorder
extends Node

# Phase 2.5: record HUMAN decisions with the same window semantics as the bot —
# you cannot reconstruct human decisions from sessions you failed to record.
# Each editable window becomes one DecisionFrame: the observation is built when
# the window OPENS (pre-edit, same contract as BotPeer), raw ops accumulate in
# submission order while the window is live, and the frame is written when the
# boundary closes it. Zero-op windows are first-class HOLD frames; attention
# proxies (window focus, raw input activity) let analysis separate a deliberate
# hold from an AFK one. Purely an observer — it never dispatches anything.

const BotObservation := preload("res://scripts/ai/bot_observation.gd")
const Analysis := preload("res://scripts/core/jam_analysis.gd")
const DecisionLog := preload("res://scripts/ai/decision_log.gd")
const History := preload("res://scripts/core/jam_history.gd")

const TRACK_DRUMS := 0
const TRACK_BASS := 1
const TRACK_CHORDS := 2
const STEPS_PER_LOOP := 64
const LOCK_HORIZON_STEPS := 2

const POLICY_NAME := "human_ui"
const POLICY_VERSION := 1

var room # duck-typed like BotPeer: loop_index, model_for(), net/transport optional
var role := TRACK_BASS
var decision_log # JamDecisionLog or null

# observability
var frames := 0
var holds := 0
var edit_frames := 0
var ops_captured := 0

const TRACK_KEYS := ["drums", "bass", "chords"]

var _last_seen_loop := -1
var _last_version := -1
var _windows_since_change := 0
var _op_seq := 0
var _input_events := 0
var _history := History.new()
var _win = null # open window: {key, obs, ops, t0, last_margin, focused}
var _track_versions := {} # track -> last seen version_id (attribution)
var _last_change_by := {"drums": "none", "bass": "none", "chords": "none"}
var _authored_since := {0: false, 1: false, 2: false} # local ops since last bump, per track


func _process(_delta: float) -> void:
	if room == null:
		return
	var loop: int = room.loop_index
	if loop >= 0 and loop != _last_seen_loop:
		_last_seen_loop = loop
		on_loop(loop)


## Boundary crossing: close (write) the window that just locked, open the next.
## Public so tests drive musical time directly.
func on_loop(loop: int) -> void:
	_history.push(loop, {
		"drums": room.model_for(TRACK_DRUMS).active.to_dict(),
		"bass": room.model_for(TRACK_BASS).active.to_dict(),
		"chords": room.model_for(TRACK_CHORDS).active.to_dict(),
	}, [
		room.model_for(TRACK_DRUMS).version_id,
		room.model_for(TRACK_BASS).version_id,
		room.model_for(TRACK_CHORDS).version_id,
	])
	_flush_window()

	# Change attribution: a track's bump is "self" iff the local player
	# dispatched ops into it since the previous bump (edit_dispatched fires
	# only for locally ACCEPTED edits, so this is the player's own authorship).
	for t in 3:
		var m = room.model_for(t)
		if not _track_versions.has(t):
			_track_versions[t] = m.version_id
		elif m.version_id != _track_versions[t]:
			_track_versions[t] = m.version_id
			_last_change_by[TRACK_KEYS[t]] = "self" if _authored_since.get(t, false) else "other"
			_authored_since[t] = false

	var model = room.model_for(role)
	if model.version_id != _last_version:
		_last_version = model.version_id
		_windows_since_change = 0

	var net = room.net
	if net != null and net.active and not net.can_edit(role):
		return # not this player's seat — nothing to record

	var epoch: int = net.room_epoch if net != null else 0
	var target := loop + 1
	var w := get_window()
	_win = {
		"key": DecisionLog.make_key(epoch, role, target, model.version_id),
		"obs": BotObservation.build_bass(
			room.model_for(TRACK_BASS), room.model_for(TRACK_DRUMS), room.model_for(TRACK_CHORDS),
			target, _windows_since_change, _history, _last_change_by.duplicate()),
		"ops": [],
		"t0": Time.get_ticks_usec(),
		"last_margin": -1.0,
		"focused": w != null and w.has_focus(),
	}
	_input_events = 0
	_windows_since_change += 1


## Fed by the room's edit_dispatched signal (or directly by tests): every op the
## local player successfully dispatched, in raw submission order.
func _on_edit_dispatched(track: int, op: String, args: Dictionary) -> void:
	_authored_since[track] = true # attribution: this player touched the track
	if _win == null or track != role:
		return
	_op_seq += 1
	ops_captured += 1
	_win.ops.append({"track": track, "op": op, "args": args.duplicate(true), "seq": _op_seq})
	_win.last_margin = _deadline_margin_steps()


func _flush_window() -> void:
	if _win == null:
		return
	var t1 := Time.get_ticks_usec()
	if decision_log != null:
		decision_log.write(DecisionLog.build_frame(
			_win.key, DecisionLog.SOURCE_HUMAN, POLICY_NAME, POLICY_VERSION,
			0, _win.obs, _win.ops, _win.t0, t1, _win.last_margin, _win.obs.features,
			{"window_focused": _win.focused, "input_events": _input_events,
				"interpretation": Analysis.interpret(_win.obs)}))
	frames += 1
	if _win.ops.is_empty():
		holds += 1
	else:
		edit_frames += 1
	_win = null


func _input(_event: InputEvent) -> void:
	_input_events += 1 # attention proxy: any raw input during the window


func _deadline_margin_steps() -> float:
	var tr = room.get("transport")
	if tr == null:
		return -1.0
	var step_in_loop := fmod(tr.position_steps(), float(STEPS_PER_LOOP))
	return float(STEPS_PER_LOOP - LOCK_HORIZON_STEPS) - step_in_loop
