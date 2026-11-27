/*
 * Psychic offline track-analysis accumulator.
 *
 * Host/background-only helper. It consumes block measurements from a decoded
 * track scan and retains bounded statistics; it is never used by dsp_process.
 */
#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstddef>

namespace dsp {

struct TrackAnalysisSummary {
    double duration_seconds = 0.0;
    double active_seconds = 0.0;
    double silence_seconds = 0.0;
    float integrated_rms_db = -120.f;
    float bass_rms_db = -120.f;
    float bass_prominence_db = 0.f;
    float sample_peak_db = -120.f;
    float mean_crest_db = 0.f;
    float max_crest_db = 0.f;
    float crest_p90_db = 0.f;
    float high_crest_seconds_ratio = 0.f;
    float loudness_p10_db = -120.f;
    float loudness_p50_db = -120.f;
    float loudness_p95_db = -120.f;
    float loudness_range_db = 0.f;
    double rising_seconds = 0.0;
    double falling_seconds = 0.0;
    double transition_seconds = 0.0;
};

/*
 * Accumulates per-block measurements using fixed-size loudness histograms.
 * Percentiles are time-weighted over active blocks (RMS > -60 dBFS), avoiding
 * silence from dominating the programme-level loudness distribution.
 */
class AdaptiveTrackAnalyzer {
public:
    void reset() noexcept {
        loudness_histogram_.fill(0.0);
        crest_histogram_.fill(0.0);
        high_crest_seconds_ = 0.0;
        duration_seconds_ = active_seconds_ = silence_seconds_ = 0.0;
        signal_energy_ = bass_energy_ = crest_time_sum_ = 0.0;
        sample_peak_db_ = -120.f;
        max_crest_db_ = 0.f;
        rising_seconds_ = falling_seconds_ = transition_seconds_ = 0.0;
    }

    void add_block(float rms_db, float peak_db, float bass_rms_db,
                   double duration_seconds, uint32_t transition = 0,
                   float transition_confidence = 0.f) noexcept {
        if (!(duration_seconds > 0.0) || !std::isfinite(duration_seconds))
            return;
        const float safe_rms = std::isfinite(rms_db)
            ? std::max(-120.f, std::min(24.f, rms_db)) : -120.f;
        const float safe_peak = std::isfinite(peak_db)
            ? std::max(-120.f, std::min(24.f, peak_db)) : -120.f;
        const float safe_bass = std::isfinite(bass_rms_db)
            ? std::max(-120.f, std::min(24.f, bass_rms_db)) : -120.f;

        duration_seconds_ += duration_seconds;
        sample_peak_db_ = std::max(sample_peak_db_, safe_peak);
        if (safe_rms <= kSilenceThresholdDb) {
            silence_seconds_ += duration_seconds;
        } else {
            active_seconds_ += duration_seconds;
            signal_energy_ += std::pow(10.0, safe_rms / 10.0) * duration_seconds;
            bass_energy_ += std::pow(10.0, safe_bass / 10.0) * duration_seconds;
            const float crest = safe_peak - safe_rms;
            crest_time_sum_ += static_cast<double>(crest) * duration_seconds;
            max_crest_db_ = std::max(max_crest_db_, crest);
            const int crest_bin = crest_histogram_bin(crest);
            crest_histogram_[static_cast<std::size_t>(crest_bin)] += duration_seconds;
            if (crest >= kHighCrestThresholdDb) high_crest_seconds_ += duration_seconds;
            const int bin = histogram_bin(safe_rms);
            loudness_histogram_[static_cast<std::size_t>(bin)] += duration_seconds;
        }

        const float confidence = std::max(0.f,
            std::min(1.f, std::isfinite(transition_confidence)
                ? transition_confidence : 0.f));
        if (confidence >= kTransitionConfidenceFloor) {
            transition_seconds_ += duration_seconds;
            if (transition == 1) rising_seconds_ += duration_seconds;
            else if (transition == 2) falling_seconds_ += duration_seconds;
        }
    }

    TrackAnalysisSummary summary() const noexcept {
        TrackAnalysisSummary out{};
        out.duration_seconds = duration_seconds_;
        out.active_seconds = active_seconds_;
        out.silence_seconds = silence_seconds_;
        out.sample_peak_db = sample_peak_db_;
        out.max_crest_db = max_crest_db_;
        out.crest_p90_db = crest_percentile(0.90);
        out.high_crest_seconds_ratio = active_seconds_ > 0.0
            ? static_cast<float>(high_crest_seconds_ / active_seconds_) : 0.f;
        out.rising_seconds = rising_seconds_;
        out.falling_seconds = falling_seconds_;
        out.transition_seconds = transition_seconds_;
        if (active_seconds_ <= 0.0) return out;

        out.integrated_rms_db = to_db(signal_energy_ / active_seconds_);
        out.bass_rms_db = to_db(bass_energy_ / active_seconds_);
        out.bass_prominence_db = out.bass_rms_db - out.integrated_rms_db;
        out.mean_crest_db = static_cast<float>(crest_time_sum_ / active_seconds_);
        out.loudness_p10_db = percentile(0.10);
        out.loudness_p50_db = percentile(0.50);
        out.loudness_p95_db = percentile(0.95);
        out.loudness_range_db = std::max(0.f,
            out.loudness_p95_db - out.loudness_p10_db);
        return out;
    }

private:
    static constexpr float kSilenceThresholdDb = -60.f;
    static constexpr float kTransitionConfidenceFloor = 0.18f;
    static constexpr float kHighCrestThresholdDb = 12.f;
    static constexpr int kHistogramMinimumDb = -120;
    static constexpr int kHistogramMaximumDb = 24;
    static constexpr std::size_t kHistogramBins =
        static_cast<std::size_t>(kHistogramMaximumDb - kHistogramMinimumDb + 1);

    static int histogram_bin(float db) noexcept {
        const int rounded = static_cast<int>(std::floor(db + 0.5f));
        return std::max(kHistogramMinimumDb,
            std::min(kHistogramMaximumDb, rounded)) - kHistogramMinimumDb;
    }

    static int crest_histogram_bin(float db) noexcept {
        const int rounded = static_cast<int>(std::floor(db + 0.5f));
        return std::max(0, std::min(36, rounded));
    }

    static float to_db(double energy) noexcept {
        return static_cast<float>(10.0 * std::log10(std::max(1.0e-30, energy)));
    }

    float crest_percentile(double fraction) const noexcept {
        const double target = active_seconds_ * fraction;
        double accumulated = 0.0;
        for (std::size_t i = 0; i < crest_histogram_.size(); ++i) {
            accumulated += crest_histogram_[i];
            if (accumulated >= target) return static_cast<float>(i);
        }
        return 36.f;
    }

    float percentile(double fraction) const noexcept {
        const double target = active_seconds_ * fraction;
        double accumulated = 0.0;
        for (std::size_t i = 0; i < loudness_histogram_.size(); ++i) {
            accumulated += loudness_histogram_[i];
            if (accumulated >= target)
                return static_cast<float>(static_cast<int>(i) +
                                          kHistogramMinimumDb);
        }
        return static_cast<float>(kHistogramMaximumDb);
    }

    std::array<double, kHistogramBins> loudness_histogram_{};
    std::array<double, 37> crest_histogram_{};
    double duration_seconds_ = 0.0;
    double active_seconds_ = 0.0;
    double silence_seconds_ = 0.0;
    double signal_energy_ = 0.0;
    double bass_energy_ = 0.0;
    double crest_time_sum_ = 0.0;
    double high_crest_seconds_ = 0.0;
    float sample_peak_db_ = -120.f;
    float max_crest_db_ = 0.f;
    double rising_seconds_ = 0.0;
    double falling_seconds_ = 0.0;
    double transition_seconds_ = 0.0;
};

} // namespace dsp
