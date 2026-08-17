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

const POLICY_NAME := "intent_bass"
const POLICY_VERSION := 1


static func decide(obs: Dictionary, seed_value: int) -> Array:
	return realization(obs, seed_value).ops


## The full explained decision — same computation as decide(), returning the
## why: interpretation vector, chosen intent + drivers, candidate scores.
## BotPeer logs this per frame so every edit is auditable from the log alone.
static func realization(obs: Dictionary, seed_value: int) -> Dictionary:
	var interp := Analysis.interpret(obs)
	var intent := IntentPolicy.decide(obs, interp)
	var real := Realizer.realize(obs, intent.intent, seed_value)
	real["drivers"] = intent.drivers
	real["realizer"] = Realizer.REALIZER_NAME
	real["realizer_version"] = Realizer.REALIZER_VERSION
	return real
