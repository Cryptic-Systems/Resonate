#include "dsp_engine.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

static bool verify_midrange_boost(float frequency_hz, float probe_hz = -1.f) {
    if (probe_hz <= 0.f) probe_hz = frequency_hz;
    DspConfig config{};
    config.sample_rate = 48000.f;
    config.channels = 2;
    config.max_block = 1024;
    config.enable_eq = 1;
    config.enable_dvc = 0;
    config.enable_limiter = 0;
    config.enable_dither = 0;
    config.limiter_threshold_db = -1.f;
    config.limiter_release_ms = 50.f;
    config.limiter_mode = DSP_LIMITER_FAST;
    config.limiter_ceiling_db = -0.5f;
    config.limiter_ceiling_low_db = -0.2f;
    config.limiter_attack_ms = 0.1f;
    config.limiter_lookahead_ms = 2.f;
    config.crossover_hz = 120.f;
    config.virtual_bass = 0.f;

    DspEngine* engine = dsp_create(&config);
    if (!engine) return false;

    DspEqBand band{};
    band.freq_hz = frequency_hz;
    band.gain_db = 6.f;
    band.q = 4.3f;
    band.type = 0;

    bool ok = dsp_eq_set_bands(engine, &band, 1) == DSP_OK;
    ok &= dsp_eq_enable(engine, 1) == DSP_OK;
    ok &= dsp_dvc_enable(engine, 0) == DSP_OK;
    ok &= dsp_limiter_enable(engine, 0) == DSP_OK;
    ok &= dsp_speaker_set_enabled(engine, 0) == DSP_OK;
    ok &= dsp_preamp_set_linear(engine, 1.f) == DSP_OK;
    ok &= dsp_dither_enable(engine, 0) == DSP_OK;

    constexpr int frames = 1024;
    constexpr int warmup_blocks = 5;
    constexpr int measured_blocks = 3;
    std::vector<int16_t> pcm(frames * 2);
    double input_energy = 0.0;
    double output_energy = 0.0;

    for (int block = 0; block < warmup_blocks + measured_blocks; ++block) {
        for (int i = 0; i < frames; ++i) {
            const int sample_index = block * frames + i;
            const float input = 0.06f * std::sin(
                2.f * 3.14159265f * probe_hz * sample_index / 48000.f);
            const auto value = static_cast<int16_t>(input * 32767.f);
            pcm[i * 2] = value;
            pcm[i * 2 + 1] = value;
        }
        if (dsp_process_pcm16(engine, pcm.data(), frames) != DSP_OK) {
            ok = false;
            break;
        }
        if (block >= warmup_blocks) {
            for (int i = 0; i < frames * 2; ++i) {
                const double input = static_cast<double>(
                    0.06f * std::sin(
                        2.f * 3.14159265f * probe_hz *
                        (block * frames + i / 2) / 48000.f));
                const double output = static_cast<double>(pcm[i]);
                input_energy += input * input * 32767.0 * 32767.0;
                output_energy += output * output;
            }
        }
    }

    const double ratio = input_energy > 0.0
        ? std::sqrt(output_energy / input_energy)
        : 0.0;
    const bool centerProbe = std::fabs(probe_hz - frequency_hz) < 0.5f;
    ok &= centerProbe ? (ratio > 1.75 && ratio < 2.25) : (ratio < 1.25);
    dsp_destroy(engine);

    if (!ok) {
        std::fprintf(stderr,
            "Midrange EQ response failed at %.0f Hz (measured gain %.2f dB)\n",
            frequency_hz, ratio > 0.0 ? 20.0 * std::log10(ratio) : -120.0);
    }
    return ok;
}

static bool verify_shaped_dither_noise_bounded() {
    DspConfig config{};
    config.sample_rate = 48000.f;
    config.channels = 2;
    config.max_block = 256;
    config.enable_eq = 0;
    config.enable_dvc = 0;
    config.enable_limiter = 0;
    config.enable_dither = 1;
    config.dither_mode = DSP_DITHER_SHAPED;
    config.limiter_threshold_db = -1.f;
    config.limiter_release_ms = 50.f;
    config.limiter_mode = DSP_LIMITER_FAST;
    config.limiter_ceiling_db = -0.5f;
    config.limiter_ceiling_low_db = -0.2f;
    config.limiter_attack_ms = 0.1f;
    config.limiter_lookahead_ms = 2.f;
    config.crossover_hz = 120.f;
    config.virtual_bass = 0.f;

    DspEngine* engine = dsp_create(&config);
    if (!engine) return false;
    constexpr int frames = 256;
    constexpr int blocks = 64;
    std::vector<int16_t> pcm(frames * 2, 0);
    int maxAbs = 0;
    bool ok = true;
    for (int block = 0; block < blocks; ++block) {
        std::fill(pcm.begin(), pcm.end(), 0);
        if (dsp_process_pcm16(engine, pcm.data(), frames) != DSP_OK) {
            ok = false;
            break;
        }
        for (const auto sample : pcm) {
            const int magnitude = std::abs(static_cast<int>(sample));
            if (magnitude > maxAbs) maxAbs = magnitude;
        }
    }
    dsp_destroy(engine);
    if (maxAbs > 2) {
        std::fprintf(stderr, "Shaped dither generated excessive silence noise: peak=%d LSB\n", maxAbs);
        ok = false;
    }
    return ok;
}

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

    bool ok = verify_shaped_dither_noise_bounded();
    ok &= dsp_eq_set_bands(engine, bands, DSP_EQ_MAX_BANDS) == DSP_OK;
    ok &= dsp_eq_band_count(engine) == DSP_EQ_MAX_BANDS;
    ok &= dsp_eq_enable(engine, 1) == DSP_OK;
    ok &= dsp_dvc_enable(engine, 1) == DSP_OK;
    ok &= dsp_dvc_set_smoothing(engine, 1, 15.f) == DSP_OK;
    ok &= dsp_dvc_set_gain_db(engine, -2.f) == DSP_OK;
    ok &= dsp_limiter_set_mode(engine, DSP_LIMITER_TWOBAND) == DSP_OK;
    ok &= dsp_limiter_get_mode(engine) == DSP_LIMITER_TWOBAND;
    ok &= dsp_limiter_is_enabled(engine) == 1;
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
    bool audible = false;
    for (const auto value : pcm) {
        if (value != 0) audible = true;
    }
    ok &= audible;

    DspStats stats{};
    ok &= dsp_get_stats(engine, &stats) == DSP_OK;
    ok &= stats.process_calls >= 1;
    ok &= stats.last_frames == frames;
    ok &= stats.channels == 2;
    ok &= std::fabs(dsp_dvc_get_gain_db(engine) - (-2.f)) < 0.1f;
    ok &= dsp_speaker_is_enabled(engine) == 1;

    dsp_destroy(engine);

    // Guard the full low-mid / presence region against silent or missing
    // parametric sections in the native PCM16 path.
    for (const float frequency : {250.f, 400.f, 630.f, 1000.f, 1600.f, 2500.f, 3150.f}) {
        ok &= verify_midrange_boost(frequency);
    }

    // A one-third-octave neighbor should not inherit most of a band's boost.
    ok &= verify_midrange_boost(1000.f, 1250.f);

    if (!ok) {
        std::fprintf(stderr, "DSP v0.4 integration smoke test failed\n");
        return 2;
    }
    std::printf("DSP v0.4 integration smoke test passed (%d bands, %d frames)\n",
                DSP_EQ_MAX_BANDS, frames);
    return 0;
}
