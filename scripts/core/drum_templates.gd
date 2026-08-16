class_name JamDrumTemplates
extends RefCounted

# Starter drum templates — port of Jammin's FJamDrumTemplates (D8). A template is
# just a generated pattern the player applies as a PENDING edit: it commits at the
# loop boundary like any other edit and the server validates it like any pattern.
# The Unreal templates' Bass-lane hits are omitted: in the Godot room the bass is
# its own ring (the drum ring's bass lane is disabled, per the multiplayer rule).

const DrumPattern := preload("res://scripts/core/drum_pattern.gd")
const PatternEditor := preload("res://scripts/core/drum_pattern_editor.gd")

const NAMES := ["Backbeat", "Four-on-floor", "Boom bap", "Half time"]

const KICK := 0
const SNARE := 1
const HAT := 2
const PERC := 3


static func count() -> int:
	return NAMES.size()


static func name_of(index: int) -> String:
	return NAMES[posmod(index, count())]


static func build(index: int, num_steps: int = 16):
	var n := maxi(1, num_steps)
	match posmod(index, count()):
		0: return _backbeat(n)
		1: return _four_on_floor(n)
		2: return _boom_bap(n)
		_: return _half_time(n)


static func _hit(p, voice: int, step: int, velocity: float) -> void:
	PatternEditor.toggle_hit(p, voice, step, velocity)


static func _backbeat(n: int):
	var p = DrumPattern.new()
	p.num_steps = n
	_hit(p, KICK, 0, 1.0)
	_hit(p, KICK, 8, 1.0)
	_hit(p, SNARE, 4, 0.8)
	_hit(p, SNARE, 12, 0.8)
	for step in n:
		_hit(p, HAT, step, 0.5 if step % 2 == 0 else 0.35)
	return p


static func _four_on_floor(n: int):
	var p = DrumPattern.new()
	p.num_steps = n
	for step in range(0, n, 4): # kick every beat
		_hit(p, KICK, step, 1.0)
	_hit(p, SNARE, 4, 0.75)
	_hit(p, SNARE, 12, 0.75)
	for step in range(2, n, 4): # open-feel hat on the offbeats
		_hit(p, HAT, step, 0.6)
	return p


static func _boom_bap(n: int):
	var p = DrumPattern.new()
	p.num_steps = n
	_hit(p, KICK, 0, 1.0)
	_hit(p, KICK, 7, 0.85) # the "boom ... ba-" push into beat 3
	_hit(p, KICK, 10, 0.9)
	_hit(p, SNARE, 4, 0.85)
	_hit(p, SNARE, 12, 0.85)
	for step in range(0, n, 2): # eighth hats
		_hit(p, HAT, step, 0.45)
	_hit(p, PERC, 14, 0.6) # late-bar perc flavor
	return p


static func _half_time(n: int):
	var p = DrumPattern.new()
	p.num_steps = n
	_hit(p, KICK, 0, 1.0)
	_hit(p, SNARE, 8, 0.9) # the big center snare
	for step in n: # washy sixteenth hats, quiet
		_hit(p, HAT, step, 0.45 if step % 4 == 0 else 0.25)
	_hit(p, PERC, 11, 0.5)
	return p
