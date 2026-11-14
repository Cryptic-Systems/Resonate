#include "dsp_engine.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

int main() {
    DspConfig config{};
    config.sample_rate = 48000.f;
    config.channels = 2;
    config.max_block = 1024;
    config.enable_eq = 1;
    config.enable_dvc = 1;
    config.enable_limiter = 1;
    config.enable_dither = 1;
    config.dither_mode = DSP_DITHER_TPDF;
    config.limiter_threshold_db = -1.f;
    config.limiter_release_ms = 50.f;
    config.limiter_mode = DSP_LIMITER_FAST;
    config.limiter_ceiling_db = -0.5f;
    config.limiter_ceiling_low_db = -0.2f;
    config.limiter_attack_ms = 0.1f;
    config.limiter_lookahead_ms = 2.f;
    config.crossover_hz = 120.f;
    config.virtual_bass = 0.55f;

    DspEngine* engine = dsp_create(&config);
    if (!engine) {
        std::fprintf(stderr, "DSP create failed\n");
        return 1;
    }

    DspEqBand bands[DSP_EQ_MAX_BANDS]{};
    for (int i = 0; i < DSP_EQ_MAX_BANDS; ++i) {
        bands[i].freq_hz = 20.f * std::pow(1000.f, i / 30.f);
        bands[i].gain_db = (i < 5) ? 2.f : 0.f;
        bands[i].q = 1.f;
        bands[i].type = 0;
    }

    bool ok = true;
    ok &= dsp_eq_set_bands(engine, bands, DSP_EQ_MAX_BANDS) == DSP_OK;
    ok &= dsp_eq_enable(engine, 1) == DSP_OK;
    ok &= dsp_dvc_enable(engine, 1) == DSP_OK;
    ok &= dsp_dvc_set_smoothing(engine, 1, 15.f) == DSP_OK;
    ok &= dsp_dvc_set_gain_db(engine, -2.f) == DSP_OK;
    ok &= dsp_limiter_set_mode(engine, DSP_LIMITER_TWOBAND) == DSP_OK;
    ok &= dsp_limiter_set_ceiling_bands(engine, -0.5f, -0.2f) == DSP_OK;
    ok &= dsp_limiter_set_crossover_hz(engine, 120.f) == DSP_OK;
    ok &= dsp_speaker_set_enabled(engine, 1) == DSP_OK;
    ok &= dsp_speaker_set_virtual_bass(engine, 0.55f) == DSP_OK;
    ok &= dsp_dither_enable(engine, 1) == DSP_OK;
    ok &= dsp_dither_set_mode(engine, DSP_DITHER_TPDF) == DSP_OK;

    constexpr int frames = 512;
    std::vector<int16_t> pcm(frames * 2);
    for (int i = 0; i < frames; ++i) {
        const float sample = 0.85f * std::sin(2.f * 3.14159265f * 55.f * i / 48000.f);
        const auto value = static_cast<int16_t>(sample * 32767.f);
        pcm[i * 2] = value;
        pcm[i * 2 + 1] = value;
    }

    ok &= dsp_process_pcm16(engine, pcm.data(), frames) == DSP_OK;
    for (const auto value : pcm) {
        if (value == INT16_MIN) continue;
    }

    DspStats stats{};
    ok &= dsp_get_stats(engine, &stats) == DSP_OK;
    ok &= stats.process_calls >= 1;
    ok &= stats.last_frames == frames;
    ok &= stats.channels == 2;

    dsp_destroy(engine);
    if (!ok) {
        std::fprintf(stderr, "DSP v0.4 integration smoke test failed\n");
        return 2;
    }
    std::printf("DSP v0.4 integration smoke test passed (%d bands, %d frames)\n",
                DSP_EQ_MAX_BANDS, frames);
    return 0;
}
