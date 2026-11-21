/**
 * Simple throughput benchmarks for DSP ENGINE.
 */

#include "dsp_engine.h"
#include <chrono>
#include <cstdio>
#include <vector>
#include <cmath>

static double now_ms() {
    using clock = std::chrono::high_resolution_clock;
    return std::chrono::duration<double, std::milli>(clock::now().time_since_epoch()).count();
}

int main() {
    DspConfig cfg{};
    cfg.sample_rate = 48000.f;
    cfg.channels = 2;
    cfg.max_block = 1024;
    cfg.enable_eq = 1;
    cfg.enable_dvc = 1;
    cfg.enable_limiter = 1;
    cfg.enable_dither = 0;
    cfg.limiter_threshold_db = -1.f;
    cfg.limiter_release_ms = 50.f;

    DspEngine* eng = dsp_create(&cfg);
    if (!eng) {
        printf("Failed to create engine\n");
        return 1;
    }

    // A few EQ bands
    DspEqBand bands[3] = {
        {100.f, 3.f, 0.7f, 1},
        {1000.f, -2.f, 1.0f, 0},
        {8000.f, 1.5f, 0.8f, 2}
    };
    dsp_eq_set_bands(eng, bands, 3);

    const int frames = 512;
    const int iterations = 20000;
    std::vector<float> buf(frames * 2, 0.1f);

    // Warm-up
    for (int i = 0; i < 100; ++i)
        dsp_process(eng, buf.data(), buf.data(), frames);

    double t0 = now_ms();
    for (int i = 0; i < iterations; ++i)
        dsp_process(eng, buf.data(), buf.data(), frames);
    double t1 = now_ms();

    double elapsed_s = (t1 - t0) / 1000.0;
    double total_samples = double(iterations) * frames * 2;
    double msamples_per_s = (total_samples / 1e6) / elapsed_s;
    double realtime_factor = (total_samples / 48000.0 / 2) / elapsed_s; // stereo

    printf("=== DSP ENGINE benchmarks ===\n");
    printf("Block size     : %d frames\n", frames);
    printf("Iterations     : %d\n", iterations);
    printf("Elapsed        : %.3f s\n", elapsed_s);
    printf("Throughput     : %.1f MSamples/s\n", msamples_per_s);
    printf("Realtime factor: %.1fx\n", realtime_factor);
    printf("=============================\n");

    dsp_destroy(eng);
    return 0;
}
