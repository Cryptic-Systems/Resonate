/**
 * Sample-rate conversion: linear, cubic (Catmull-Rom), HQ windowed-sinc.
 * ratio ≈ source_rate / dest_rate  (< 1 upsamples, > 1 downsamples)
 */
#pragma once

#include "dsp_engine.h"
#include <cmath>
#include <cstring>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

namespace dsp {

constexpr int kResamplerSincHalf = 16;

inline float sinc_weight(float x) {
    if (x == 0.f) return 1.f;
    const float pix = static_cast<float>(M_PI) * x;
    float s = std::sin(pix) / pix;
    if (x > -kResamplerSincHalf && x < kResamplerSincHalf) {
        float w = 0.5f + 0.5f * std::cos(static_cast<float>(M_PI) * x / kResamplerSincHalf);
        s *= w;
    } else {
        s = 0.f;
    }
    return s;
}

struct ResamplerState {
    float phase = 0.f;
    void reset() { phase = 0.f; }
};

inline DspError resample_interleaved(
    ResamplerState& st,
    const float* in, int in_frames,
    float* out, int* out_frames,
    int channels,
    float ratio,
    DspSrcQuality quality)
{
    if (!in || !out || !out_frames || in_frames < 1 || channels < 1 || ratio <= 0.f)
        return DSP_ERR_INVALID_ARG;

    int max_out = *out_frames;
    if (max_out < 1) return DSP_ERR_INVALID_ARG;

    float phase = st.phase;
    int written = 0;

    auto sample_at = [&](int idx, int c) -> float {
        if (idx < 0 || idx >= in_frames) return 0.f;
        return in[idx * channels + c];
    };

    /* phase is continuous position in this buffer; may start residual from prior call */
    while (written < max_out) {
        int i0 = static_cast<int>(phase);
        float frac = phase - static_cast<float>(i0);
        /* Need one sample ahead for linear/cubic; HQ taps handled via sample_at clamp */
        if (i0 >= in_frames) break;
        if (quality != DSP_SRC_HQ && quality != DSP_SRC_NONE && i0 >= in_frames - 1) break;

        for (int c = 0; c < channels; ++c) {
            float y;
            if (quality == DSP_SRC_HQ) {
                float sum = 0.f, wsum = 0.f;
                for (int k = -kResamplerSincHalf; k <= kResamplerSincHalf; ++k) {
                    float w = sinc_weight(static_cast<float>(k) - frac);
                    sum  += w * sample_at(i0 + k, c);
                    wsum += w;
                }
                y = (wsum != 0.f) ? (sum / wsum) : sample_at(i0, c);
            } else if (quality == DSP_SRC_CUBIC) {
                float y0 = sample_at(i0 - 1, c);
                float y1 = sample_at(i0,     c);
                float y2 = sample_at(i0 + 1, c);
                float y3 = sample_at(i0 + 2, c);
                float a0 = -0.5f * y0 + 1.5f * y1 - 1.5f * y2 + 0.5f * y3;
                float a1 = y0 - 2.5f * y1 + 2.f * y2 - 0.5f * y3;
                float a2 = -0.5f * y0 + 0.5f * y2;
                y = ((a0 * frac + a1) * frac + a2) * frac + y1;
            } else if (quality == DSP_SRC_LINEAR) {
                float y1 = sample_at(i0, c);
                float y2 = sample_at(i0 + 1, c);
                y = y1 + frac * (y2 - y1);
            } else {
                y = sample_at(i0, c);
            }
            out[written * channels + c] = y;
        }
        ++written;
        phase += ratio;
    }

    /*
     * Streaming residual in the next buffer's index space.
     * Linear/cubic stop near in_frames-1 (need a neighbor sample), so phase can
     * land slightly below in_frames — that is a normal end-of-buffer, not overflow.
     * OVERFLOW only when the out buffer filled while input still had usable samples.
     */
    const int i_end = static_cast<int>(phase);
    const bool need_neighbor =
        (quality == DSP_SRC_LINEAR || quality == DSP_SRC_CUBIC);
    const bool input_exhausted =
        (i_end >= in_frames) ||
        (need_neighbor && i_end >= in_frames - 1) ||
        (quality == DSP_SRC_HQ && i_end >= in_frames) ||
        (quality == DSP_SRC_NONE && i_end >= in_frames);

    float residual = phase - static_cast<float>(in_frames);
    DspError status = DSP_OK;
    if (!input_exhausted && written >= max_out) {
        /* Host must pass a larger out buffer to consume remaining input. */
        st.phase = 0.f;
        status = DSP_ERR_OVERFLOW;
    } else if (residual >= 0.f) {
        st.phase = residual;
        if (st.phase > 0.f && st.phase < 1e-6f) st.phase = 0.f;
    } else {
        /* Finished this buffer (interpolation edge). Continuity: keep frac only. */
        st.phase = phase - static_cast<float>(i_end);
        if (st.phase < 0.f) st.phase = 0.f;
        if (st.phase >= 1.f) st.phase = 0.f;
    }

    *out_frames = written;
    return status;
}

} // namespace dsp
