/**
 * Resonate integration helpers: speaker-mode HPF + virtual bass, LR2 crossover,
 * two-band peak limiting. Header-only, used by processor.cpp.
 */
#pragma once

#include <cmath>
#include <cstring>

namespace dsp {
namespace resonate {

struct Biquad {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    double z1 = 0, z2 = 0;

    void reset() { z1 = z2 = 0; }

    float process(float x) {
        double y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return static_cast<float>(y);
    }

    static Biquad highpass(float fc, float sr, float q = 0.7071f) {
        Biquad f;
        if (fc < 20.f) fc = 20.f;
        if (fc > sr * 0.45f) fc = sr * 0.45f;
        const double w0 = 2.0 * 3.14159265358979323846 * (fc / sr);
        const double cosw = std::cos(w0);
        const double sinw = std::sin(w0);
        const double alpha = sinw / (2.0 * q);
        const double a0 = 1.0 + alpha;
        f.b0 = ((1.0 + cosw) * 0.5) / a0;
        f.b1 = (-(1.0 + cosw)) / a0;
        f.b2 = ((1.0 + cosw) * 0.5) / a0;
        f.a1 = (-2.0 * cosw) / a0;
        f.a2 = (1.0 - alpha) / a0;
        return f;
    }

    static Biquad lowpass(float fc, float sr, float q = 0.7071f) {
        Biquad f;
        if (fc < 20.f) fc = 20.f;
        if (fc > sr * 0.45f) fc = sr * 0.45f;
        const double w0 = 2.0 * 3.14159265358979323846 * (fc / sr);
        const double cosw = std::cos(w0);
        const double sinw = std::sin(w0);
        const double alpha = sinw / (2.0 * q);
        const double a0 = 1.0 + alpha;
        f.b0 = ((1.0 - cosw) * 0.5) / a0;
        f.b1 = (1.0 - cosw) / a0;
        f.b2 = ((1.0 - cosw) * 0.5) / a0;
        f.a1 = (-2.0 * cosw) / a0;
        f.a2 = (1.0 - alpha) / a0;
        return f;
    }

    static Biquad lowshelf(float fc, float sr, float gain_db) {
        Biquad f;
        if (fc < 20.f) fc = 20.f;
        const double A = std::pow(10.0, gain_db / 40.0);
        const double w0 = 2.0 * 3.14159265358979323846 * (fc / sr);
        const double cosw = std::cos(w0);
        const double sinw = std::sin(w0);
        const double alpha = sinw / 2.0 * std::sqrt((A + 1.0 / A) * (1.0 / 0.7071 - 1.0) + 2.0);
        const double twoSqrtAalpha = 2.0 * std::sqrt(A) * alpha;
        const double a0 = (A + 1.0) + (A - 1.0) * cosw + twoSqrtAalpha;
        f.b0 = (A * ((A + 1.0) - (A - 1.0) * cosw + twoSqrtAalpha)) / a0;
        f.b1 = (2.0 * A * ((A - 1.0) - (A + 1.0) * cosw)) / a0;
        f.b2 = (A * ((A + 1.0) - (A - 1.0) * cosw - twoSqrtAalpha)) / a0;
        f.a1 = (-2.0 * ((A - 1.0) + (A + 1.0) * cosw)) / a0;
        f.a2 = ((A + 1.0) + (A - 1.0) * cosw - twoSqrtAalpha) / a0;
        return f;
    }
};

/** Phone speaker path: cascade HP + optional harmonic virtual bass. */
struct SpeakerPath {
    Biquad hp[8];
    Biquad lp_bass[8];
    float amount = 0.55f;
    bool enabled = false;
    float sample_rate = 48000.f;

    void configure(float sr, bool on, float vb) {
        sample_rate = sr > 0.f ? sr : 48000.f;
        enabled = on;
        amount = vb < 0.f ? 0.f : (vb > 1.f ? 1.f : vb);
        for (int c = 0; c < 8; ++c) {
            hp[c] = Biquad::highpass(180.f, sample_rate, 0.7071f);
            lp_bass[c] = Biquad::lowpass(90.f, sample_rate, 0.7071f);
        }
    }

    void reset() {
        for (int c = 0; c < 8; ++c) {
            hp[c].reset();
            lp_bass[c].reset();
        }
    }

    template <typename Sample>
    void process_planar(Sample** chans, int frames, int channels) {
        if (!enabled || channels < 1) return;
        const int ch = channels > 8 ? 8 : channels;
        const float mix = amount;
        for (int i = 0; i < frames; ++i) {
            for (int c = 0; c < ch; ++c) {
                float x = static_cast<float>(chans[c][i]);
                float bass = lp_bass[c].process(x);
                float harm = bass * (1.5f - 0.5f * bass * bass);
                if (harm > 1.f) harm = 1.f;
                if (harm < -1.f) harm = -1.f;
                float y = hp[c].process(x);
                y += mix * 0.35f * harm;
                chans[c][i] = static_cast<Sample>(y);
            }
        }
    }
};

/** LR2-style split + independent peak limiters (high / low). */
struct TwoBandLimiter {
    Biquad lp[8];
    Biquad hp[8];
    float env_lo = 0.f;
    float env_hi = 0.f;
    float gain_lo = 1.f;
    float gain_hi = 1.f;
    float ceiling_lo = 0.977f;
    float ceiling_hi = 0.944f;
    float attack = 0.01f;
    float release = 0.05f;
    float crossover_hz = 120.f;
    float sample_rate = 48000.f;

    void configure(float sr, float xover_hz, float ceil_hi_db, float ceil_lo_db,
                   float atk_ms, float rel_ms) {
        sample_rate = sr > 0.f ? sr : 48000.f;
        crossover_hz = xover_hz;
        if (crossover_hz < 80.f) crossover_hz = 80.f;
        if (crossover_hz > 200.f) crossover_hz = 200.f;
        auto db_to_lin = [](float db) {
            return std::pow(10.f, db * 0.05f);
        };
        ceiling_hi = db_to_lin(ceil_hi_db);
        ceiling_lo = db_to_lin(ceil_lo_db);
        if (ceiling_hi < 1e-6f) ceiling_hi = 1e-6f;
        if (ceiling_lo < 1e-6f) ceiling_lo = 1e-6f;
        const float atk = atk_ms > 0.f ? atk_ms : 0.1f;
        const float rel = rel_ms > 0.f ? rel_ms : 50.f;
        attack  = 1.f - std::exp(-1.f / (0.001f * atk * sample_rate));
        release = 1.f - std::exp(-1.f / (0.001f * rel * sample_rate));
        for (int c = 0; c < 8; ++c) {
            lp[c] = Biquad::lowpass(crossover_hz, sample_rate, 0.7071f);
            hp[c] = Biquad::highpass(crossover_hz, sample_rate, 0.7071f);
        }
    }

    void reset() {
        env_lo = env_hi = 0.f;
        gain_lo = gain_hi = 1.f;
        for (int c = 0; c < 8; ++c) {
            lp[c].reset();
            hp[c].reset();
        }
    }

    template <typename Sample>
    float process_planar(Sample** chans, int frames, int channels) {
        const int ch = channels > 8 ? 8 : channels;
        float min_gain = 1.f;
        for (int i = 0; i < frames; ++i) {
            float peak_lo = 0.f, peak_hi = 0.f;
            float lo_s[8], hi_s[8];
            for (int c = 0; c < ch; ++c) {
                float x = static_cast<float>(chans[c][i]);
                lo_s[c] = lp[c].process(x);
                hi_s[c] = hp[c].process(x);
                float a = lo_s[c] >= 0.f ? lo_s[c] : -lo_s[c];
                if (a > peak_lo) peak_lo = a;
                a = hi_s[c] >= 0.f ? hi_s[c] : -hi_s[c];
                if (a > peak_hi) peak_hi = a;
            }
            if (peak_lo > env_lo) env_lo += attack * (peak_lo - env_lo);
            else                  env_lo += release * (peak_lo - env_lo);
            if (peak_hi > env_hi) env_hi += attack * (peak_hi - env_hi);
            else                  env_hi += release * (peak_hi - env_hi);

            float tgt_lo = 1.f;
            if (env_lo > ceiling_lo && env_lo > 1e-12f)
                tgt_lo = ceiling_lo / env_lo;
            float tgt_hi = 1.f;
            if (env_hi > ceiling_hi && env_hi > 1e-12f)
                tgt_hi = ceiling_hi / env_hi;

            if (tgt_lo < gain_lo) gain_lo += attack * (tgt_lo - gain_lo);
            else                  gain_lo += release * (tgt_lo - gain_lo);
            if (tgt_hi < gain_hi) gain_hi += attack * (tgt_hi - gain_hi);
            else                  gain_hi += release * (tgt_hi - gain_hi);

            if (gain_lo < min_gain) min_gain = gain_lo;
            if (gain_hi < min_gain) min_gain = gain_hi;

            for (int c = 0; c < ch; ++c) {
                float y = lo_s[c] * gain_lo + hi_s[c] * gain_hi;
                if (y > ceiling_hi) y = ceiling_hi;
                if (y < -ceiling_hi) y = -ceiling_hi;
                chans[c][i] = static_cast<Sample>(y);
            }
        }
        return min_gain;
    }
};

} // namespace resonate
} // namespace dsp
