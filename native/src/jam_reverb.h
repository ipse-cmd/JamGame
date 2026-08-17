#pragma once

// Freeverb-style stereo reverb (Schroeder/Moorer: 8 parallel combs + 4 series
// allpasses per channel, classic public-domain tunings by Jezar at Dreampoint).
// Implemented fresh here — the DaisySP reverb moved to an LGPL companion repo,
// which a statically-linked cross-platform GDExtension is better off without.
// Audio-thread safe: fixed member buffers (sized for up to 96kHz), no
// allocation after Init.

#include <cstdint>
#include <cstring>

namespace jam {

class Reverb {
public:
	void Init(float sample_rate) {
		scale_ = sample_rate / 44100.0f;
		if (scale_ < 0.5f) scale_ = 0.5f;
		if (scale_ > 2.2f) scale_ = 2.2f;
		for (int c = 0; c < kCombs; c++) {
			comb_len_[0][c] = tune(kCombTuning[c]);
			comb_len_[1][c] = tune(kCombTuning[c] + kStereoSpread);
		}
		for (int a = 0; a < kAllpasses; a++) {
			ap_len_[0][a] = tune(kAllpassTuning[a]);
			ap_len_[1][a] = tune(kAllpassTuning[a] + kStereoSpread);
		}
		std::memset(comb_buf_, 0, sizeof(comb_buf_));
		std::memset(ap_buf_, 0, sizeof(ap_buf_));
		std::memset(comb_idx_, 0, sizeof(comb_idx_));
		std::memset(ap_idx_, 0, sizeof(ap_idx_));
		std::memset(comb_lp_, 0, sizeof(comb_lp_));
		SetRoom(0.84f);
		SetDamp(0.35f);
	}

	void SetRoom(float room) { feedback_ = 0.7f + 0.28f * clamp01(room); }
	void SetDamp(float damp) { damp_ = 0.4f * clamp01(damp); }

	/** Mono in -> stereo wet out (add to your dry signal, scaled by your wet gain). */
	void Process(float in, float *out_l, float *out_r) {
		const float input = in * kFixedGain;
		float out[2] = {0.0f, 0.0f};
		for (int ch = 0; ch < 2; ch++) {
			for (int c = 0; c < kCombs; c++) {
				const int32_t len = comb_len_[ch][c];
				int32_t &idx = comb_idx_[ch][c];
				float *buf = comb_buf_[ch][c];
				const float y = buf[idx];
				comb_lp_[ch][c] = y * (1.0f - damp_) + comb_lp_[ch][c] * damp_;
				buf[idx] = input + comb_lp_[ch][c] * feedback_;
				if (++idx >= len) idx = 0;
				out[ch] += y;
			}
			for (int a = 0; a < kAllpasses; a++) {
				const int32_t len = ap_len_[ch][a];
				int32_t &idx = ap_idx_[ch][a];
				float *buf = ap_buf_[ch][a];
				const float bufout = buf[idx];
				buf[idx] = out[ch] + bufout * 0.5f;
				out[ch] = bufout - out[ch];
				if (++idx >= len) idx = 0;
			}
		}
		*out_l = out[0];
		*out_r = out[1];
	}

private:
	static constexpr int kCombs = 8;
	static constexpr int kAllpasses = 4;
	static constexpr int kStereoSpread = 23;
	static constexpr float kFixedGain = 0.015f;
	// Classic freeverb tunings (samples at 44.1kHz).
	static constexpr int kCombTuning[kCombs] = {1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617};
	static constexpr int kAllpassTuning[kAllpasses] = {556, 441, 341, 225};
	static constexpr int kMaxComb = (1617 + kStereoSpread) * 22 / 10 + 4; // up to 96kHz
	static constexpr int kMaxAp = (556 + kStereoSpread) * 22 / 10 + 4;

	static float clamp01(float v) { return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v); }
	int32_t tune(int samples44) {
		int32_t n = (int32_t)(samples44 * scale_);
		return n < 4 ? 4 : n;
	}

	float scale_ = 1.0f;
	float feedback_ = 0.84f;
	float damp_ = 0.2f;
	float comb_buf_[2][kCombs][kMaxComb];
	float ap_buf_[2][kAllpasses][kMaxAp];
	int32_t comb_len_[2][kCombs] = {};
	int32_t ap_len_[2][kAllpasses] = {};
	int32_t comb_idx_[2][kCombs] = {};
	int32_t ap_idx_[2][kAllpasses] = {};
	float comb_lp_[2][kCombs] = {};
};

} // namespace jam
