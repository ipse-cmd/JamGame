class_name JamChordComp
extends RefCounted

# Chord PERFORMANCE (comping): how the chord track plays, kept strictly apart
# from WHAT it plays (the slots). A comp = a per-bar rhythm of chord hits; a
# voicing = how the triad spreads across octaves (the ladder idea, smallest
# version). Both are commit-gated fields on the chord track, so they replicate
# and promote like every other musical edit. Pure data + math — the room's
# scheduler renders through it; every peer derives identical events.
#
# Rolled chords: simultaneous voices spread by ROLL_SECONDS low→high —
# measured reality (~40% of real keys hits roll ~8ms; see style-era notes) —
# deterministic, applied at schedule time.

const COMP_SCHEMA := 1
const ROLL_SECONDS := 0.008
const BASE_VELOCITY := 0.7 # comping sits quiet/wide (measured velocity bands)

# hits: step (0..15 within the bar), vel (relative), dur (sixteenths — gated
# synths hold this long; the pluck self-times). "arp": hits cycle single
# voiced notes (hit order = arp order) instead of striking the full voicing.
const PATTERNS := [
	{"name": "Pad", "hits": [{"step": 0, "vel": 1.0, "dur": 16}]},
	{"name": "Pulse", "hits": [{"step": 0, "vel": 1.0, "dur": 8}, {"step": 8, "vel": 0.8, "dur": 8}]},
	{"name": "Offbeat", "hits": [
		{"step": 2, "vel": 0.7, "dur": 2}, {"step": 6, "vel": 0.7, "dur": 2},
		{"step": 10, "vel": 0.7, "dur": 2}, {"step": 14, "vel": 0.75, "dur": 2}]},
	{"name": "Charleston", "hits": [{"step": 0, "vel": 1.0, "dur": 4}, {"step": 6, "vel": 0.7, "dur": 2}]},
	{"name": "Arp", "arp": true, "hits": [
		{"step": 0, "vel": 0.9, "dur": 2}, {"step": 2, "vel": 0.6, "dur": 2},
		{"step": 4, "vel": 0.75, "dur": 2}, {"step": 6, "vel": 0.6, "dur": 2},
		{"step": 8, "vel": 0.85, "dur": 2}, {"step": 10, "vel": 0.6, "dur": 2},
		{"step": 12, "vel": 0.75, "dur": 2}, {"step": 14, "vel": 0.6, "dur": 2}]},
]

const VOICINGS := ["Close", "Open", "Wide"]
const SYNTHS := ["Pluck", "Poly Pad", "Poly Keys", "String", "Mallet"]


static func synth_name(s: int) -> String:
	return SYNTHS[clampi(s, 0, SYNTHS.size() - 1)]


static func pattern_name(comp: int) -> String:
	return PATTERNS[clampi(comp, 0, PATTERNS.size() - 1)].name


static func voicing_name(v: int) -> String:
	return VOICINGS[clampi(v, 0, VOICINGS.size() - 1)]


## Spread a close triad [root, third, fifth] into the selected voicing.
## Close = as-is; Open = drop the middle voice up an octave; Wide = root down,
## fifth up an octave. Same pattern, different texture — the cheapest variety.
static func voice(triad: Array, voicing: int) -> Array:
	var r := int(triad[0])
	var t := int(triad[1])
	var f := int(triad[2])
	match clampi(voicing, 0, VOICINGS.size() - 1):
		1: return [r, f, t + 12] # open
		2: return [r - 12, t, f + 12] # wide
		_: return [r, t, f] # close


## The scheduled events for one step of one bar: [{midis: Array, vel: float,
## roll: bool}]. Empty when the comp has no hit on this step. Arp patterns
## emit one voiced note per hit, cycling low→high by hit order.
static func events_for_step(comp: int, voicing: int, step: int, triad: Array) -> Array:
	var p: Dictionary = PATTERNS[clampi(comp, 0, PATTERNS.size() - 1)]
	var voiced := voice(triad, voicing)
	var out: Array = []
	for i in p.hits.size():
		var h: Dictionary = p.hits[i]
		if int(h.step) != step:
			continue
		if p.get("arp", false):
			out.append({"midis": [voiced[i % voiced.size()]], "vel": BASE_VELOCITY * float(h.vel),
				"roll": false, "dur_steps": int(h.get("dur", 2))})
		else:
			out.append({"midis": voiced, "vel": BASE_VELOCITY * float(h.vel),
				"roll": true, "dur_steps": int(h.get("dur", 4))})
	return out
