class_name JamChordTrack
extends RefCounted

# Chord strip track: one diatonic chord slot per bar of the loop. Stores only the
# scale degree (-1 = empty slot); actual pitches derive from the room key at render
# time, mirroring Jammin's rhythm/pitch separation.

var slots: Array = [-1, -1, -1, -1] # degree 0..6, or -1 for empty
# PERFORMANCE fields (commit-gated like the slots): which comp pattern and
# voicing render the chords (JamChordComp). WHAT to play vs HOW to play it.
var comp := 0
var voicing := 0
var synth := 0 # 0 Pluck, 1 Poly Pad, 2 Poly Keys (JamChordComp.SYNTHS)


# Untyped on purpose — class_name self-references need the editor's global class cache,
# which headless test runs don't have.
func clone():
	var c = get_script().new()
	c.slots = slots.duplicate()
	c.comp = comp
	c.voicing = voicing
	c.synth = synth
	return c


func equals(other) -> bool:
	return slots == other.slots and comp == other.comp \
		and voicing == other.voicing and synth == other.synth


func to_dict() -> Dictionary:
	return {"slots": slots.duplicate(), "comp": comp, "voicing": voicing, "synth": synth}


func from_dict(d: Dictionary) -> void:
	slots = d.get("slots", [-1, -1, -1, -1]).duplicate()
	comp = int(d.get("comp", 0))
	voicing = int(d.get("voicing", 0))
	synth = int(d.get("synth", 0))


func set_performance(p_comp: int, p_voicing: int, p_synth := 0) -> void:
	comp = maxi(0, p_comp)
	voicing = maxi(0, p_voicing)
	synth = maxi(0, p_synth)


func cycle_slot(bar: int, delta: int) -> void:
	if bar < 0 or bar >= slots.size():
		return
	# Cycle through -1 (empty), 0..6, wrapping in both directions.
	var v: int = slots[bar] + 1 + delta # shift to 0..7 space
	v = posmod(v, 8)
	slots[bar] = v - 1


## Direct idempotent assignment (radial picker / non-incremental editors).
func set_slot(bar: int, degree: int) -> void:
	if bar >= 0 and bar < slots.size() and degree >= 0 and degree <= 6:
		slots[bar] = degree


func clear_slot(bar: int) -> void:
	if bar >= 0 and bar < slots.size():
		slots[bar] = -1


func clear() -> void:
	for i in slots.size():
		slots[i] = -1
