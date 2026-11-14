#include <jni.h>
#include <android/log.h>

#include "dsp_engine.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <mutex>
#include <new>

#define LOG_TAG "DspEngineJni"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

constexpr int kMaxFrames = 4096;
constexpr int kMaxChannels = 2;
constexpr int kMaxEqBands = DSP_EQ_MAX_BANDS;

struct PendingSettings {
    std::mutex writer;
    std::atomic<uint32_t> sequence{2};
    std::atomic<int> processingEnabled{1};
    std::atomic<int> eqEnabled{1};
    std::atomic<int> eqCount{0};
    std::array<std::atomic<float>, kMaxEqBands> freq{};
    std::array<std::atomic<float>, kMaxEqBands> gain{};
    std::array<std::atomic<float>, kMaxEqBands> q{};
    std::array<std::atomic<int>, kMaxEqBands> type{};
    std::atomic<int> dvcEnabled{1};
    std::atomic<float> dvcDb{0.f};
    std::atomic<int> dvcSmoothing{1};
    std::atomic<float> dvcSmoothingMs{15.f};
    std::atomic<float> preampLinear{1.f};
    std::atomic<int> speakerEnabled{0};
    std::atomic<float> virtualBass{0.55f};
    std::atomic<int> limiterEnabled{1};
    std::atomic<int> limiterMode{DSP_LIMITER_FAST};
    std::atomic<float> limiterThreshold{-1.f};
    std::atomic<float> limiterRelease{50.f};
    std::atomic<float> limiterAttack{0.1f};
    std::atomic<float> limiterLookahead{2.f};
    std::atomic<float> limiterKnee{0.f};
    std::atomic<float> limiterHigh{-0.5f};
    std::atomic<float> limiterLow{-0.2f};
    std::atomic<float> crossover{120.f};
    std::atomic<int> ditherEnabled{0};
    std::atomic<int> ditherMode{DSP_DITHER_TPDF};

    PendingSettings() {
        for (int i = 0; i < kMaxEqBands; ++i) {
            freq[i].store(1000.f);
            gain[i].store(0.f);
            q[i].store(1.f);
            type[i].store(0);
        }
    }

    template <typename F>
    void update(F&& fn) {
        std::lock_guard<std::mutex> lock(writer);
        const uint32_t current = sequence.load(std::memory_order_relaxed);
        sequence.store(current + 1, std::memory_order_release);
        fn();
        sequence.store(current + 2, std::memory_order_release);
    }
};

struct Snapshot {
    uint32_t sequence = 0;
    int processingEnabled = 1;
    int eqEnabled = 1;
    int eqCount = 0;
    DspEqBand bands[kMaxEqBands]{};
    int dvcEnabled = 1;
    float dvcDb = 0.f;
    int dvcSmoothing = 1;
    float dvcSmoothingMs = 15.f;
    float preampLinear = 1.f;
    int speakerEnabled = 0;
    float virtualBass = 0.55f;
    int limiterEnabled = 1;
    int limiterMode = DSP_LIMITER_FAST;
    float limiterThreshold = -1.f;
    float limiterRelease = 50.f;
    float limiterAttack = 0.1f;
    float limiterLookahead = 2.f;
    float limiterKnee = 0.f;
    float limiterHigh = -0.5f;
    float limiterLow = -0.2f;
    float crossover = 120.f;
    int ditherEnabled = 0;
    int ditherMode = DSP_DITHER_TPDF;
};

struct NativeHandle {
    DspEngine* engine = nullptr;
    PendingSettings pending;
    uint32_t appliedSequence = 0; // Audio-thread owned.
    const int sampleRate;
    const int channels;
    std::atomic<uint32_t> processCalls{0};
    std::atomic<float> averageUs{0.f};
    std::atomic<float> maxUs{0.f};
    std::atomic<uint32_t> overruns{0};
    std::atomic<int32_t> lastFrames{0};

    NativeHandle(int sr, int ch) : sampleRate(sr), channels(ch) {}
};

bool readSnapshot(const PendingSettings& p, Snapshot* out) {
    for (int attempt = 0; attempt < 3; ++attempt) {
        const uint32_t before = p.sequence.load(std::memory_order_acquire);
        if ((before & 1U) != 0U) continue;
        Snapshot s;
        s.sequence = before;
        s.processingEnabled = p.processingEnabled.load(std::memory_order_relaxed);
        s.eqEnabled = p.eqEnabled.load(std::memory_order_relaxed);
        s.eqCount = std::clamp(p.eqCount.load(std::memory_order_relaxed), 0, kMaxEqBands);
        for (int i = 0; i < s.eqCount; ++i) {
            s.bands[i].freq_hz = p.freq[i].load(std::memory_order_relaxed);
            s.bands[i].gain_db = p.gain[i].load(std::memory_order_relaxed);
            s.bands[i].q = p.q[i].load(std::memory_order_relaxed);
            s.bands[i].type = p.type[i].load(std::memory_order_relaxed);
        }
        s.dvcEnabled = p.dvcEnabled.load(std::memory_order_relaxed);
        s.dvcDb = p.dvcDb.load(std::memory_order_relaxed);
        s.dvcSmoothing = p.dvcSmoothing.load(std::memory_order_relaxed);
        s.dvcSmoothingMs = p.dvcSmoothingMs.load(std::memory_order_relaxed);
        s.preampLinear = p.preampLinear.load(std::memory_order_relaxed);
        s.speakerEnabled = p.speakerEnabled.load(std::memory_order_relaxed);
        s.virtualBass = p.virtualBass.load(std::memory_order_relaxed);
        s.limiterEnabled = p.limiterEnabled.load(std::memory_order_relaxed);
        s.limiterMode = p.limiterMode.load(std::memory_order_relaxed);
        s.limiterThreshold = p.limiterThreshold.load(std::memory_order_relaxed);
        s.limiterRelease = p.limiterRelease.load(std::memory_order_relaxed);
        s.limiterAttack = p.limiterAttack.load(std::memory_order_relaxed);
        s.limiterLookahead = p.limiterLookahead.load(std::memory_order_relaxed);
        s.limiterKnee = p.limiterKnee.load(std::memory_order_relaxed);
        s.limiterHigh = p.limiterHigh.load(std::memory_order_relaxed);
        s.limiterLow = p.limiterLow.load(std::memory_order_relaxed);
        s.crossover = p.crossover.load(std::memory_order_relaxed);
        s.ditherEnabled = p.ditherEnabled.load(std::memory_order_relaxed);
        s.ditherMode = p.ditherMode.load(std::memory_order_relaxed);
        const uint32_t after = p.sequence.load(std::memory_order_acquire);
        if (before == after && (after & 1U) == 0U) {
            *out = s;
            return true;
        }
    }
    return false;
}

// All upstream C API setters are invoked here, on the same thread that calls
// dsp_process_pcm16. This protects the upstream implementation's EQ rebuild,
// limiter state and speaker filter state from UI/audio data races.
void applyPending(NativeHandle* h) {
    const uint32_t pendingSequence = h->pending.sequence.load(std::memory_order_acquire);
    if ((pendingSequence & 1U) != 0U || pendingSequence == h->appliedSequence) return;
    Snapshot s;
    if (!readSnapshot(h->pending, &s) || s.sequence == h->appliedSequence) return;
    DspEngine* e = h->engine;
    if (!e) return;
    dsp_set_processing_enabled(e, s.processingEnabled);
    dsp_eq_enable(e, s.eqEnabled);
    if (s.eqCount > 0) dsp_eq_set_bands(e, s.bands, s.eqCount);
    else dsp_eq_set_bands(e, nullptr, 0);
    dsp_dvc_enable(e, s.dvcEnabled);
    dsp_dvc_set_smoothing(e, s.dvcSmoothing, s.dvcSmoothingMs);
    dsp_dvc_set_gain_db(e, s.dvcDb);
    dsp_preamp_set_linear(e, s.preampLinear);
    dsp_speaker_set_enabled(e, s.speakerEnabled);
    dsp_speaker_set_virtual_bass(e, s.virtualBass);
    dsp_limiter_enable(e, s.limiterEnabled);
    dsp_limiter_set_mode(e, static_cast<DspLimiterMode>(s.limiterMode));
    dsp_limiter_set_threshold(e, s.limiterThreshold);
    dsp_limiter_set_release(e, s.limiterRelease);
    dsp_limiter_set_attack_ms(e, s.limiterAttack);
    dsp_limiter_set_lookahead_ms(e, s.limiterLookahead);
    dsp_limiter_set_knee_db(e, s.limiterKnee);
    dsp_limiter_set_ceiling_bands(e, s.limiterHigh, s.limiterLow);
    dsp_limiter_set_crossover_hz(e, s.crossover);
    dsp_dither_enable(e, s.ditherEnabled);
    dsp_dither_set_mode(e, static_cast<DspDitherMode>(s.ditherMode));
    h->appliedSequence = s.sequence;
}

NativeHandle* fromHandle(jlong value) {
    return value == 0 ? nullptr : reinterpret_cast<NativeHandle*>(value);
}

void setEqBands(NativeHandle* h, const DspEqBand* bands, int count, bool enabled) {
    if (!h) return;
    const int safeCount = std::clamp(count, 0, kMaxEqBands);
    h->pending.update([&] {
        h->pending.eqEnabled.store(enabled ? 1 : 0, std::memory_order_relaxed);
        h->pending.eqCount.store(safeCount, std::memory_order_relaxed);
        for (int i = 0; i < safeCount; ++i) {
            h->pending.freq[i].store(bands[i].freq_hz, std::memory_order_relaxed);
            h->pending.gain[i].store(bands[i].gain_db, std::memory_order_relaxed);
            h->pending.q[i].store(bands[i].q, std::memory_order_relaxed);
            h->pending.type[i].store(bands[i].type, std::memory_order_relaxed);
        }
    });
}

} // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_com_aetherion_resonate_dsp_DspEngineJni_nativeCreate(
        JNIEnv*, jclass, jdouble sampleRate, jint channels) {
    int sr = static_cast<int>(std::lround(sampleRate));
    if (sr < 8000) sr = 44100;
    const int ch = std::clamp(static_cast<int>(channels), 1, kMaxChannels);
    auto* h = new (std::nothrow) NativeHandle(sr, ch);
    if (!h) return 0;

    DspConfig cfg{};
    cfg.sample_rate = static_cast<float>(sr);
    cfg.channels = ch;
    cfg.max_block = kMaxFrames;
    cfg.enable_eq = 1;
    cfg.enable_dvc = 1;
    cfg.enable_limiter = 1;
    cfg.enable_dither = 0;
    cfg.dither_mode = DSP_DITHER_TPDF;
    cfg.limiter_threshold_db = -1.f;
    cfg.limiter_release_ms = 50.f;
    cfg.limiter_mode = DSP_LIMITER_FAST;
    cfg.limiter_ceiling_db = -0.5f;
    cfg.limiter_ceiling_low_db = -0.2f;
    cfg.limiter_attack_ms = 0.1f;
    cfg.limiter_lookahead_ms = 2.f;
    cfg.crossover_hz = 120.f;
    cfg.virtual_bass = 0.55f;

    h->engine = dsp_create(&cfg);
    if (!h->engine) {
        delete h;
        LOGE("dsp_create failed sr=%d channels=%d", sr, ch);
        return 0;
    }
    return reinterpret_cast<jlong>(h);
}

extern "C" JNIEXPORT void JNICALL
Java_com_aetherion_resonate_dsp_DspEngineJni_nativeDestroy(JNIEnv*, jclass, jlong value) {
    NativeHandle* h = fromHandle(value);
    if (!h) return;
    dsp_destroy(h->engine);
    h->engine = nullptr;
    delete h;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_aetherion_resonate_dsp_DspEngineJni_nativeProcessPcm16Direct(
        JNIEnv* env, jclass, jlong value, jobject buffer, jint frames,
        jint channels, jdouble /*sampleRate*/) {
    NativeHandle* h = fromHandle(value);
    if (!h || !h->engine || frames <= 0 || frames > kMaxFrames ||
        channels != h->channels || channels <= 0 || channels > kMaxChannels) return DSP_ERR_INVALID_ARG;
    void* address = env->GetDirectBufferAddress(buffer);
    const jlong capacity = env->GetDirectBufferCapacity(buffer);
    const jlong required = static_cast<jlong>(frames) * channels * sizeof(int16_t);
    if (!address || capacity < required) return DSP_ERR_INVALID_ARG;

    const auto start = std::chrono::steady_clock::now();
    applyPending(h);
    const DspError rc = dsp_process_pcm16(h->engine, static_cast<int16_t*>(address), frames);
    const int64_t elapsedNs = std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now() - start).count();
    if (rc == DSP_OK) {
        const uint32_t calls = h->processCalls.fetch_add(1, std::memory_order_relaxed) + 1;
        const float elapsedUs = static_cast<float>(elapsedNs) / 1000.f;
        float oldAverage = h->averageUs.load(std::memory_order_relaxed);
        while (!h->averageUs.compare_exchange_weak(
            oldAverage,
            oldAverage + (elapsedUs - oldAverage) / static_cast<float>(calls),
            std::memory_order_relaxed)) {}
        float oldMax = h->maxUs.load(std::memory_order_relaxed);
        while (elapsedUs > oldMax && !h->maxUs.compare_exchange_weak(
            oldMax, elapsedUs, std::memory_order_relaxed)) {}
        h->lastFrames.store(frames, std::memory_order_relaxed);
        const double budgetNs = static_cast<double>(frames) * 1.0e9 /
            static_cast<double>(h->sampleRate);
        if (static_cast<double>(elapsedNs) > budgetNs)
            h->overruns.fetch_add(1, std::memory_order_relaxed);
    }
    return rc;
}

extern "C" JNIEXPORT void JNICALL
Java_com_aetherion_resonate_dsp_DspEngineJni_nativeSetEnabled(
        JNIEnv*, jclass, jlong value, jboolean enabled) {
    if (auto* h = fromHandle(value)) h->pending.update([&] {
        h->pending.eqEnabled.store(enabled == JNI_TRUE, std::memory_order_relaxed);
    });
}

extern "C" JNIEXPORT void JNICALL
Java_com_aetherion_resonate_dsp_DspEngineJni_nativeSetProcessingEnabled(
        JNIEnv*, jclass, jlong value, jboolean enabled) {
    if (auto* h = fromHandle(value)) h->pending.update([&] {
        h->pending.processingEnabled.store(enabled == JNI_TRUE, std::memory_order_relaxed);
    });
}

extern "C" JNIEXPORT void JNICALL
Java_com_aetherion_resonate_dsp_DspEngineJni_nativeSetVolume(
        JNIEnv*, jclass, jlong value, jdouble linearGain) {
    if (auto* h = fromHandle(value)) h->pending.update([&] {
        const double g = std::clamp(linearGain, 0.0, 4.0);
        h->pending.dvcDb.store(static_cast<float>(g <= 1.0e-6 ? -120.0 : 20.0 * std::log10(g)), std::memory_order_relaxed);
    });
}

extern "C" JNIEXPORT void JNICALL
Java_com_aetherion_resonate_dsp_DspEngineJni_nativeSetEqBands(
        JNIEnv* env, jclass, jlong value, jdoubleArray centersHz,
        jdoubleArray gainsDb, jboolean enabled) {
    NativeHandle* h = fromHandle(value);
    if (!h || !gainsDb) return;
    const jsize count = std::min(env->GetArrayLength(gainsDb), kMaxEqBands);
    if (count <= 0) {
        setEqBands(h, nullptr, 0, enabled == JNI_TRUE);
        return;
    }
    jdouble gains[kMaxEqBands]{};
    jdouble centers[kMaxEqBands]{};
    env->GetDoubleArrayRegion(gainsDb, 0, count, gains);
    const bool hasCenters =
        centersHz != nullptr && env->GetArrayLength(centersHz) >= count;
    if (hasCenters)
        env->GetDoubleArrayRegion(centersHz, 0, count, centers);
    DspEqBand bands[kMaxEqBands]{};
    for (int i = 0; i < count; ++i) {
        bands[i].freq_hz = hasCenters ? static_cast<float>(centers[i])
                                     : static_cast<float>(20.0 * std::pow(1000.0, i / static_cast<double>(std::max(1, count - 1))));
        bands[i].gain_db = static_cast<float>(gains[i]);
        bands[i].q = 1.f;
        bands[i].type = 0;
    }
    setEqBands(h, bands, count, enabled == JNI_TRUE);
}

extern "C" JNIEXPORT void JNICALL
Java_com_aetherion_resonate_dsp_DspEngineJni_nativeSetParametricEqBands(
        JNIEnv* env, jclass, jlong value, jfloatArray frequencies,
        jfloatArray gains, jfloatArray qs, jintArray types, jboolean enabled) {
    NativeHandle* h = fromHandle(value);
    if (!h || !frequencies || !gains || !qs || !types) return;
    const jsize count = std::min({env->GetArrayLength(frequencies),
        env->GetArrayLength(gains), env->GetArrayLength(qs),
        env->GetArrayLength(types), kMaxEqBands});
    jfloat f[kMaxEqBands]{}, g[kMaxEqBands]{}, q[kMaxEqBands]{};
    jint t[kMaxEqBands]{};
    env->GetFloatArrayRegion(frequencies, 0, count, f);
    env->GetFloatArrayRegion(gains, 0, count, g);
    env->GetFloatArrayRegion(qs, 0, count, q);
    env->GetIntArrayRegion(types, 0, count, t);
    DspEqBand bands[kMaxEqBands]{};
    for (int i = 0; i < count; ++i) {
        bands[i].freq_hz = std::clamp(f[i], 20.f, 20000.f);
        bands[i].gain_db = std::clamp(g[i], -24.f, 24.f);
        bands[i].q = std::clamp(q[i], 0.1f, 18.f);
        bands[i].type = std::clamp(t[i], 0, 4);
    }
    setEqBands(h, bands, count, enabled == JNI_TRUE);
}

extern "C" JNIEXPORT void JNICALL
Java_com_aetherion_resonate_dsp_DspEngineJni_nativeSetDvc(
        JNIEnv*, jclass, jlong value, jboolean enabled, jfloat db,
        jboolean smoothing, jfloat smoothingMs) {
    if (auto* h = fromHandle(value)) h->pending.update([&] {
        h->pending.dvcEnabled.store(enabled == JNI_TRUE, std::memory_order_relaxed);
        h->pending.dvcDb.store(std::clamp(db, -120.f, 24.f), std::memory_order_relaxed);
        h->pending.dvcSmoothing.store(smoothing == JNI_TRUE, std::memory_order_relaxed);
        h->pending.dvcSmoothingMs.store(std::clamp(smoothingMs, 0.f, 200.f), std::memory_order_relaxed);
    });
}

extern "C" JNIEXPORT void JNICALL
Java_com_aetherion_resonate_dsp_DspEngineJni_nativeSetSpeakerMode(
        JNIEnv*, jclass, jlong value, jboolean enabled) {
    if (auto* h = fromHandle(value)) h->pending.update([&] {
        h->pending.speakerEnabled.store(enabled == JNI_TRUE, std::memory_order_relaxed);
    });
}

extern "C" JNIEXPORT void JNICALL
Java_com_aetherion_resonate_dsp_DspEngineJni_nativeSetVirtualBass(
        JNIEnv*, jclass, jlong value, jdouble amount) {
    if (auto* h = fromHandle(value)) h->pending.update([&] {
        h->pending.virtualBass.store(static_cast<float>(std::clamp(amount, 0.0, 1.0)), std::memory_order_relaxed);
    });
}

extern "C" JNIEXPORT void JNICALL
Java_com_aetherion_resonate_dsp_DspEngineJni_nativeSetPreamp(
        JNIEnv*, jclass, jlong value, jdouble linearGain) {
    if (auto* h = fromHandle(value)) h->pending.update([&] {
        h->pending.preampLinear.store(static_cast<float>(std::clamp(linearGain, 0.0, 4.0)), std::memory_order_relaxed);
    });
}

extern "C" JNIEXPORT void JNICALL
Java_com_aetherion_resonate_dsp_DspEngineJni_nativeSetLimiterCeiling(
        JNIEnv*, jclass, jlong value, jfloat highDb, jfloat lowDb) {
    if (auto* h = fromHandle(value)) h->pending.update([&] {
        h->pending.limiterHigh.store(std::clamp(highDb, -12.f, -0.05f), std::memory_order_relaxed);
        h->pending.limiterLow.store(std::clamp(lowDb, -12.f, -0.05f), std::memory_order_relaxed);
    });
}

extern "C" JNIEXPORT void JNICALL
Java_com_aetherion_resonate_dsp_DspEngineJni_nativeSetCrossoverHz(
        JNIEnv*, jclass, jlong value, jfloat freqHz) {
    if (auto* h = fromHandle(value)) h->pending.update([&] {
        h->pending.crossover.store(std::clamp(freqHz, 80.f, 200.f), std::memory_order_relaxed);
    });
}

extern "C" JNIEXPORT void JNICALL
Java_com_aetherion_resonate_dsp_DspEngineJni_nativeSetLimiterConfig(
        JNIEnv*, jclass, jlong value, jboolean enabled, jint mode,
        jfloat thresholdDb, jfloat releaseMs, jfloat attackMs,
        jfloat lookaheadMs, jfloat kneeDb) {
    if (auto* h = fromHandle(value)) h->pending.update([&] {
        h->pending.limiterEnabled.store(enabled == JNI_TRUE, std::memory_order_relaxed);
        h->pending.limiterMode.store(std::clamp(mode, 0, 3), std::memory_order_relaxed);
        h->pending.limiterThreshold.store(std::clamp(thresholdDb, -24.f, 0.f), std::memory_order_relaxed);
        h->pending.limiterRelease.store(std::clamp(releaseMs, 1.f, 2000.f), std::memory_order_relaxed);
        h->pending.limiterAttack.store(std::clamp(attackMs, 0.01f, 100.f), std::memory_order_relaxed);
        h->pending.limiterLookahead.store(std::clamp(lookaheadMs, 0.f, 40.f), std::memory_order_relaxed);
        h->pending.limiterKnee.store(std::clamp(kneeDb, 0.f, 12.f), std::memory_order_relaxed);
    });
}

extern "C" JNIEXPORT void JNICALL
Java_com_aetherion_resonate_dsp_DspEngineJni_nativeSetDither(
        JNIEnv*, jclass, jlong value, jboolean enabled, jint mode) {
    if (auto* h = fromHandle(value)) h->pending.update([&] {
        h->pending.ditherEnabled.store(enabled == JNI_TRUE, std::memory_order_relaxed);
        h->pending.ditherMode.store(std::clamp(mode, 0, 2), std::memory_order_relaxed);
    });
}

extern "C" JNIEXPORT jdoubleArray JNICALL
Java_com_aetherion_resonate_dsp_DspEngineJni_nativeGetStats(
        JNIEnv* env, jclass, jlong value) {
    jdoubleArray arr = env->NewDoubleArray(6);
    if (!arr) return nullptr;
    double vals[6]{};
    if (auto* h = fromHandle(value)) {
        const int64_t calls = h->processCalls.load(std::memory_order_relaxed);
        vals[0] = static_cast<double>(calls);
        vals[1] = static_cast<double>(h->averageUs.load(std::memory_order_relaxed));
        vals[2] = static_cast<double>(h->maxUs.load(std::memory_order_relaxed));
        vals[3] = static_cast<double>(h->overruns.load(std::memory_order_relaxed));
        vals[4] = static_cast<double>(h->lastFrames.load(std::memory_order_relaxed));
        vals[5] = static_cast<double>(h->sampleRate);
    }
    env->SetDoubleArrayRegion(arr, 0, 6, vals);
    return arr;
}

extern "C" JNIEXPORT void JNICALL
Java_com_aetherion_resonate_dsp_DspEngineJni_nativeResetStats(
        JNIEnv*, jclass, jlong value) {
    if (auto* h = fromHandle(value)) {
        h->processCalls.store(0, std::memory_order_relaxed);
        h->averageUs.store(0.f, std::memory_order_relaxed);
        h->maxUs.store(0.f, std::memory_order_relaxed);
        h->overruns.store(0, std::memory_order_relaxed);
        h->lastFrames.store(0, std::memory_order_relaxed);
    }
}
