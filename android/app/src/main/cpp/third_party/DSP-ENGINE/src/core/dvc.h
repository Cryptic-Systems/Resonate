/**
 * Direct Volume Control — linear gain with optional one-pole smoothing.
 */
#pragma once

#include "utils/math_utils.h"
#include <cmath>

namespace dsp {

class Dvc {
public:
    void set_enabled(bool on) { enabled_ = on; }
    bool enabled() const { return enabled_; }

    void set_gain_db(float db) {
        target_db_ = db;
        target_lin_ = db_to_linear_f(db);
        if (!smooth_)
            current_lin_ = target_lin_;
    }

    float gain_db() const { return target_db_; }
    float gain_linear() const { return current_lin_; }

    void set_smoothing(bool on, float time_ms, float sample_rate) {
        smooth_ = on && time_ms > 0.f;
        time_ms_ = time_ms > 0.f ? time_ms : 0.f;
        sample_rate_ = sample_rate > 0.f ? sample_rate : sample_rate_;
        update_coeff();
    }

    void set_sample_rate(float sample_rate) {
        if (sample_rate > 0.f) sample_rate_ = sample_rate;
        update_coeff();
    }

    bool smoothing() const { return smooth_; }
    float smoothing_ms() const { return time_ms_; }

    void update_coeff() {
        if (!smooth_ || time_ms_ <= 0.f || sample_rate_ <= 0.f) {
            coeff_ = 1.f;
            return;
        }
        coeff_ = 1.f - std::exp(-1.f / (0.001f * time_ms_ * sample_rate_));
        if (coeff_ < 0.f) coeff_ = 0.f;
        if (coeff_ > 1.f) coeff_ = 1.f;
    }

    void process(const float* in, float* out, int frames, int channels) {
        if (!enabled_ || (!smooth_ && target_lin_ == 1.f && current_lin_ == 1.f)) {
            if (in != out) {
                const int n = frames * channels;
                for (int i = 0; i < n; ++i) out[i] = in[i];
            }
            return;
        }
        for (int i = 0; i < frames; ++i) {
            if (smooth_)
                current_lin_ += coeff_ * (target_lin_ - current_lin_);
            else
                current_lin_ = target_lin_;
            const float g = current_lin_;
            for (int c = 0; c < channels; ++c) {
                const int idx = i * channels + c;
                out[idx] = in[idx] * g;
            }
        }
    }

    template <typename Sample>
    void process_planar(Sample** chans, int frames, int channels) {
        if (!enabled_) return;
        for (int i = 0; i < frames; ++i) {
            if (smooth_)
                current_lin_ += coeff_ * (target_lin_ - current_lin_);
            else
                current_lin_ = target_lin_;
            const Sample g = static_cast<Sample>(current_lin_);
            if (g == Sample(1)) continue;
            for (int c = 0; c < channels; ++c)
                chans[c][i] *= g;
        }
    }

    void reset() { current_lin_ = target_lin_; }

private:
    bool  enabled_     = true;
    bool  smooth_      = false;
    float time_ms_     = 0.f;
    float sample_rate_ = 48000.f;
    float target_db_   = 0.f;
    float target_lin_  = 1.f;
    float current_lin_ = 1.f;
    float coeff_       = 1.f;
};

} // namespace dsp
