#include "jam_audio_stream.h"

#include <godot_cpp/classes/audio_server.hpp>
#include <godot_cpp/core/class_db.hpp>

namespace godot {

// ---------------------------------------------------------------- JamAudioStream

void JamAudioStream::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_voice_table", "voice", "samples"), &JamAudioStream::set_voice_table);
	ClassDB::bind_method(D_METHOD("schedule_trigger", "sample", "voice", "velocity", "pitch", "choke"),
			&JamAudioStream::schedule_trigger, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("get_sample_cursor"), &JamAudioStream::get_sample_cursor);
	ClassDB::bind_method(D_METHOD("get_mix_rate"), &JamAudioStream::get_mix_rate);
	ClassDB::bind_method(D_METHOD("get_launched_count"), &JamAudioStream::get_launched_count);
	ClassDB::bind_method(D_METHOD("get_late_count"), &JamAudioStream::get_late_count);
	ClassDB::bind_method(D_METHOD("get_dropped_count"), &JamAudioStream::get_dropped_count);
	ClassDB::bind_method(D_METHOD("drain_onsets"), &JamAudioStream::drain_onsets);
}

void JamAudioStream::set_voice_table(int p_voice, const PackedFloat32Array &p_samples) {
	ERR_FAIL_INDEX(p_voice, MAX_VOICES);
	VoiceTable &vt = voices_[p_voice];
	vt.ready.store(false, std::memory_order_release);
	const int64_t n = p_samples.size();
	vt.data.resize((size_t)n);
	const float *src = p_samples.ptr();
	for (int64_t i = 0; i < n; i++) {
		vt.data[(size_t)i] = src[i];
	}
	vt.ready.store(true, std::memory_order_release);
}

bool JamAudioStream::schedule_trigger(int64_t p_sample, int p_voice, float p_velocity, float p_pitch, bool p_choke) {
	if (p_voice < 0 || p_voice >= MAX_VOICES) {
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
	ev.velocity = p_velocity;
	ev.pitch = p_pitch;
	ev.choke = p_choke ? 1 : 0;
	q_write_.store(w + 1, std::memory_order_release);
	return true;
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
	for (int i = 0; i < MAX_ACTIVE; i++) {
		active_[i].on = false;
	}
	playing_ = true;
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

	// Launch every event whose stamp falls inside this block (stamps are non-decreasing).
	uint32_t r = s->q_read_.load(std::memory_order_relaxed);
	const uint32_t w = s->q_write_.load(std::memory_order_acquire);
	while (r != w) {
		const JamAudioStream::TriggerEvent &ev = s->queue_[r & (JamAudioStream::QUEUE_CAP - 1)];
		if (ev.sample >= block_end) {
			break; // future block
		}
		int64_t offset = ev.sample - cursor;
		if (offset < 0) {
			s->late_.fetch_add(1, std::memory_order_relaxed);
			offset = 0; // degrade to block start, like Jammin's late-trigger path
		}
		if (ev.choke) {
			for (int a = 0; a < MAX_ACTIVE; a++) {
				if (active_[a].on && active_[a].voice == ev.voice) {
					active_[a].on = false;
				}
			}
		}
		for (int a = 0; a < MAX_ACTIVE; a++) {
			if (!active_[a].on) {
				active_[a].on = true;
				active_[a].voice = ev.voice;
				active_[a].pos = 0.0;
				active_[a].step = (double)ev.pitch;
				active_[a].gain = ev.velocity;
				active_[a].start_offset = (int32_t)offset;
				break;
			}
		}
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

	// Advance and mix active voices.
	for (int a = 0; a < MAX_ACTIVE; a++) {
		ActiveVoice &v = active_[a];
		if (!v.on) {
			continue;
		}
		const JamAudioStream::VoiceTable &vt = s->voices_[v.voice];
		if (!vt.ready.load(std::memory_order_acquire)) {
			v.on = false;
			continue;
		}
		const float *data = vt.data.data();
		const int64_t n = (int64_t)vt.data.size();
		const int32_t begin = v.start_offset;
		v.start_offset = 0;
		double pos = v.pos;
		bool alive = true;
		for (int32_t i = begin; i < p_frames; i++) {
			const int64_t ip = (int64_t)pos;
			if (ip >= n) {
				alive = false;
				break;
			}
			const float smp = data[ip] * v.gain;
			p_buffer[i].left += smp;
			p_buffer[i].right += smp;
			pos += v.step;
		}
		v.pos = pos;
		v.on = alive && ((int64_t)pos < n);
	}

	s->sample_cursor_.store(block_end, std::memory_order_release);
	return p_frames;
}

} // namespace godot
