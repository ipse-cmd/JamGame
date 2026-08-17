class_name JamIntentBassPolicy
extends RefCounted

# Phase 3C: the full perception → intention → realization pipeline as a policy
# with the SAME contract as the frozen baseline: a pure function
# decide(observation, seed) -> ops. Every stage is deterministic, so a logged
# observation + seed replays the whole pipeline — interpretation, intent,
# candidates, evaluation, chosen ops — byte for byte, anywhere.
#
# The frozen RuleBassPolicy stays untouched as the comparison baseline; this
# policy mounts via `--bot --bot-policy=intent`.

const Analysis := preload("res://scripts/core/jam_analysis.gd")
const IntentPolicy := preload("res://scripts/ai/intent_policy.gd")
const Realizer := preload("res://scripts/ai/bass_realizer.gd")
const StylePrior := preload("res://scripts/ai/style_prior.gd")

const POLICY_NAME := "intent_bass"
# v2: 3E — the committed jazz profile (corpus-derived, versioned with the
# game) enters as a modest scoring prior over the same candidate set. Style
# biases among reasonable responses; W_STYLE deliberately small so it never
# outranks "the drummer/chords just did something I need to react to". Both
# rankings are logged every frame — the ablation is built into the corpus.
const POLICY_VERSION := 2

const STYLE_PROFILE_PATH := "res://data/style_profiles/jazz.json"
const W_STYLE := 0.35


static func decide(obs: Dictionary, seed_value: int) -> Array:
	return realization(obs, seed_value).ops


## The full explained decision — same computation as decide(), returning the
## why: interpretation vector, chosen intent + drivers, candidate scores.
## BotPeer logs this per frame so every edit is auditable from the log alone.
static func realization(obs: Dictionary, seed_value: int) -> Dictionary:
	var interp := Analysis.interpret(obs)
	var intent := IntentPolicy.decide(obs, interp)
	var style_bass = null
	var style_meta = null
	var profile = StylePrior.load_profile(STYLE_PROFILE_PATH)
	if profile != null and profile.get("roles", {}).has("bass"):
		var role: Dictionary = profile.roles.bass
		var factor: float = StylePrior.CONFIDENCE_FACTOR.get(role.get("confidence", ""), 0.0)
		if factor > 0.0:
			style_bass = role.profile
			style_meta = { # exact provenance rides with every decision
				"style_id": profile.style_id,
				"style_schema": StylePrior.STYLE_SCHEMA,
				"bass_source": role.source,
				"n_events": role.profile.n_events,
				"confidence": role.confidence,
				"w_style": W_STYLE * factor,
			}
	var real := Realizer.realize(obs, intent.intent, seed_value,
		style_bass, style_meta.w_style if style_meta != null else 0.0)
	real["drivers"] = intent.drivers
	real["realizer"] = Realizer.REALIZER_NAME
	real["realizer_version"] = Realizer.REALIZER_VERSION
	real["style"] = style_meta # null when no profile — absent, not fabricated
	return real
