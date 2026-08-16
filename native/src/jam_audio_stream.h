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
// This is the seam where Jammin's DaisySP voice engine will eventually live; for the
// spike, voices are pre-rendered PCM tables handed over from GDScript at startup.

#include <godot_cpp/classes/audio_stream.hpp>
#include <godot_cpp/classes/audio_stream_playback.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>

#include <atomic>
#include <cstdint>
#include <vector>

namespace godot {

class JamAudioStreamPlayback;

class JamAudioStream : public AudioStream {
	GDCLASS(JamAudioStream, AudioStream)
	friend class JamAudioStreamPlayback;

	struct TriggerEvent {
		int64_t sample = 0;
		int32_t voice = 0;
		float velocity = 1.0f;
		float pitch = 1.0f;
		int32_t choke = 0; // kill other active instances of this voice first (mono bass)
	};

	static constexpr uint32_t QUEUE_CAP = 2048; // power of two
	static constexpr uint32_t DIAG_CAP = 8192; // power of two, holds (intended, actual) pairs
	static constexpr int MAX_VOICES = 8;

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

	struct VoiceTable {
		std::vector<float> data;
		std::atomic<bool> ready{false};
	};
	VoiceTable voices_[MAX_VOICES];

protected:
	static void _bind_methods();

public:
	// ---- game-thread API ----
	void set_voice_table(int p_voice, const PackedFloat32Array &p_samples);
	bool schedule_trigger(int64_t p_sample, int p_voice, float p_velocity, float p_pitch, bool p_choke);
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

	struct ActiveVoice {
		bool on = false;
		int32_t voice = 0;
		double pos = 0.0;
		double step = 1.0;
		float gain = 1.0f;
		int32_t start_offset = 0; // offset inside the current mix block; 0 afterwards
	};
	static constexpr int MAX_ACTIVE = 32;
	ActiveVoice active_[MAX_ACTIVE];

	Ref<JamAudioStream> stream_;
	bool playing_ = false;

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
