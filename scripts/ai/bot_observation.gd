class_name JamBotObservation
extends RefCounted

# Phase 1A: the observation a bot policy receives. This is the ONLY game state a
# policy may see — the MCP `get_bot_observation` path and BotPeer must both call
# this constructor, never hand-roll their own view, so gaps discovered while
# playing the policy manually are gaps in the real interface.
#
# Future-facing: for each track the builder picks the pending snapshot when its
# commit lands at or before the bot's target loop (that IS the state the bot's
# edit will coexist with), otherwise the active one.

const SCHEMA_VERSION := 1

const TRACK_DRUMS := 0
const TRACK_BASS := 1
const TRACK_CHORDS := 2

const VOICE_KICK := 0
const VOICE_SNARE := 1
const VOICE_HAT := 2
const VOICE_PERC := 3


## Observation for a BASS decision targeting target_loop.
## windows_since_change: decision windows since the bass line last actually
## changed (committed version bump) — the policy's only repetition signal in 1A.
static func build_bass(bass_model, drums_model, chords_model, target_loop: int, windows_since_change: int) -> Dictionary:
	var bass_line = _state_at(bass_model, target_loop)
	var drum_pattern = _state_at(drums_model, target_loop)
	var chord_track = _state_at(chords_model, target_loop)

	var voice_steps := [[], [], [], []]
	for h in drum_pattern.hits:
		voice_steps[h.voice].append(h.step)

	return {
		"schema": SCHEMA_VERSION,
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
	}


## The track state that will be audible at target_loop: a pending snapshot whose
## commit boundary is at or before it, else the active one.
static func _state_at(model, target_loop: int):
	if model.has_pending() and model.commit_loop_index <= target_loop:
		return model.pending
	return model.active
