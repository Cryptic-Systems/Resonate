/**
 * DSP ENGINE — Public C ABI
 *
 * Highly optimized 64-bit processing engine with Direct Volume Control (DVC),
 * multi-band parametric EQ, true-peak / two-band limiter, preamp, speaker-mode
 * virtual bass, dither, sample-rate conversion, and optional platform backends.
 *
 * Version 0.6.0 — Full intelligent stack (budget, auto-VB, auto-preamp, crest, silence)
 *
 * THREAD SAFETY
 * -------------
 * dsp_process / dsp_process_pcm16 / dsp_process_src must run on a single audio
 * thread. Control calls may be issued from any thread: they write into a
 * lock-free mailbox that is applied at the start of the next process block.
 * Meter getters are best-effort snapshots (may tear slightly).
 * Offline analysis APIs (dsp_analyze_buffer / dsp_probe_max_bass_gain_db) are
 * pure and may run on any thread; they do not touch engine state.
 *
 * Pipeline (when processing enabled):
 *   EQ → auto-bass shelf → speaker/VB → preamp → DVC (auto-gain) → limiter → dither
 *
 * DVC gain changes use optional one-pole smoothing (default ~15 ms when DVC is
 * enabled at create). When auto-gain is enabled it drives DVC toward a short-term
 * RMS target (with bias / max boost / max cut and headroom clamp).
 *
 * INTELLIGENT BASS + LEVEL
 * -----------------------
 * Path A (offline): dsp_analyze_buffer / dsp_probe_max_bass_gain_db measure a
 * buffer's true-peak headroom and the max safe low-shelf gain under a ceiling.
 * Path B (online):  dsp_auto_bass_* servos a dedicated low-shelf so applied
 * boost stays under (ceiling - margin), using running level meters + GR.
 * Auto-DVC:         dsp_auto_gain_* matches short-term RMS to a target level.
 */

#ifndef DSP_ENGINE_H
#define DSP_ENGINE_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32) || defined(__CYGWIN__)
  #if defined(DSP_ENGINE_STATIC)
    #define DSP_API
  #elif defined(DSP_ENGINE_EXPORTS)
    #define DSP_API __declspec(dllexport)
  #else
    #define DSP_API __declspec(dllimport)
  #endif
#else
  #define DSP_API __attribute__((visibility("default")))
#endif

typedef enum {
    DSP_OK = 0,
    DSP_ERR_INVALID_ARG = -1,
    DSP_ERR_NO_MEM = -2,
    DSP_ERR_DEVICE = -3,
    DSP_ERR_ALREADY_RUNNING = -4,
    DSP_ERR_NOT_RUNNING = -5,
    DSP_ERR_UNSUPPORTED = -6,
    DSP_ERR_OVERFLOW = -7,
    DSP_ERR_UNDERFLOW = -8
} DspError;

typedef enum {
    DSP_SRC_NONE = 0,
    DSP_SRC_LINEAR = 1,
    DSP_SRC_CUBIC = 2,
    DSP_SRC_HQ = 3
} DspSrcQuality;

typedef enum {
    DSP_DITHER_NONE = 0,
    DSP_DITHER_TPDF = 1,
    DSP_DITHER_SHAPED = 2
} DspDitherMode;

typedef enum {
    DSP_LIMITER_FAST = 0,
    DSP_LIMITER_LOOKAHEAD = 1,
    DSP_LIMITER_TRUEPEAK = 2,
    /** Linkwitz-Riley split + independent high/low brickwall ceilings. */
    DSP_LIMITER_TWOBAND = 3
} DspLimiterMode;

typedef struct DspEngine DspEngine;

typedef struct {
    float sample_rate;
    int channels;
    int max_block;
    int enable_eq;
    int enable_dvc;
    int enable_limiter;
    int enable_dither;
    DspDitherMode dither_mode;
    float limiter_threshold_db;
    float limiter_release_ms;
    DspLimiterMode limiter_mode;
    float limiter_ceiling_db;
    float limiter_knee_db;
    float limiter_attack_ms;
    float limiter_lookahead_ms;
    /** Optional create-time defaults (0 = use engine defaults). */
    float preamp_db;
    float crossover_hz;
    float limiter_ceiling_low_db;
    int   enable_speaker;
    float virtual_bass;
} DspConfig;

typedef struct {
    float freq_hz;
    float gain_db;
    float q;
    int type; /* 0=peak, 1=lowshelf, 2=highshelf, 3=lp, 4=hp */
} DspEqBand;

/** Maximum parametric EQ bands accepted by dsp_eq_set_bands / dsp_eq_set_band.
 *  Matches the engine-side storage and MultiBandEq capacity. */
#define DSP_EQ_MAX_BANDS 31

/**
 * Gain-reduction metering for UI.
 * gr_db: instantaneous GR in dB (>= 0).
 * gr_peak_db: peak-hold GR in dB (slow decay, good for meters).
 * active: 1 if instantaneous GR > ~0.1 dB.
 */
typedef struct {
    float gr_db;
    float gr_peak_db;
    int   active;
} DspLimiterMeter;

/** Optional process / CPU diagnostics for host UIs. */
typedef struct {
    int64_t process_calls;
    int64_t total_ns;
    int64_t max_ns;
    int64_t overrun_count;
    int32_t last_frames;
    int32_t sample_rate;
    int32_t channels;
} DspStats;

/**
 * Offline / host-side buffer analysis (Path A).
 * Peaks in dBFS relative to full-scale 1.0. crest_db = sample_peak - rms.
 * bass_energy_db approximates energy below ~120 Hz (one-pole LP on mono).
 */
typedef struct {
    float sample_peak_db;
    float true_peak_db;
    float rms_db;
    float crest_db;
    float bass_energy_db;
} DspAnalysisResult;

/**
 * Running level meters updated every process block (Path B).
 * headroom_db = limiter_ceiling_db - post_eq_peak_db (before limiter).
 * Values are peak-hold with slow decay; suitable for UI and auto-bass.
 */
typedef struct {
    float in_peak_db;
    float in_true_peak_db;
    float post_eq_peak_db;
    float bass_band_peak_db;
    float headroom_db;
    /** Short-term RMS (dBFS), ~window set by auto-gain / default ~400 ms. */
    float short_term_rms_db;
} DspLevelMeter;

/**
 * Snapshot of the auto-DVC controller decision for the most recently processed
 * block. Values are best-effort telemetry, not control inputs.
 */
typedef struct {
    float pre_dvc_peak_db;
    float target_rms_db;
    float rms_error_db;
    float constrained_target_db;
    float peak_gain_cap_db;
    float applied_gain_db;
    int peak_limited;
    int silence_gate_active;
} DspAutoGainMeter;

DSP_API const char* dsp_version(void);
DSP_API DspEngine* dsp_create(const DspConfig* cfg);
DSP_API void       dsp_destroy(DspEngine* eng);
DSP_API DspError   dsp_reset(DspEngine* eng);
DSP_API DspError   dsp_set_sample_rate(DspEngine* eng, float rate);
DSP_API DspError   dsp_set_channels(DspEngine* eng, int channels);

/** Master processing gate (bypass when 0). Default on. */
DSP_API DspError dsp_set_processing_enabled(DspEngine* eng, int enable);
DSP_API int      dsp_is_processing_enabled(const DspEngine* eng);

/**
 * Float interleaved process. in/out may alias.
 * Applies any pending control-mailbox changes at block start.
 */
DSP_API DspError dsp_process(DspEngine* eng, const float* in, float* out, int frames);

/**
 * In-place PCM16 interleaved process (Resonate / Media3 path).
 * Converts to float, runs the full pipeline, quantizes back to int16
 * (with engine dither settings when enabled).
 */
DSP_API DspError dsp_process_pcm16(DspEngine* eng, int16_t* interleaved, int frames);

/**
 * SRC then full DSP pipeline. *out_frames is capacity in; written count out.
 * Size out for at least ceil(in_frames / ratio) + 8 frames (more if upsampling).
 * Returns DSP_ERR_OVERFLOW if out is too small to consume all input (partial
 * written samples are still valid and are DSP-processed).
 */
DSP_API DspError dsp_process_src(DspEngine* eng,
                                 const float* in, int in_frames,
                                 float* out, int* out_frames,
                                 float ratio, DspSrcQuality quality);

DSP_API DspError dsp_eq_enable(DspEngine* eng, int enable);
/** Bulk-set up to DSP_EQ_MAX_BANDS bands. Full DspEqBand (freq, gain, q, type) is retained. */
DSP_API DspError dsp_eq_set_bands(DspEngine* eng, const DspEqBand* bands, int count);
DSP_API DspError dsp_eq_set_band(DspEngine* eng, int index, const DspEqBand* band);
DSP_API int      dsp_eq_band_count(const DspEngine* eng);
DSP_API int      dsp_eq_is_enabled(const DspEngine* eng);

DSP_API DspError dsp_dvc_set_gain_db(DspEngine* eng, float gain_db);
DSP_API float    dsp_dvc_get_gain_db(const DspEngine* eng);
DSP_API DspError dsp_dvc_enable(DspEngine* eng, int enable);
DSP_API int      dsp_dvc_is_enabled(const DspEngine* eng);
/**
 * One-pole smoothing on DVC gain changes (avoids zipper noise).
 * enable: non-zero on; time_ms: time constant (typical 10–30; <=0 disables).
 * Coeff is tied to the engine sample rate (recomputed on set_sample_rate).
 */
DSP_API DspError dsp_dvc_set_smoothing(DspEngine* eng, int enable, float time_ms);
DSP_API int      dsp_dvc_get_smoothing(const DspEngine* eng);
DSP_API float    dsp_dvc_get_smoothing_ms(const DspEngine* eng);

/** Separate preamp (linear or dB). Applied before DVC. */
DSP_API DspError dsp_preamp_set_linear(DspEngine* eng, float linear_gain);
DSP_API DspError dsp_preamp_set_db(DspEngine* eng, float gain_db);
DSP_API float    dsp_preamp_get_linear(const DspEngine* eng);
DSP_API float    dsp_preamp_get_db(const DspEngine* eng);

/**
 * Phone-speaker delivery: high-pass + optional virtual-bass harmonics.
 * virtual_bass amount in [0, 1]; ignored when speaker mode is off.
 */
DSP_API DspError dsp_speaker_set_enabled(DspEngine* eng, int enable);
DSP_API int      dsp_speaker_is_enabled(const DspEngine* eng);
DSP_API DspError dsp_speaker_set_virtual_bass(DspEngine* eng, float amount);
DSP_API float    dsp_speaker_get_virtual_bass(const DspEngine* eng);

DSP_API DspError dsp_limiter_enable(DspEngine* eng, int enable);
DSP_API DspError dsp_limiter_set_threshold(DspEngine* eng, float threshold_db);
DSP_API DspError dsp_limiter_set_release(DspEngine* eng, float release_ms);
DSP_API DspError dsp_limiter_set_mode(DspEngine* eng, DspLimiterMode mode);
DSP_API DspError dsp_limiter_set_ceiling(DspEngine* eng, float ceiling_db);
/** Independent high/low ceilings for DSP_LIMITER_TWOBAND (also updates single ceiling). */
DSP_API DspError dsp_limiter_set_ceiling_bands(DspEngine* eng, float high_db, float low_db);
DSP_API DspError dsp_limiter_set_knee_db(DspEngine* eng, float knee_db);
DSP_API DspError dsp_limiter_set_lookahead_ms(DspEngine* eng, float lookahead_ms);
DSP_API DspError dsp_limiter_set_attack_ms(DspEngine* eng, float attack_ms);
/** LR crossover frequency for two-band mode. Safe range [80, 200] Hz. */
DSP_API DspError dsp_limiter_set_crossover_hz(DspEngine* eng, float freq_hz);

DSP_API float    dsp_limiter_get_threshold(const DspEngine* eng);
DSP_API float    dsp_limiter_get_release(const DspEngine* eng);
DSP_API float    dsp_limiter_get_ceiling(const DspEngine* eng);
DSP_API float    dsp_limiter_get_ceiling_high(const DspEngine* eng);
DSP_API float    dsp_limiter_get_ceiling_low(const DspEngine* eng);
DSP_API float    dsp_limiter_get_knee_db(const DspEngine* eng);
DSP_API float    dsp_limiter_get_lookahead_ms(const DspEngine* eng);
DSP_API float    dsp_limiter_get_attack_ms(const DspEngine* eng);
DSP_API float    dsp_limiter_get_crossover_hz(const DspEngine* eng);
DSP_API DspLimiterMode dsp_limiter_get_mode(const DspEngine* eng);
DSP_API int      dsp_limiter_is_enabled(const DspEngine* eng);
DSP_API int      dsp_limiter_get_latency_samples(const DspEngine* eng);

DSP_API float    dsp_limiter_get_gr_db(const DspEngine* eng);
DSP_API float    dsp_limiter_get_gr_peak_db(const DspEngine* eng);
DSP_API DspError dsp_limiter_get_meter(const DspEngine* eng, DspLimiterMeter* out);
DSP_API DspError dsp_limiter_reset_meters(DspEngine* eng);

DSP_API DspError      dsp_dither_enable(DspEngine* eng, int enable);
DSP_API DspError      dsp_dither_set_mode(DspEngine* eng, DspDitherMode mode);
DSP_API DspDitherMode dsp_dither_get_mode(const DspEngine* eng);
DSP_API int           dsp_dither_is_enabled(const DspEngine* eng);

DSP_API DspError dsp_get_stats(DspEngine* eng, DspStats* out);
DSP_API DspError dsp_reset_stats(DspEngine* eng);

/* ---------- Intelligent analysis + auto-bass (v0.5) ---------- */

/**
 * Analyze an interleaved float buffer without engine state.
 * channels in [1, 8]. sample_rate used for bass-energy filter only.
 */
DSP_API DspError dsp_analyze_buffer(const float* interleaved, int frames, int channels,
                                    float sample_rate, DspAnalysisResult* out);

/**
 * Binary-search the maximum low-shelf gain (dB) that keeps true-peak under
 * (ceiling_db - margin_db). shelf_freq_hz typical 60–100. Pure / offline.
 */
DSP_API DspError dsp_probe_max_bass_gain_db(const float* interleaved, int frames, int channels,
                                           float sample_rate, float shelf_freq_hz,
                                           float ceiling_db, float margin_db,
                                           float* out_max_gain_db);

DSP_API DspError dsp_get_level_meter(const DspEngine* eng, DspLevelMeter* out);
DSP_API DspError dsp_reset_level_meters(DspEngine* eng);

/**
 * Online auto-bass: dedicated low-shelf after user EQ.
 * applied_db tracks min(target_db, headroom_db - margin_db), smoothed.
 * Does not disable the limiter — it remains the hard ceiling.
 */
DSP_API DspError dsp_auto_bass_enable(DspEngine* eng, int enable);
DSP_API int      dsp_auto_bass_is_enabled(const DspEngine* eng);
DSP_API DspError dsp_auto_bass_set_target_db(DspEngine* eng, float target_shelf_db);
DSP_API float    dsp_auto_bass_get_target_db(const DspEngine* eng);
DSP_API DspError dsp_auto_bass_set_margin_db(DspEngine* eng, float margin_db);
DSP_API float    dsp_auto_bass_get_margin_db(const DspEngine* eng);
DSP_API DspError dsp_auto_bass_set_freq_hz(DspEngine* eng, float freq_hz);
DSP_API float    dsp_auto_bass_get_freq_hz(const DspEngine* eng);
DSP_API float    dsp_auto_bass_get_applied_db(const DspEngine* eng);

/**
 * Online auto-DVC / auto-gain (item 5): drives DVC so short-term RMS approaches
 * target_rms_db + bias_db. Boost is further limited by headroom − margin so the
 * limiter is not forced into constant GR. When enabled, auto-gain owns DVC gain
 * (manual dsp_dvc_set_gain_db is treated as bias if you also set bias, or is
 * overwritten each block — prefer bias API while auto-gain is on).
 *
 * target_rms_db: typical −20 … −14 dBFS short-term
 * max_boost_db / max_cut_db: clamp on the correction
 * window_ms: RMS integration time (200–3000; default 400)
 */
DSP_API DspError dsp_auto_gain_enable(DspEngine* eng, int enable);
DSP_API int      dsp_auto_gain_is_enabled(const DspEngine* eng);
DSP_API DspError dsp_auto_gain_set_target_rms_db(DspEngine* eng, float target_rms_db);
DSP_API float    dsp_auto_gain_get_target_rms_db(const DspEngine* eng);
DSP_API DspError dsp_auto_gain_set_bias_db(DspEngine* eng, float bias_db);
DSP_API float    dsp_auto_gain_get_bias_db(const DspEngine* eng);
DSP_API DspError dsp_auto_gain_set_max_boost_db(DspEngine* eng, float max_boost_db);
DSP_API float    dsp_auto_gain_get_max_boost_db(const DspEngine* eng);
DSP_API DspError dsp_auto_gain_set_max_cut_db(DspEngine* eng, float max_cut_db);
DSP_API float    dsp_auto_gain_get_max_cut_db(const DspEngine* eng);
DSP_API DspError dsp_auto_gain_set_window_ms(DspEngine* eng, float window_ms);
DSP_API float    dsp_auto_gain_get_window_ms(const DspEngine* eng);
DSP_API float    dsp_auto_gain_get_applied_db(const DspEngine* eng);
DSP_API float    dsp_get_short_term_rms_db(const DspEngine* eng);
DSP_API DspError dsp_auto_gain_get_meter(const DspEngine* eng, DspAutoGainMeter* out);

/* ---------- Extended intelligence (v0.6) ---------- */

/**
 * Shared headroom budget weights (normalized internally).
 * bass / preamp / gain share the available headroom so they do not all
 * spend the full margin independently. Defaults: 0.50 / 0.20 / 0.30.
 */
DSP_API DspError dsp_headroom_budget_set(DspEngine* eng,
                                         float bass_weight,
                                         float preamp_weight,
                                         float gain_weight);
DSP_API DspError dsp_headroom_budget_get(const DspEngine* eng,
                                         float* bass_weight,
                                         float* preamp_weight,
                                         float* gain_weight);

/**
 * Clip-aware auto-preamp: servos preamp dB toward target, capped by its
 * share of headroom. Independent of user preamp when disabled.
 */
DSP_API DspError dsp_auto_preamp_enable(DspEngine* eng, int enable);
DSP_API int      dsp_auto_preamp_is_enabled(const DspEngine* eng);
DSP_API DspError dsp_auto_preamp_set_target_db(DspEngine* eng, float target_db);
DSP_API float    dsp_auto_preamp_get_target_db(const DspEngine* eng);
DSP_API float    dsp_auto_preamp_get_applied_db(const DspEngine* eng);

/**
 * Content-aware virtual bass: scales speaker VB amount from bass-band energy.
 * When track already has strong sub energy, applied VB is reduced.
 * target_amount in [0,1] is the maximum when content is bass-light.
 */
DSP_API DspError dsp_auto_vb_enable(DspEngine* eng, int enable);
DSP_API int      dsp_auto_vb_is_enabled(const DspEngine* eng);
DSP_API DspError dsp_auto_vb_set_target(DspEngine* eng, float target_amount);
DSP_API float    dsp_auto_vb_get_target(const DspEngine* eng);
DSP_API float    dsp_auto_vb_get_applied(const DspEngine* eng);

/**
 * Crest-based limiter personality from offline analysis (or live estimate).
 * High crest (dynamic) → slightly higher ceiling / slower release.
 * Low crest (dense) → tighter ceiling / faster release.
 * Pass crest_db from DspAnalysisResult.crest_db; 0 disables override.
 */
DSP_API DspError dsp_limiter_set_crest_hint(DspEngine* eng, float crest_db);
DSP_API float    dsp_limiter_get_crest_hint(const DspEngine* eng);

/**
 * Feed offline analysis into the live engine (bass energy, crest, optional
 * max safe bass). Safe to call from UI thread; applied next process block.
 */
DSP_API DspError dsp_apply_analysis_hint(DspEngine* eng, const DspAnalysisResult* analysis,
                                         float max_safe_bass_db);

/**
 * Silence hygiene: when short-term RMS stays below threshold for hold_ms,
 * decay auto-applied gains and ease limiter GR peak-hold. Reduces “stuck”
 * meters and gain across gaps / track changes.
 */
DSP_API DspError dsp_silence_hygiene_enable(DspEngine* eng, int enable);
DSP_API int      dsp_silence_hygiene_is_enabled(const DspEngine* eng);
DSP_API DspError dsp_silence_hygiene_set_threshold_db(DspEngine* eng, float rms_db);
DSP_API DspError dsp_silence_hygiene_set_hold_ms(DspEngine* eng, float hold_ms);

DSP_API int dsp_set_realtime_priority(DspEngine* eng, int priority);

typedef struct DspBackend DspBackend;
typedef struct {
    int sample_rate;
    int channels;
    int buffer_frames;
    int exclusive;
    int device_id;
} DspBackendConfig;
typedef void (*DspRenderCallback)(void* user, float* out, int frames);

DSP_API DspBackend* dsp_backend_create(void);
DSP_API void        dsp_backend_destroy(DspBackend* be);
DSP_API DspError dsp_backend_open(DspBackend* be, const DspBackendConfig* cfg);
DSP_API void     dsp_backend_close(DspBackend* be);
DSP_API DspError dsp_backend_start(DspBackend* be, DspRenderCallback cb, void* user);
DSP_API DspError dsp_backend_stop(DspBackend* be);
DSP_API int  dsp_backend_is_running(const DspBackend* be);
DSP_API int  dsp_backend_xrun_count(const DspBackend* be);
DSP_API int  dsp_backend_actual_rate(const DspBackend* be);
DSP_API int  dsp_backend_actual_channels(const DspBackend* be);
DSP_API int  dsp_backend_actual_buffer_frames(const DspBackend* be);

#ifdef __cplusplus
}
#endif

#endif /* DSP_ENGINE_H */
