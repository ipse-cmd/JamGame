class_name JamChordTrack
extends RefCounted

# Chord strip track: one diatonic chord slot per bar of the loop. Stores only the
# scale degree (-1 = empty slot); actual pitches derive from the room key at render
# time, mirroring Jammin's rhythm/pitch separation.

var slots: Array = [-1, -1, -1, -1] # degree 0..6, or -1 for empty


# Untyped on purpose — class_name self-references need the editor's global class cache,
# which headless test runs don't have.
func clone():
	var c = get_script().new()
	c.slots = slots.duplicate()
	return c


func equals(other) -> bool:
	return slots == other.slots


func cycle_slot(bar: int, delta: int) -> void:
	if bar < 0 or bar >= slots.size():
		return
	# Cycle through -1 (empty), 0..6, wrapping in both directions.
	var v: int = slots[bar] + 1 + delta # shift to 0..7 space
	v = posmod(v, 8)
	slots[bar] = v - 1


func clear_slot(bar: int) -> void:
	if bar >= 0 and bar < slots.size():
		slots[bar] = -1


func clear() -> void:
	for i in slots.size():
		slots[i] = -1
