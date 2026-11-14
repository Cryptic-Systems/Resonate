/**
 * DSP ENGINE — Public C ABI
 *
 * Highly optimized 64-bit processing engine with Direct Volume Control (DVC),
 * multi-band parametric EQ, true-peak / two-band limiter, preamp, speaker-mode
 * virtual bass, dither, sample-rate conversion, and optional platform backends.
 *
 * Version 0.4.0 — Resonate integration surface
 *
 * THREAD SAFETY
 * -------------
 * dsp_process / dsp_process_pcm16 / dsp_process_src must run on a single audio
 * thread. Control calls may be issued from any thread: they write into a
 * lock-free mailbox that is applied at the start of the next process block.
 * Meter getters are best-effort snapshots (may tear slightly).
 *
 * Pipeline (when processing enabled):
 *   DC block → EQ → speaker/VB → preamp → DVC → limiter → dither
 *
 * DVC gain changes use optional one-pole smoothing (default ~15 ms when DVC is
 * enabled at create).
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
