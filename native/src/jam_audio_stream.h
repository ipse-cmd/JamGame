#pragma once

// JamAudio GDExtension — the G2 spike. A custom AudioStream/AudioStreamPlayback pair
// whose contract is future scheduling: the game thread submits TriggerEvents stamped
// with ABSOLUTE sample numbers; _mix() places each onset at the exact offset inside
// whatever block the audio thread happens to be rendering. Render-thread frame rate
// is irrelevant to onset placement as long as the game thread maintains lookahead.
//
// Audio-thread rules (enforced by construction): no allocation, no locks, no engine
// calls, no GDScript — consume ready events, advance voices, mix floats, bump cursor.
//
// Voices are Jammin's DaisySP rack (jam_voices.h) — the same synthesis, presets,
// pool sizes, and mix gains as the Unreal original, rendered live per sample.
// The scheduling contract is unchanged: absolute-sample stamps, SPSC queue,
// sample-exact onset placement inside whatever block the audio thread renders.

#include <godot_cpp/classes/audio_stream.hpp>
#include <godot_cpp/classes/audio_stream_playback.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>

#include <atomic>
#include <cstdint>

#include "jam_voices.h"

namespace godot {

class JamAudioStreamPlayback;

class JamAudioStream : public AudioStream {
	GDCLASS(JamAudioStream, AudioStream)
	friend class JamAudioStreamPlayback;

	struct TriggerEvent {
		int64_t sample = 0;
		int32_t voice = 0; // 0 kick, 1 snare, 2 hat, 3 perc, 4 bass, 5 pluck
		int32_t midi = 60; // tonal voices only
		float velocity = 1.0f;
		float duration = 0.25f; // seconds; bass gate length (drums/pluck self-time)
		int32_t variant = 0; // drum kit preset
	};

	static constexpr uint32_t QUEUE_CAP = 2048; // power of two
	static constexpr uint32_t DIAG_CAP = 8192; // power of two, holds (intended, actual) pairs
	static constexpr int VOICE_KICK = 0, VOICE_SNARE = 1, VOICE_HAT = 2,
			VOICE_PERC = 3, VOICE_BASS = 4, VOICE_PLUCK = 5, VOICE_POLY = 6,
			VOICE_STRING = 7, VOICE_MALLET = 8;
	static constexpr int NUM_VOICE_TYPES = 9;
	static constexpr int NUM_MIX_POOLS = 6; // tonal note voices share the Notes slot (5)

	// SPSC trigger queue: game thread writes, audio thread reads.
	// Contract: sample stamps must be non-decreasing (the scheduler emits steps in order).
	TriggerEvent queue_[QUEUE_CAP];
	std::atomic<uint32_t> q_write_{0};
	std::atomic<uint32_t> q_read_{0};

	// SPSC diagnostics ring: audio thread writes (intended, actual) pairs, game thread drains.
	int64_t diag_[DIAG_CAP] = {};
	std::atomic<uint32_t> d_write_{0};
	std::atomic<uint32_t> d_read_{0};

	std::atomic<int64_t> sample_cursor_{0};
	std::atomic<int64_t> launched_{0};
	std::atomic<int64_t> late_{0};
	std::atomic<int64_t> dropped_{0};

	// Room mixer: per-pool user gains on top of the rack's base mix (D10).
	std::atomic<float> pool_gains_[NUM_MIX_POOLS] = {{1.0f}, {1.0f}, {1.0f}, {1.0f}, {1.0f}, {1.0f}};

protected:
	static void _bind_methods();

public:
	// ---- game-thread API ----
	bool schedule_note(int64_t p_sample, int p_voice, int p_midi, float p_velocity,
			float p_duration, int p_variant);
	void set_pool_gain(int p_pool, float p_gain);
	int64_t get_sample_cursor() const;
	double get_mix_rate() const;
	int64_t get_launched_count() const;
	int64_t get_late_count() const;
	int64_t get_dropped_count() const;
	// Drains the diagnostics ring: flat [intended, actual, intended, actual, ...].
	PackedInt64Array drain_onsets();

	// ---- AudioStream interface ----
	virtual Ref<AudioStreamPlayback> _instantiate_playback() const override;
	virtual String _get_stream_name() const override;
	virtual double _get_length() const override;
	virtual bool _is_monophonic() const override;
};

class JamAudioStreamPlayback : public AudioStreamPlayback {
	GDCLASS(JamAudioStreamPlayback, AudioStreamPlayback)
	friend class JamAudioStream;

	static constexpr int MAX_BLOCK_EVENTS = 64; // events launched within one mix block

	jam::VoiceRack rack_;
	bool rack_ready_ = false;

	Ref<JamAudioStream> stream_;
	bool playing_ = false;

	void fire(const JamAudioStream::TriggerEvent &ev);

protected:
	static void _bind_methods() {}

public:
	virtual void _start(double p_from_pos) override;
	virtual void _stop() override;
	virtual bool _is_playing() const override;
	virtual int32_t _get_loop_count() const override;
	virtual double _get_playback_position() const override;
	virtual void _seek(double p_position) override;
	virtual int32_t _mix(AudioFrame *p_buffer, float p_rate_scale, int32_t p_frames) override;
};

} // namespace godot
