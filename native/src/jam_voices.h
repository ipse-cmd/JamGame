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
#include "Drums/analogsnaredrum.h"
#include "Drums/hihat.h"
#include "Drums/synthbassdrum.h"
#include "Drums/synthsnaredrum.h"
#include "Filters/svf.h"
#include "PhysicalModeling/KarplusString.h"
#include "PhysicalModeling/modalvoice.h"
#include "PhysicalModeling/stringvoice.h"
#include "Synthesis/oscillator.h"

#include "jam_reverb.h"

namespace jam {

inline float midi_to_hz(int32_t midi) {
	return 440.0f * std::pow(2.0f, (float(midi) - 69.0f) / 12.0f);
}

inline float clamp01(float v) {
	return std::min(1.0f, std::max(0.0f, v));
}

inline int32_t wrapn(int32_t variant, int32_t n) {
	return ((variant % n) + n) % n;
}

/**
 * Parametric drum layer, clean-room after WeirdDrums by Daniele Filaretti
 * (MIT, github.com/dfilaretti/WeirdDrums — a JUCE plugin; topology reused,
 * code reimplemented over DaisySP) which itself channels Sonic Charge
 * Microtonic: one sine osc with an exponential PITCH envelope, a filtered
 * noise layer with its own decay, mixed through tanh drive. One topology,
 * any drum: zaps, lasers, trash snares.
 */
class WdLayer {
public:
	void Init(float sample_rate) {
		sr_ = std::max(1.0f, sample_rate);
		osc_.Init(sr_);
		osc_.SetWaveform(daisysp::Oscillator::WAVE_SIN);
		osc_.SetAmp(1.0f);
		filt_.Init(sr_);
		noise_state_ = 0x13572468u;
	}

	/** freq: base Hz; penv_oct: pitch env depth in octaves; penv/amp/noise decays in s. */
	void Trigger(float velocity, float freq, float penv_oct, float penv_decay,
			float amp_decay, float noise_mix, float noise_hz, float noise_res,
			float noise_decay, float drive) {
		base_f_ = freq;
		penv_oct_ = penv_oct;
		penv_k_ = 1.0f / (std::max(0.005f, penv_decay) * sr_);
		amp_k_ = 1.0f / (std::max(0.01f, amp_decay) * sr_);
		noise_k_ = 1.0f / (std::max(0.01f, noise_decay) * sr_);
		penv_ = amp_env_ = noise_env_ = 1.0f;
		noise_mix_ = noise_mix;
		drive_ = drive;
		amp_ = clamp01(velocity);
		filt_.SetFreq(noise_hz);
		filt_.SetRes(noise_res);
		life_ = (int32_t)std::lround(std::max(amp_decay, noise_decay) * 1.2f * sr_) + 64;
	}

	float Process() {
		if (life_ > 0) { --life_; }
		penv_ = std::max(0.0f, penv_ - penv_k_);
		amp_env_ = std::max(0.0f, amp_env_ - amp_k_);
		noise_env_ = std::max(0.0f, noise_env_ - noise_k_);
		osc_.SetFreq(base_f_ * std::pow(2.0f, penv_oct_ * penv_ * penv_));
		const float tone = osc_.Process() * amp_env_ * amp_env_;
		noise_state_ ^= noise_state_ << 13;
		noise_state_ ^= noise_state_ >> 17;
		noise_state_ ^= noise_state_ << 5;
		filt_.Process(((float(noise_state_) / 2147483648.0f) - 1.0f));
		const float noise = filt_.Band() * noise_env_ * noise_env_;
		const float mixed = tone * (1.0f - noise_mix_) + noise * noise_mix_;
		return std::tanh(mixed * drive_) * amp_;
	}

	bool IsFinished() const { return life_ <= 0; }

private:
	float sr_ = 48000.0f;
	float base_f_ = 60.0f, penv_oct_ = 2.0f;
	float penv_ = 0.0f, amp_env_ = 0.0f, noise_env_ = 0.0f;
	float penv_k_ = 0.001f, amp_k_ = 0.001f, noise_k_ = 0.001f;
	float noise_mix_ = 0.0f, drive_ = 1.0f, amp_ = 0.0f;
	int32_t life_ = 0;
	uint32_t noise_state_ = 0x13572468u;
	daisysp::Oscillator osc_;
	daisysp::Svf filt_;
};

/** Kick. Variants: 0 deep / 1 punch / 2 boom (808 analog model),
 *  3 click / 4 solid (synthetic model — naturally more audible on small
 *  speakers), 5 zap (WeirdDrums-style parametric). */
class KickVoice {
public:
	static constexpr int kVariants = 6;
	void Init(float sample_rate) {
		sr_ = std::max(1.0f, sample_rate);
		drum_.Init(sr_);
		synth_.Init(sr_);
		synth_.SetSustain(false);
		wd_.Init(sr_);
	}
	void Trigger(float velocity, int32_t variant = 0) {
		// Analog tones raised vs the Unreal presets: the 808 model's energy is
		// nearly all sub-65Hz, which vanishes on desktop speakers under the
		// saw bass; tone adds the beater click that lets the kick read.
		const float v = clamp01(velocity);
		float life = 0.6f;
		mode_ = 0;
		switch (wrapn(variant, kVariants)) {
			default:
			case 0: drum_.SetFreq(52.0f); drum_.SetTone(0.85f); drum_.SetDecay(0.4f);  life = 0.6f;  break; // deep
			case 1: drum_.SetFreq(65.0f); drum_.SetTone(0.95f); drum_.SetDecay(0.25f); life = 0.35f; break; // punch
			case 2: drum_.SetFreq(42.0f); drum_.SetTone(0.7f);  drum_.SetDecay(0.75f); life = 0.95f; break; // boom
			case 3: // click (synthetic, FM-flavored)
				mode_ = 1;
				synth_.SetFreq(60.0f); synth_.SetTone(0.8f); synth_.SetDecay(0.35f);
				synth_.SetDirtiness(0.3f); synth_.SetFmEnvelopeAmount(0.6f); synth_.SetFmEnvelopeDecay(0.3f);
				life = 0.45f;
				break;
			case 4: // solid
				mode_ = 1;
				synth_.SetFreq(50.0f); synth_.SetTone(0.55f); synth_.SetDecay(0.55f);
				synth_.SetDirtiness(0.1f); synth_.SetFmEnvelopeAmount(0.35f); synth_.SetFmEnvelopeDecay(0.4f);
				life = 0.6f;
				break;
			case 5: // zap (parametric: deep pitch sweep + drive)
				mode_ = 2;
				wd_.Trigger(v, 55.0f, 3.0f, 0.07f, 0.35f, 0.05f, 3000.0f, 0.2f, 0.05f, 2.5f);
				break;
		}
		if (mode_ == 0) {
			drum_.SetAttackFmAmount(0.8f);
			drum_.SetAccent(v);
			drum_.Trig();
		} else if (mode_ == 1) {
			synth_.SetAccent(v);
			synth_.Trig();
		}
		if (mode_ != 2) {
			life_ = (int32_t)std::lround(life * sr_);
		}
	}
	float Process() {
		if (mode_ == 2) {
			return wd_.Process();
		}
		if (life_ > 0) { --life_; }
		return mode_ == 1 ? synth_.Process(false) : drum_.Process(false);
	}
	bool IsFinished() const { return mode_ == 2 ? wd_.IsFinished() : life_ <= 0; }

private:
	float sr_ = 48000.0f;
	int32_t life_ = 0;
	int mode_ = 0; // 0 analog, 1 synthetic, 2 parametric
	daisysp::AnalogBassDrum drum_;
	daisysp::SyntheticBassDrum synth_;
	WdLayer wd_;
};

/** Snare. Variants: 0 snap / 1 tight / 2 fat (synthetic model),
 *  3 808 / 4 rim (analog model), 5 trash (parametric noise). */
class SnareVoice {
public:
	static constexpr int kVariants = 6;
	void Init(float sample_rate) {
		sr_ = std::max(1.0f, sample_rate);
		drum_.Init(sr_);
		analog_.Init(sr_);
		analog_.SetSustain(false);
		wd_.Init(sr_);
	}
	void Trigger(float velocity, int32_t variant = 0) {
		const float v = clamp01(velocity);
		float life = 0.5f;
		mode_ = 0;
		switch (wrapn(variant, kVariants)) {
			default:
			case 0: drum_.SetFreq(200.0f); drum_.SetDecay(0.3f);  drum_.SetSnappy(0.6f);  life = 0.5f; break; // snap
			case 1: drum_.SetFreq(245.0f); drum_.SetDecay(0.15f); drum_.SetSnappy(0.9f);  life = 0.3f; break; // tight
			case 2: drum_.SetFreq(165.0f); drum_.SetDecay(0.5f);  drum_.SetSnappy(0.35f); life = 0.7f; break; // fat
			case 3: // 808 (analog model: tonier)
				mode_ = 1;
				analog_.SetFreq(185.0f); analog_.SetTone(0.5f); analog_.SetDecay(0.3f); analog_.SetSnappy(0.7f);
				life = 0.45f;
				break;
			case 4: // rim
				mode_ = 1;
				analog_.SetFreq(330.0f); analog_.SetTone(0.8f); analog_.SetDecay(0.1f); analog_.SetSnappy(0.2f);
				life = 0.2f;
				break;
			case 5: // trash (parametric: driven bandpass noise)
				mode_ = 2;
				wd_.Trigger(v, 180.0f, 1.0f, 0.05f, 0.12f, 0.75f, 1800.0f, 0.4f, 0.25f, 3.0f);
				break;
		}
		if (mode_ == 0) {
			drum_.SetAccent(v);
			drum_.Trig();
		} else if (mode_ == 1) {
			analog_.SetAccent(v);
			analog_.Trig();
		}
		if (mode_ != 2) {
			life_ = (int32_t)std::lround(life * sr_);
		}
	}
	float Process() {
		if (mode_ == 2) {
			return wd_.Process();
		}
		if (life_ > 0) { --life_; }
		return mode_ == 1 ? analog_.Process(false) : drum_.Process(false);
	}
	bool IsFinished() const { return mode_ == 2 ? wd_.IsFinished() : life_ <= 0; }

private:
	float sr_ = 48000.0f;
	int32_t life_ = 0;
	int mode_ = 0;
	daisysp::SyntheticSnareDrum drum_;
	daisysp::AnalogSnareDrum analog_;
	WdLayer wd_;
};

/** Hat. Variants: 0 closed / 1 open / 2 crisp (metallic model),
 *  3 shaker (parametric high-passed noise swell). */
class HatVoice {
public:
	static constexpr int kVariants = 4;
	void Init(float sample_rate) {
		sr_ = std::max(1.0f, sample_rate);
		drum_.Init(sr_);
		wd_.Init(sr_);
	}
	void Trigger(float velocity, int32_t variant = 0) {
		const float v = clamp01(velocity);
		float life = 0.35f;
		mode_ = 0;
		switch (wrapn(variant, kVariants)) {
			default:
			case 0: drum_.SetFreq(8000.0f);  drum_.SetTone(0.7f);  drum_.SetDecay(0.3f);  life = 0.35f; break; // closed
			case 1: drum_.SetFreq(7000.0f);  drum_.SetTone(0.55f); drum_.SetDecay(0.85f); life = 0.9f;  break; // open
			case 2: drum_.SetFreq(10500.0f); drum_.SetTone(0.9f);  drum_.SetDecay(0.15f); life = 0.2f;  break; // crisp
			case 3: // shaker: pure noise layer, no tone
				mode_ = 1;
				wd_.Trigger(v, 200.0f, 0.0f, 0.05f, 0.02f, 1.0f, 6500.0f, 0.3f, 0.14f, 1.3f);
				break;
		}
		if (mode_ == 0) {
			drum_.SetAccent(v);
			drum_.Trig();
			life_ = (int32_t)std::lround(life * sr_);
		}
	}
	float Process() {
		if (mode_ == 1) {
			return wd_.Process();
		}
		if (life_ > 0) { --life_; }
		return drum_.Process(false);
	}
	bool IsFinished() const { return mode_ == 1 ? wd_.IsFinished() : life_ <= 0; }

private:
	float sr_ = 48000.0f;
	int32_t life_ = 0;
	int mode_ = 0;
	daisysp::HiHat<> drum_;
	WdLayer wd_;
};

/** Perc. Variants: 0 tom / 1 conga / 2 low tom (tuned analog drum),
 *  3 block / 4 bell (MODAL synthesis — real struck bodies, the Rings/Elements
 *  lineage; far truer percussion than a pitched bass drum),
 *  5 laser (parametric pitch-sweep). */
class PercVoice {
public:
	static constexpr int kVariants = 6;
	void Init(float sample_rate) {
		sr_ = std::max(1.0f, sample_rate);
		drum_.Init(sr_);
		modal_.Init(sr_);
		modal_.SetSustain(false);
		wd_.Init(sr_);
	}
	void Trigger(float velocity, int32_t variant = 0) {
		const float v = clamp01(velocity);
		float life = 0.3f;
		mode_ = 0;
		switch (wrapn(variant, kVariants)) {
			default:
			case 0: drum_.SetFreq(180.0f); drum_.SetTone(0.8f);  drum_.SetDecay(0.18f); life = 0.3f;  break; // tom
			case 1: drum_.SetFreq(260.0f); drum_.SetTone(0.9f);  drum_.SetDecay(0.12f); life = 0.2f;  break; // conga
			case 2: drum_.SetFreq(115.0f); drum_.SetTone(0.65f); drum_.SetDecay(0.3f);  life = 0.45f; break; // low tom
			case 3: // block (woody modal strike)
				mode_ = 1;
				modal_.SetFreq(420.0f); modal_.SetStructure(0.35f);
				modal_.SetBrightness(0.6f + 0.2f * v); modal_.SetDamping(0.75f);
				life = 0.4f;
				break;
			case 4: // bell (ringing modal)
				mode_ = 1;
				modal_.SetFreq(660.0f); modal_.SetStructure(0.9f);
				modal_.SetBrightness(0.7f); modal_.SetDamping(0.25f);
				life = 1.4f;
				break;
			case 5: // laser (parametric downward sweep)
				mode_ = 2;
				wd_.Trigger(v, 1400.0f, 2.2f, 0.14f, 0.22f, 0.1f, 4000.0f, 0.3f, 0.05f, 1.8f);
				break;
		}
		if (mode_ == 0) {
			drum_.SetAccent(v);
			drum_.Trig();
		} else if (mode_ == 1) {
			modal_.SetAccent(v);
			modal_.Trig();
		}
		if (mode_ != 2) {
			life_ = (int32_t)std::lround(life * sr_);
		}
	}
	float Process() {
		if (mode_ == 2) {
			return wd_.Process();
		}
		if (life_ > 0) { --life_; }
		return mode_ == 1 ? modal_.Process(false) : drum_.Process(false);
	}
	bool IsFinished() const { return mode_ == 2 ? wd_.IsFinished() : life_ <= 0; }

private:
	float sr_ = 48000.0f;
	int32_t life_ = 0;
	int mode_ = 0;
	daisysp::AnalogBassDrum drum_;
	daisysp::ModalVoice modal_;
	WdLayer wd_;
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

/** Extended Karplus-Strong (Mutable StringVoice): exciter + string with
 *  structure/brightness/damping — a far richer pluck than the raw string. */
class StringPluckVoice {
public:
	void Init(float sample_rate) {
		sr_ = std::max(1.0f, sample_rate);
		str_.Init(sr_);
		str_.SetSustain(false);
	}
	void Pluck(int32_t midi, float velocity) {
		const float v = clamp01(velocity);
		str_.SetFreq(midi_to_hz(midi));
		str_.SetAccent(v);
		str_.SetStructure(0.5f);
		str_.SetBrightness(0.35f + 0.35f * v);
		str_.SetDamping(0.55f);
		str_.Trig();
		life_ = (int32_t)std::lround(2.0f * sr_);
	}
	float Process() {
		if (life_ > 0) { --life_; }
		return str_.Process(false);
	}
	bool IsFinished() const { return life_ <= 0; }

private:
	float sr_ = 48000.0f;
	int32_t life_ = 0;
	daisysp::StringVoice str_;
};

/** Modal mallet (Mutable ModalVoice): struck resonant body — vibes/marimba
 *  territory for the chords/notes role. */
class MalletVoice {
public:
	void Init(float sample_rate) {
		sr_ = std::max(1.0f, sample_rate);
		modal_.Init(sr_);
		modal_.SetSustain(false);
	}
	void Strike(int32_t midi, float velocity) {
		const float v = clamp01(velocity);
		modal_.SetFreq(midi_to_hz(midi));
		modal_.SetAccent(v);
		modal_.SetStructure(0.6f);
		modal_.SetBrightness(0.35f + 0.3f * v);
		modal_.SetDamping(0.4f);
		modal_.Trig();
		life_ = (int32_t)std::lround(2.2f * sr_);
	}
	float Process() {
		if (life_ > 0) { --life_; }
		return modal_.Process(false);
	}
	bool IsFinished() const { return life_ <= 0; }

private:
	float sr_ = 48000.0f;
	int32_t life_ = 0;
	daisysp::ModalVoice modal_;
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

/** The full Jammin voice rack + master section (reverb send, soft limit). */
struct VoiceRack {
	VoicePool<KickVoice, 4> kick;
	VoicePool<SnareVoice, 4> snare;
	VoicePool<HatVoice, 8> hat;
	VoicePool<PercVoice, 4> perc;
	VoicePool<BassVoice, 4> bass;
	VoicePool<PluckVoice, 16> pluck;
	VoicePool<PolyVoice, 10> poly; // pluck/poly/string/mallet share the Notes slot
	VoicePool<StringPluckVoice, 12> string;
	VoicePool<MalletVoice, 12> mallet;

	Reverb verb;

	// Per-pool reverb sends (pre user-gain): drums dry-ish, notes wet.
	static constexpr float kSend[6] = {0.03f, 0.12f, 0.08f, 0.18f, 0.05f, 0.28f};
	static constexpr float kWet = 0.9f;

	void Init(float sample_rate) {
		kick.Init(sample_rate);
		snare.Init(sample_rate);
		hat.Init(sample_rate);
		perc.Init(sample_rate);
		bass.Init(sample_rate);
		pluck.Init(sample_rate);
		poly.Init(sample_rate);
		string.Init(sample_rate);
		mallet.Init(sample_rate);
		verb.Init(sample_rate);
	}

	/** gains: 6 per-pool user gains (the room mixer) on top of the base mix.
	 *  Kick base raised from Unreal's 0.8: the 808 sub needs headroom against
	 *  the saw bass on small speakers. Output is STEREO (the reverb tail is
	 *  the game's first stereo element) with a soft tanh limit on the master. */
	void Render(const float *gains, float *out_l, float *out_r) {
		float pools[6];
		pools[0] = 1.15f * kick.Render();
		pools[1] = 0.5f * snare.Render();
		pools[2] = 0.25f * hat.Render();
		pools[3] = 0.45f * perc.Render();
		pools[4] = 0.35f * bass.Render();
		pools[5] = 0.25f * (pluck.Render() + poly.Render() + string.Render() + mallet.Render());
		float dry = 0.0f;
		float send = 0.0f;
		for (int p = 0; p < 6; p++) {
			dry += gains[p] * pools[p];
			send += kSend[p] * gains[p] * pools[p];
		}
		float wl = 0.0f, wr = 0.0f;
		verb.Process(send, &wl, &wr);
		// Master soft limit: raw float sums can exceed 1.0 at full mixer gains.
		*out_l = std::tanh(dry + kWet * wl);
		*out_r = std::tanh(dry + kWet * wr);
	}
};

} // namespace jam
