class_name JamBotObservation
extends RefCounted

# The versioned policy input boundary (JamObservation): the ONLY game state a
# policy may see. BotPeer, the MCP manual-policy path, offline trainers, and
# replay tooling must all consume THIS structure — never a hand-rolled view —
# so gaps discovered while playing a policy are gaps in the real interface,
# and a logged observation stays sufficient to reproduce its decision.
#
# Contract: the structure must survive JSON encode/decode (decision logs, a
# future Python boundary). from_json() rehydrates the policy-facing fields and
# the suite pins encode→decode→encode as a byte-identical fixed point.
#
# Shape (observation_schema 2):
#   canonical state   bass_notes, chord_slots, kick/snare/hat_steps, ...
#   snapshot features JamFeatures.extract of the same future-facing state
#   temporal context  deltas / event-overlap lookbacks / change ages (JamHistory)
#   decision metadata role, target_loop, versions, windows_since_change
#
# Future-facing: for each track the builder picks the pending snapshot when its
# commit lands at or before the bot's target loop (that IS the state the bot's
# edit will coexist with), otherwise the active one.

# v3: bass lanes reinterpreted as chord-relative roles (R/3/5/7/O);
# features moved to FEATURES_SCHEMA 2 (semantic + sounding bass families).
const OBSERVATION_SCHEMA := 3

const Features := preload("res://scripts/core/jam_features.gd")

const TRACK_DRUMS := 0
const TRACK_BASS := 1
const TRACK_CHORDS := 2

const VOICE_KICK := 0
const VOICE_SNARE := 1
const VOICE_HAT := 2
const VOICE_PERC := 3


## Observation for a BASS decision targeting target_loop.
## windows_since_change: decision windows since the bass line last actually
## changed (committed version bump). history (JamHistory or null) contributes
## the temporal section; without it, temporal is {} — absent, not fabricated.
static func build_bass(bass_model, drums_model, chords_model, target_loop: int,
		windows_since_change: int, history = null) -> Dictionary:
	var bass_line = state_at(bass_model, target_loop)
	var drum_pattern = state_at(drums_model, target_loop)
	var chord_track = state_at(chords_model, target_loop)

	var voice_steps := [[], [], [], []]
	for h in drum_pattern.hits:
		voice_steps[h.voice].append(h.step)

	var state := {
		"drums": drum_pattern.to_dict(),
		"bass": bass_line.to_dict(),
		"chords": chord_track.to_dict(),
	}

	return {
		"observation_schema": OBSERVATION_SCHEMA,
		"role": TRACK_BASS,
		"target_loop": target_loop,
		"steps_per_bar": bass_line.num_steps,
		"bass_notes": bass_line.notes.duplicate(),
		"bass_version": bass_model.version_id,
		"chord_slots": chord_track.slots.duplicate(),
		"kick_steps": voice_steps[VOICE_KICK],
		"snare_steps": voice_steps[VOICE_SNARE],
		"hat_steps": voice_steps[VOICE_HAT],
		"drum_density": float(drum_pattern.hits.size()) / float(drum_pattern.num_steps * 4),
		"windows_since_change": windows_since_change,
		"features": Features.extract(state),
		"temporal": history.temporal() if history != null else {},
	}


## The track state that will be audible at target_loop: a pending snapshot whose
## commit boundary is at or before it, else the active one. Public: BotPeer uses
## the same choice when snapshotting states for measurement/history.
static func state_at(model, target_loop: int):
	if model.has_pending() and model.commit_loop_index <= target_loop:
		return model.pending
	return model.active


## Rehydrate an observation that went through JSON (decision logs): string keys
## back to int, floats back to int where the schema says int. A logged frame's
## observation + rng_seed must reproduce its ops exactly — replay tooling and
## the location-independence proof both depend on this round-trip.
static func from_json(d: Dictionary) -> Dictionary:
	var obs := d.duplicate(true)
	var notes := {}
	for k in d.get("bass_notes", {}):
		notes[int(str(k))] = int(d.bass_notes[k])
	obs.bass_notes = notes
	for list_key in ["kick_steps", "snare_steps", "hat_steps"]:
		var ints: Array = []
		for v in d.get(list_key, []):
			ints.append(int(v))
		obs[list_key] = ints
	var slots: Array = []
	for v in d.get("chord_slots", []):
		slots.append(int(v))
	obs.chord_slots = slots
	for int_key in ["observation_schema", "role", "target_loop", "steps_per_bar", "bass_version", "windows_since_change"]:
		if obs.has(int_key):
			obs[int_key] = int(obs[int_key])
	return obs
