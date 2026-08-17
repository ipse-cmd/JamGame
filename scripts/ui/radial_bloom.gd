class_name JamRadialBloom
extends Control

# Contextual radial palette: the "hold = expose musical options" layer of the
# pointer grammar. Opens at a gesture's position, tracks the drag, resolves on
# release (momentary, instrument-like). A quick release near the origin goes
# STICKY instead — the bloom stays open and the next click chooses — so both
# hold-drag-release and tap-then-tap work. Purely an input surface: it emits
# the chosen index and the ROOM dispatches the op.

signal finished(index: int) # >= 0 chosen option, -1 center action, -2 cancelled

const RADIUS := 64.0
const DEAD_RADIUS := 22.0
const OPTION_R := 21.0
const STICKY_MS := 300 # release faster than this without choosing -> sticky mode

const VEIL := Color(0, 0, 0, 0.35)
const PUCK := Color("39404e")
const CENTER_PUCK := Color("2a2f3a")
const CENTER_HOVER := Color("3a4150")
const TEXT_LIGHT := Color("e8ecf1")
const TEXT_DARK := Color("11141a")

var options: Array = [] # [{label: String, color: Color (optional)}]
var center_label := "" # "" = no center action (release there cancels)
var _origin := Vector2.ZERO
var _hover := -2
var _opened_ms := 0
var _sticky := false
var _done := false


## Pure gesture resolution, unit-testable: where does a pointer at `pointer`
## land for a bloom at `origin`? -2 = nothing, -1 = center, 0.. = option index
## (0 at 12 o'clock, clockwise).
static func resolve(origin: Vector2, pointer: Vector2, option_count: int, has_center: bool) -> int:
	var v := pointer - origin
	var r := v.length()
	if r < DEAD_RADIUS:
		return -1 if has_center else -2
	if r > RADIUS + OPTION_R * 2.0 or option_count <= 0:
		return -2
	var sector := TAU / float(option_count)
	return int(round(fposmod(v.angle() + PI / 2.0, TAU) / sector)) % option_count


func open(center_global: Vector2, opts: Array, center_lbl := "") -> void:
	options = opts
	center_label = center_lbl
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var vp := get_viewport_rect().size
	var m := RADIUS + OPTION_R + 6.0
	_origin = center_global.clamp(Vector2(m, m), vp - Vector2(m, m))
	_opened_ms = Time.get_ticks_msec()
	_hover = resolve(_origin, get_global_mouse_position(), options.size(), center_label != "")
	queue_redraw()


func _input(event: InputEvent) -> void:
	if _done:
		return
	if event is InputEventMouseMotion:
		var h := resolve(_origin, get_global_mouse_position(), options.size(), center_label != "")
		if h != _hover:
			_hover = h
			queue_redraw()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if _sticky:
				_finish(_hover)
		else:
			if _sticky:
				return
			if _hover < 0 and Time.get_ticks_msec() - _opened_ms < STICKY_MS:
				_sticky = true # quick tap: stay open, next click decides
				return
			_finish(_hover)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_finish(-2)
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_finish(-2)


func _finish(index: int) -> void:
	_done = true
	get_viewport().set_input_as_handled()
	finished.emit(index)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), VEIL)
	var font := get_theme_default_font()
	draw_circle(_origin, DEAD_RADIUS - 2.0, CENTER_HOVER if _hover == -1 else CENTER_PUCK)
	if center_label != "":
		draw_string(font, _origin + Vector2(-DEAD_RADIUS, 5), center_label,
			HORIZONTAL_ALIGNMENT_CENTER, DEAD_RADIUS * 2.0, 13, TEXT_LIGHT)
	for i in options.size():
		var ang := -PI / 2.0 + TAU * float(i) / float(options.size())
		var p := _origin + Vector2.from_angle(ang) * RADIUS
		var col: Color = options[i].get("color", PUCK)
		if i == _hover:
			draw_circle(p, OPTION_R + 3.0, Color(1, 1, 1, 0.9))
		draw_circle(p, OPTION_R, col)
		var tcol := TEXT_DARK if col.get_luminance() > 0.5 else TEXT_LIGHT
		draw_string(font, p + Vector2(-OPTION_R, 5), str(options[i].label),
			HORIZONTAL_ALIGNMENT_CENTER, OPTION_R * 2.0, 13, tcol)
