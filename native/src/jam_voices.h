#pragma once

// Jammin's DaisySP voice set, ported verbatim from the Unreal original
// (Plugins/JamAudioCore/Private/Voices/JamSynthVoices.h) — same DSP modules,
// same parameter presets, same pool sizes, so the Godot port SOUNDS like
// Jammin. Audio-thread rules: no allocation, no locks; fixed-size pools that
// prefer a free voice and steal the oldest otherwise. Drum voices take a kit
// VARIANT on trigger (D9): parameter presets applied just before Trig so
// retriggers can hop between sounds freely. Tonal voices (bass, pluck) are
// pooled so chords and overlapping/held notes don't cut each other off.

#include <algorithm>
#include <cmath>
#include <cstdint>

#include "Control/adsr.h"
#include "Drums/analogbassdrum.h"
#include "Drums/hihat.h"
#include "Drums/synthsnaredrum.h"
#include "Filters/svf.h"
#include "PhysicalModeling/KarplusString.h"
#include "Synthesis/oscillator.h"

namespace jam {

inline float midi_to_hz(int32_t midi) {
	return 440.0f * std::pow(2.0f, (float(midi) - 69.0f) / 12.0f);
}

inline float clamp01(float v) {
	return std::min(1.0f, std::max(0.0f, v));
}

inline int32_t wrap3(int32_t variant) {
	return ((variant % 3) + 3) % 3;
}

/** Kick (analog bass drum). Variants: 0 deep, 1 punch, 2 boom. */
class KickVoice {
public:
	void Init(float sample_rate) {
		sr_ = std::max(1.0f, sample_rate);
		drum_.Init(sr_);
	}
	void Trigger(float velocity, int32_t variant = 0) {
		// Tone raised vs the Unreal presets: the 808 model's energy is nearly
		// all sub-65Hz, which vanishes on desktop speakers under the saw bass
		// (measured: kick RMS ~14dB below snare). Tone adds the beater click
		// that lets the kick read at any playback level; character unchanged.
		float life = 0.6f;
		switch (wrap3(variant)) {
			default:
			case 0: drum_.SetFreq(52.0f); drum_.SetTone(0.85f); drum_.SetDecay(0.4f);  life = 0.6f;  break; // deep
			case 1: drum_.SetFreq(65.0f); drum_.SetTone(0.95f); drum_.SetDecay(0.25f); life = 0.35f; break; // punch
			case 2: drum_.SetFreq(42.0f); drum_.SetTone(0.7f);  drum_.SetDecay(0.75f); life = 0.95f; break; // boom
		}
		drum_.SetAttackFmAmount(0.8f);
		drum_.SetAccent(clamp01(velocity));
		drum_.Trig();
		life_ = (int32_t)std::lround(life * sr_);
	}
	float Process() {
		if (life_ > 0) { --life_; }
		return drum_.Process(false);
	}
	bool IsFinished() const { return life_ <= 0; }

private:
	float sr_ = 48000.0f;
	int32_t life_ = 0;
	daisysp::AnalogBassDrum drum_;
};

/** Snare (synthetic). Variants: 0 snap, 1 tight, 2 fat. */
class SnareVoice {
public:
	void Init(float sample_rate) {
		sr_ = std::max(1.0f, sample_rate);
		drum_.Init(sr_);
	}
	void Trigger(float velocity, int32_t variant = 0) {
		float life = 0.5f;
		switch (wrap3(variant)) {
			default:
			case 0: drum_.SetFreq(200.0f); drum_.SetDecay(0.3f);  drum_.SetSnappy(0.6f);  life = 0.5f; break; // snap
			case 1: drum_.SetFreq(245.0f); drum_.SetDecay(0.15f); drum_.SetSnappy(0.9f);  life = 0.3f; break; // tight
			case 2: drum_.SetFreq(165.0f); drum_.SetDecay(0.5f);  drum_.SetSnappy(0.35f); life = 0.7f; break; // fat
		}
		drum_.SetAccent(clamp01(velocity));
		drum_.Trig();
		life_ = (int32_t)std::lround(life * sr_);
	}
	float Process() {
		if (life_ > 0) { --life_; }
		return drum_.Process(false);
	}
	bool IsFinished() const { return life_ <= 0; }

private:
	float sr_ = 48000.0f;
	int32_t life_ = 0;
	daisysp::SyntheticSnareDrum drum_;
};

/** Hat (metallic). Variants: 0 closed, 1 open, 2 crisp. */
class HatVoice {
public:
	void Init(float sample_rate) {
		sr_ = std::max(1.0f, sample_rate);
		drum_.Init(sr_);
	}
	void Trigger(float velocity, int32_t variant = 0) {
		float life = 0.35f;
		switch (wrap3(variant)) {
			default:
			case 0: drum_.SetFreq(8000.0f);  drum_.SetTone(0.7f);  drum_.SetDecay(0.3f);  life = 0.35f; break; // closed
			case 1: drum_.SetFreq(7000.0f);  drum_.SetTone(0.55f); drum_.SetDecay(0.85f); life = 0.9f;  break; // open
			case 2: drum_.SetFreq(10500.0f); drum_.SetTone(0.9f);  drum_.SetDecay(0.15f); life = 0.2f;  break; // crisp
		}
		drum_.SetAccent(clamp01(velocity));
		drum_.Trig();
		life_ = (int32_t)std::lround(life * sr_);
	}
	float Process() {
		if (life_ > 0) { --life_; }
		return drum_.Process(false);
	}
	bool IsFinished() const { return life_ <= 0; }

private:
	float sr_ = 48000.0f;
	int32_t life_ = 0;
	daisysp::HiHat<> drum_;
};

/** Perc: a tuned analog drum pitched into tom/conga territory. Variants: 0 tom, 1 conga, 2 low tom. */
class PercVoice {
public:
	void Init(float sample_rate) {
		sr_ = std::max(1.0f, sample_rate);
		drum_.Init(sr_);
	}
	void Trigger(float velocity, int32_t variant = 0) {
		float life = 0.3f;
		switch (wrap3(variant)) {
			default:
			case 0: drum_.SetFreq(180.0f); drum_.SetTone(0.8f);  drum_.SetDecay(0.18f); life = 0.3f;  break; // tom
			case 1: drum_.SetFreq(260.0f); drum_.SetTone(0.9f);  drum_.SetDecay(0.12f); life = 0.2f;  break; // conga
			case 2: drum_.SetFreq(115.0f); drum_.SetTone(0.65f); drum_.SetDecay(0.3f);  life = 0.45f; break; // low tom
		}
		drum_.SetAccent(clamp01(velocity));
		drum_.Trig();
		life_ = (int32_t)std::lround(life * sr_);
	}
	float Process() {
		if (life_ > 0) { --life_; }
		return drum_.Process(false);
	}
	bool IsFinished() const { return life_ <= 0; }

private:
	float sr_ = 48000.0f;
	int32_t life_ = 0;
	daisysp::AnalogBassDrum drum_;
};

/** Bass: poly-blep saw -> ADSR -> low-pass. Gate held for the note duration; finished after the release tail. */
class BassVoice {
public:
	void Init(float sample_rate) {
		sr_ = std::max(1.0f, sample_rate);
		osc_.Init(sr_);
		osc_.SetWaveform(daisysp::Oscillator::WAVE_POLYBLEP_SAW);
		osc_.SetAmp(1.0f);
		env_.Init(sr_);
		env_.SetAttackTime(0.005f);
		env_.SetDecayTime(0.10f);
		env_.SetSustainLevel(0.7f);
		env_.SetReleaseTime(kReleaseSeconds);
		filter_.Init(sr_);
		filter_.SetRes(0.2f);
		filter_.SetFreq(1200.0f);
	}

	void NoteOn(int32_t midi, float velocity, float duration_seconds) {
		osc_.SetFreq(midi_to_hz(midi));
		amp_ = clamp01(velocity);
		const float dur = std::min(10.0f, std::max(0.005f, duration_seconds));
		gate_ = std::max(1, (int32_t)std::lround(dur * sr_));
		// Lifetime = gate + the envelope's release tail (a little extra so it fully decays before freeing).
		life_ = gate_ + (int32_t)std::lround((kReleaseSeconds + 0.02f) * sr_);
	}

	float Process() {
		const bool gate = gate_ > 0;
		if (gate) { --gate_; }
		if (life_ > 0) { --life_; }
		const float e = env_.Process(gate);
		filter_.Process(osc_.Process());
		return filter_.Low() * e * amp_;
	}

	bool IsFinished() const { return life_ <= 0; }

private:
	static constexpr float kReleaseSeconds = 0.10f;
	float sr_ = 48000.0f;
	float amp_ = 0.0f;
	int32_t gate_ = 0;
	int32_t life_ = 0;
	daisysp::Oscillator osc_;
	daisysp::Adsr env_;
	daisysp::Svf filter_;
};

/** Pluck: Karplus-Strong string excited by a short noise burst. Finished once the ring has decayed. */
class PluckVoice {
public:
	void Init(float sample_rate) {
		sr_ = std::max(1.0f, sample_rate);
		str_.Init(sr_);
		str_.SetBrightness(0.6f);
		str_.SetDamping(0.5f);
		str_.SetNonLinearity(0.1f);
	}

	void Pluck(int32_t midi, float velocity, float damping) {
		str_.SetFreq(midi_to_hz(midi));
		str_.SetDamping(clamp01(damping));
		excite_amp_ = clamp01(velocity);
		excite_ = std::max(1, (int32_t)std::lround(0.003f * sr_)); // ~3 ms burst
		life_ = (int32_t)std::lround(kDecaySeconds * sr_);         // generous full-decay window
	}

	float Process() {
		if (life_ > 0) { --life_; }
		float in = 0.0f;
		if (excite_ > 0) {
			in = NextNoise() * excite_amp_;
			--excite_;
		}
		return str_.Process(in);
	}

	bool IsFinished() const { return life_ <= 0; }

private:
	// xorshift32 -> [-1, 1). Realtime-safe, deterministic, no global RNG.
	float NextNoise() {
		noise_ ^= noise_ << 13;
		noise_ ^= noise_ >> 17;
		noise_ ^= noise_ << 5;
		return (float(noise_) / 2147483648.0f) - 1.0f;
	}

	static constexpr float kDecaySeconds = 2.5f;
	float sr_ = 48000.0f;
	float excite_amp_ = 0.0f;
	int32_t excite_ = 0;
	int32_t life_ = 0;
	uint32_t noise_ = 0x1234567u;
	daisysp::String str_;
};

/**
 * Poly virtual-analog voice — clean-room implementation over DaisySP,
 * architecture after PolyAnalog by Alexis ZBIK (github.com/alexiszbik/polyanalog,
 * upstream is unlicensed so NO code is copied): 2 VCOs (supersaw/saw/square+PW),
 * osc mix, octave/fifth tuning + fine detune on VCO B, noise mix, ADSR, and a
 * resonant low-pass swept by the envelope. The hardware original was 4-voice
 * (Daisy Seed); the desktop pool runs 10. Presets: 0 Pad (supersaw, slow
 * attack, long release), 1 Keys (saw+square, fast, brighter).
 */
class PolyVoice {
public:
	static constexpr int kSupersaw = 3;

	void Init(float sample_rate) {
		sr_ = std::max(1.0f, sample_rate);
		for (int i = 0; i < kSupersaw; ++i) {
			osc_a_[i].Init(sr_);
			osc_a_[i].SetWaveform(daisysp::Oscillator::WAVE_POLYBLEP_SAW);
			osc_a_[i].SetAmp(1.0f);
		}
		osc_b_.Init(sr_);
		osc_b_.SetAmp(1.0f);
		env_.Init(sr_);
		filter_.Init(sr_);
		noise_state_ = 0x2468ace1u;
	}

	void NoteOn(int32_t midi, float velocity, float duration_seconds, int32_t preset) {
		const float f = midi_to_hz(midi);
		if (((preset % 2) + 2) % 2 == 0) { // Pad: supersaw A + detuned saw B an octave down
			n_saw_ = kSupersaw;
			for (int i = 0; i < n_saw_; ++i) {
				const float det = 1.0f + 0.007f * (float(i) - 1.0f); // -0.7%, 0, +0.7%
				osc_a_[i].SetFreq(f * det);
			}
			osc_b_.SetWaveform(daisysp::Oscillator::WAVE_POLYBLEP_SAW);
			osc_b_.SetFreq(f * 0.5f * 1.003f);
			mix_ = 0.5f;
			noise_mix_ = 0.02f;
			env_.SetAttackTime(0.08f);
			env_.SetDecayTime(0.05f);
			env_.SetSustainLevel(1.0f);
			env_.SetReleaseTime(release_ = 0.35f);
			lp_base_ = 1200.0f;
			lp_env_ = 900.0f;
			filter_.SetRes(0.15f);
		} else { // Keys: single saw + square, snappier and brighter
			n_saw_ = 1;
			osc_a_[0].SetFreq(f);
			osc_b_.SetWaveform(daisysp::Oscillator::WAVE_POLYBLEP_SQUARE);
			osc_b_.SetPw(0.4f);
			osc_b_.SetFreq(f * 1.004f);
			mix_ = 0.45f;
			noise_mix_ = 0.0f;
			env_.SetAttackTime(0.004f);
			env_.SetDecayTime(0.12f);
			env_.SetSustainLevel(0.6f);
			env_.SetReleaseTime(release_ = 0.15f);
			lp_base_ = 2400.0f;
			lp_env_ = 1400.0f;
			filter_.SetRes(0.2f);
		}
		amp_ = clamp01(velocity) / float(n_saw_ + 1);
		const float dur = std::min(16.0f, std::max(0.02f, duration_seconds));
		gate_ = std::max(1, (int32_t)std::lround(dur * sr_));
		life_ = gate_ + (int32_t)std::lround((release_ + 0.05f) * sr_);
	}

	float Process() {
		const bool gate = gate_ > 0;
		if (gate) { --gate_; }
		if (life_ > 0) { --life_; }
		const float e = env_.Process(gate);
		float a = 0.0f;
		for (int i = 0; i < n_saw_; ++i) {
			a += osc_a_[i].Process();
		}
		a /= float(n_saw_);
		const float b = osc_b_.Process();
		float s = a * (1.0f - mix_) + b * mix_;
		if (noise_mix_ > 0.0f) {
			noise_state_ ^= noise_state_ << 13;
			noise_state_ ^= noise_state_ >> 17;
			noise_state_ ^= noise_state_ << 5;
			s += ((float(noise_state_) / 2147483648.0f) - 1.0f) * noise_mix_;
		}
		filter_.SetFreq(lp_base_ + lp_env_ * e);
		filter_.Process(s);
		return filter_.Low() * e * amp_ * 2.0f;
	}

	bool IsFinished() const { return life_ <= 0; }

private:
	float sr_ = 48000.0f;
	int n_saw_ = 1;
	float mix_ = 0.5f, noise_mix_ = 0.0f, amp_ = 0.0f;
	float lp_base_ = 1200.0f, lp_env_ = 900.0f, release_ = 0.2f;
	int32_t gate_ = 0, life_ = 0;
	uint32_t noise_state_ = 0x2468ace1u;
	daisysp::Oscillator osc_a_[kSupersaw];
	daisysp::Oscillator osc_b_;
	daisysp::Adsr env_;
	daisysp::Svf filter_;
};

/**
 * Fixed-size polyphonic pool. TVoice must provide Init(sr), Process(), IsFinished().
 * Allocation prefers a free voice, else steals the oldest. Fixed arrays — no heap at runtime.
 */
template <typename TVoice, int N>
class VoicePool {
public:
	void Init(float sample_rate) {
		for (int i = 0; i < N; ++i) {
			voices_[i].Init(sample_rate);
			active_[i] = false;
			age_[i] = 0;
		}
	}

	/** Reserve a voice (free first, else steal the oldest), mark it active, and return it to be triggered. */
	TVoice &Allocate() {
		int chosen = -1;
		for (int i = 0; i < N; ++i) {
			if (!active_[i]) { chosen = i; break; }
		}
		if (chosen < 0) {
			chosen = 0;
			for (int i = 1; i < N; ++i) {
				if (age_[i] > age_[chosen]) { chosen = i; }
			}
		}
		active_[chosen] = true;
		age_[chosen] = 0;
		return voices_[chosen];
	}

	/** Sum all sounding voices for one sample; retire any that have finished. */
	float Render() {
		float sum = 0.0f;
		for (int i = 0; i < N; ++i) {
			if (active_[i]) {
				sum += voices_[i].Process();
				++age_[i];
				if (voices_[i].IsFinished()) { active_[i] = false; }
			}
		}
		return sum;
	}

private:
	TVoice voices_[N];
	bool active_[N] = {};
	int32_t age_[N] = {};
};

/** The full Jammin voice rack: pool sizes and base mix gains from the Unreal renderer. */
struct VoiceRack {
	VoicePool<KickVoice, 4> kick;
	VoicePool<SnareVoice, 4> snare;
	VoicePool<HatVoice, 8> hat;
	VoicePool<PercVoice, 4> perc;
	VoicePool<BassVoice, 4> bass;
	VoicePool<PluckVoice, 16> pluck;
	VoicePool<PolyVoice, 10> poly; // shares the Notes mixer slot with pluck

	void Init(float sample_rate) {
		kick.Init(sample_rate);
		snare.Init(sample_rate);
		hat.Init(sample_rate);
		perc.Init(sample_rate);
		bass.Init(sample_rate);
		pluck.Init(sample_rate);
		poly.Init(sample_rate);
	}

	/** gains: 6 per-pool user gains (the room mixer) on top of the base mix.
	 *  Kick base raised from Unreal's 0.8: the 808 sub needs headroom against
	 *  the saw bass on small speakers. */
	float Render(const float *gains) {
		return gains[0] * 1.15f * kick.Render()
			 + gains[1] * 0.5f * snare.Render()
			 + gains[2] * 0.25f * hat.Render()
			 + gains[3] * 0.45f * perc.Render()
			 + gains[4] * 0.35f * bass.Render()
			 + gains[5] * 0.25f * (pluck.Render() + poly.Render());
	}
};

} // namespace jam
