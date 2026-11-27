#pragma once
/*
 * Host-side adapter from a completed whole-track scan to Psychic's existing
 * playback analysis-hint API. This is deliberately not part of the C ABI.
 */
#include "dsp_engine.h"
#include "track_scan_session.h"

#include <algorithm>
#include <cmath>

namespace dsp {

struct TrackPlaybackHint {
    DspAnalysisResult analysis{};
    // 24 dB is the existing C API's sentinel meaning "no safe-bass cap".
    float max_safe_bass_db = 24.f;
};

/*
 * Translate only measurements that the scan actually owns:
 * - bass_rms_db is the scanner's 120 Hz low-pass RMS measurement;
 * - mean_crest_db is its time-weighted mean block crest factor.
 *
 * The scan does not calculate true peak or a safe bass-boost ceiling. Those
 * fields are intentionally not fabricated; dsp_apply_analysis_hint currently
 * consumes only bass_energy_db and crest_db from DspAnalysisResult.
 *
 * Insufficient, incomplete, or malformed scans fail closed. This adapter
 * never changes user EQ, gain targets, or enhancement enablement.
 */
inline bool make_track_playback_hint(const TrackScanSnapshot& scan,
                                     TrackPlaybackHint* out) noexcept {
    if (!out || scan.state != TrackScanState::Completed ||
        !scan.report_ready || !scan.intelligence.sufficient_data)
        return false;

    const auto& s = scan.analysis;
    if (!std::isfinite(s.duration_seconds) ||
        !std::isfinite(s.active_seconds) ||
        !std::isfinite(s.bass_rms_db) ||
        !std::isfinite(s.mean_crest_db) ||
        s.duration_seconds < 5.0 || s.active_seconds < 3.0 ||
        s.active_seconds > s.duration_seconds ||
        s.bass_rms_db < -120.f || s.bass_rms_db > 24.f ||
        s.mean_crest_db < -24.f || s.mean_crest_db > 48.f)
        return false;

    TrackPlaybackHint hint{};
    // dsp_apply_analysis_hint only reads these two fields today.
    hint.analysis.bass_energy_db =
        std::max(-120.f, std::min(24.f, s.bass_rms_db));
    hint.analysis.crest_db =
        std::max(0.f, std::min(24.f, s.mean_crest_db));
    hint.max_safe_bass_db = 24.f; // no probe was run; do not invent a cap
    *out = hint;
    return true;
}

inline DspError apply_track_playback_hint(
    DspEngine* engine, const TrackScanSnapshot& scan) noexcept {
    if (!engine) return DSP_ERR_INVALID_ARG;
    TrackPlaybackHint hint{};
    if (!make_track_playback_hint(scan, &hint))
        return DSP_ERR_INVALID_ARG;
    return dsp_apply_analysis_hint(engine, &hint.analysis,
                                   hint.max_safe_bass_db);
}

} // namespace dsp
