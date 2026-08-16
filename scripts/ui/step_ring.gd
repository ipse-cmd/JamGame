class_name JamStepRing
extends Control

# Code-drawn circular step sequencer (the Jammin ring, redrawn in Godot). Purely a
# projection: the room computes cell states from the commit models and pushes them in;
# the ring never owns music state (UI displays state, never owns it).

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

const BG := Color("1b1e24")
const BEAT_SHADE := Color(1, 1, 1, 0.045)
const GRID_SHADE := Color(1, 1, 1, 0.018)
const PLAYHEAD := Color(1, 1, 1, 0.10)
const CURSOR := Color("f0f3f7")
const TEXT := Color("cfd6dd")
const DIM_TEXT := Color("8a93a0")


func _draw() -> void:
	var center := size / 2.0
	var outer := minf(size.x, size.y) / 2.0 - 6.0
	var inner := outer * 0.38
	var lanes := lane_names.size()
	var lane_thickness := (outer - inner) / float(lanes)
	var step_angle := TAU / float(num_steps)
	var gap := 0.018

	draw_circle(center, outer + 4.0, BG)

	# Beat shading + step grid background
	for s in num_steps:
		var a0 := -PI / 2.0 + s * step_angle + gap
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
		var a0 := -PI / 2.0 + step * step_angle + gap
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
		var a0 := -PI / 2.0 + playhead_step * step_angle
		draw_colored_polygon(_wedge(center, inner - 4.0, outer + 4.0, a0, a0 + step_angle), PLAYHEAD)

	# Cursor outline on (selected_lane, cursor_step)
	var cr0 := inner + selected_lane * lane_thickness + 1.0
	var cr1 := inner + (selected_lane + 1) * lane_thickness - 1.0
	var ca0 := -PI / 2.0 + cursor_step * step_angle + gap * 0.5
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
