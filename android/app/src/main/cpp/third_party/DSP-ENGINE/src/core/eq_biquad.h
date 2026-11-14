/**
 * Multi-band parametric EQ — RBJ biquads (peak/shelf/LP/HP), double-precision.
 * Real-time safe: coefficients updated from control thread; process reads
 * a staging bank without locks.
 */
#ifndef DSP_EQ_BIQUAD_H
#define DSP_EQ_BIQUAD_H

#include <cmath>
#include <cstring>
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#include <atomic>
#include <algorithm>

namespace dsp {

constexpr int kEqMaxBands = 31;
constexpr int kEqMaxChannels = 8;

/** Matches DspEqBand.type in the public C header. */
enum EqFilterType {
    EQ_PEAK = 0,
    EQ_LOW_SHELF = 1,
    EQ_HIGH_SHELF = 2,
    EQ_LOW_PASS = 3,
    EQ_HIGH_PASS = 4
};

struct BiquadCoeffs {
    double b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0;
};

struct BiquadState {
    double z1 = 0.0, z2 = 0.0;
};

inline BiquadCoeffs peaking_rbj(double sr, double freq, double gain_db, double q) {
    BiquadCoeffs c;
    if (sr <= 0.0 || freq <= 0.0) return c;
    const double f = std::min(freq, sr * 0.45);
    const double A = std::pow(10.0, gain_db / 40.0);
    const double w0 = 2.0 * M_PI * f / sr;
    const double cosw = std::cos(w0);
    const double sinw = std::sin(w0);
    const double alpha = sinw / (2.0 * std::max(0.3, std::min(q, 8.0)));

    const double b0 = 1.0 + alpha * A;
    const double b1 = -2.0 * cosw;
    const double b2 = 1.0 - alpha * A;
    const double a0 = 1.0 + alpha / A;
    const double a1 = -2.0 * cosw;
    const double a2 = 1.0 - alpha / A;

    c.b0 = b0 / a0; c.b1 = b1 / a0; c.b2 = b2 / a0;
    c.a1 = a1 / a0; c.a2 = a2 / a0;
    return c;
}

inline BiquadCoeffs low_shelf_rbj(double sr, double freq, double gain_db, double q) {
    BiquadCoeffs c;
    if (sr <= 0.0 || freq <= 0.0) return c;
    const double f = std::min(freq, sr * 0.45);
    const double A = std::pow(10.0, gain_db / 40.0);
    const double w0 = 2.0 * M_PI * f / sr;
    const double cosw = std::cos(w0);
    const double sinw = std::sin(w0);
    const double S = std::max(0.1, std::min(q, 2.0));
    const double alpha = sinw / 2.0 * std::sqrt((A + 1.0 / A) * (1.0 / S - 1.0) + 2.0);
    const double twoSqrtAalpha = 2.0 * std::sqrt(A) * alpha;

    const double b0 =    A * ((A + 1.0) - (A - 1.0) * cosw + twoSqrtAalpha);
    const double b1 =  2.0 * A * ((A - 1.0) - (A + 1.0) * cosw);
    const double b2 =    A * ((A + 1.0) - (A - 1.0) * cosw - twoSqrtAalpha);
    const double a0 =        (A + 1.0) + (A - 1.0) * cosw + twoSqrtAalpha;
    const double a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cosw);
    const double a2 =        (A + 1.0) + (A - 1.0) * cosw - twoSqrtAalpha;

    c.b0 = b0 / a0; c.b1 = b1 / a0; c.b2 = b2 / a0;
    c.a1 = a1 / a0; c.a2 = a2 / a0;
    return c;
}

inline BiquadCoeffs high_shelf_rbj(double sr, double freq, double gain_db, double q) {
    BiquadCoeffs c;
    if (sr <= 0.0 || freq <= 0.0) return c;
    const double f = std::min(freq, sr * 0.45);
    const double A = std::pow(10.0, gain_db / 40.0);
    const double w0 = 2.0 * M_PI * f / sr;
    const double cosw = std::cos(w0);
    const double sinw = std::sin(w0);
    const double S = std::max(0.1, std::min(q, 2.0));
    const double alpha = sinw / 2.0 * std::sqrt((A + 1.0 / A) * (1.0 / S - 1.0) + 2.0);
    const double twoSqrtAalpha = 2.0 * std::sqrt(A) * alpha;

    const double b0 =    A * ((A + 1.0) + (A - 1.0) * cosw + twoSqrtAalpha);
    const double b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosw);
    const double b2 =    A * ((A + 1.0) + (A - 1.0) * cosw - twoSqrtAalpha);
    const double a0 =        (A + 1.0) - (A - 1.0) * cosw + twoSqrtAalpha;
    const double a1 =  2.0 * ((A - 1.0) - (A + 1.0) * cosw);
    const double a2 =        (A + 1.0) - (A - 1.0) * cosw - twoSqrtAalpha;

    c.b0 = b0 / a0; c.b1 = b1 / a0; c.b2 = b2 / a0;
    c.a1 = a1 / a0; c.a2 = a2 / a0;
    return c;
}

inline BiquadCoeffs low_pass_rbj(double sr, double freq, double q) {
    BiquadCoeffs c;
    if (sr <= 0.0 || freq <= 0.0) return c;
    const double f = std::min(freq, sr * 0.45);
    const double w0 = 2.0 * M_PI * f / sr;
    const double cosw = std::cos(w0);
    const double sinw = std::sin(w0);
    const double alpha = sinw / (2.0 * std::max(0.3, std::min(q, 8.0)));

    const double b0 = (1.0 - cosw) * 0.5;
    const double b1 = 1.0 - cosw;
    const double b2 = (1.0 - cosw) * 0.5;
    const double a0 = 1.0 + alpha;
    const double a1 = -2.0 * cosw;
    const double a2 = 1.0 - alpha;

    c.b0 = b0 / a0; c.b1 = b1 / a0; c.b2 = b2 / a0;
    c.a1 = a1 / a0; c.a2 = a2 / a0;
    return c;
}

inline BiquadCoeffs high_pass_rbj(double sr, double freq, double q) {
    BiquadCoeffs c;
    if (sr <= 0.0 || freq <= 0.0) return c;
    const double f = std::min(freq, sr * 0.45);
    const double w0 = 2.0 * M_PI * f / sr;
    const double cosw = std::cos(w0);
    const double sinw = std::sin(w0);
    const double alpha = sinw / (2.0 * std::max(0.3, std::min(q, 8.0)));

    const double b0 = (1.0 + cosw) * 0.5;
    const double b1 = -(1.0 + cosw);
    const double b2 = (1.0 + cosw) * 0.5;
    const double a0 = 1.0 + alpha;
    const double a1 = -2.0 * cosw;
    const double a2 = 1.0 - alpha;

    c.b0 = b0 / a0; c.b1 = b1 / a0; c.b2 = b2 / a0;
    c.a1 = a1 / a0; c.a2 = a2 / a0;
    return c;
}

inline BiquadCoeffs make_eq_coeffs(int type, double sr, double freq, double gain_db, double q) {
    switch (type) {
    case EQ_LOW_SHELF:  return low_shelf_rbj(sr, freq, gain_db, q);
    case EQ_HIGH_SHELF: return high_shelf_rbj(sr, freq, gain_db, q);
    case EQ_LOW_PASS:   return low_pass_rbj(sr, freq, q);
    case EQ_HIGH_PASS:  return high_pass_rbj(sr, freq, q);
    case EQ_PEAK:
    default:            return peaking_rbj(sr, freq, gain_db, q);
    }
}

inline double process_biquad(const BiquadCoeffs& c, BiquadState& s, double x) {
    const double y = c.b0 * x + s.z1;
    s.z1 = c.b1 * x - c.a1 * y + s.z2;
    s.z2 = c.b2 * x - c.a2 * y;
    return y;
}

struct EqBandParam {
    double freq_hz = 1000.0;
    double gain_db = 0.0;
    double q = 1.4;
    int    type = EQ_PEAK;
    bool   active = false;
};

struct EqBank {
    int band_count = 0;
    EqBandParam params[kEqMaxBands];
    BiquadCoeffs coeffs[kEqMaxBands];
};

class MultiBandEq {
public:
    void init(double sample_rate, int channels) {
        sr_ = sample_rate > 0 ? sample_rate : 48000.0;
        channels_ = std::max(1, std::min(channels, kEqMaxChannels));
        static const double kDefaultHz[kEqMaxBands] = {
            20, 25, 32, 40, 50, 63, 80, 100, 125, 160,
            200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600,
            2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000
        };
        bank_[0].band_count = 0;
        bank_[1].band_count = 0;
        for (int i = 0; i < kEqMaxBands; ++i) {
            for (int b = 0; b < 2; ++b) {
                bank_[b].params[i].freq_hz = kDefaultHz[i];
                bank_[b].params[i].gain_db = 0.0;
                bank_[b].params[i].q = q_for_freq(kDefaultHz[i]);
                bank_[b].params[i].type = EQ_PEAK;
                bank_[b].params[i].active = false;
                bank_[b].coeffs[i] = BiquadCoeffs{};
            }
        }
        active_bank_.store(0, std::memory_order_relaxed);
        enabled_.store(false, std::memory_order_relaxed);
        reset_state();
    }

    static double q_for_freq(double hz) {
        if (hz < 100.0) return 0.9;
        if (hz < 500.0) return 1.2;
        if (hz < 4000.0) return 1.6;
        return 1.3;
    }

    void set_enabled(bool on) { enabled_.store(on, std::memory_order_release); }
    bool is_enabled() const { return enabled_.load(std::memory_order_acquire); }
    int band_count() const {
        return bank_[active_bank_.load(std::memory_order_acquire)].band_count;
    }
    void reset_state() { std::memset(state_, 0, sizeof(state_)); }

    /** type: 0=peak, 1=low_shelf, 2=high_shelf, 3=low_pass, 4=high_pass */
    void set_band(int index, double freq_hz, double gain_db, double q, int type = EQ_PEAK) {
        if (index < 0 || index >= kEqMaxBands) return;
        const int cur = active_bank_.load(std::memory_order_acquire);
        const int staging = 1 - cur;
        bank_[staging] = bank_[cur];
        auto& p = bank_[staging].params[index];
        p.freq_hz = std::max(20.0, std::min(freq_hz, sr_ * 0.45));
        p.gain_db = std::max(-24.0, std::min(gain_db, 24.0));
        p.q = (q > 0.0) ? q : q_for_freq(p.freq_hz);
        p.type = (type >= EQ_PEAK && type <= EQ_HIGH_PASS) ? type : EQ_PEAK;
        if (p.type == EQ_LOW_PASS || p.type == EQ_HIGH_PASS)
            p.active = true;
        else
            p.active = std::fabs(p.gain_db) >= 0.05;
        bank_[staging].coeffs[index] = p.active
            ? make_eq_coeffs(p.type, sr_, p.freq_hz, p.gain_db, p.q) : BiquadCoeffs{};
        if (index >= bank_[staging].band_count)
            bank_[staging].band_count = index + 1;
        active_bank_.store(staging, std::memory_order_release);
    }

    void set_band_count(int count) {
        count = std::max(0, std::min(count, kEqMaxBands));
        const int cur = active_bank_.load(std::memory_order_acquire);
        const int staging = 1 - cur;
        bank_[staging] = bank_[cur];
        bank_[staging].band_count = count;
        for (int i = count; i < kEqMaxBands; ++i) {
            bank_[staging].params[i].active = false;
            bank_[staging].params[i].gain_db = 0.0;
            bank_[staging].coeffs[i] = BiquadCoeffs{};
        }
        active_bank_.store(staging, std::memory_order_release);
    }

    void set_bands(const double* centers_hz, const double* gains_db, int count) {
        if (!gains_db || count <= 0) return;
        count = std::min(count, kEqMaxBands);
        const int cur = active_bank_.load(std::memory_order_acquire);
        const int staging = 1 - cur;
        bank_[staging] = bank_[cur];
        bank_[staging].band_count = count;
        for (int i = 0; i < count; ++i) {
            auto& p = bank_[staging].params[i];
            if (centers_hz) p.freq_hz = std::max(20.0, std::min(centers_hz[i], sr_ * 0.45));
            p.gain_db = std::max(-24.0, std::min(gains_db[i], 24.0));
            p.q = q_for_freq(p.freq_hz);
            p.type = EQ_PEAK;
            p.active = std::fabs(p.gain_db) >= 0.05;
            bank_[staging].coeffs[i] = p.active
                ? peaking_rbj(sr_, p.freq_hz, p.gain_db, p.q) : BiquadCoeffs{};
        }
        for (int i = count; i < kEqMaxBands; ++i) {
            bank_[staging].params[i].active = false;
            bank_[staging].params[i].gain_db = 0.0;
            bank_[staging].coeffs[i] = BiquadCoeffs{};
        }
        active_bank_.store(staging, std::memory_order_release);
    }

    void reset_flat() {
        const int cur = active_bank_.load(std::memory_order_acquire);
        const int staging = 1 - cur;
        bank_[staging] = bank_[cur];
        for (int i = 0; i < kEqMaxBands; ++i) {
            bank_[staging].params[i].gain_db = 0.0;
            bank_[staging].params[i].active = false;
            bank_[staging].coeffs[i] = BiquadCoeffs{};
        }
        bank_[staging].band_count = 0;
        active_bank_.store(staging, std::memory_order_release);
        reset_state();
    }

    void process(double** channels, int frames) {
        if (!enabled_.load(std::memory_order_acquire) || frames <= 0) return;
        const int bank = active_bank_.load(std::memory_order_acquire);
        const EqBank& eq = bank_[bank];
        for (int ch = 0; ch < channels_; ++ch) {
            double* x = channels[ch];
            if (!x) continue;
            for (int b = 0; b < eq.band_count; ++b) {
                if (!eq.params[b].active) continue;
                const BiquadCoeffs& c = eq.coeffs[b];
                BiquadState& st = state_[ch][b];
                for (int i = 0; i < frames; ++i)
                    x[i] = process_biquad(c, st, x[i]);
            }
        }
    }

    void get_band(int index, double* freq, double* gain, double* q) const {
        const int bank = active_bank_.load(std::memory_order_acquire);
        if (index < 0 || index >= bank_[bank].band_count) {
            if (freq) *freq = 0; if (gain) *gain = 0; if (q) *q = 0;
            return;
        }
        const auto& p = bank_[bank].params[index];
        if (freq) *freq = p.freq_hz;
        if (gain) *gain = p.gain_db;
        if (q) *q = p.q;
    }

private:
    double sr_ = 48000.0;
    int channels_ = 2;
    EqBank bank_[2];
    std::atomic<int> active_bank_{0};
    std::atomic<bool> enabled_{false};
    BiquadState state_[kEqMaxChannels][kEqMaxBands]{};
};

} // namespace dsp

#endif
