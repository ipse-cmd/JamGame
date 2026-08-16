class_name JamChordStrip
extends Control

# Code-drawn chord strip: one diatonic chord slot per bar of the 4-bar loop.
# Read-only projection + the room dispatches edits; same rules as the rings.

const Harmony := preload("res://scripts/core/harmony.gd")

var active_slots: Array = [-1, -1, -1, -1]
var pending_slots = null # Array when a pending session is open, else null
var cursor_bar := 0
var playhead_bar := -1
var focused := false
var status_text := ""
var key_root_pc := 0 # pitch class of the room key root (0 = C)

const BG := Color("1b1e24")
const SLOT_BG := Color("242832")
const TEXT := Color("cfd6dd")
const DIM_TEXT := Color("8a93a0")
const ACTIVE_CHORD := Color("9ecf6e")
const GHOST_CHORD := Color(0.62, 0.81, 0.43, 0.55)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BG)
	if focused:
		draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, 0.55), false, 2.0)

	var font := get_theme_default_font()
	draw_string(font, Vector2(10, 18), "CHORDS", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, TEXT)
	draw_string(font, Vector2(0, 18), status_text, HORIZONTAL_ALIGNMENT_RIGHT, size.x - 10, 12, DIM_TEXT)

	var n := active_slots.size()
	var margin := 10.0
	var top := 26.0
	var slot_w := (size.x - margin * (n + 1)) / float(n)
	var slot_h := size.y - top - margin

	for i in n:
		var rect := Rect2(margin + i * (slot_w + margin), top, slot_w, slot_h)
		draw_rect(rect, SLOT_BG)
		if i == playhead_bar:
			draw_rect(rect, Color(1, 1, 1, 0.07))
			draw_rect(rect, Color(1, 1, 1, 0.35), false, 1.5)
		if i == cursor_bar:
			draw_rect(rect.grow(1.0), Color("f0f3f7"), false, 2.0)

		var shown: int = active_slots[i]
		var ghost := false
		if pending_slots != null and pending_slots[i] != active_slots[i]:
			shown = pending_slots[i]
			ghost = true
		var label := "—"
		if shown >= 0:
			var root_midi: int = 60 + key_root_pc
			label = Harmony.ROMAN[shown] + "  " + Harmony.pitch_class_name(Harmony.degree_to_midi(root_midi, shown))
		var col := GHOST_CHORD if ghost else (ACTIVE_CHORD if shown >= 0 else DIM_TEXT)
		var text_y := rect.position.y + rect.size.y / 2.0 + 6.0
		draw_string(font, Vector2(rect.position.x, text_y), label, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 16, col)
		draw_string(font, Vector2(rect.position.x + 6, rect.position.y + 16), "bar %d" % (i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, DIM_TEXT)
