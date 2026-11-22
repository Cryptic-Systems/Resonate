/**
 * Unit tests for DSP ENGINE v0.6.0
 */

#include "test_framework.h"
#include "dsp_engine.h"
#include "audio/ring_buffer.h"
#include "utils/math_utils.h"
#include "core/resampler.h"
#include <vector>
#include <cmath>
#include <cstring>
#include <limits>
#include <cstdint>

using namespace dsp_test;

static DspEngine* create_engine(int channels = 2, float rate = 48000.f) {
    DspConfig cfg{};
    cfg.sample_rate = rate;
    cfg.channels = channels;
    cfg.max_block = 1024;
    cfg.enable_eq = 1;
    cfg.enable_dvc = 1;
    cfg.enable_limiter = 1;
    cfg.enable_dither = 0;
    cfg.dither_mode = DSP_DITHER_TPDF;
    cfg.limiter_threshold_db = -1.0f;
    cfg.limiter_release_ms = 50.f;
    return dsp_create(&cfg);
}

TEST(version) {
    const char* v = dsp_version();
    EXPECT_TRUE(v != nullptr);
    EXPECT_TRUE(std::strstr(v, "0.6") != nullptr);
}

TEST(lifecycle) {
    DspEngine* eng = create_engine();
    EXPECT_TRUE(eng != nullptr);
    EXPECT_EQ(dsp_reset(eng), DSP_OK);
    dsp_destroy(eng);
}

TEST(invalid_create) {
    DspConfig cfg{};
    cfg.channels = 0;
    cfg.max_block = 1024;
    EXPECT_TRUE(dsp_create(&cfg) == nullptr);
}

TEST(dvc_gain) {
    DspEngine* eng = create_engine();
    /* Default create enables ~15 ms smoothing; disable for instant-gain check. */
    EXPECT_EQ(dsp_dvc_set_smoothing(eng, 0, 0.f), DSP_OK);
    EXPECT_EQ(dsp_dvc_set_gain_db(eng, -6.0f), DSP_OK);
    EXPECT_NEAR(dsp_dvc_get_gain_db(eng), -6.0f, 1e-5);
    const int frames = 256;
    std::vector<float> in(frames * 2, 0.5f), out(frames * 2);
    EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);
    EXPECT_NEAR(out[0], 0.5f * 0.501187f, 0.01f);
    dsp_destroy(eng);
}

TEST(dvc_smoothing) {
    DspEngine* eng = create_engine();
    EXPECT_EQ(dsp_dvc_set_smoothing(eng, 1, 20.f), DSP_OK);
    EXPECT_EQ(dsp_dvc_get_smoothing(eng), 1);
    EXPECT_NEAR(dsp_dvc_get_smoothing_ms(eng), 20.f, 1e-3);
    EXPECT_EQ(dsp_dvc_set_gain_db(eng, -6.0f), DSP_OK);
    /* ~960 samples ≈ 20 ms @ 48 kHz; after one tau gain ≈ 0.63 toward target. */
    const int frames = 1024;
    std::vector<float> in(frames * 2, 1.0f), out(frames * 2);
    EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);
    EXPECT_GT(out[0], 0.95f);
    EXPECT_LT(out[(frames - 1) * 2], 0.75f);
    EXPECT_GT(out[(frames - 1) * 2], 0.55f);
    dsp_destroy(eng);
}

TEST(eq_bands) {
    DspEngine* eng = create_engine();
    DspEqBand bands[2] = {{1000.f, 6.0f, 1.0f, 0}, {5000.f, -3.0f, 0.7f, 0}};
    EXPECT_EQ(dsp_eq_set_bands(eng, bands, 2), DSP_OK);
    const int frames = 512;
    std::vector<float> in(frames * 2, 0.1f), out(frames * 2);
    EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);
    EXPECT_TRUE(std::isfinite(out[0]));
    dsp_destroy(eng);
}

TEST(limiter) {
    DspEngine* eng = create_engine();
    EXPECT_EQ(dsp_limiter_enable(eng, 1), DSP_OK);
    EXPECT_EQ(dsp_limiter_set_threshold(eng, -6.0f), DSP_OK);
    dsp_eq_enable(eng, 0);
    dsp_dvc_set_gain_db(eng, 0.f);
    const int frames = 1024;
    std::vector<float> in(frames * 2, 0.9f), out(frames * 2);
    EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);
    EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);
    float peak = 0.f;
    for (float s : out) { float a = std::fabs(s); if (a > peak) peak = a; }
    EXPECT_LT(peak, 0.65f);
    dsp_destroy(eng);
}

TEST(dither) {
    DspEngine* eng = create_engine();
    dsp_eq_enable(eng, 0); dsp_limiter_enable(eng, 0); dsp_dvc_set_gain_db(eng, 0.f);
    EXPECT_EQ(dsp_dither_enable(eng, 1), DSP_OK);
    const int frames = 256;
    std::vector<float> in(frames * 2, 0.25f), out(frames * 2);
    EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);
    EXPECT_NEAR(out[0], 0.25f, 3.0f / 32768.f);
    dsp_destroy(eng);
}

TEST(src_linear) {
    DspEngine* eng = create_engine();
    const int in_frames = 128;
    std::vector<float> in(in_frames * 2, 0.2f), out(256 * 2);
    int out_frames = 256;
    EXPECT_EQ(dsp_process_src(eng, in.data(), in_frames, out.data(), &out_frames, 0.5f, DSP_SRC_LINEAR), DSP_OK);
    EXPECT_GT(out_frames, 0);
    dsp_destroy(eng);
}

TEST(src_cubic) {
    DspEngine* eng = create_engine();
    const int in_frames = 128;
    std::vector<float> in(in_frames * 2, 0.2f), out(256 * 2);
    int out_frames = 256;
    EXPECT_EQ(dsp_process_src(eng, in.data(), in_frames, out.data(), &out_frames, 1.5f, DSP_SRC_CUBIC), DSP_OK);
    EXPECT_GT(out_frames, 0);
    dsp_destroy(eng);
}

TEST(src_pipeline) {
    DspEngine* eng = create_engine();
    dsp_eq_enable(eng, 0); dsp_limiter_enable(eng, 0); dsp_dither_enable(eng, 0);
    dsp_dvc_enable(eng, 1);
    EXPECT_EQ(dsp_dvc_set_gain_db(eng, -6.0f), DSP_OK);
    const int in_frames = 64;
    std::vector<float> in(in_frames * 2, 0.5f), out(128 * 2);
    int out_frames = 128;
    EXPECT_EQ(dsp_process_src(eng, in.data(), in_frames, out.data(), &out_frames, 1.0f, DSP_SRC_LINEAR), DSP_OK);
    EXPECT_GT(out_frames, 0);
    dsp_destroy(eng);
}

TEST(limiter_lookahead_mode_api) {
    DspEngine* eng = create_engine();
    EXPECT_EQ(dsp_limiter_set_mode(eng, DSP_LIMITER_LOOKAHEAD), DSP_OK);
    EXPECT_EQ(dsp_limiter_set_ceiling(eng, -1.0f), DSP_OK);
    EXPECT_EQ(dsp_limiter_set_lookahead_ms(eng, 2.0f), DSP_OK);
    EXPECT_GT(dsp_limiter_get_latency_samples(eng), 0);
    dsp_destroy(eng);
}

TEST(limiter_lookahead_brickwall) {
    DspConfig cfg{};
    cfg.sample_rate = 48000.f; cfg.channels = 2; cfg.max_block = 1024;
    cfg.enable_limiter = 1; cfg.dither_mode = DSP_DITHER_NONE;
    cfg.limiter_threshold_db = -1.0f; cfg.limiter_release_ms = 50.f;
    DspEngine* eng = dsp_create(&cfg);
    EXPECT_EQ(dsp_limiter_set_mode(eng, DSP_LIMITER_LOOKAHEAD), DSP_OK);
    EXPECT_EQ(dsp_limiter_set_ceiling(eng, -1.0f), DSP_OK);
    EXPECT_EQ(dsp_limiter_set_lookahead_ms(eng, 2.0f), DSP_OK);
    dsp_limiter_enable(eng, 1);
    const int frames = 512;
    std::vector<float> in(frames * 2, 0.f), out(frames * 2, 0.f);
    in[100 * 2] = 2.0f; in[100 * 2 + 1] = 2.0f;
    EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);
    const float ceil_lin = std::pow(10.0f, -1.0f / 20.0f);
    float peak = 0.f;
    for (float s : out) { float a = std::fabs(s); if (a > peak) peak = a; }
    EXPECT_LT(peak, ceil_lin + 0.02f);
    dsp_destroy(eng);
}

TEST(limiter_lookahead_latency) {
    DspEngine* eng = create_engine();
    dsp_limiter_enable(eng, 1);
    EXPECT_EQ(dsp_limiter_set_mode(eng, DSP_LIMITER_LOOKAHEAD), DSP_OK);
    EXPECT_EQ(dsp_limiter_set_lookahead_ms(eng, 1.0f), DSP_OK);
    int L = dsp_limiter_get_latency_samples(eng);
    EXPECT_GE(L, 40); EXPECT_LE(L, 56);
    dsp_destroy(eng);
}

TEST(limiter_truepeak_mode) {
    DspEngine* eng = create_engine();
    EXPECT_EQ(dsp_limiter_set_mode(eng, DSP_LIMITER_TRUEPEAK), DSP_OK);
    EXPECT_EQ(dsp_limiter_set_ceiling(eng, -1.0f), DSP_OK);
    EXPECT_EQ(dsp_limiter_set_lookahead_ms(eng, 2.0f), DSP_OK);
    dsp_limiter_enable(eng, 1);
    const int frames = 512;
    std::vector<float> in(frames * 2, 0.f), out(frames * 2, 0.f);
    for (int i = 0; i < frames; ++i) {
        float s = (i % 2 == 0) ? 0.95f : -0.95f;
        in[i * 2] = s; in[i * 2 + 1] = s;
    }
    EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);
    EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);
    const float ceil_lin = std::pow(10.0f, -1.0f / 20.0f);
    float peak = 0.f;
    for (float s : out) { float a = std::fabs(s); if (a > peak) peak = a; }
    EXPECT_LT(peak, ceil_lin + 0.05f);
    dsp_destroy(eng);
}

TEST(limiter_soft_knee_and_ceiling) {
    DspEngine* eng = create_engine();
    dsp_eq_enable(eng, 0); dsp_dvc_set_gain_db(eng, 0.f);
    dsp_limiter_enable(eng, 1);
    EXPECT_EQ(dsp_limiter_set_threshold(eng, -6.0f), DSP_OK);
    EXPECT_EQ(dsp_limiter_set_ceiling(eng, -1.0f), DSP_OK);
    EXPECT_EQ(dsp_limiter_set_knee_db(eng, 6.0f), DSP_OK);
    const int frames = 1024;
    std::vector<float> in(frames * 2, 0.9f), out(frames * 2);
    EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);
    EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);
    float peak = 0.f;
    for (float s : out) { float a = std::fabs(s); if (a > peak) peak = a; }
    const float ceil_lin = std::pow(10.0f, -1.0f / 20.0f);
    EXPECT_LT(peak, ceil_lin + 0.05f);
    dsp_destroy(eng);
}

TEST(limiter_config_create) {
    DspConfig cfg{};
    cfg.sample_rate = 48000.f; cfg.channels = 2; cfg.max_block = 512;
    cfg.enable_limiter = 1; cfg.dither_mode = DSP_DITHER_NONE;
    cfg.limiter_threshold_db = -3.0f; cfg.limiter_release_ms = 80.f;
    cfg.limiter_mode = DSP_LIMITER_TRUEPEAK;
    cfg.limiter_ceiling_db = -1.0f; cfg.limiter_knee_db = 4.0f;
    cfg.limiter_attack_ms = 0.2f; cfg.limiter_lookahead_ms = 3.0f;
    DspEngine* eng = dsp_create(&cfg);
    EXPECT_TRUE(eng != nullptr);
    EXPECT_EQ(dsp_limiter_get_mode(eng), DSP_LIMITER_TRUEPEAK);
    EXPECT_NEAR(dsp_limiter_get_attack_ms(eng), 0.2f, 1e-5);
    EXPECT_NEAR(dsp_limiter_get_knee_db(eng), 4.0f, 1e-5);
    dsp_destroy(eng);
}

TEST(limiter_meter_gr) {
    DspConfig cfg{};
    cfg.sample_rate = 48000.f; cfg.channels = 2; cfg.max_block = 512;
    cfg.enable_limiter = 1; cfg.dither_mode = DSP_DITHER_NONE;
    cfg.limiter_threshold_db = -12.0f; cfg.limiter_release_ms = 50.f;
    cfg.limiter_ceiling_db = -1.0f; cfg.limiter_mode = DSP_LIMITER_FAST;
    DspEngine* eng = dsp_create(&cfg);
    EXPECT_TRUE(eng != nullptr);
    DspLimiterMeter m{};
    EXPECT_EQ(dsp_limiter_get_meter(eng, &m), DSP_OK);
    const int frames = 512;
    std::vector<float> in(frames * 2, 0.9f), out(frames * 2);
    EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);
    EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);
    EXPECT_GT(dsp_limiter_get_gr_db(eng), 1.0f);
    EXPECT_EQ(dsp_limiter_reset_meters(eng), DSP_OK);
    dsp_destroy(eng);
}

TEST(ceiling_default_zero_init) {
    DspConfig cfg{};
    cfg.sample_rate = 48000.f;
    cfg.channels = 2;
    cfg.max_block = 256;
    cfg.enable_limiter = 1;
    cfg.limiter_threshold_db = -1.f;
    cfg.limiter_release_ms = 50.f;
    DspEngine* eng = dsp_create(&cfg);
    EXPECT_TRUE(eng != nullptr);
    EXPECT_NEAR(dsp_limiter_get_ceiling(eng), -0.1f, 1e-5);
    dsp_destroy(eng);
}

TEST(process_nan_safe) {
    DspEngine* eng = create_engine();
    dsp_eq_enable(eng, 0);
    dsp_dvc_set_gain_db(eng, 0.f);
    dsp_limiter_enable(eng, 1);
    const int frames = 64;
    std::vector<float> in(frames * 2, 0.1f), out(frames * 2, 0.f);
    in[10] = std::nanf("");
    in[11] = std::numeric_limits<float>::infinity();
    EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);
    for (float s : out) EXPECT_TRUE(std::isfinite(s));
    dsp_destroy(eng);
}

TEST(limiter_getters) {
    DspEngine* eng = create_engine();
    EXPECT_EQ(dsp_limiter_set_threshold(eng, -3.0f), DSP_OK);
    EXPECT_NEAR(dsp_limiter_get_threshold(eng), -3.0f, 1e-5);
    dsp_destroy(eng);
}

TEST(dither_getters) {
    DspEngine* eng = create_engine();
    EXPECT_EQ(dsp_dither_set_mode(eng, DSP_DITHER_SHAPED), DSP_OK);
    EXPECT_EQ(dsp_dither_get_mode(eng), DSP_DITHER_SHAPED);
    dsp_destroy(eng);
}

TEST(math_db) {
    EXPECT_NEAR(dsp::db_to_linear(0.0), 1.0, 1e-9);
}

TEST(ring_buffer_spsc) {
    dsp::RingBuffer rb(64, 2);
    float in[32]; for (int i = 0; i < 32; ++i) in[i] = float(i);
    EXPECT_EQ(rb.write(in, 16), 16u);
    float out[32] = {};
    EXPECT_EQ(rb.read(out, 16), 16u);
}

TEST(resampler_module) {
    dsp::ResamplerState st;
    float in[8]; for (int i = 0; i < 8; ++i) in[i] = 0.5f;
    float out[16]; int out_frames = 8;
    EXPECT_EQ(dsp::resample_interleaved(st, in, 4, out, &out_frames, 2, 1.0f, DSP_SRC_LINEAR), DSP_OK);
}

TEST(backend_create) {
    DspBackend* be = dsp_backend_create();
    if (be) dsp_backend_destroy(be);
}

TEST(process_silence) {
    DspEngine* eng = create_engine();
    const int frames = 64;
    std::vector<float> in(frames * 2, 0.f), out(frames * 2, 1.f);
    EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);
    for (float s : out) EXPECT_NEAR(s, 0.f, 1e-6);
    dsp_destroy(eng);
}

TEST(process_large_block) {
    DspConfig cfg{};
    cfg.sample_rate = 48000.f; cfg.channels = 2; cfg.max_block = 128;
    cfg.enable_dvc = 1; cfg.dither_mode = DSP_DITHER_NONE;
    cfg.limiter_threshold_db = -1.f; cfg.limiter_release_ms = 50.f;
    DspEngine* eng = dsp_create(&cfg);
    dsp_dvc_set_gain_db(eng, 0.f);
    const int frames = 500;
    std::vector<float> in(frames * 2, 0.25f), out(frames * 2);
    EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);
    EXPECT_NEAR(out[0], 0.25f, 1e-5);
    dsp_destroy(eng);
}

TEST(process_identity) {
    DspEngine* eng = create_engine();
    dsp_eq_enable(eng, 0); dsp_dvc_set_gain_db(eng, 0.f);
    dsp_limiter_enable(eng, 0); dsp_dither_enable(eng, 0);
    const int frames = 128;
    std::vector<float> in(frames * 2);
    for (int i = 0; i < frames * 2; ++i) in[i] = (i % 17) * 0.01f;
    std::vector<float> out(frames * 2);
    EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);
    for (int i = 0; i < frames * 2; ++i) EXPECT_NEAR(out[i], in[i], 1e-5);
    dsp_destroy(eng);
}


TEST(process_pcm16) {
    DspEngine* eng = create_engine();
    dsp_eq_enable(eng, 0);
    dsp_dvc_set_smoothing(eng, 0, 0.f);
    dsp_dvc_set_gain_db(eng, 0.f);
    dsp_limiter_enable(eng, 0);
    const int frames = 64;
    std::vector<int16_t> buf(frames * 2, 8000);
    EXPECT_EQ(dsp_process_pcm16(eng, buf.data(), frames), DSP_OK);
    EXPECT_NEAR(static_cast<float>(buf[0]), 8000.f, 2.f);
    dsp_destroy(eng);
}

TEST(preamp_and_speaker) {
    DspEngine* eng = create_engine();
    EXPECT_EQ(dsp_preamp_set_db(eng, -6.f), DSP_OK);
    EXPECT_NEAR(dsp_preamp_get_db(eng), -6.f, 0.05f);
    EXPECT_EQ(dsp_speaker_set_enabled(eng, 1), DSP_OK);
    EXPECT_EQ(dsp_speaker_is_enabled(eng), 1);
    EXPECT_EQ(dsp_speaker_set_virtual_bass(eng, 0.7f), DSP_OK);
    EXPECT_NEAR(dsp_speaker_get_virtual_bass(eng), 0.7f, 1e-5);
    /* Force mailbox apply via process */
    const int frames = 128;
    std::vector<float> in(frames * 2, 0.2f), out(frames * 2);
    EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);
    EXPECT_TRUE(std::isfinite(out[0]));
    dsp_destroy(eng);
}

TEST(twoband_limiter) {
    DspConfig cfg{};
    cfg.sample_rate = 48000.f; cfg.channels = 2; cfg.max_block = 512;
    cfg.enable_limiter = 1; cfg.dither_mode = DSP_DITHER_NONE;
    cfg.limiter_threshold_db = -1.f; cfg.limiter_release_ms = 50.f;
    cfg.limiter_mode = DSP_LIMITER_TWOBAND;
    cfg.limiter_ceiling_db = -1.f; cfg.limiter_ceiling_low_db = -0.5f;
    cfg.crossover_hz = 120.f;
    DspEngine* eng = dsp_create(&cfg);
    EXPECT_TRUE(eng != nullptr);
    EXPECT_EQ(dsp_limiter_get_mode(eng), DSP_LIMITER_TWOBAND);
    EXPECT_NEAR(dsp_limiter_get_crossover_hz(eng), 120.f, 1e-3);
    const int frames = 256;
    std::vector<float> in(frames * 2, 0.95f), out(frames * 2);
    EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);
    EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);
    float peak = 0.f;
    for (float s : out) { float a = std::fabs(s); if (a > peak) peak = a; }
    EXPECT_LT(peak, 0.95f);
    dsp_destroy(eng);
}

TEST(processing_bypass) {
    DspEngine* eng = create_engine();
    EXPECT_EQ(dsp_set_processing_enabled(eng, 0), DSP_OK);
    const int frames = 64;
    std::vector<float> in(frames * 2), out(frames * 2);
    for (int i = 0; i < frames * 2; ++i) in[i] = (i % 7) * 0.01f;
    EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);
    for (int i = 0; i < frames * 2; ++i) EXPECT_NEAR(out[i], in[i], 1e-5);
    dsp_destroy(eng);
}

TEST(stats_api) {
    DspEngine* eng = create_engine();
    const int frames = 128;
    std::vector<float> in(frames * 2, 0.1f), out(frames * 2);
    EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);
    DspStats st{};
    EXPECT_EQ(dsp_get_stats(eng, &st), DSP_OK);
    EXPECT_GT(st.process_calls, 0);
    EXPECT_EQ(dsp_reset_stats(eng), DSP_OK);
    dsp_destroy(eng);
}


TEST(eq_31_bands_full_params) {
    /* Regression: engine must accept DSP_EQ_MAX_BANDS (31) full DspEqBand entries
     * without dropping q or type, then process without NaNs. */
    DspEngine* eng = create_engine();
    EXPECT_TRUE(eng != nullptr);
    EXPECT_EQ(DSP_EQ_MAX_BANDS, 31);

    DspEqBand bands[DSP_EQ_MAX_BANDS];
    static const float kHz[31] = {
        20, 25, 32, 40, 50, 63, 80, 100, 125, 160,
        200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600,
        2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000
    };
    for (int i = 0; i < DSP_EQ_MAX_BANDS; ++i) {
        bands[i].freq_hz = kHz[i];
        bands[i].gain_db = (i % 2 == 0) ? 3.0f : -2.5f;
        /* Non-default Q values across the set. */
        bands[i].q = 0.5f + 0.15f * static_cast<float>(i % 7);
        /* Mix peak / low-shelf / high-shelf (and a couple of HP/LP). */
        if (i == 0)
            bands[i].type = 1; /* low shelf */
        else if (i == DSP_EQ_MAX_BANDS - 1)
            bands[i].type = 2; /* high shelf */
        else if (i == 5)
            bands[i].type = 4; /* high-pass */
        else if (i == 25)
            bands[i].type = 3; /* low-pass */
        else
            bands[i].type = 0; /* peak */
    }

    EXPECT_EQ(dsp_eq_set_bands(eng, bands, DSP_EQ_MAX_BANDS), DSP_OK);
    EXPECT_EQ(dsp_eq_band_count(eng), DSP_EQ_MAX_BANDS);
    EXPECT_EQ(dsp_eq_enable(eng, 1), DSP_OK);

    /* Count > max must be rejected. */
    EXPECT_EQ(dsp_eq_set_bands(eng, bands, DSP_EQ_MAX_BANDS + 1), DSP_ERR_INVALID_ARG);
    EXPECT_EQ(dsp_eq_band_count(eng), DSP_EQ_MAX_BANDS); /* previous set retained */

    /* Single-band index at the last slot must also work. */
    DspEqBand last = bands[DSP_EQ_MAX_BANDS - 1];
    last.q = 2.7f;
    last.type = 2;
    last.gain_db = 4.0f;
    EXPECT_EQ(dsp_eq_set_band(eng, DSP_EQ_MAX_BANDS - 1, &last), DSP_OK);
    EXPECT_EQ(dsp_eq_set_band(eng, DSP_EQ_MAX_BANDS, &last), DSP_ERR_INVALID_ARG);

    const int frames = 512;
    std::vector<float> in(frames * 2, 0.1f), out(frames * 2);
    EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);
    for (float s : out)
        EXPECT_TRUE(std::isfinite(s));

    /* Re-set all 31 with deliberately varied non-default Q + types and process again. */
    for (int i = 0; i < DSP_EQ_MAX_BANDS; ++i) {
        bands[i].q = 0.4f + 0.2f * static_cast<float>((i * 3) % 11);
        bands[i].type = (i % 5); /* 0..4 cycle: peak, LS, HS, LP, HP */
        bands[i].gain_db = (bands[i].type == 3 || bands[i].type == 4) ? 0.f
                          : ((i % 2) ? 2.0f : -1.5f);
    }
    EXPECT_EQ(dsp_eq_set_bands(eng, bands, DSP_EQ_MAX_BANDS), DSP_OK);
    EXPECT_EQ(dsp_eq_band_count(eng), DSP_EQ_MAX_BANDS);
    EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);
    for (float s : out)
        EXPECT_TRUE(std::isfinite(s));

    dsp_destroy(eng);
}



TEST(analyze_buffer) {
    const int frames = 2048;
    const int ch = 2;
    std::vector<float> buf(frames * ch);
    for (int i = 0; i < frames; ++i) {
        float s = 0.5f * std::sin(2.f * 3.14159265f * 100.f * i / 48000.f);
        buf[i * 2] = s;
        buf[i * 2 + 1] = s;
    }
    DspAnalysisResult r{};
    EXPECT_EQ(dsp_analyze_buffer(buf.data(), frames, ch, 48000.f, &r), DSP_OK);
    EXPECT_NEAR(r.sample_peak_db, -6.0f, 0.5f);
    EXPECT_TRUE(r.true_peak_db >= r.sample_peak_db - 0.1f);
    EXPECT_TRUE(r.crest_db > 0.f);
    EXPECT_TRUE(std::isfinite(r.bass_energy_db));

    float max_g = 0.f;
    EXPECT_EQ(dsp_probe_max_bass_gain_db(buf.data(), frames, ch, 48000.f,
                                         80.f, -0.1f, 1.0f, &max_g), DSP_OK);
    EXPECT_TRUE(max_g > 0.f);
    EXPECT_TRUE(max_g < 24.f);

    for (float& s : buf) s = 0.95f;
    EXPECT_EQ(dsp_probe_max_bass_gain_db(buf.data(), frames, ch, 48000.f,
                                         80.f, -0.1f, 1.0f, &max_g), DSP_OK);
    EXPECT_TRUE(max_g < 1.0f);
}

TEST(level_meter_and_auto_bass) {
    DspEngine* eng = create_engine();
    EXPECT_EQ(dsp_limiter_enable(eng, 1), DSP_OK);
    EXPECT_EQ(dsp_limiter_set_ceiling(eng, -0.1f), DSP_OK);
    EXPECT_EQ(dsp_auto_bass_set_margin_db(eng, 1.0f), DSP_OK);
    EXPECT_EQ(dsp_auto_bass_set_freq_hz(eng, 80.f), DSP_OK);
    EXPECT_EQ(dsp_auto_bass_set_target_db(eng, 6.0f), DSP_OK);
    EXPECT_EQ(dsp_auto_bass_enable(eng, 1), DSP_OK);
    EXPECT_EQ(dsp_auto_bass_is_enabled(eng), 1);

    const int frames = 512;
    std::vector<float> in(frames * 2), out(frames * 2);
    for (int i = 0; i < frames; ++i) {
        float s = 0.25f * std::sin(2.f * 3.14159265f * 60.f * i / 48000.f);
        in[i * 2] = s;
        in[i * 2 + 1] = s;
    }
    for (int n = 0; n < 20; ++n)
        EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);

    DspLevelMeter m{};
    EXPECT_EQ(dsp_get_level_meter(eng, &m), DSP_OK);
    EXPECT_TRUE(m.in_peak_db > -30.f);
    EXPECT_TRUE(std::isfinite(m.headroom_db));
    EXPECT_TRUE(std::isfinite(m.post_eq_peak_db));

    float applied = dsp_auto_bass_get_applied_db(eng);
    EXPECT_TRUE(applied > 0.5f);
    EXPECT_TRUE(applied <= 6.5f);

    for (float& s : in) s *= 3.5f;
    for (int n = 0; n < 30; ++n)
        EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);
    float applied_loud = dsp_auto_bass_get_applied_db(eng);
    EXPECT_TRUE(applied_loud < applied + 0.1f);

    for (float s : out)
        EXPECT_TRUE(std::isfinite(s));
    EXPECT_TRUE(std::fabs(out[0]) <= 1.05f);

    EXPECT_EQ(dsp_auto_bass_enable(eng, 0), DSP_OK);
    EXPECT_EQ(dsp_reset_level_meters(eng), DSP_OK);
    dsp_destroy(eng);
}


TEST(auto_gain_rms) {
    DspEngine* eng = create_engine();
    EXPECT_EQ(dsp_limiter_enable(eng, 1), DSP_OK);
    EXPECT_EQ(dsp_limiter_set_ceiling(eng, -0.1f), DSP_OK);
    EXPECT_EQ(dsp_auto_gain_set_target_rms_db(eng, -18.f), DSP_OK);
    EXPECT_EQ(dsp_auto_gain_set_max_boost_db(eng, 12.f), DSP_OK);
    EXPECT_EQ(dsp_auto_gain_set_max_cut_db(eng, 12.f), DSP_OK);
    EXPECT_EQ(dsp_auto_gain_set_window_ms(eng, 200.f), DSP_OK);
    EXPECT_EQ(dsp_auto_gain_enable(eng, 1), DSP_OK);
    EXPECT_EQ(dsp_auto_gain_is_enabled(eng), 1);

    const int frames = 512;
    std::vector<float> in(frames * 2), out(frames * 2);
    /* Quiet tone ~ -18 dBFS peak-ish RMS lower */
    for (int i = 0; i < frames; ++i) {
        float s = 0.05f * std::sin(2.f * 3.14159265f * 440.f * i / 48000.f);
        in[i * 2] = s;
        in[i * 2 + 1] = s;
    }
    for (int n = 0; n < 40; ++n)
        EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);

    float applied = dsp_auto_gain_get_applied_db(eng);
    float rms = dsp_get_short_term_rms_db(eng);
    EXPECT_TRUE(std::isfinite(rms));
    EXPECT_TRUE(applied > 1.0f); /* quiet → boost toward target */

    DspLevelMeter m{};
    EXPECT_EQ(dsp_get_level_meter(eng, &m), DSP_OK);
    EXPECT_TRUE(std::isfinite(m.short_term_rms_db));

    /* Louder input should reduce boost */
    for (float& s : in) s *= 8.f;
    for (int n = 0; n < 50; ++n)
        EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);
    float applied2 = dsp_auto_gain_get_applied_db(eng);
    EXPECT_TRUE(applied2 < applied);

    for (float s : out) EXPECT_TRUE(std::isfinite(s));
    EXPECT_EQ(dsp_auto_gain_enable(eng, 0), DSP_OK);
    dsp_destroy(eng);
}


TEST(auto_gain_does_not_learn_sustained_silence) {
    DspEngine* eng = create_engine();
    EXPECT_EQ(dsp_auto_gain_set_target_rms_db(eng, -18.f), DSP_OK);
    EXPECT_EQ(dsp_auto_gain_set_max_boost_db(eng, 12.f), DSP_OK);
    EXPECT_EQ(dsp_auto_gain_set_max_cut_db(eng, 12.f), DSP_OK);
    EXPECT_EQ(dsp_auto_gain_set_window_ms(eng, 200.f), DSP_OK);
    EXPECT_EQ(dsp_silence_hygiene_enable(eng, 1), DSP_OK);
    EXPECT_EQ(dsp_auto_gain_enable(eng, 1), DSP_OK);

    constexpr int frames = 512;
    std::vector<float> silence(frames * 2, 0.f), loud(frames * 2, 0.25f);
    std::vector<float> out(frames * 2, 0.f);

    /* Sustained silence must not accumulate a large positive DVC correction. */
    for (int n = 0; n < 320; ++n)
        EXPECT_EQ(dsp_process(eng, silence.data(), out.data(), frames), DSP_OK);
    const float silence_gain = dsp_auto_gain_get_applied_db(eng);
    EXPECT_TRUE(std::isfinite(silence_gain));
    EXPECT_LT(silence_gain, 1.0f);

    /* On signal return, the gate releases only after stable signal is present;
       gain must not jump to a silence-derived positive boost. */
    for (int n = 0; n < 80; ++n)
        EXPECT_EQ(dsp_process(eng, loud.data(), out.data(), frames), DSP_OK);
    const float resumed_gain = dsp_auto_gain_get_applied_db(eng);
    EXPECT_TRUE(std::isfinite(resumed_gain));
    EXPECT_LT(resumed_gain, 1.0f);
    for (float sample : out) EXPECT_TRUE(std::isfinite(sample));

    dsp_destroy(eng);
}


TEST(headroom_budget_and_hints) {
    DspEngine* eng = create_engine();
    EXPECT_EQ(dsp_headroom_budget_set(eng, 0.6f, 0.2f, 0.2f), DSP_OK);
    float b, p, g;
    EXPECT_EQ(dsp_headroom_budget_get(eng, &b, &p, &g), DSP_OK);
    EXPECT_NEAR(b, 0.6f, 1e-4f);

    EXPECT_EQ(dsp_auto_preamp_set_target_db(eng, 3.f), DSP_OK);
    EXPECT_EQ(dsp_auto_preamp_enable(eng, 1), DSP_OK);
    EXPECT_EQ(dsp_auto_vb_set_target(eng, 0.7f), DSP_OK);
    EXPECT_EQ(dsp_speaker_set_enabled(eng, 1), DSP_OK);
    EXPECT_EQ(dsp_auto_vb_enable(eng, 1), DSP_OK);
    EXPECT_EQ(dsp_silence_hygiene_enable(eng, 1), DSP_OK);

    DspAnalysisResult ar{};
    ar.sample_peak_db = -3.f;
    ar.true_peak_db = -2.5f;
    ar.rms_db = -14.f;
    ar.crest_db = 11.f;
    ar.bass_energy_db = -25.f;
    EXPECT_EQ(dsp_apply_analysis_hint(eng, &ar, 5.0f), DSP_OK);
    EXPECT_NEAR(dsp_limiter_get_crest_hint(eng), 11.f, 1e-3f);

    const int frames = 512;
    std::vector<float> in(frames * 2, 0.1f), out(frames * 2);
    for (int n = 0; n < 10; ++n)
        EXPECT_EQ(dsp_process(eng, in.data(), out.data(), frames), DSP_OK);
    EXPECT_TRUE(std::isfinite(dsp_auto_preamp_get_applied_db(eng)));
    EXPECT_TRUE(dsp_auto_vb_get_applied(eng) >= 0.f);
    for (float s : out) EXPECT_TRUE(std::isfinite(s));
    dsp_destroy(eng);
}

TEST(resonate_twoband_limiter_mode_and_timing_updates) {
    DspEngine* eng = create_engine();
    EXPECT_TRUE(eng != nullptr);
    EXPECT_EQ(dsp_limiter_set_mode(eng, DSP_LIMITER_TWOBAND), DSP_OK);
    EXPECT_EQ(dsp_limiter_set_attack_ms(eng, 3.0f), DSP_OK);
    EXPECT_EQ(dsp_limiter_set_release(eng, 80.0f), DSP_OK);
    dsp_destroy(eng);
}

TEST(resonate_shaped_dither_noise_is_bounded) {
    DspConfig cfg{};
    cfg.sample_rate = 48000.f;
    cfg.channels = 2;
    cfg.max_block = 256;
    cfg.enable_eq = 0;
    cfg.enable_dvc = 0;
    cfg.enable_limiter = 0;
    cfg.enable_dither = 1;
    cfg.dither_mode = DSP_DITHER_SHAPED;
    DspEngine* eng = dsp_create(&cfg);
    EXPECT_TRUE(eng != nullptr);

    constexpr int frames = 256;
    std::vector<int16_t> pcm(frames * 2, 0);
    int max_abs = 0;
    for (int block = 0; block < 64; ++block) {
        std::fill(pcm.begin(), pcm.end(), 0);
        EXPECT_EQ(dsp_process_pcm16(eng, pcm.data(), frames), DSP_OK);
        for (int16_t sample : pcm) {
            int magnitude = static_cast<int>(sample);
            if (magnitude < 0) magnitude = -magnitude;
            if (magnitude > max_abs) max_abs = magnitude;
        }
    }
    EXPECT_TRUE(max_abs <= 2);
    dsp_destroy(eng);
}

int main() { return run_all(); }
