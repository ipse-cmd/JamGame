class_name JamMixerPanel
extends Control

# Drum-synth / room-mixer popout (M): six gain sliders (Kick/Snare/Hat/Perc/
# Bass/Notes, 0..2 with a unity notch), kit-sound buttons per drum lane, and
# the groove template selector. Pure projection + dispatch: it reads
# room.drum_state and emits the SAME validated ops as the keyboard (mix / kit
# / groove), so the server owns the result and every peer hears the same mix.
# Editable only for the drums seat; read-only display otherwise.

const Groove := preload("res://scripts/core/jam_groove.gd")

const PANEL_W := 640.0
const PANEL_H := 320.0
const COL_W := 92.0
const SLIDER_TOP := 66.0
const SLIDER_H := 150.0
const BG := Color("1b1e24ee")
const TRACK := Color("2a2f3a")
const FILL := Color("6fd3e0")
const NOTCH := Color(1, 1, 1, 0.5)
const TEXT := Color("cfd6dd")
const DIM := Color("8a93a0")
const POOL_LANES := 4 # first 4 pools are drum lanes with kit variants

var room # JamRoom (duck-typed: drum_state, net, _dispatch, drum-focus consts)
var _drag_pool := -1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	size = Vector2(PANEL_W, PANEL_H)


func _panel_origin() -> Vector2:
	return Vector2.ZERO # panel is positioned by the room; local coords


func _can_edit() -> bool:
	return room != null and room.net.can_edit(0) # drums own the mix (D10)


func _pool_rect(pool: int) -> Rect2:
	var x := 24.0 + pool * (COL_W + 8.0)
	return Rect2(Vector2(x, SLIDER_TOP), Vector2(COL_W, SLIDER_H))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			for pool in 6:
				if _pool_rect(pool).has_point(event.position):
					_drag_pool = pool
					_drag_to(event.position.y)
					accept_event()
					return
			# Kit buttons (below sliders, drum lanes only).
			for lane in POOL_LANES:
				if _kit_rect(lane).has_point(event.position) and _can_edit():
					room._dispatch(0, "kit", {"lane": lane})
					accept_event()
					queue_redraw()
					return
			if _groove_rect().has_point(event.position) and _can_edit():
				var next := (int(room.drum_state.groove) + 1) % Groove.TEMPLATES.size()
				room._dispatch(0, "groove", {"index": next})
				accept_event()
				queue_redraw()
				return
		else:
			_drag_pool = -1
	elif event is InputEventMouseMotion and _drag_pool >= 0:
		_drag_to(event.position.y)
		accept_event()


func _drag_to(y: float) -> void:
	if not _can_edit() or _drag_pool < 0:
		return
	var r := _pool_rect(_drag_pool)
	var frac := clampf(1.0 - (y - r.position.y) / r.size.y, 0.0, 1.0)
	var gain := snappedf(frac * 2.0, 0.05)
	if absf(gain - float(room.drum_state.mix[_drag_pool])) >= 0.05:
		room._dispatch(0, "mix", {"pool": _drag_pool, "gain": gain})
	queue_redraw()


func _kit_rect(lane: int) -> Rect2:
	var r := _pool_rect(lane)
	return Rect2(Vector2(r.position.x, r.position.y + SLIDER_H + 26.0), Vector2(COL_W, 20.0))


func _groove_rect() -> Rect2:
	return Rect2(Vector2(24.0, PANEL_H - 30.0), Vector2(PANEL_W - 48.0, 22.0))


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BG)
	draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, 0.25), false, 1.5)
	var font := get_theme_default_font()
	var editable := _can_edit()
	draw_string(font, Vector2(24, 26), "DRUM SYNTH · ROOM MIX" + ("" if editable else "  (drummer controls this)"),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, TEXT)
	draw_string(font, Vector2(0, 26), "M closes", HORIZONTAL_ALIGNMENT_RIGHT, size.x - 24, 11, DIM)

	if room == null:
		return
	var mix: Array = room.drum_state.mix
	for pool in 6:
		var r := _pool_rect(pool)
		var name: String = room.drum_state.MIX_POOLS[pool]
		draw_string(font, Vector2(r.position.x, r.position.y - 8), name,
			HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 13, TEXT)
		# Track + fill (gain 0..2, bottom-up) + unity notch at half height.
		var track := Rect2(r.position + Vector2(r.size.x / 2.0 - 7.0, 0), Vector2(14.0, r.size.y))
		draw_rect(track, TRACK)
		var frac: float = clampf(float(mix[pool]) / 2.0, 0.0, 1.0)
		var fill_h := track.size.y * frac
		draw_rect(Rect2(Vector2(track.position.x, track.end.y - fill_h), Vector2(track.size.x, fill_h)),
			FILL if editable else DIM)
		var notch_y := track.position.y + track.size.y * 0.5
		draw_line(Vector2(track.position.x - 5, notch_y), Vector2(track.end.x + 5, notch_y), NOTCH, 1.0)
		draw_string(font, Vector2(r.position.x, r.end.y + 16), "%.2f" % float(mix[pool]),
			HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 12, DIM)
		if pool < POOL_LANES:
			var kr := _kit_rect(pool)
			draw_rect(kr, TRACK)
			draw_string(font, Vector2(kr.position.x, kr.position.y + 15), room.drum_state.kit_name(pool),
				HORIZONTAL_ALIGNMENT_CENTER, kr.size.x, 12, TEXT)

	var gr := _groove_rect()
	draw_rect(gr, TRACK)
	draw_string(font, Vector2(gr.position.x, gr.position.y + 16),
		"GROOVE:  %s   (click or V to cycle)" % Groove.template_name(int(room.drum_state.groove)),
		HORIZONTAL_ALIGNMENT_CENTER, gr.size.x, 13, TEXT)
