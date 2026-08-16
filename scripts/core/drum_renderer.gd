class_name JamDrumRenderer
extends RefCounted

# Drum modifier processor — direct port of Jammin's FJamDrumModifierProcessor (D3).
# Pure, non-destructive transforms over the PER-STEP playback hit set; the stored
# pattern is never touched. Pipeline per scheduled step:
#
#   base hits at step -> Drop (thin) -> Intensify (boost/add) -> Fill (phrase-end) -> triggers
#
# Deterministic (no RNG) so every peer derives the same feel from replicated
# modifier state. Modifiers NEVER touch audio directly — they transform hits, and
# the transport schedules the result into G2 like any other hit (the seam rule).
#
# Modifier event shape: { type: "fill"|"drop"|"intensify", start_loop: int,
# duration: int, strength: float }

const VOICE_KICK := 0
const VOICE_SNARE := 1
const VOICE_HAT := 2
const VOICE_PERC := 3

const INTENSIFY_GHOST_HAT_VELOCITY := 0.3
const FILL_SNARE_VELOCITY := 0.8
const FILL_HAT_VELOCITY := 0.6


## True when loop falls in [start_loop, start_loop + duration).
static func is_modifier_active(m: Dictionary, loop: int) -> bool:
	return m.duration > 0 and loop >= m.start_loop and loop < m.start_loop + m.duration


## Transform the base hits at a step by every active modifier, order Drop ->
## Intensify -> Fill. base_hits is left untouched; result is sorted by voice.
## final_bar: this step lies in the final bar of the phrase (the turnaround) —
## the only place Fill adds hits.
static func render_step(base_hits: Array, step: int, num_steps: int, modifiers: Array,
		loop: int, final_bar: bool) -> Array:
	var hits: Array = base_hits.duplicate(true) # non-destructive: work on a copy

	var drop := _strongest_of(modifiers, "drop", loop)
	var intensify := _strongest_of(modifiers, "intensify", loop)
	var fill := _strongest_of(modifiers, "fill", loop)

	if drop.any:
		_apply_drop(hits, drop.strength, step)
	if intensify.any:
		_apply_intensify(hits, intensify.strength, step)
	if fill.any:
		_apply_fill(hits, step, num_steps, final_bar)

	hits.sort_custom(func(a, b): return a.voice < b.voice) # deterministic order
	return hits


## Strongest active strength for a type this pulse; {any: bool, strength: float}.
static func _strongest_of(modifiers: Array, type: String, loop: int) -> Dictionary:
	var any := false
	var strongest := 0.0
	for m in modifiers:
		if m.type == type and is_modifier_active(m, loop):
			any = true
			strongest = maxf(strongest, clampf(m.strength, 0.0, 1.0))
	return {"any": any, "strength": strongest}


## Drop (§9.2): thin the step. Light drop removes hats/perc; heavy drop (>= 0.5)
## removes everything except a kick on the downbeat.
static func _apply_drop(hits: Array, strength: float, step: int) -> void:
	var kept: Array = []
	for h in hits:
		var keep: bool
		if strength < 0.5:
			keep = h.voice != VOICE_HAT and h.voice != VOICE_PERC
		else:
			keep = h.voice == VOICE_KICK and step == 0
		if keep:
			kept.append(h)
	hits.assign(kept)


## Intensify (§9.3): boost surviving hits toward full velocity, accent hard when
## strong, and drop a ghost hat on the off (odd) 16ths.
static func _apply_intensify(hits: Array, strength: float, step: int) -> void:
	for h in hits:
		h.velocity = clampf(lerpf(h.velocity, 1.0, 0.5 * strength), 0.0, 1.0)
		if strength >= 0.5:
			h.accent = true
	if step % 2 == 1:
		_add_if_absent(hits, VOICE_HAT, step, INTENSIFY_GHOST_HAT_VELOCITY + 0.2 * strength)


## Fill (§9.1): only on the phrase turnaround, deterministic end-of-phrase hits in
## the last four steps — snare on {N-4, N-2, N-1}, hat on {N-3, N-2, N-1}.
static func _apply_fill(hits: Array, step: int, num_steps: int, final_bar: bool) -> void:
	if not final_bar or num_steps < 4:
		return
	var n := num_steps
	if step == n - 4 or step == n - 2 or step == n - 1:
		_add_if_absent(hits, VOICE_SNARE, step, FILL_SNARE_VELOCITY)
	if step == n - 3 or step == n - 2 or step == n - 1:
		_add_if_absent(hits, VOICE_HAT, step, FILL_HAT_VELOCITY)


## Add a hit for voice at step if that voice isn't already present (base takes precedence).
static func _add_if_absent(hits: Array, voice: int, step: int, velocity: float) -> void:
	for h in hits:
		if h.voice == voice:
			return
	hits.append({"voice": voice, "step": step, "velocity": clampf(velocity, 0.0, 1.0), "accent": false})
