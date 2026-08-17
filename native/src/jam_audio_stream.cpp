#include "jam_audio_stream.h"

#include <godot_cpp/classes/audio_server.hpp>
#include <godot_cpp/core/class_db.hpp>

namespace godot {

// ---------------------------------------------------------------- JamAudioStream

void JamAudioStream::_bind_methods() {
	ClassDB::bind_method(D_METHOD("schedule_note", "sample", "voice", "midi", "velocity", "duration", "variant"),
			&JamAudioStream::schedule_note, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("set_pool_gain", "pool", "gain"), &JamAudioStream::set_pool_gain);
	ClassDB::bind_method(D_METHOD("get_sample_cursor"), &JamAudioStream::get_sample_cursor);
	ClassDB::bind_method(D_METHOD("get_mix_rate"), &JamAudioStream::get_mix_rate);
	ClassDB::bind_method(D_METHOD("get_launched_count"), &JamAudioStream::get_launched_count);
	ClassDB::bind_method(D_METHOD("get_late_count"), &JamAudioStream::get_late_count);
	ClassDB::bind_method(D_METHOD("get_dropped_count"), &JamAudioStream::get_dropped_count);
	ClassDB::bind_method(D_METHOD("drain_onsets"), &JamAudioStream::drain_onsets);
}

bool JamAudioStream::schedule_note(int64_t p_sample, int p_voice, int p_midi, float p_velocity,
		float p_duration, int p_variant) {
	if (p_voice < 0 || p_voice >= NUM_VOICE_TYPES) {
		return false;
	}
	const uint32_t w = q_write_.load(std::memory_order_relaxed);
	const uint32_t r = q_read_.load(std::memory_order_acquire);
	if (w - r >= QUEUE_CAP) {
		dropped_.fetch_add(1, std::memory_order_relaxed);
		return false;
	}
	TriggerEvent &ev = queue_[w & (QUEUE_CAP - 1)];
	ev.sample = p_sample;
	ev.voice = p_voice;
	ev.midi = p_midi;
	ev.velocity = p_velocity;
	ev.duration = p_duration;
	ev.variant = p_variant;
	q_write_.store(w + 1, std::memory_order_release);
	return true;
}

void JamAudioStream::set_pool_gain(int p_pool, float p_gain) {
	if (p_pool < 0 || p_pool >= NUM_VOICE_TYPES) {
		return;
	}
	const float g = (p_gain == p_gain) ? p_gain : 1.0f; // NaN guard
	pool_gains_[p_pool].store(std::min(2.0f, std::max(0.0f, g)), std::memory_order_relaxed);
}

int64_t JamAudioStream::get_sample_cursor() const {
	return sample_cursor_.load(std::memory_order_acquire);
}

double JamAudioStream::get_mix_rate() const {
	return (double)AudioServer::get_singleton()->get_mix_rate();
}

int64_t JamAudioStream::get_launched_count() const {
	return launched_.load(std::memory_order_relaxed);
}

int64_t JamAudioStream::get_late_count() const {
	return late_.load(std::memory_order_relaxed);
}

int64_t JamAudioStream::get_dropped_count() const {
	return dropped_.load(std::memory_order_relaxed);
}

PackedInt64Array JamAudioStream::drain_onsets() {
	PackedInt64Array out;
	uint32_t r = d_read_.load(std::memory_order_relaxed);
	const uint32_t w = d_write_.load(std::memory_order_acquire);
	while (r != w) {
		out.push_back(diag_[r & (DIAG_CAP - 1)]);
		r++;
	}
	d_read_.store(r, std::memory_order_release);
	return out;
}

Ref<AudioStreamPlayback> JamAudioStream::_instantiate_playback() const {
	Ref<JamAudioStreamPlayback> playback;
	playback.instantiate();
	playback->stream_ = Ref<JamAudioStream>(const_cast<JamAudioStream *>(this));
	return playback;
}

String JamAudioStream::_get_stream_name() const {
	return "JamAudioStream";
}

double JamAudioStream::_get_length() const {
	return 0.0; // endless
}

bool JamAudioStream::_is_monophonic() const {
	return false;
}

// ---------------------------------------------------------------- JamAudioStreamPlayback

void JamAudioStreamPlayback::_start(double p_from_pos) {
	rack_.Init((float)AudioServer::get_singleton()->get_mix_rate());
	rack_ready_ = true;
	playing_ = true;
}

void JamAudioStreamPlayback::fire(const JamAudioStream::TriggerEvent &ev) {
	switch (ev.voice) {
		case JamAudioStream::VOICE_KICK: rack_.kick.Allocate().Trigger(ev.velocity, ev.variant); break;
		case JamAudioStream::VOICE_SNARE: rack_.snare.Allocate().Trigger(ev.velocity, ev.variant); break;
		case JamAudioStream::VOICE_HAT: rack_.hat.Allocate().Trigger(ev.velocity, ev.variant); break;
		case JamAudioStream::VOICE_PERC: rack_.perc.Allocate().Trigger(ev.velocity, ev.variant); break;
		case JamAudioStream::VOICE_BASS: rack_.bass.Allocate().NoteOn(ev.midi, ev.velocity, ev.duration); break;
		case JamAudioStream::VOICE_PLUCK: rack_.pluck.Allocate().Pluck(ev.midi, ev.velocity, 0.5f); break;
		default: break;
	}
}

void JamAudioStreamPlayback::_stop() {
	playing_ = false;
}

bool JamAudioStreamPlayback::_is_playing() const {
	return playing_;
}

int32_t JamAudioStreamPlayback::_get_loop_count() const {
	return 0;
}

double JamAudioStreamPlayback::_get_playback_position() const {
	if (stream_.is_null()) {
		return 0.0;
	}
	const double rate = (double)AudioServer::get_singleton()->get_mix_rate();
	return rate > 0.0 ? (double)stream_->sample_cursor_.load(std::memory_order_relaxed) / rate : 0.0;
}

void JamAudioStreamPlayback::_seek(double p_position) {
	// Absolute-sample timeline; seeking is meaningless here.
}

int32_t JamAudioStreamPlayback::_mix(AudioFrame *p_buffer, float p_rate_scale, int32_t p_frames) {
	// AUDIO THREAD. No allocation, no locks, no engine calls beyond the buffer we own.
	for (int32_t i = 0; i < p_frames; i++) {
		p_buffer[i].left = 0.0f;
		p_buffer[i].right = 0.0f;
	}
	if (stream_.is_null() || !playing_ || p_frames <= 0) {
		return p_frames;
	}
	JamAudioStream *s = stream_.ptr();
	const int64_t cursor = s->sample_cursor_.load(std::memory_order_relaxed);
	const int64_t block_end = cursor + p_frames;

	// Collect every event whose stamp falls inside this block (stamps are
	// non-decreasing, so collection order == launch order).
	struct Pending {
		int32_t offset;
		JamAudioStream::TriggerEvent ev;
	};
	Pending pending[MAX_BLOCK_EVENTS];
	int n_pending = 0;

	uint32_t r = s->q_read_.load(std::memory_order_relaxed);
	const uint32_t w = s->q_write_.load(std::memory_order_acquire);
	while (r != w && n_pending < MAX_BLOCK_EVENTS) {
		const JamAudioStream::TriggerEvent &ev = s->queue_[r & (JamAudioStream::QUEUE_CAP - 1)];
		if (ev.sample >= block_end) {
			break; // future block
		}
		int64_t offset = ev.sample - cursor;
		if (offset < 0) {
			s->late_.fetch_add(1, std::memory_order_relaxed);
			offset = 0; // degrade to block start, like Jammin's late-trigger path
		}
		pending[n_pending].offset = (int32_t)offset;
		pending[n_pending].ev = ev;
		n_pending++;
		s->launched_.fetch_add(1, std::memory_order_relaxed);
		// Record (intended, actual) for the game thread's timing verification.
		const uint32_t dw = s->d_write_.load(std::memory_order_relaxed);
		const uint32_t dr = s->d_read_.load(std::memory_order_acquire);
		if (dw - dr <= JamAudioStream::DIAG_CAP - 2) {
			s->diag_[dw & (JamAudioStream::DIAG_CAP - 1)] = ev.sample;
			s->diag_[(dw + 1) & (JamAudioStream::DIAG_CAP - 1)] = cursor + offset;
			s->d_write_.store(dw + 2, std::memory_order_release);
		}
		r++;
	}
	s->q_read_.store(r, std::memory_order_release);

	// Per-sample render: fire due events at their exact offset, then sum the rack.
	if (rack_ready_) {
		float gains[JamAudioStream::NUM_VOICE_TYPES];
		for (int g = 0; g < JamAudioStream::NUM_VOICE_TYPES; g++) {
			gains[g] = s->pool_gains_[g].load(std::memory_order_relaxed);
		}
		int idx = 0;
		for (int32_t i = 0; i < p_frames; i++) {
			while (idx < n_pending && pending[idx].offset <= i) {
				fire(pending[idx].ev);
				idx++;
			}
			const float smp = rack_.Render(gains);
			p_buffer[i].left += smp;
			p_buffer[i].right += smp;
		}
	}

	s->sample_cursor_.store(block_end, std::memory_order_release);
	return p_frames;
}

} // namespace godot
