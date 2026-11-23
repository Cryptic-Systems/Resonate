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
#include <vector>
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
    std::atomic<float> headroomBassWeight{0.50f};
    std::atomic<float> headroomPreampWeight{0.20f};
    std::atomic<float> headroomGainWeight{0.30f};
    std::atomic<int> autoPreampEnabled{0};
    std::atomic<float> autoPreampTargetDb{0.f};
    std::atomic<int> autoVirtualBassEnabled{0};
    std::atomic<float> autoVirtualBassTarget{0.55f};
    std::atomic<int> silenceHygieneEnabled{0};
    std::atomic<float> silenceThresholdDb{-70.f};
    std::atomic<float> silenceHoldMs{500.f};
    std::atomic<int> autoBassEnabled{0};
    std::atomic<float> autoBassTargetDb{4.f};
    std::atomic<float> autoBassMarginDb{1.f};
    std::atomic<float> autoBassFreqHz{80.f};
    std::atomic<int> autoGainEnabled{0};
    std::atomic<float> autoGainTargetRmsDb{-18.f};
    std::atomic<float> autoGainBiasDb{0.f};
    std::atomic<float> autoGainMaxBoostDb{6.f};
    std::atomic<float> autoGainMaxCutDb{12.f};
    std::atomic<float> autoGainWindowMs{400.f};
    std::atomic<int> analysisHintEnabled{0};
    std::atomic<float> analysisSamplePeakDb{-160.f};
    std::atomic<float> analysisTruePeakDb{-160.f};
    std::atomic<float> analysisRmsDb{-160.f};
    std::atomic<float> analysisCrestDb{0.f};
    std::atomic<float> analysisBassEnergyDb{-160.f};
    std::atomic<float> analysisMaxSafeBassDb{24.f};

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
    float headroomBassWeight = 0.50f;
    float headroomPreampWeight = 0.20f;
    float headroomGainWeight = 0.30f;
    int autoPreampEnabled = 0;
    float autoPreampTargetDb = 0.f;
    int autoVirtualBassEnabled = 0;
    float autoVirtualBassTarget = 0.55f;
    int silenceHygieneEnabled = 0;
    float silenceThresholdDb = -70.f;
    float silenceHoldMs = 500.f;
    int autoBassEnabled = 0;
    float autoBassTargetDb = 4.f;
    float autoBassMarginDb = 1.f;
    float autoBassFreqHz = 80.f;
    int autoGainEnabled = 0;
    float autoGainTargetRmsDb = -18.f;
    float autoGainBiasDb = 0.f;
    float autoGainMaxBoostDb = 6.f;
    float autoGainMaxCutDb = 12.f;
    float autoGainWindowMs = 400.f;
    int analysisHintEnabled = 0;
    float analysisSamplePeakDb = -160.f;
    float analysisTruePeakDb = -160.f;
    float analysisRmsDb = -160.f;
    float analysisCrestDb = 0.f;
    float analysisBassEnergyDb = -160.f;
    float analysisMaxSafeBassDb = 24.f;
};

struct NativeHandle {
    DspEngine* engine = nullptr;
    PendingSettings pending;
    uint32_t appliedSequence = 0; // Audio-thread owned.
    Snapshot appliedSnapshot{};
    bool hasAppliedSnapshot = false;
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
        s.headroomBassWeight = p.headroomBassWeight.load(std::memory_order_relaxed);
        s.headroomPreampWeight = p.headroomPreampWeight.load(std::memory_order_relaxed);
        s.headroomGainWeight = p.headroomGainWeight.load(std::memory_order_relaxed);
        s.autoPreampEnabled = p.autoPreampEnabled.load(std::memory_order_relaxed);
        s.autoPreampTargetDb = p.autoPreampTargetDb.load(std::memory_order_relaxed);
        s.autoVirtualBassEnabled = p.autoVirtualBassEnabled.load(std::memory_order_relaxed);
        s.autoVirtualBassTarget = p.autoVirtualBassTarget.load(std::memory_order_relaxed);
        s.silenceHygieneEnabled = p.silenceHygieneEnabled.load(std::memory_order_relaxed);
        s.silenceThresholdDb = p.silenceThresholdDb.load(std::memory_order_relaxed);
        s.silenceHoldMs = p.silenceHoldMs.load(std::memory_order_relaxed);
        s.autoBassEnabled = p.autoBassEnabled.load(std::memory_order_relaxed);
        s.autoBassTargetDb = p.autoBassTargetDb.load(std::memory_order_relaxed);
        s.autoBassMarginDb = p.autoBassMarginDb.load(std::memory_order_relaxed);
        s.autoBassFreqHz = p.autoBassFreqHz.load(std::memory_order_relaxed);
        s.autoGainEnabled = p.autoGainEnabled.load(std::memory_order_relaxed);
        s.autoGainTargetRmsDb = p.autoGainTargetRmsDb.load(std::memory_order_relaxed);
        s.autoGainBiasDb = p.autoGainBiasDb.load(std::memory_order_relaxed);
        s.autoGainMaxBoostDb = p.autoGainMaxBoostDb.load(std::memory_order_relaxed);
        s.autoGainMaxCutDb = p.autoGainMaxCutDb.load(std::memory_order_relaxed);
        s.autoGainWindowMs = p.autoGainWindowMs.load(std::memory_order_relaxed);
        s.analysisHintEnabled = p.analysisHintEnabled.load(std::memory_order_relaxed);
        s.analysisSamplePeakDb = p.analysisSamplePeakDb.load(std::memory_order_relaxed);
        s.analysisTruePeakDb = p.analysisTruePeakDb.load(std::memory_order_relaxed);
        s.analysisRmsDb = p.analysisRmsDb.load(std::memory_order_relaxed);
        s.analysisCrestDb = p.analysisCrestDb.load(std::memory_order_relaxed);
        s.analysisBassEnergyDb = p.analysisBassEnergyDb.load(std::memory_order_relaxed);
        s.analysisMaxSafeBassDb = p.analysisMaxSafeBassDb.load(std::memory_order_relaxed);
        const uint32_t after = p.sequence.load(std::memory_order_acquire);
        if (before == after && (after & 1U) == 0U) {
            *out = s;
            return true;
        }
    }
    return false;
}

// All upstream C API setters are invoked here, on the same thread that calls
// dsp_process_pcm16. Apply only fields that actually changed. Reapplying the
// complete snapshot for every slider update rebuilt the 31-band EQ and reset
// limiter/speaker state even for unrelated controls, producing audible dropouts.
bool sameEqBands(const Snapshot& a, const Snapshot& b) {
    if (a.eqCount != b.eqCount) return false;
    for (int i = 0; i < a.eqCount; ++i) {
        if (a.bands[i].freq_hz != b.bands[i].freq_hz ||
            a.bands[i].gain_db != b.bands[i].gain_db ||
            a.bands[i].q != b.bands[i].q ||
            a.bands[i].type != b.bands[i].type) return false;
    }
    return true;
}

void applyPending(NativeHandle* h) {
    const uint32_t pendingSequence = h->pending.sequence.load(std::memory_order_acquire);
    if ((pendingSequence & 1U) != 0U || pendingSequence == h->appliedSequence) return;
    Snapshot s;
    if (!readSnapshot(h->pending, &s) || s.sequence == h->appliedSequence) return;
    DspEngine* e = h->engine;
    if (!e) return;
    const Snapshot& old = h->appliedSnapshot;
    const bool initial = !h->hasAppliedSnapshot;

    if (initial || s.processingEnabled != old.processingEnabled)
        dsp_set_processing_enabled(e, s.processingEnabled);

    if (initial || s.eqEnabled != old.eqEnabled)
        dsp_eq_enable(e, s.eqEnabled);
    if (initial || !sameEqBands(s, old)) {
        if (s.eqCount > 0) dsp_eq_set_bands(e, s.bands, s.eqCount);
        else dsp_eq_set_bands(e, nullptr, 0);
    }

    if (initial || s.dvcEnabled != old.dvcEnabled)
        dsp_dvc_enable(e, s.dvcEnabled);
    if (initial || s.dvcSmoothing != old.dvcSmoothing ||
        s.dvcSmoothingMs != old.dvcSmoothingMs)
        dsp_dvc_set_smoothing(e, s.dvcSmoothing, s.dvcSmoothingMs);
    if (initial || s.dvcDb != old.dvcDb)
        dsp_dvc_set_gain_db(e, s.dvcDb);
    if (initial || s.preampLinear != old.preampLinear)
        dsp_preamp_set_linear(e, s.preampLinear);

    if (initial || s.speakerEnabled != old.speakerEnabled)
        dsp_speaker_set_enabled(e, s.speakerEnabled);
    if (initial || s.virtualBass != old.virtualBass)
        dsp_speaker_set_virtual_bass(e, s.virtualBass);

    if (initial || s.limiterEnabled != old.limiterEnabled)
        dsp_limiter_enable(e, s.limiterEnabled);
    if (initial || s.limiterMode != old.limiterMode)
        dsp_limiter_set_mode(e, static_cast<DspLimiterMode>(s.limiterMode));
    if (initial || s.limiterThreshold != old.limiterThreshold)
        dsp_limiter_set_threshold(e, s.limiterThreshold);
    if (initial || s.limiterRelease != old.limiterRelease)
        dsp_limiter_set_release(e, s.limiterRelease);
    if (initial || s.limiterAttack != old.limiterAttack)
        dsp_limiter_set_attack_ms(e, s.limiterAttack);
    if (initial || s.limiterLookahead != old.limiterLookahead)
        dsp_limiter_set_lookahead_ms(e, s.limiterLookahead);
    if (initial || s.limiterKnee != old.limiterKnee)
        dsp_limiter_set_knee_db(e, s.limiterKnee);
    if (initial || s.limiterHigh != old.limiterHigh ||
        s.limiterLow != old.limiterLow)
        dsp_limiter_set_ceiling_bands(e, s.limiterHigh, s.limiterLow);
    if (initial || s.crossover != old.crossover)
        dsp_limiter_set_crossover_hz(e, s.crossover);

    if (initial || s.ditherEnabled != old.ditherEnabled)
        dsp_dither_enable(e, s.ditherEnabled);
    if (initial || s.ditherMode != old.ditherMode)
        dsp_dither_set_mode(e, static_cast<DspDitherMode>(s.ditherMode));

    if (initial || s.headroomBassWeight != old.headroomBassWeight ||
        s.headroomPreampWeight != old.headroomPreampWeight ||
        s.headroomGainWeight != old.headroomGainWeight)
        dsp_headroom_budget_set(e, s.headroomBassWeight,
            s.headroomPreampWeight, s.headroomGainWeight);
    if (initial || s.autoPreampEnabled != old.autoPreampEnabled)
        dsp_auto_preamp_enable(e, s.autoPreampEnabled);
    if (initial || s.autoPreampTargetDb != old.autoPreampTargetDb)
        dsp_auto_preamp_set_target_db(e, s.autoPreampTargetDb);
    if (initial || s.autoVirtualBassEnabled != old.autoVirtualBassEnabled)
        dsp_auto_vb_enable(e, s.autoVirtualBassEnabled);
    if (initial || s.autoVirtualBassTarget != old.autoVirtualBassTarget)
        dsp_auto_vb_set_target(e, s.autoVirtualBassTarget);
    if (initial || s.silenceHygieneEnabled != old.silenceHygieneEnabled)
        dsp_silence_hygiene_enable(e, s.silenceHygieneEnabled);
    if (initial || s.silenceThresholdDb != old.silenceThresholdDb)
        dsp_silence_hygiene_set_threshold_db(e, s.silenceThresholdDb);
    if (initial || s.silenceHoldMs != old.silenceHoldMs)
        dsp_silence_hygiene_set_hold_ms(e, s.silenceHoldMs);
    if (initial || s.autoBassEnabled != old.autoBassEnabled)
        dsp_auto_bass_enable(e, s.autoBassEnabled);
    if (initial || s.autoBassTargetDb != old.autoBassTargetDb)
        dsp_auto_bass_set_target_db(e, s.autoBassTargetDb);
    if (initial || s.autoBassMarginDb != old.autoBassMarginDb)
        dsp_auto_bass_set_margin_db(e, s.autoBassMarginDb);
    if (initial || s.autoBassFreqHz != old.autoBassFreqHz)
        dsp_auto_bass_set_freq_hz(e, s.autoBassFreqHz);
    if (initial || s.autoGainEnabled != old.autoGainEnabled)
        dsp_auto_gain_enable(e, s.autoGainEnabled);
    if (initial || s.autoGainTargetRmsDb != old.autoGainTargetRmsDb)
        dsp_auto_gain_set_target_rms_db(e, s.autoGainTargetRmsDb);
    if (initial || s.autoGainBiasDb != old.autoGainBiasDb)
        dsp_auto_gain_set_bias_db(e, s.autoGainBiasDb);
    if (initial || s.autoGainMaxBoostDb != old.autoGainMaxBoostDb)
        dsp_auto_gain_set_max_boost_db(e, s.autoGainMaxBoostDb);
    if (initial || s.autoGainMaxCutDb != old.autoGainMaxCutDb)
        dsp_auto_gain_set_max_cut_db(e, s.autoGainMaxCutDb);
    if (initial || s.autoGainWindowMs != old.autoGainWindowMs)
        dsp_auto_gain_set_window_ms(e, s.autoGainWindowMs);

    if (initial || s.analysisHintEnabled != old.analysisHintEnabled ||
        s.analysisSamplePeakDb != old.analysisSamplePeakDb ||
        s.analysisTruePeakDb != old.analysisTruePeakDb ||
        s.analysisRmsDb != old.analysisRmsDb ||
        s.analysisCrestDb != old.analysisCrestDb ||
        s.analysisBassEnergyDb != old.analysisBassEnergyDb ||
        s.analysisMaxSafeBassDb != old.analysisMaxSafeBassDb) {
        DspAnalysisResult analysis{};
        analysis.sample_peak_db = s.analysisHintEnabled ? s.analysisSamplePeakDb : -160.f;
        analysis.true_peak_db = s.analysisHintEnabled ? s.analysisTruePeakDb : -160.f;
        analysis.rms_db = s.analysisHintEnabled ? s.analysisRmsDb : -160.f;
        analysis.crest_db = s.analysisHintEnabled ? s.analysisCrestDb : 0.f;
        analysis.bass_energy_db = s.analysisHintEnabled ? s.analysisBassEnergyDb : -160.f;
        // 24 dB is upstream's no-cap sentinel; otherwise use the measured probe.
        dsp_apply_analysis_hint(e, &analysis, s.analysisHintEnabled ? s.analysisMaxSafeBassDb : 24.f);
        // Upstream only updates crest for positive hints; explicitly clear a
        // previous track's limiter personality when a physical deck is reused.
        dsp_limiter_set_crest_hint(e, analysis.crest_db > 0.f ? analysis.crest_db : 0.f);
    }

    h->appliedSnapshot = s;
    h->hasAppliedSnapshot = true;
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
        bands[i].q = count >= 24 ? 4.3f : 1.4f;
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

extern "C" JNIEXPORT void JNICALL
Java_com_aetherion_resonate_dsp_DspEngineJni_nativeSetIntelligenceConfig(
        JNIEnv*, jclass, jlong value,
        jfloat bassWeight, jfloat preampWeight, jfloat gainWeight,
        jboolean autoPreampEnabled, jfloat autoPreampTargetDb,
        jboolean autoVirtualBassEnabled, jfloat autoVirtualBassTarget,
        jboolean silenceHygieneEnabled, jfloat silenceThresholdDb,
        jfloat silenceHoldMs) {
    if (auto* h = fromHandle(value)) h->pending.update([&] {
        h->pending.headroomBassWeight.store(std::clamp(bassWeight, 0.f, 1.f), std::memory_order_relaxed);
        h->pending.headroomPreampWeight.store(std::clamp(preampWeight, 0.f, 1.f), std::memory_order_relaxed);
        h->pending.headroomGainWeight.store(std::clamp(gainWeight, 0.f, 1.f), std::memory_order_relaxed);
        h->pending.autoPreampEnabled.store(autoPreampEnabled == JNI_TRUE, std::memory_order_relaxed);
        h->pending.autoPreampTargetDb.store(std::clamp(autoPreampTargetDb, -12.f, 12.f), std::memory_order_relaxed);
        h->pending.autoVirtualBassEnabled.store(autoVirtualBassEnabled == JNI_TRUE, std::memory_order_relaxed);
        h->pending.autoVirtualBassTarget.store(std::clamp(autoVirtualBassTarget, 0.f, 1.f), std::memory_order_relaxed);
        h->pending.silenceHygieneEnabled.store(silenceHygieneEnabled == JNI_TRUE, std::memory_order_relaxed);
        h->pending.silenceThresholdDb.store(std::clamp(silenceThresholdDb, -120.f, -20.f), std::memory_order_relaxed);
        h->pending.silenceHoldMs.store(std::clamp(silenceHoldMs, 50.f, 5000.f), std::memory_order_relaxed);
    });
}

extern "C" JNIEXPORT void JNICALL
Java_com_aetherion_resonate_dsp_DspEngineJni_nativeSetAutoDynamicsConfig(
        JNIEnv*, jclass, jlong value,
        jboolean autoBassEnabled, jfloat autoBassTargetDb,
        jfloat autoBassMarginDb, jfloat autoBassFreqHz,
        jboolean autoGainEnabled, jfloat autoGainTargetRmsDb,
        jfloat autoGainBiasDb, jfloat autoGainMaxBoostDb,
        jfloat autoGainMaxCutDb, jfloat autoGainWindowMs) {
    if (auto* h = fromHandle(value)) {
        const float values[] = {autoBassTargetDb, autoBassMarginDb, autoBassFreqHz,
            autoGainTargetRmsDb, autoGainBiasDb, autoGainMaxBoostDb,
            autoGainMaxCutDb, autoGainWindowMs};
        for (float v : values) if (!std::isfinite(v)) return;
        h->pending.update([&] {
            h->pending.autoBassEnabled.store(autoBassEnabled == JNI_TRUE, std::memory_order_relaxed);
            h->pending.autoBassTargetDb.store(std::clamp(autoBassTargetDb, 0.f, 12.f), std::memory_order_relaxed);
            h->pending.autoBassMarginDb.store(std::clamp(autoBassMarginDb, 0.f, 12.f), std::memory_order_relaxed);
            h->pending.autoBassFreqHz.store(std::clamp(autoBassFreqHz, 40.f, 160.f), std::memory_order_relaxed);
            h->pending.autoGainEnabled.store(autoGainEnabled == JNI_TRUE, std::memory_order_relaxed);
            h->pending.autoGainTargetRmsDb.store(std::clamp(autoGainTargetRmsDb, -30.f, -8.f), std::memory_order_relaxed);
            h->pending.autoGainBiasDb.store(std::clamp(autoGainBiasDb, -6.f, 6.f), std::memory_order_relaxed);
            h->pending.autoGainMaxBoostDb.store(std::clamp(autoGainMaxBoostDb, 0.f, 12.f), std::memory_order_relaxed);
            h->pending.autoGainMaxCutDb.store(std::clamp(autoGainMaxCutDb, 0.f, 24.f), std::memory_order_relaxed);
            h->pending.autoGainWindowMs.store(std::clamp(autoGainWindowMs, 200.f, 3000.f), std::memory_order_relaxed);
        });
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_aetherion_resonate_dsp_DspEngineJni_nativeSetAnalysisHint(
        JNIEnv*, jclass, jlong value, jboolean enabled,
        jfloat samplePeakDb, jfloat truePeakDb, jfloat rmsDb,
        jfloat crestDb, jfloat bassEnergyDb, jfloat maxSafeBassDb) {
    if (auto* h = fromHandle(value)) {
        const bool useHint = enabled == JNI_TRUE &&
            std::isfinite(samplePeakDb) && std::isfinite(truePeakDb) &&
            std::isfinite(rmsDb) && std::isfinite(crestDb) &&
            std::isfinite(bassEnergyDb) &&
            (maxSafeBassDb == 24.f || (std::isfinite(maxSafeBassDb) && maxSafeBassDb >= 0.f && maxSafeBassDb <= 18.f));
        h->pending.update([&] {
            h->pending.analysisHintEnabled.store(useHint ? 1 : 0, std::memory_order_relaxed);
            h->pending.analysisSamplePeakDb.store(useHint ? std::clamp(samplePeakDb, -160.f, 6.f) : -160.f, std::memory_order_relaxed);
            h->pending.analysisTruePeakDb.store(useHint ? std::clamp(truePeakDb, -160.f, 6.f) : -160.f, std::memory_order_relaxed);
            h->pending.analysisRmsDb.store(useHint ? std::clamp(rmsDb, -160.f, 0.1f) : -160.f, std::memory_order_relaxed);
            h->pending.analysisCrestDb.store(useHint ? std::clamp(crestDb, 0.f, 30.f) : 0.f, std::memory_order_relaxed);
            h->pending.analysisBassEnergyDb.store(useHint ? std::clamp(bassEnergyDb, -160.f, 0.1f) : -160.f, std::memory_order_relaxed);
            h->pending.analysisMaxSafeBassDb.store(useHint ? maxSafeBassDb : 24.f, std::memory_order_relaxed);
        });
    }
}

extern "C" JNIEXPORT jfloat JNICALL
Java_com_aetherion_resonate_dsp_DspEngineJni_nativeProbeMaxBassGainDb(
        JNIEnv* env, jclass, jbyteArray pcm16, jint channels, jfloat sampleRate,
        jfloat shelfFreqHz, jfloat ceilingDb, jfloat marginDb) {
    if (!pcm16 || channels < 1 || channels > 8 ||
        !std::isfinite(sampleRate) || sampleRate < 8000.f ||
        !std::isfinite(shelfFreqHz) || shelfFreqHz < 40.f || shelfFreqHz > 160.f ||
        !std::isfinite(ceilingDb) || ceilingDb < -12.f || ceilingDb > 0.f ||
        !std::isfinite(marginDb) || marginDb < 0.f || marginDb > 12.f) {
        return -1.f;
    }
    const jsize byteCount = env->GetArrayLength(pcm16);
    const jsize frameBytes = channels * 2;
    if (byteCount < frameBytes * 4 || byteCount > 3 * 1024 * 1024 ||
        byteCount % frameBytes != 0) return -1.f;
    jbyte* bytes = env->GetByteArrayElements(pcm16, nullptr);
    if (!bytes) return -1.f;
    const int frames = byteCount / frameBytes;
    std::vector<float> samples(static_cast<size_t>(frames) * channels);
    for (jsize i = 0; i < byteCount / 2; ++i) {
        const uint16_t lo = static_cast<uint8_t>(bytes[i * 2]);
        const uint16_t hi = static_cast<uint8_t>(bytes[i * 2 + 1]);
        const int16_t sample = static_cast<int16_t>(lo | (hi << 8));
        samples[static_cast<size_t>(i)] = static_cast<float>(sample) / 32768.f;
    }
    env->ReleaseByteArrayElements(pcm16, bytes, JNI_ABORT);
    float maximum = 0.f;
    const DspError error = dsp_probe_max_bass_gain_db(
        samples.data(), frames, channels, sampleRate, shelfFreqHz,
        ceilingDb, marginDb, &maximum);
    if (error != DSP_OK || !std::isfinite(maximum)) return -1.f;
    return std::clamp(maximum, 0.f, 18.f);
}

extern "C" JNIEXPORT jfloatArray JNICALL
Java_com_aetherion_resonate_dsp_DspEngineJni_nativeGetMeters(
        JNIEnv* env, jclass, jlong value) {
    jfloatArray arr = env->NewFloatArray(20);
    if (!arr) return nullptr;
    float vals[20] = {-160.f, -160.f, -160.f, -160.f, 0.f, -160.f,
                      0.f, 0.f, 0.f, 0.f, 0.f, 0.f,
                      -120.f, -18.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f};
    if (auto* h = fromHandle(value); h && h->engine) {
        DspLevelMeter levels{};
        DspLimiterMeter limiter{};
        DspAutoGainMeter autoGain{};
        if (dsp_get_level_meter(h->engine, &levels) == DSP_OK) {
            vals[0] = levels.in_peak_db;
            vals[1] = levels.in_true_peak_db;
            vals[2] = levels.post_eq_peak_db;
            vals[3] = levels.bass_band_peak_db;
            vals[4] = levels.headroom_db;
            vals[5] = levels.short_term_rms_db;
        }
        if (dsp_limiter_get_meter(h->engine, &limiter) == DSP_OK) {
            vals[6] = limiter.gr_db;
            vals[7] = limiter.gr_peak_db;
        }
        vals[8] = dsp_auto_bass_get_applied_db(h->engine);
        vals[9] = dsp_auto_gain_get_applied_db(h->engine);
        vals[10] = dsp_auto_preamp_get_applied_db(h->engine);
        vals[11] = dsp_auto_vb_get_applied(h->engine);
        if (dsp_auto_gain_get_meter(h->engine, &autoGain) == DSP_OK) {
            vals[12] = autoGain.pre_dvc_peak_db;
            vals[13] = autoGain.target_rms_db;
            vals[14] = autoGain.rms_error_db;
            vals[15] = autoGain.constrained_target_db;
            vals[16] = autoGain.peak_gain_cap_db;
            vals[17] = autoGain.applied_gain_db;
            vals[18] = static_cast<float>(autoGain.peak_limited);
            vals[19] = static_cast<float>(autoGain.silence_gate_active);
        }
    }
    env->SetFloatArrayRegion(arr, 0, 20, vals);
    return arr;
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
