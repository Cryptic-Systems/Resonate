/**
 * Shared DSP math helpers (dB conversion, soft-clip, clamp).
 */
#pragma once

#include <algorithm>
#include <cmath>

namespace dsp {

inline double db_to_linear(double db) {
    if (db <= -120.0) return 0.0;
    return std::pow(10.0, db / 20.0);
}

inline float db_to_linear_f(float db) {
    return static_cast<float>(db_to_linear(static_cast<double>(db)));
}

inline double linear_to_db(double lin) {
    if (lin <= 1e-10) return -200.0;
    return 20.0 * std::log10(lin);
}

inline float linear_to_db_f(float lin) {
    return static_cast<float>(linear_to_db(static_cast<double>(lin)));
}

/** Pade approximate tanh for soft-clipping. */
inline float fast_tanh(float x) {
    const float x2 = x * x;
    return x * (27.0f + x2) / (27.0f + 9.0f * x2);
}

template <typename T>
inline T clamp(T v, T lo, T hi) {
    return std::max(lo, std::min(v, hi));
}

} // namespace dsp
