class_name JamTrackOps
extends RefCounted

# Domain layer: application of a validated musical edit op to a track's commit
# model. This is the single implementation used by the room (local dispatch and
# server-side application) AND by integration test harnesses — the protocol is
# only real if every consumer runs the same op semantics.

const PatternEditor := preload("res://scripts/core/drum_pattern_editor.gd")
const Templates := preload("res://scripts/core/drum_templates.gd")

const TRACK_DRUMS := 0
const TRACK_BASS := 1
const TRACK_CHORDS := 2

const DEFAULT_VELOCITY := 0.75


static func apply(model, track: int, op: String, args: Dictionary, at_loop: int, commit_delay: int = 1) -> void:
	if op == "cancel":
		model.cancel_pending()
		return
	var p = model.begin_or_get_pending(at_loop, commit_delay)
	match track:
		TRACK_DRUMS:
			match op:
				"toggle": PatternEditor.toggle_hit(p, args.voice, args.step, DEFAULT_VELOCITY)
				"accent": PatternEditor.toggle_accent(p, args.voice, args.step)
				"clear_voice": PatternEditor.clear_voice(p, args.voice)
				"clear_all": PatternEditor.clear_all(p)
				"template":
					var t = Templates.build(args.index, p.num_steps)
					p.hits = t.hits
		TRACK_BASS:
			match op:
				"place": p.place_or_toggle(args.step, args.degree)
				"clear": p.clear()
		TRACK_CHORDS:
			match op:
				"cycle": p.cycle_slot(args.bar, args.delta)
				"set": p.set_slot(args.bar, args.degree)
				"comp": p.set_performance(args.comp, args.voicing, args.get("synth", 0))
				"clear_slot": p.clear_slot(args.bar)
				"clear": p.clear()
