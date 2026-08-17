extends Control

# JamRoom — the G0 spike shell. Single player, local 4-bar loop, three tracks
# (drum ring, bass ring, chord strip), each behind its own active/pending commit
# model that promotes at the next loop boundary — Unreal Jammin is the reference
# behavior. UI is a read-only projection; input dispatches edits to pending buffers.

const DrumPattern := preload("res://scripts/core/drum_pattern.gd")
const PatternEditor := preload("res://scripts/core/drum_pattern_editor.gd")
const CommitModel := preload("res://scripts/core/commit_model.gd")
const BassLine := preload("res://scripts/core/bass_line.gd")
const ChordTrack := preload("res://scripts/core/chord_track.gd")
const Harmony := preload("res://scripts/core/harmony.gd")
const AudioEngine := preload("res://scripts/audio/audio_engine.gd")
const Transport := preload("res://scripts/audio/transport.gd")
const NetSession := preload("res://scripts/net/net_session.gd")
const TrackOps := preload("res://scripts/core/track_ops.gd")
const DrumState := preload("res://scripts/core/drum_state.gd")
const DrumRenderer := preload("res://scripts/core/drum_renderer.gd")
const Templates := preload("res://scripts/core/drum_templates.gd")
const StepRing := preload("res://scripts/ui/step_ring.gd")
const ChordStrip := preload("res://scripts/ui/chord_strip.gd")
const RadialBloom := preload("res://scripts/ui/radial_bloom.gd")
const BotPeer := preload("res://scripts/ai/bot_peer.gd")
const IntentBassPolicy := preload("res://scripts/ai/intent_bass_policy.gd")
const DecisionLog := preload("res://scripts/ai/decision_log.gd")
const HumanRecorder := preload("res://scripts/ai/human_recorder.gd")

## Emitted for every locally accepted edit (keyboard, pointer, or mounted bot) —
## the tap point for decision recording. Fires AFTER local application.
signal edit_dispatched(track: int, op: String, args: Dictionary)

const BARS_PER_LOOP := 4
const STEPS_PER_BAR := 16
const STEPS_PER_LOOP := BARS_PER_LOOP * STEPS_PER_BAR
const DEFAULT_VELOCITY := 0.75
const BASS_ROOT_MIDI := 36 # C2 — bass ring degrees ascend from here (key of C major)
const CHORD_ROOT_MIDI := 60 # C4

const DRUM_LANE_NAMES := ["Kick", "Snare", "Hat", "Perc"]
const DRUM_LANE_COLORS := [Color("e05a4e"), Color("e8b84b"), Color("6fd3e0"), Color("b58ce8")]
const BASS_LANE_COLORS := [Color("e06c5a"), Color("e8b84b"), Color("8fd15f"), Color("5fc9d8"), Color("b58ce8")]

enum Focus { DRUMS, BASS, CHORDS }

const HELP_TEXT := """CONTROLS

POINTER (mouse / touch)
  tap wedge     toggle hit / place tone
  hold wedge    radial options
                (drums: accent/del,
                 bass: R 3 5 7 O)
  press chord bar  chord picker
  drag + release chooses; quick tap
  keeps it open; Esc / right-click cancels

GLOBAL
  Tab     switch instrument
  Space   pause / resume
  F1      toggle this help
  C       cancel pending edit
  X       clear all (focused track)
  Del     clear lane / line / slot

NETWORK (deliberately ugly)
  F2      host a jam (port 7777)
  F3      join 127.0.0.1
  F9      hitch test (stall main thread)
  F10     toggle net lag simulator
In a room you only edit YOUR track:
host=drums, 2nd player=bass, 3rd=chords.

DRUM RING (focus: DRUMS)
  1-4     select lane
  Left/Right  move step cursor
  Enter   place / remove hit
  Y       toggle accent
  F/G/H   fill / drop / intensify
  K       kit sound (selected lane)
  T       starter templates

BASS RING (focus: BASS)
  1-5     select scale degree
  Left/Right  move step cursor
  Enter   place / re-tune / remove

CHORD STRIP (focus: CHORDS)
  Left/Right  select bar
  A / D   cycle chord
  Del     clear slot

Edits show as ghosts and COMMIT at the
next 4-bar loop boundary (Jammin rule:
edit in loop N -> commit at N+1)."""

var drums: JamCommitModel
var bass: JamCommitModel
var chords: JamCommitModel
var drum_state: JamDrumState
var _template_cursor := -1 # last applied starter template (T cycles)

var transport: JamTransport
var audio: JamAudioEngine
var net: JamNetSession
var drum_ring: JamStepRing
var bass_ring: JamStepRing
var chord_strip: JamChordStrip
var hud_line: Label
var status_line: Label
var net_line: Label
var help_label: Label

var focus: int = Focus.DRUMS
var drum_lane := 0
var drum_cursor := 0
var bass_lane := 0
var bass_cursor := 0
var chord_cursor := 0

var loop_index := -1 # audible loop (display + pending-edit basis)
var bar_in_loop := 0
var step_in_bar := 0
var _sched_loop := -1 # loop index in the SCHEDULE domain (runs ahead by the lookahead)
var hitch_mode := false # F9: deliberately stall the main thread to prove timing immunity
var _is_bot_instance := false # --bot mounts an autonomous player; no human to record


func _ready() -> void:
	add_to_group("mcp_watch")
	_build_tracks()
	_build_scene()
	transport.native = audio.native
	transport.mix_rate = audio.mix_rate
	transport.cursor_source = audio.sample_cursor
	transport.sixteenth.connect(_on_sixteenth)
	transport.schedule_sixteenth.connect(_on_schedule_sixteenth)
	transport.start()
	for arg in OS.get_cmdline_user_args():
		if arg == "--host":
			net.host()
		elif arg.begins_with("--bpm="):
			# Dev/test knob: match a test harness transport (e.g. 448 = 4x) so an
			# externally launched peer agrees on loop timing.
			transport.bpm = float(arg.trim_prefix("--bpm="))
		elif arg.begins_with("--join="):
			net.join(arg.trim_prefix("--join="))
		elif arg == "--lagsim":
			net.lag_sim = true
		elif arg == "--bot" or arg.begins_with("--bot-seed="):
			# Autonomous bass peer (Phase 1B): the real rule-based BotPeer, playing
			# through the normal dispatch path like any human, decisions logged.
			var bot := BotPeer.new()
			bot.room = self
			if arg.begins_with("--bot-seed="):
				bot.session_seed = int(arg.trim_prefix("--bot-seed="))
			if "--bot-policy=intent" in OS.get_cmdline_user_args():
				bot.policy = IntentBassPolicy
				bot.log_realization = true
			var dlog := DecisionLog.new()
			dlog.open({
				"session_id": "bot_%d" % int(Time.get_unix_time_from_system()),
				"session_seed": bot.session_seed,
				"policy": bot.policy.POLICY_NAME,
				"source": DecisionLog.SOURCE_RULE_BOT,
			})
			bot.decision_log = dlog
			add_child(bot)
			_is_bot_instance = true
		elif arg == "--shadow" or arg.begins_with("--shadow-seed="):
			# Phase 2.5 shadow policy: decides + logs proposals on the human's
			# observations, never dispatches. Mount alongside the human UI.
			var sbot := BotPeer.new()
			sbot.room = self
			sbot.shadow = true
			if arg.begins_with("--shadow-seed="):
				sbot.session_seed = int(arg.trim_prefix("--shadow-seed="))
			var slog := DecisionLog.new()
			slog.open({
				"session_id": "shadow_%d" % int(Time.get_unix_time_from_system()),
				"session_seed": sbot.session_seed,
				"source": DecisionLog.SOURCE_RULE_BOT,
			})
			sbot.decision_log = slog
			add_child(sbot)

	# Human decision recording is ALWAYS on for player instances — you cannot
	# reconstruct human decisions from sessions you failed to record. Bass-role
	# windows only (bass-first roadmap); zero-op HOLDs included.
	if not _is_bot_instance:
		var rec := HumanRecorder.new()
		rec.room = self
		var hlog := DecisionLog.new()
		hlog.open({
			"session_id": "human_%d" % int(Time.get_unix_time_from_system()),
			"source": DecisionLog.SOURCE_HUMAN,
		})
		rec.decision_log = hlog
		edit_dispatched.connect(rec._on_edit_dispatched)
		add_child(rec)
	_refresh_ui()


func _process(_delta: float) -> void:
	if hitch_mode:
		# TEST ONLY (G2.6): murder the main thread. Queued audio must not care.
		OS.delay_msec(randi_range(5, 25))


func _build_tracks() -> void:
	var starter := DrumPattern.new()
	for kick_step in [0, 8]:
		PatternEditor.toggle_hit(starter, 0, kick_step)
	PatternEditor.toggle_accent(starter, 0, 0)
	for snare_step in [4, 12]:
		PatternEditor.toggle_hit(starter, 1, snare_step)
	for hat_step in range(0, 16, 2):
		PatternEditor.toggle_hit(starter, 2, hat_step, 0.6)
	drums = CommitModel.new(starter)

	var line := BassLine.new()
	line.notes = {0: 0, 8: 0, 12: 4}
	bass = CommitModel.new(line)

	var track := ChordTrack.new()
	track.slots = [0, 5, 3, 4] # I - vi - IV - V
	chords = CommitModel.new(track)

	drum_state = DrumState.new()


func _build_scene() -> void:
	var bg := ColorRect.new()
	bg.color = Color("101318")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	audio = AudioEngine.new()
	add_child(audio)
	transport = Transport.new()
	add_child(transport)
	net = NetSession.new()
	net.name = "Net" # stable node path — RPCs are bound to it on every instance
	net.room = self
	add_child(net)

	hud_line = _make_label(Vector2(60, 24), 18, Color("f0f3f7"))
	status_line = _make_label(Vector2(60, 52), 13, Color("8a93a0"))
	net_line = _make_label(Vector2(60, 74), 13, Color("7fa0c0"))

	drum_ring = StepRing.new()
	drum_ring.title = "DRUMS"
	drum_ring.lane_names = DRUM_LANE_NAMES
	drum_ring.lane_colors = DRUM_LANE_COLORS
	drum_ring.position = Vector2(50, 110)
	drum_ring.size = Vector2(440, 440)
	add_child(drum_ring)

	bass_ring = StepRing.new()
	bass_ring.title = "BASS"
	bass_ring.lane_names = _bass_lane_names()
	bass_ring.lane_colors = BASS_LANE_COLORS
	bass_ring.position = Vector2(505, 110)
	bass_ring.size = Vector2(440, 440)
	add_child(bass_ring)

	chord_strip = ChordStrip.new()
	chord_strip.position = Vector2(50, 580)
	chord_strip.size = Vector2(895, 116)
	add_child(chord_strip)

	# Pointer grammar: tap = obvious action, hold = radial options. The rings
	# report gestures; every handler routes through the SAME _dispatch as the
	# keyboard (role gate, validation, commit boundary all apply unchanged).
	drum_ring.cell_tapped.connect(_on_drum_cell_tapped)
	drum_ring.cell_held.connect(_on_drum_cell_held)
	bass_ring.cell_tapped.connect(_on_bass_cell_tapped)
	bass_ring.cell_held.connect(_on_bass_cell_held)
	chord_strip.bar_pressed.connect(_on_chord_bar_pressed)

	help_label = _make_label(Vector2(975, 84), 11, Color("aeb7c2"))
	help_label.text = HELP_TEXT


func _make_label(pos: Vector2, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	add_child(l)
	return l


func _bass_lane_names() -> Array:
	var names: Array = []
	for d in BassLine.NUM_DEGREES:
		# Lanes are chord-relative roles (R/3/5/7/O), not fixed pitches — the
		# sounding note follows the bar's chord at render time.
		names.append("%d · %s" % [d + 1, Harmony.BASS_TONE_NAMES[d]])
	return names


# ---------------------------------------------------------------- transport

## Audible playhead crossed a step. In native mode this is display-only (audio was
## already scheduled ahead); in legacy mode it also commits and fires sounds.
func _on_sixteenth(abs_step: int) -> void:
	@warning_ignore("integer_division")
	var new_loop: int = abs_step / STEPS_PER_LOOP
	if transport.native:
		loop_index = new_loop
	elif new_loop != loop_index:
		loop_index = new_loop
		_try_commits(loop_index)
	var step_in_loop := abs_step % STEPS_PER_LOOP
	step_in_bar = step_in_loop % STEPS_PER_BAR
	@warning_ignore("integer_division")
	bar_in_loop = step_in_loop / STEPS_PER_BAR

	if not transport.native:
		for h in drums.active.hits:
			if h.step == step_in_bar:
				audio.trigger_drum(h.voice, h.velocity, h.accent)
		if bass.active.notes.has(step_in_bar):
			audio.trigger_bass(
				Harmony.chord_tone_midi(BASS_ROOT_MIDI, chords.active.slots[bar_in_loop], bass.active.notes[step_in_bar]), 0.8)
		if step_in_bar == 0:
			var deg: int = chords.active.slots[bar_in_loop]
			if deg >= 0:
				audio.trigger_chord(Harmony.triad_midi(CHORD_ROOT_MIDI, deg), 0.7)
	_refresh_ui()


## Native path: submit this step's events with an absolute sample stamp, ahead of
## audible time. Commits run in the SCHEDULE domain so a promoted pattern applies
## exactly from the boundary step onward — the future buffer taken down to samples.
func _on_schedule_sixteenth(abs_step: int, at_sample: int) -> void:
	@warning_ignore("integer_division")
	var s_loop: int = abs_step / STEPS_PER_LOOP
	if s_loop != _sched_loop:
		_sched_loop = s_loop
		_try_commits(_sched_loop)
		drum_state.prune(_sched_loop)
	var step_in_loop := abs_step % STEPS_PER_LOOP
	var sb := step_in_loop % STEPS_PER_BAR
	@warning_ignore("integer_division")
	var bar: int = step_in_loop / STEPS_PER_BAR

	# Base hits -> modifier lens (Drop/Intensify/Fill, non-destructive) -> triggers.
	var base_hits: Array = []
	for h in drums.active.hits:
		if h.step == sb:
			base_hits.append(h)
	var final_bar := bar == BARS_PER_LOOP - 1 # the phrase turnaround (phrase = one 4-bar loop)
	var rendered := DrumRenderer.render_step(base_hits, sb, STEPS_PER_BAR, drum_state.modifiers, s_loop, final_bar)
	for h in rendered:
		audio.schedule_drum(at_sample, h.voice, h.velocity, h.accent)
	if bass.active.notes.has(sb):
		audio.schedule_bass(at_sample,
			Harmony.chord_tone_midi(BASS_ROOT_MIDI, chords.active.slots[bar], bass.active.notes[sb]),
			0.8, _bass_gate_seconds(sb))
	if sb == 0:
		var deg: int = chords.active.slots[bar]
		if deg >= 0:
			audio.schedule_chord(at_sample, Harmony.triad_midi(CHORD_ROOT_MIDI, deg), 0.7)


## Gate length for the bass note at step sb: hold until the next occupied step
## (wrapping), capped at 4 sixteenths — walking legato without smear. The
## DaisySP bass voice gates its ADSR on this and adds its own release tail.
func _bass_gate_seconds(sb: int) -> float:
	var gap := STEPS_PER_BAR
	for d in range(1, STEPS_PER_BAR + 1):
		if bass.active.notes.has((sb + d) % STEPS_PER_BAR):
			gap = d
			break
	var sec_per_step := (60.0 / transport.bpm) / 4.0
	return minf(float(gap), 4.0) * sec_per_step * 0.95


func _try_commits(at_loop: int) -> void:
	for t in [Focus.DRUMS, Focus.BASS, Focus.CHORDS]:
		if model_for(t).try_commit_at_loop(at_loop) and net.active and net.is_server:
			net.broadcast_track(t) # replicate the promoted state (version + boundary)


# ---------------------------------------------------------------- edit routing

func model_for(track: int) -> JamCommitModel:
	match track:
		Focus.DRUMS: return drums
		Focus.BASS: return bass
		_: return chords


func _blank_factory(track: int) -> Callable:
	match track:
		Focus.DRUMS: return Callable(DrumPattern, "new")
		Focus.BASS: return Callable(BassLine, "new")
		_: return Callable(ChordTrack, "new")


## Public dispatch surface — the ONLY entry point for non-UI participants
## (BotPeer, MCP-driven play). Same path as human input, no privileges.
func dispatch(track: int, op: String, args: Dictionary) -> void:
	_dispatch(track, op, args)


## Every edit goes through here. Solo: apply directly. Client: apply locally as a
## prediction (immediate ghost, Jammin D7 style) AND send the intent to the server;
## the server's echoed state overwrites and reconciles. Host: apply + broadcast.
func _dispatch(track: int, op: String, args: Dictionary) -> void:
	if not net.can_edit(track):
		return # not your instrument in this room (also enforced server-side)
	apply_edit(track, op, args)
	edit_dispatched.emit(track, op, args)
	if net.active:
		if net.is_server:
			if track == Focus.DRUMS and op in NetSession.DRUM_STATE_OPS:
				net.broadcast_drums()
			else:
				net.broadcast_track(track)
		else:
			net.send_cmd(track, op, args)


## Application of a musical edit op to this machine's models. Used by local
## dispatch AND by the server when validating a client command. Pattern-op
## semantics live in the domain layer (JamTrackOps); drum-role state ops
## (modifiers/kit) go to JamDrumState and apply live, not commit-gated.
func apply_edit(track: int, op: String, args: Dictionary) -> void:
	if track == Focus.DRUMS and op in NetSession.DRUM_STATE_OPS:
		match op:
			"fill": drum_state.press_fill(loop_index, bar_in_loop, BARS_PER_LOOP)
			"drop": drum_state.press_drop(loop_index)
			"intensify": drum_state.press_intensify(loop_index)
			"kit":
				drum_state.cycle_kit(args.lane)
				audio.set_kit_variant(args.lane, drum_state.kit[args.lane])
		return
	TrackOps.apply(model_for(track), track, op, args, loop_index, _commit_delay())


## LOCK HORIZON: an edit landing in the final steps of a loop cannot reach every
## peer before the boundary, so it schedules one loop further out. Horizon = 2
## sixteenths (~268 ms at 112 BPM) > the worst simulated RTT.
const LOCK_HORIZON_STEPS := 2


func _commit_delay() -> int:
	var step_in_loop := bar_in_loop * STEPS_PER_BAR + step_in_bar
	return 2 if step_in_loop >= STEPS_PER_LOOP - LOCK_HORIZON_STEPS else 1


## Replicated drum-role state (kit + modifiers) arrived from the server.
func apply_drum_state(state: Dictionary) -> void:
	drum_state.from_dict(state)
	audio.apply_kit(drum_state.kit)
	_refresh_ui()


## Replicated commit-model state arrived from the server: overwrite local replica.
func apply_track_state(track: int, state: Dictionary) -> void:
	model_for(track).apply_state(state, _blank_factory(track))
	_refresh_ui()


func queue_ui_refresh() -> void:
	_refresh_ui()


# ---------------------------------------------------------------- input

func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed:
		return
	if k.echo and k.keycode != KEY_LEFT and k.keycode != KEY_RIGHT:
		return
	match k.keycode:
		KEY_TAB:
			focus = (focus + 1) % 3
		KEY_F1:
			help_label.visible = not help_label.visible
		KEY_F9:
			hitch_mode = not hitch_mode
		KEY_SPACE:
			transport.toggle_pause()
		KEY_LEFT:
			_move_cursor(-1)
		KEY_RIGHT:
			_move_cursor(1)
		KEY_ENTER, KEY_KP_ENTER:
			_place()
		KEY_Y:
			_toggle_accent()
		KEY_DELETE:
			_clear_lane()
		KEY_X:
			_clear_all()
		KEY_C:
			_dispatch(focus, "cancel", {})
		KEY_A:
			_cycle_chord(-1)
		KEY_D:
			_cycle_chord(1)
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5:
			_select_lane(k.keycode - KEY_1)
		KEY_F: # drummer: queue a fill for the phrase turnaround
			_dispatch(Focus.DRUMS, "fill", {})
		KEY_G: # drummer: drop (press again while active = heavy)
			_dispatch(Focus.DRUMS, "drop", {})
		KEY_H: # drummer: intensify (press again while active = extend)
			_dispatch(Focus.DRUMS, "intensify", {})
		KEY_K: # drummer: cycle kit sound for the selected lane
			_dispatch(Focus.DRUMS, "kit", {"lane": drum_lane})
		KEY_T: # drummer: cycle starter templates (pending, commits at boundary)
			_template_cursor = (_template_cursor + 1) % Templates.count()
			_dispatch(Focus.DRUMS, "template", {"index": _template_cursor})
		KEY_F2:
			net.host()
		KEY_F3:
			net.join("127.0.0.1")
		KEY_F10:
			net.lag_sim = not net.lag_sim
		_:
			return
	get_viewport().set_input_as_handled()
	_refresh_ui()


func _move_cursor(dir: int) -> void:
	match focus:
		Focus.DRUMS: drum_cursor = posmod(drum_cursor + dir, STEPS_PER_BAR)
		Focus.BASS: bass_cursor = posmod(bass_cursor + dir, STEPS_PER_BAR)
		Focus.CHORDS: chord_cursor = posmod(chord_cursor + dir, BARS_PER_LOOP)


func _select_lane(n: int) -> void:
	match focus:
		Focus.DRUMS:
			if n < DrumPattern.NUM_VOICES:
				drum_lane = n
		Focus.BASS:
			if n < BassLine.NUM_DEGREES:
				bass_lane = n
		_:
			pass


func _place() -> void:
	match focus:
		Focus.DRUMS:
			_dispatch(Focus.DRUMS, "toggle", {"voice": drum_lane, "step": drum_cursor})
		Focus.BASS:
			_dispatch(Focus.BASS, "place", {"step": bass_cursor, "degree": bass_lane})
		Focus.CHORDS:
			pass # chords edit via A/D


func _toggle_accent() -> void:
	if focus == Focus.DRUMS:
		_dispatch(Focus.DRUMS, "accent", {"voice": drum_lane, "step": drum_cursor})


func _clear_lane() -> void:
	match focus:
		Focus.DRUMS:
			_dispatch(Focus.DRUMS, "clear_voice", {"voice": drum_lane})
		Focus.BASS:
			_dispatch(Focus.BASS, "clear", {})
		Focus.CHORDS:
			_dispatch(Focus.CHORDS, "clear_slot", {"bar": chord_cursor})


func _clear_all() -> void:
	match focus:
		Focus.DRUMS:
			_dispatch(Focus.DRUMS, "clear_all", {})
		Focus.BASS:
			_dispatch(Focus.BASS, "clear", {})
		Focus.CHORDS:
			_dispatch(Focus.CHORDS, "clear", {})


func _cycle_chord(delta: int) -> void:
	if focus == Focus.CHORDS:
		_dispatch(Focus.CHORDS, "cycle", {"bar": chord_cursor, "delta": delta})


# ---------------------------------------------------------------- pointer grammar

var _bloom = null # the open JamRadialBloom, if any


func _open_bloom(gpos: Vector2, opts: Array, center_lbl: String, on_finish: Callable) -> void:
	if _bloom != null:
		_bloom.queue_free()
	_bloom = RadialBloom.new()
	add_child(_bloom)
	_bloom.finished.connect(func(idx: int) -> void:
		_bloom.queue_free()
		_bloom = null
		if idx != -2:
			on_finish.call(idx)
		_refresh_ui())
	_bloom.open(gpos, opts, center_lbl)


## Tap a drum wedge: toggle a hit in that lane, no cursor dance needed.
func _on_drum_cell_tapped(lane: int, step: int) -> void:
	focus = Focus.DRUMS
	drum_lane = lane
	drum_cursor = step
	_dispatch(Focus.DRUMS, "toggle", {"voice": lane, "step": step})
	_refresh_ui()


## Hold a drum wedge: edit the hit (accent / delete) instead of toggling it.
func _on_drum_cell_held(lane: int, step: int, gpos: Vector2) -> void:
	focus = Focus.DRUMS
	drum_lane = lane
	drum_cursor = step
	_refresh_ui()
	_open_bloom(gpos, [{"label": "ACC"}, {"label": "DEL"}], "", _apply_drum_bloom.bind(lane, step))


func _apply_drum_bloom(idx: int, lane: int, step: int) -> void:
	if idx == 0:
		_dispatch(Focus.DRUMS, "accent", {"voice": lane, "step": step})
	elif idx == 1:
		var line = drums.pending if drums.pending != null else drums.active
		for h in line.hits:
			if h.voice == lane and h.step == step:
				_dispatch(Focus.DRUMS, "toggle", {"voice": lane, "step": step})
				return


## Tap a bass wedge: the lane IS the harmonic role (R/3/5/7/O), so tapping
## places/re-tunes/removes directly — no radial detour for the common case.
func _on_bass_cell_tapped(lane: int, step: int) -> void:
	focus = Focus.BASS
	bass_lane = lane
	bass_cursor = step
	_dispatch(Focus.BASS, "place", {"step": step, "degree": lane})
	_refresh_ui()


## Hold a bass step: bloom the full tone vocabulary around it (thin lanes on
## touch, or deliberate choice), x removes whatever the step holds.
func _on_bass_cell_held(_lane: int, step: int, gpos: Vector2) -> void:
	focus = Focus.BASS
	bass_cursor = step
	_refresh_ui()
	var opts: Array = []
	for d in BassLine.NUM_DEGREES:
		opts.append({"label": Harmony.BASS_TONE_NAMES[d], "color": BASS_LANE_COLORS[d]})
	_open_bloom(gpos, opts, "×", _apply_bass_bloom.bind(step))


func _apply_bass_bloom(idx: int, step: int) -> void:
	if idx >= 0:
		bass_lane = idx
		_dispatch(Focus.BASS, "place", {"step": step, "degree": idx})
	else:
		var line = bass.pending if bass.pending != null else bass.active
		if line.notes.has(step): # place same degree = remove
			_dispatch(Focus.BASS, "place", {"step": step, "degree": line.notes[step]})


## Press a chord bar: bloom the diatonic vocabulary, x clears the slot.
func _on_chord_bar_pressed(bar: int, gpos: Vector2) -> void:
	focus = Focus.CHORDS
	chord_cursor = bar
	_refresh_ui()
	var opts: Array = []
	for d in Harmony.ROMAN.size():
		opts.append({"label": Harmony.ROMAN[d]})
	_open_bloom(gpos, opts, "×", _apply_chord_bloom.bind(bar))


func _apply_chord_bloom(idx: int, bar: int) -> void:
	if idx >= 0:
		_dispatch(Focus.CHORDS, "set", {"bar": bar, "degree": idx})
	else:
		_dispatch(Focus.CHORDS, "clear_slot", {"bar": bar})


# ---------------------------------------------------------------- UI refresh

func _refresh_ui() -> void:
	drum_ring.cells = _drum_cells()
	drum_ring.playhead_step = step_in_bar
	drum_ring.cursor_step = drum_cursor
	drum_ring.selected_lane = drum_lane
	drum_ring.focused = focus == Focus.DRUMS
	var lane_names := []
	for lane in DRUM_LANE_NAMES.size():
		lane_names.append("%s · %s" % [DRUM_LANE_NAMES[lane], drum_state.kit_name(lane)])
	drum_ring.lane_names = lane_names
	var mod_tags: String = drum_state.active_tags(maxi(_sched_loop, loop_index))
	drum_ring.status_text = _track_status(drums) + ("" if mod_tags.is_empty() else "  ·  " + mod_tags)
	drum_ring.queue_redraw()

	bass_ring.cells = _bass_cells()
	bass_ring.playhead_step = step_in_bar
	bass_ring.cursor_step = bass_cursor
	bass_ring.selected_lane = bass_lane
	bass_ring.focused = focus == Focus.BASS
	bass_ring.status_text = _track_status(bass)
	bass_ring.queue_redraw()

	chord_strip.active_slots = chords.active.slots
	chord_strip.pending_slots = chords.pending.slots if chords.has_pending() else null
	chord_strip.cursor_bar = chord_cursor
	chord_strip.playhead_bar = bar_in_loop
	chord_strip.focused = focus == Focus.CHORDS
	chord_strip.status_text = _track_status(chords)
	chord_strip.queue_redraw()

	var pause_tag := "" if transport.playing else "  ·  PAUSED (Space)"
	var hitch_tag := "  ·  HITCHING (F9)" if hitch_mode else ""
	hud_line.text = "JAMMIN LITE  ·  %d BPM  ·  Key C  ·  Loop %d  ·  Bar %d  Beat %d%s%s" % [
		int(transport.bpm), maxi(loop_index, 0), bar_in_loop + 1, int(step_in_bar / 4.0) + 1, pause_tag, hitch_tag]
	var audio_tag := "audio: legacy (frame-quantized)"
	if audio.native:
		var d: Dictionary = audio.diagnostics()
		audio_tag = "audio: native sample-scheduled  ·  late %d  ·  dropped %d" % [d.late, d.dropped]
	status_line.text = "Focus: %s (Tab)  ·  F1 help  ·  %s" % [["DRUMS", "BASS", "CHORDS"][focus], audio_tag]
	net_line.text = _net_status_text()


func _net_status_text() -> String:
	if not net.active:
		return "NET: solo  ·  F2 host  ·  F3 join 127.0.0.1"
	var track_names := ["DRUMS", "BASS", "CHORDS"]
	var owned := ""
	for t in net.owned_tracks():
		owned += ("" if owned.is_empty() else ", ") + track_names[t]
	if owned.is_empty():
		owned = "nothing (spectator)"
	var lag_tag := ""
	if net.lag_sim:
		lag_tag = "  ·  LAGSIM %d±%dms %.1f%%loss" % [int(net.lag_base_ms), int(net.lag_jitter_ms), net.lag_loss_pct * 100.0]
	if net.is_server:
		return "NET: HOST  ·  %s  ·  you edit: %s  ·  rejects %d%s" % [net.status, owned, net.rejects, lag_tag]
	var agree := "YES" if net.debug_state().versions_agree else "NO"
	return "NET: CLIENT  ·  %s  ·  RTT %.0f ms  ·  you edit: %s  ·  server loop %d / local %d  ·  versions agree: %s%s" % [
		net.status, net.rtt_ms, owned, net.server_loop, loop_index, agree, lag_tag]


func _track_status(model: JamCommitModel) -> String:
	if model.has_pending():
		return "pending → loop %d" % model.commit_loop_index
	return "v%d live" % model.version_id


func _drum_cells() -> Dictionary:
	var out := {}
	var active: JamDrumPattern = drums.active
	if not drums.has_pending():
		for h in active.hits:
			out[Vector2i(h.voice, h.step)] = {"color": DRUM_LANE_COLORS[h.voice], "mode": JamStepRing.CELL_SOLID, "accent": h.accent}
		return out
	var pend: JamDrumPattern = drums.pending
	for h in active.hits:
		if pend.find_hit_index(h.voice, h.step) < 0:
			out[Vector2i(h.voice, h.step)] = {"color": DRUM_LANE_COLORS[h.voice], "mode": JamStepRing.CELL_GHOST_REMOVE, "accent": false}
	for h in pend.hits:
		var mode := JamStepRing.CELL_SOLID if active.find_hit_index(h.voice, h.step) >= 0 else JamStepRing.CELL_GHOST_ADD
		out[Vector2i(h.voice, h.step)] = {"color": DRUM_LANE_COLORS[h.voice], "mode": mode, "accent": h.accent}
	return out


func _bass_cells() -> Dictionary:
	var out := {}
	var active: JamBassLine = bass.active
	if not bass.has_pending():
		for step in active.notes:
			var deg: int = active.notes[step]
			out[Vector2i(deg, step)] = {"color": BASS_LANE_COLORS[deg], "mode": JamStepRing.CELL_SOLID, "accent": false}
		return out
	var pend: JamBassLine = bass.pending
	for step in active.notes:
		var deg: int = active.notes[step]
		if not pend.notes.has(step) or pend.notes[step] != deg:
			out[Vector2i(deg, step)] = {"color": BASS_LANE_COLORS[deg], "mode": JamStepRing.CELL_GHOST_REMOVE, "accent": false}
	for step in pend.notes:
		var deg: int = pend.notes[step]
		var same: bool = active.notes.has(step) and active.notes[step] == deg
		var mode := JamStepRing.CELL_SOLID if same else JamStepRing.CELL_GHOST_ADD
		out[Vector2i(deg, step)] = {"color": BASS_LANE_COLORS[deg], "mode": mode, "accent": false}
	return out


# ---------------------------------------------------------------- MCP observability

func _mcp_state() -> Dictionary:
	return {
		"loop": loop_index,
		"bar": bar_in_loop + 1,
		"sixteenth": step_in_bar,
		"bpm": transport.bpm,
		"playing": transport.playing,
		"focus": ["DRUMS", "BASS", "CHORDS"][focus],
		"drum_hits": drums.active.hits.size(),
		"drum_pending": drums.has_pending(),
		"drum_version": drums.version_id,
		"drum_cursor": {"lane": drum_lane, "step": drum_cursor},
		"bass_notes": bass.active.notes.size(),
		"bass_pending": bass.has_pending(),
		"chord_slots": chords.active.slots,
		"chord_pending": chords.has_pending(),
		"hitch_mode": hitch_mode,
		"kit": drum_state.kit,
		"modifiers": drum_state.modifiers,
		"audio": audio.diagnostics(),
		"net": net.debug_state(),
	}
