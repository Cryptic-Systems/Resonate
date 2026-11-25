/*
 * Psychic host-side incremental track scan session.
 *
 * Owns no decoded audio. A host decoder feeds measurements or decoded PCM
 * from a worker thread; snapshots may be read concurrently by host/UI code.
 * Never call this from the real-time DSP callback.
 */
#pragma once

#include "track_analyzer.h"
#include "track_intelligence.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <mutex>

namespace dsp {

enum class TrackScanState : uint32_t {
    Idle = 0,
    Scanning,
    Completed,
    Cancelled
};

struct TrackScanSnapshot {
    TrackScanState state = TrackScanState::Idle;
    double expected_duration_seconds = 0.0;
    double processed_duration_seconds = 0.0;
    float progress = 0.f;
    bool report_ready = false;
    TrackAnalysisSummary analysis{};
    TrackIntelligenceReport intelligence{};
};

/*
 * Background-only lifecycle:
 *   begin(expected_duration) -> add_block(...) OR add_audio_block(...)
 *   zero or more times -> finalize() OR cancel().
 *
 * add_audio_block accepts interleaved float PCM (1-8 channels, 8-384 kHz)
 * and calculates full-band RMS, sample peak, and 120 Hz low-pass RMS. The
 * decoder and worker scheduler remain host-owned. No PCM is retained.
 *
 * A single producer should feed blocks; snapshots may be read concurrently.
 * The mutex is intentionally acceptable here because this API is not real-time.
 */
class AdaptiveTrackScanSession {
public:
    bool begin(double expected_duration_seconds = 0.0) noexcept {
        if (!std::isfinite(expected_duration_seconds) ||
            expected_duration_seconds < 0.0) return false;
        std::lock_guard<std::mutex> lock(mutex_);
        if (state_ == TrackScanState::Scanning) return false;
        analyzer_.reset();
        bass_filter_state_.fill(0.0);
        filter_sample_rate_ = 0.0;
        expected_duration_seconds_ = expected_duration_seconds;
        processed_duration_seconds_ = 0.0;
        intelligence_ = TrackIntelligenceReport{};
        state_ = TrackScanState::Scanning;
        return true;
    }

    // Feed precomputed measurements when the host already has a validated
    // analysis path. dB values are sanitized by AdaptiveTrackAnalyzer.
    bool add_block(float rms_db, float peak_db, float bass_rms_db,
                   double duration_seconds, uint32_t transition = 0,
                   float transition_confidence = 0.f) noexcept {
        if (!std::isfinite(duration_seconds) || duration_seconds <= 0.0)
            return false;
        std::lock_guard<std::mutex> lock(mutex_);
        if (state_ != TrackScanState::Scanning) return false;
        analyzer_.add_block(rms_db, peak_db, bass_rms_db, duration_seconds,
                            transition, transition_confidence);
        processed_duration_seconds_ += duration_seconds;
        return true;
    }

    // Interleaved float PCM. This method is for host/background analysis only.
    bool add_audio_block(const float* interleaved, std::size_t frames,
                         uint32_t channels, double sample_rate,
                         uint32_t transition = 0,
                         float transition_confidence = 0.f) noexcept {
        if (!interleaved || frames == 0 || channels == 0 || channels > 8 ||
            !std::isfinite(sample_rate) || sample_rate < 8000.0 ||
            sample_rate > 384000.0 ||
            frames > static_cast<std::size_t>(-1) / channels)
            return false;

        const double duration = static_cast<double>(frames) / sample_rate;
        if (!std::isfinite(duration) || duration <= 0.0) return false;

        std::lock_guard<std::mutex> lock(mutex_);
        if (state_ != TrackScanState::Scanning) return false;

        // Reset filter history if the host changes stream sample rate.
        if (filter_sample_rate_ != sample_rate) {
            bass_filter_state_.fill(0.0);
            filter_sample_rate_ = sample_rate;
        }

        constexpr double kBassCutoffHz = 120.0;
        const double alpha = std::exp(
            -2.0 * 3.14159265358979323846 * kBassCutoffHz / sample_rate);
        double sum_squares = 0.0;
        double bass_sum_squares = 0.0;
        double peak = 0.0;
        const std::size_t sample_count = frames * channels;

        for (std::size_t frame = 0; frame < frames; ++frame) {
            for (uint32_t channel = 0; channel < channels; ++channel) {
                const std::size_t index = frame * channels + channel;
                const double raw = std::isfinite(interleaved[index])
                    ? static_cast<double>(interleaved[index]) : 0.0;
                const double magnitude = std::fabs(raw);
                peak = std::max(peak, magnitude);
                sum_squares += raw * raw;

                double& low_state = bass_filter_state_[channel];
                low_state = (1.0 - alpha) * raw + alpha * low_state;
                bass_sum_squares += low_state * low_state;
            }
        }

        const double mean_square = sum_squares /
                                   static_cast<double>(sample_count);
        const double bass_mean_square = bass_sum_squares /
                                        static_cast<double>(sample_count);
        const auto to_db = [](double power) noexcept {
            return power > 1.0e-24
                ? static_cast<float>(10.0 * std::log10(power)) : -120.0f;
        };
        const float rms_db = to_db(mean_square);
        const float bass_rms_db = to_db(bass_mean_square);
        const float peak_db = peak > 1.0e-12
            ? static_cast<float>(20.0 * std::log10(peak)) : -120.0f;

        analyzer_.add_block(rms_db, peak_db, bass_rms_db, duration,
                            transition, transition_confidence);
        processed_duration_seconds_ += duration;
        return true;
    }

    bool finalize() noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        if (state_ != TrackScanState::Scanning) return false;
        intelligence_ = AdaptiveTrackIntelligence::analyze(analyzer_.summary());
        state_ = TrackScanState::Completed;
        return true;
    }

    bool cancel() noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        if (state_ != TrackScanState::Scanning) return false;
        state_ = TrackScanState::Cancelled;
        intelligence_ = TrackIntelligenceReport{};
        return true;
    }

    TrackScanSnapshot snapshot() const noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        TrackScanSnapshot out{};
        out.state = state_;
        out.expected_duration_seconds = expected_duration_seconds_;
        out.processed_duration_seconds = processed_duration_seconds_;
        if (expected_duration_seconds_ > 0.0) {
            const double ratio = processed_duration_seconds_ /
                                 expected_duration_seconds_;
            out.progress = state_ == TrackScanState::Completed ? 1.f :
                static_cast<float>(std::max(0.0, std::min(0.999, ratio)));
        } else if (state_ == TrackScanState::Completed) {
            out.progress = 1.f;
        }
        out.report_ready = state_ == TrackScanState::Completed;
        out.analysis = analyzer_.summary();
        if (out.report_ready) out.intelligence = intelligence_;
        return out;
    }

private:
    mutable std::mutex mutex_;
    AdaptiveTrackAnalyzer analyzer_{};
    TrackIntelligenceReport intelligence_{};
    std::array<double, 8> bass_filter_state_{};
    double filter_sample_rate_ = 0.0;
    TrackScanState state_ = TrackScanState::Idle;
    double expected_duration_seconds_ = 0.0;
    double processed_duration_seconds_ = 0.0;
};

} // namespace dsp
