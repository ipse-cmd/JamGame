class_name JamStepRing
extends Control

# Code-drawn circular step sequencer (the Jammin ring, redrawn in Godot). Purely a
# projection: the room computes cell states from the commit models and pushes them in;
# the ring never owns music state (UI displays state, never owns it).
#
# Pointer grammar (mouse today, touch via Godot's emulation): the ring is also an
# input surface — tap a wedge to perform the obvious action, hold it to ask for
# options. The ring only reports (lane, step) gestures; the ROOM decides what
# they mean and dispatches ops through the same validated path as the keyboard.

signal cell_tapped(lane: int, step: int)
signal cell_held(lane: int, step: int, global_pos: Vector2)

const HOLD_MS := 220

# Cell display modes
const CELL_SOLID := 0 # in active (and pending, if a session is open)
const CELL_GHOST_ADD := 1 # pending-only: will appear at the commit boundary
const CELL_GHOST_REMOVE := 2 # active-only while pending removes it

var title := "DRUMS"
var num_steps := 16
var lane_names: Array = []
var lane_colors: Array = []
var cells := {} # Vector2i(lane, step) -> { color: Color, mode: int, accent: bool }
var playhead_step := -1
var cursor_step := 0
var selected_lane := 0
var focused := false
var status_text := ""

var _press_cell := Vector2i(-1, -1)
var _press_time_ms := 0
var _pressed := false
var _held_fired := false

const BG := Color("1b1e24")
const BEAT_SHADE := Color(1, 1, 1, 0.045)
const GRID_SHADE := Color(1, 1, 1, 0.018)
const PLAYHEAD := Color(1, 1, 1, 0.10)
const CURSOR := Color("f0f3f7")
const TEXT := Color("cfd6dd")
const DIM_TEXT := Color("8a93a0")


## Inverse of the draw layout: local position -> (lane, step), or (-1, -1)
## outside the annulus. Pure math, unit-tested against wedge centroids.
func pick(pos: Vector2) -> Vector2i:
	var center := size / 2.0
	var outer := minf(size.x, size.y) / 2.0 - 6.0
	var inner := outer * 0.38
	var v := pos - center
	var r := v.length()
	if r < inner or r > outer or lane_names.is_empty():
		return Vector2i(-1, -1)
	var lanes := lane_names.size()
	var lane := clampi(int((r - inner) / ((outer - inner) / float(lanes))), 0, lanes - 1)
	# Half-step shift mirrors the draw layout: step 0 is centered on 12 o'clock.
	var sa := TAU / float(num_steps)
	var ang := fposmod(v.angle() + PI / 2.0 + sa / 2.0, TAU)
	var step := int(ang / sa) % num_steps
	return Vector2i(lane, step)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var c := pick(event.position)
			if c.x >= 0:
				_pressed = true
				_held_fired = false
				_press_cell = c
				_press_time_ms = Time.get_ticks_msec()
				accept_event()
		elif _pressed:
			_pressed = false
			if not _held_fired:
				cell_tapped.emit(_press_cell.x, _press_cell.y)
			accept_event()


func _process(_delta: float) -> void:
	if _pressed and not _held_fired and Time.get_ticks_msec() - _press_time_ms >= HOLD_MS:
		_held_fired = true
		cell_held.emit(_press_cell.x, _press_cell.y, get_global_mouse_position())


func _draw() -> void:
	var center := size / 2.0
	var outer := minf(size.x, size.y) / 2.0 - 6.0
	var inner := outer * 0.38
	var lanes := lane_names.size()
	var lane_thickness := (outer - inner) / float(lanes)
	var step_angle := TAU / float(num_steps)
	var gap := 0.018
	# Step 0 is CENTERED on 12 o'clock (clock-face convention: beat 1 sits AT
	# the top), so every wedge starts half a step early. pick() must mirror this.
	var a_base := -PI / 2.0 - step_angle / 2.0

	draw_circle(center, outer + 4.0, BG)

	# Beat shading + step grid background
	for s in num_steps:
		var a0 := a_base + s * step_angle + gap
		var a1 := a0 + step_angle - 2.0 * gap
		var shade := BEAT_SHADE if s % 4 == 0 else GRID_SHADE
		draw_colored_polygon(_wedge(center, inner, outer, a0, a1), shade)

	# Cells
	for key in cells:
		var lane: int = key.x
		var step: int = key.y
		var cell: Dictionary = cells[key]
		var r0 := inner + lane * lane_thickness + 2.0
		var r1 := inner + (lane + 1) * lane_thickness - 2.0
		var a0 := a_base + step * step_angle + gap
		var a1 := a0 + step_angle - 2.0 * gap
		var poly := _wedge(center, r0, r1, a0, a1)
		var col: Color = cell.color
		match cell.mode:
			CELL_GHOST_ADD:
				col.a = 0.4
				draw_colored_polygon(poly, col)
				_outline(poly, Color(col.r, col.g, col.b, 0.9), 1.5)
			CELL_GHOST_REMOVE:
				col.a = 0.12
				draw_colored_polygon(poly, col)
			_:
				draw_colored_polygon(poly, col)
				if cell.get("accent", false):
					_outline(poly, Color(1, 1, 1, 0.95), 2.0)

	# Playhead wedge across all lanes
	if playhead_step >= 0:
		var a0 := a_base + playhead_step * step_angle
		draw_colored_polygon(_wedge(center, inner - 4.0, outer + 4.0, a0, a0 + step_angle), PLAYHEAD)

	# Cursor outline on (selected_lane, cursor_step)
	var cr0 := inner + selected_lane * lane_thickness + 1.0
	var cr1 := inner + (selected_lane + 1) * lane_thickness - 1.0
	var ca0 := a_base + cursor_step * step_angle + gap * 0.5
	var ca1 := ca0 + step_angle - gap
	_outline(_wedge(center, cr0, cr1, ca0, ca1), CURSOR, 2.0)

	# Focus border
	if focused:
		draw_arc(center, outer + 4.0, 0.0, TAU, 96, Color(1, 1, 1, 0.55), 2.0, true)

	# Center text
	var font := get_theme_default_font()
	var lane_col: Color = lane_colors[selected_lane] if selected_lane < lane_colors.size() else TEXT
	draw_string(font, Vector2(0, center.y - 18), title, HORIZONTAL_ALIGNMENT_CENTER, size.x, 18, TEXT)
	var lane_label: String = lane_names[selected_lane] if selected_lane < lane_names.size() else ""
	draw_string(font, Vector2(0, center.y + 4), lane_label, HORIZONTAL_ALIGNMENT_CENTER, size.x, 14, lane_col)
	draw_string(font, Vector2(0, center.y + 24), status_text, HORIZONTAL_ALIGNMENT_CENTER, size.x, 12, DIM_TEXT)


func _wedge(center: Vector2, r0: float, r1: float, a0: float, a1: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var segs := maxi(2, int(ceil((a1 - a0) / 0.1)))
	for i in segs + 1:
		pts.append(center + Vector2.from_angle(a0 + (a1 - a0) * i / segs) * r1)
	for i in segs + 1:
		pts.append(center + Vector2.from_angle(a1 - (a1 - a0) * i / segs) * r0)
	return pts


func _outline(poly: PackedVector2Array, color: Color, width: float) -> void:
	var closed := poly.duplicate()
	closed.append(poly[0])
	draw_polyline(closed, color, width, true)
