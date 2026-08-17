class_name JamIntentPolicy
extends RefCounted

# Phase 3B: INTENTION, kept strictly between perception and realization.
#
#   JamAnalysis      "chords changed under me, external=.78, repetition=.46"
#   JamIntentPolicy  RESPOND
#   (3C realizer)    what a response actually sounds like
#
# The vocabulary is small and behavioral — HOLD / RESPOND / SIMPLIFY /
# INTENSIFY / VARY / REVERT — and the policy is deterministic threshold rules
# over the interpretation vector: no RNG, no note knowledge, fully replayable
# from any logged frame. SHADOW-ONLY for now: intents are logged alongside the
# frozen baseline's proposals and the human's actual ops, so the comparison
# "did causal signals improve behavioral timing?" is answered from session
# logs before any intent is ever realized.
#
# style_context is architected now but intentionally inert: the 3A signals
# describe INTERACTION, not genre (someone changed something, I just changed
# something, the line repeats) — genre belongs to how intents are realized
# (3D/3E) and how strongly pressures matter, and we refuse to invent those
# weights without corpus evidence. Unknown styles behave as DEFAULT.

const POLICY_NAME := "intent_rules"
const POLICY_VERSION := 1
const INTENT_SCHEMA := 1

const STYLE_DEFAULT := "default"

const HOLD := "HOLD"
const RESPOND := "RESPOND"
const SIMPLIFY := "SIMPLIFY"
const INTENSIFY := "INTENSIFY"
const VARY := "VARY"
const REVERT := "REVERT"

# Decision thresholds: versioned design opinions, tuned against logged
# sessions — not against imagination (see VALIDATION.md, 2.5 divergence).
const T_SELF := 0.5 # own fresh edit: sit on your hands
const T_EXTERNAL := 0.5 # someone changed the jam: react
const T_CROWDED := 0.6 # density tension: back off
const T_ENERGY := 0.6 # jam is hot and bass is absent: join in
const T_UNDERPLAYING := 0.2 # bass_density below this while hot = under-participating
const T_REPETITION := 0.6 # stale: introduce novelty


## Decide an intent from a schema-4 observation + its interpretation vector.
## Priority order is part of the contract (REVERT before HOLD-on-self: "my
## edit made it worse" outranks "I just edited"). Returns the intent plus the
## drivers that fired — the reason IS the log.
static func decide(obs: Dictionary, interp: Dictionary, style_context := STYLE_DEFAULT) -> Dictionary:
	var self_p := float(interp.get("self_change_pressure", 0.0))
	var external := float(interp.get("external_change_pressure", 0.0))
	var crowding := float(interp.get("density_tension", 0.0))
	var energy := float(interp.get("energy", 0.0))
	var repetition := float(interp.get("repetition_pressure", 0.0))
	var bass_density := float(obs.get("features", {}).get("bass_density", 0.0))
	var lcb: Dictionary = obs.get("last_change_by", {})

	var intent := HOLD
	var drivers := {}
	if lcb.get("bass", "none") == "self" and obs.get("bass_notes_prev") != null \
			and crowding >= T_CROWDED:
		# bass_notes_prev's first consumer: my own change crowded the jam — go
		# back. Not a mutation in the opposite direction; the actual pattern.
		intent = REVERT
		drivers = {"density_tension": crowding, "last_change_by_bass": "self"}
	elif self_p >= T_SELF:
		intent = HOLD
		drivers = {"self_change_pressure": self_p}
	elif external >= T_EXTERNAL:
		intent = RESPOND
		drivers = {"external_change_pressure": external}
	elif crowding >= T_CROWDED:
		intent = SIMPLIFY
		drivers = {"density_tension": crowding}
	elif energy >= T_ENERGY and bass_density < T_UNDERPLAYING:
		intent = INTENSIFY
		drivers = {"energy": energy, "bass_density": bass_density}
	elif repetition >= T_REPETITION:
		intent = VARY
		drivers = {"repetition_pressure": repetition}

	return {
		"intent_schema": INTENT_SCHEMA,
		"policy_name": POLICY_NAME,
		"policy_version": POLICY_VERSION,
		"style": style_context if style_context == STYLE_DEFAULT else STYLE_DEFAULT,
		"style_requested": style_context,
		"intent": intent,
		"drivers": drivers,
	}
