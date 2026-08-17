class_name JamDrumState
extends RefCounted

# Live drum-role state (Jammin D3/D9): kit variants and scheduled performance
# modifiers. Unlike patterns this is NOT commit-gated — it replicates immediately
# as room state and applies from the next scheduled step. Pure data + deterministic
# press rules; rendering happens in JamDrumRenderer, sound selection in the audio
# engine. This object never touches audio or the network itself.

const NUM_LANES := 4
const NUM_VARIANTS := 3
const KIT_NAMES := [
	["Deep", "Punch", "Boom"], # Kick
	["Snap", "Tight", "Fat"], # Snare
	["Closed", "Open", "Crisp"], # Hat
	["Tom", "Conga", "Low Tom"], # Perc
]

const MIX_POOLS := ["Kick", "Snare", "Hat", "Perc", "Bass", "Notes"] # D10 canonical order

var kit: Array = [0, 0, 0, 0] # variant index per lane
var modifiers: Array = [] # {type: String, start_loop: int, duration: int, strength: float}
# Room mixer (D10): per-pool user gain 0..2 on top of the rack's base mix.
# Server-owned like kit — the drummer adjusts, everyone hears the same mix.
var mix: Array = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
# Groove template index (JamGroove.TEMPLATES) — a render-time lens, room-wide.
var groove := 0


func to_dict() -> Dictionary:
	return {"kit": kit.duplicate(), "modifiers": modifiers.duplicate(true),
		"mix": mix.duplicate(), "groove": groove}


func from_dict(d: Dictionary) -> void:
	kit = d.get("kit", [0, 0, 0, 0]).duplicate()
	modifiers = d.get("modifiers", []).duplicate(true)
	mix = d.get("mix", [1.0, 1.0, 1.0, 1.0, 1.0, 1.0]).duplicate()
	groove = int(d.get("groove", 0))


func set_mix(pool: int, gain: float) -> void:
	if pool >= 0 and pool < mix.size():
		mix[pool] = clampf(gain, 0.0, 2.0)


func cycle_kit(lane: int) -> void:
	if lane >= 0 and lane < NUM_LANES:
		kit[lane] = (int(kit[lane]) + 1) % NUM_VARIANTS


func kit_name(lane: int) -> String:
	return KIT_NAMES[lane][int(kit[lane])]


func _active_of(type: String, loop: int):
	for m in modifiers:
		if m.type == type and JamDrumRendererRef.is_modifier_active(m, loop):
			return m
	return null


const JamDrumRendererRef := preload("res://scripts/core/drum_renderer.gd")


## Fill (D9 phrase-gating): the window must reach the upcoming turnaround (final
## bar of the phrase). Pressed on the final bar itself, the window auto-stretches
## to cover the NEXT turnaround too. A press while a fill already covers this loop
## is ignored (no stacking).
func press_fill(loop: int, bar: int, bars_per_loop: int) -> void:
	if _active_of("fill", loop) != null:
		return
	var duration := 1 if bar < bars_per_loop - 1 else 2
	modifiers.append({"type": "fill", "start_loop": loop, "duration": duration, "strength": 1.0})


## Drop: first press = light (thin hats/perc); pressing again while active
## escalates to heavy (everything but the downbeat kick).
func press_drop(loop: int) -> void:
	var active = _active_of("drop", loop)
	if active != null:
		active.strength = 1.0
		return
	modifiers.append({"type": "drop", "start_loop": loop, "duration": 1, "strength": 0.4})


## Intensify: press again while active to extend the window one more loop.
func press_intensify(loop: int) -> void:
	var active = _active_of("intensify", loop)
	if active != null:
		active.duration = int(active.duration) + 1
		return
	modifiers.append({"type": "intensify", "start_loop": loop, "duration": 1, "strength": 0.8})


## Drop events whose window has fully passed (expired modifiers stop applying on
## their own; this just keeps the replicated list small).
func prune(loop: int) -> void:
	var kept: Array = []
	for m in modifiers:
		if m.start_loop + m.duration > loop:
			kept.append(m)
	modifiers = kept


## Short display tags for modifiers active at loop, e.g. "FILL DROP".
func active_tags(loop: int) -> String:
	var tags := ""
	for type in ["fill", "drop", "intensify"]:
		if _active_of(type, loop) != null:
			tags += ("" if tags.is_empty() else " ") + type.to_upper()
	return tags
