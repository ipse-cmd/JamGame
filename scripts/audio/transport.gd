class_name JamTransport
extends Node

# The single loop clock (no second clock, ever — Jammin rule).
#
# NATIVE mode (G2): a lookahead scheduler anchored to the audio thread's absolute
# sample cursor. Each frame it emits schedule_sixteenth for every step whose sample
# stamp falls inside [already-scheduled, cursor + lookahead], so events are submitted
# to the native queue BEFORE they are due — the game thread can hitch by tens of ms
# without touching anything already queued. The separate sixteenth signal tracks the
# AUDIBLE playhead (cursor crossing step stamps) and drives UI/display only.
#
# LEGACY mode: the G0 frame-polled tick (kept for running without the extension).

signal sixteenth(abs_step: int) # audible playhead crossed a step (UI/display)
signal schedule_sixteenth(abs_step: int, at_sample: int) # native: submit this step's events now

var bpm: float = 112.0
var playing: bool = false
var native := false
var mix_rate := 44100.0
# Must exceed one step spacing (134 ms per sixteenth at 112 BPM) plus the worst
# main-thread stall, or steps that become due between frames get submitted late.
var lookahead_seconds := 0.25
var start_margin_seconds := 0.05
var cursor_source: Callable # returns the absolute sample cursor (int)

# --- native state ---
var _start_sample: int = 0 # sample stamp of musical step 0
var _sched_step: int = 0 # next step to submit to the audio queue
var _play_step: int = 0 # next step the audible playhead will cross

# --- legacy state ---
const MAX_CATCHUP_STEPS := 8
var _anchor_usec: int = 0
var _elapsed_paused: float = 0.0
var _next_step: int = 0


func samples_per_step() -> float:
	return mix_rate * 60.0 / bpm / 4.0


func step_sample(step: int) -> int:
	return _start_sample + int(round(step * samples_per_step()))


func start() -> void:
	if native:
		_start_sample = int(cursor_source.call()) + int(start_margin_seconds * mix_rate)
		_sched_step = 0
		_play_step = 0
	else:
		_anchor_usec = Time.get_ticks_usec()
		_elapsed_paused = 0.0
		_next_step = 0
	playing = true


## Re-anchor the local timeline so the musical position is pos_steps RIGHT NOW —
## used by a joining client to phase-lock onto the server's musical clock (the
## Jammin M-PL0 move). Scheduling resumes from the first step safely in the future.
func start_at(pos_steps: float) -> void:
	if native:
		var cur := int(cursor_source.call())
		_start_sample = cur - int(round(pos_steps * samples_per_step()))
		var next := int(ceil(pos_steps))
		var margin := cur + int(start_margin_seconds * mix_rate)
		while step_sample(next) <= margin:
			next += 1
		_sched_step = next
		_play_step = next
	else:
		_anchor_usec = Time.get_ticks_usec() - int(pos_steps * (60.0 / bpm / 4.0) * 1e6)
		_next_step = int(ceil(pos_steps))
	playing = true


func toggle_pause() -> void:
	if native:
		if playing:
			playing = false # scheduling stops; up to lookahead_seconds already queued rings out
		else:
			# Re-anchor so the next unscheduled step lands just after now; the audible
			# playhead jumps to match (steps queued across the pause already sounded).
			_start_sample = int(cursor_source.call()) + int(start_margin_seconds * mix_rate) \
					- int(round(_sched_step * samples_per_step()))
			_play_step = _sched_step
			playing = true
		return
	if playing:
		_elapsed_paused = _elapsed_seconds()
		playing = false
	else:
		_anchor_usec = Time.get_ticks_usec() - int(_elapsed_paused * 1e6)
		playing = true


## Continuous playhead position in sixteenths since start (for smooth UI).
func position_steps() -> float:
	if native:
		return (float(int(cursor_source.call()) - _start_sample)) / samples_per_step()
	var elapsed := _elapsed_paused if not playing else _elapsed_seconds()
	return elapsed / (60.0 / bpm / 4.0)


func _process(_delta: float) -> void:
	if not playing:
		return
	if native:
		var cur := int(cursor_source.call())
		while step_sample(_play_step) <= cur:
			sixteenth.emit(_play_step)
			_play_step += 1
		var horizon := cur + int(lookahead_seconds * mix_rate)
		while step_sample(_sched_step) <= horizon:
			schedule_sixteenth.emit(_sched_step, step_sample(_sched_step))
			_sched_step += 1
		return
	# legacy frame-polled tick
	var now := _elapsed_seconds()
	var sps := 60.0 / bpm / 4.0
	var due := int(floor(now / sps)) + 1
	if due - _next_step > MAX_CATCHUP_STEPS:
		_next_step = due - 1 # jump silently; the room re-derives loop index from abs_step
	while _next_step * sps <= now:
		sixteenth.emit(_next_step)
		_next_step += 1


func _elapsed_seconds() -> float:
	return float(Time.get_ticks_usec() - _anchor_usec) / 1e6
