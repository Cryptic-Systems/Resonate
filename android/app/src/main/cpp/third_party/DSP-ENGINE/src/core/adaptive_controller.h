/*
 * Psychic Adaptive Audio Control Engine (AACE)
 *
 * Coordinates automatic gain/headroom decisions without doing audio analysis
 * or touching audio buffers. The caller supplies block measurements and
 * applies the returned targets on the audio thread.
 *
 * Header-only by design: fixed-size state, no allocation, locks, or callbacks.
 */
#pragma once

#include <algorithm>
#include <cmath>
#include <atomic>
#include <cstdint>

namespace dsp {

static_assert(std::atomic<uint32_t>::is_always_lock_free,
              "AACE telemetry requires lock-free 32-bit atomics");
static_assert(std::atomic<float>::is_always_lock_free,
              "AACE telemetry requires lock-free float atomics");

enum AdaptiveSectionTransition : uint32_t {
    kSectionSteady = 0,
    kSectionRising = 1,
    kSectionFalling = 2
};

struct AdaptiveTrackState {
    float short_rms_db = -120.f;
    float long_rms_db = -120.f;
    float bass_rms_db = -120.f;
    float loudness_trend_db = 0.f;
    float bass_prominence_db = -120.f;
    uint32_t section_transition = kSectionSteady;
    float section_transition_confidence = 0.f;
    float anticipatory_gain_hint_db = 0.f;
};

struct AdaptiveHeadroomBudget {
    float available_db = 0.f;
    float budget_peak_db = -120.f;
    float bass_db = 0.f;
    float preamp_db = 0.f;
    float gain_boost_db = 0.f;
};

/*
 * Per-block explanation of adaptive decisions. All payload fields are atomic
 * so readers can inspect a coherent snapshot without racing the audio thread.
 */
enum AdaptiveDecisionReason : uint32_t {
    kDecisionActive          = 1u << 0,
    kDecisionBudgetLimited   = 1u << 1,
    kDecisionSafetyHint      = 1u << 2,
    kDecisionTargetLimited   = 1u << 3,
    kDecisionSilenceRecovery = 1u << 4,
    kDecisionDisabledFade    = 1u << 5,
    kDecisionContentAware    = 1u << 6
};

struct AdaptiveDecisionSnapshot {
    uint32_t block_index = 0;
    uint32_t bass_reasons = 0;
    uint32_t preamp_reasons = 0;
    uint32_t gain_reasons = 0;
    uint32_t virtual_bass_reasons = 0;
    float source_peak_db = -120.f;
    float source_rms_db = -120.f;
    float track_short_rms_db = -120.f;
    float track_long_rms_db = -120.f;
    float track_bass_rms_db = -120.f;
    float track_loudness_trend_db = 0.f;
    float track_bass_prominence_db = -120.f;
    uint32_t section_transition = kSectionSteady;
    float section_transition_confidence = 0.f;
    float anticipatory_gain_hint_db = 0.f;
    float gain_cut_confidence = 0.f;
    float gain_cut_limit_db = 0.f;
    float budget_peak_db = -120.f;
    float control_rms_db = -120.f;
    float output_rms_db = -120.f;
    float available_headroom_db = 0.f;
    float bass_budget_db = 0.f;
    float preamp_budget_db = 0.f;
    float gain_budget_db = 0.f;
    float bass_target_db = 0.f;
    float bass_applied_db = 0.f;
    float preamp_target_db = 0.f;
    float preamp_applied_db = 0.f;
    float gain_target_db = 0.f;
    float gain_applied_db = 0.f;
    float virtual_bass_target = 0.f;
    float virtual_bass_applied = 0.f;
    float limiter_reduction_db = 0.f;
};

class AdaptiveDecisionTelemetry {
public:
    void publish(const AdaptiveDecisionSnapshot& s) noexcept {
        sequence_.fetch_add(1, std::memory_order_acq_rel); // writer active
        block_index_.store(s.block_index, std::memory_order_relaxed);
        bass_reasons_.store(s.bass_reasons, std::memory_order_relaxed);
        preamp_reasons_.store(s.preamp_reasons, std::memory_order_relaxed);
        gain_reasons_.store(s.gain_reasons, std::memory_order_relaxed);
        virtual_bass_reasons_.store(s.virtual_bass_reasons, std::memory_order_relaxed);
        source_peak_db_.store(s.source_peak_db, std::memory_order_relaxed);
        source_rms_db_.store(s.source_rms_db, std::memory_order_relaxed);
        track_short_rms_db_.store(s.track_short_rms_db, std::memory_order_relaxed);
        track_long_rms_db_.store(s.track_long_rms_db, std::memory_order_relaxed);
        track_bass_rms_db_.store(s.track_bass_rms_db, std::memory_order_relaxed);
        track_loudness_trend_db_.store(s.track_loudness_trend_db, std::memory_order_relaxed);
        track_bass_prominence_db_.store(s.track_bass_prominence_db, std::memory_order_relaxed);
        section_transition_.store(s.section_transition, std::memory_order_relaxed);
        section_transition_confidence_.store(s.section_transition_confidence, std::memory_order_relaxed);
        anticipatory_gain_hint_db_.store(s.anticipatory_gain_hint_db, std::memory_order_relaxed);
        gain_cut_confidence_.store(s.gain_cut_confidence, std::memory_order_relaxed);
        gain_cut_limit_db_.store(s.gain_cut_limit_db, std::memory_order_relaxed);
        budget_peak_db_.store(s.budget_peak_db, std::memory_order_relaxed);
        control_rms_db_.store(s.control_rms_db, std::memory_order_relaxed);
        output_rms_db_.store(s.output_rms_db, std::memory_order_relaxed);
        available_headroom_db_.store(s.available_headroom_db, std::memory_order_relaxed);
        bass_budget_db_.store(s.bass_budget_db, std::memory_order_relaxed);
        preamp_budget_db_.store(s.preamp_budget_db, std::memory_order_relaxed);
        gain_budget_db_.store(s.gain_budget_db, std::memory_order_relaxed);
        bass_target_db_.store(s.bass_target_db, std::memory_order_relaxed);
        bass_applied_db_.store(s.bass_applied_db, std::memory_order_relaxed);
        preamp_target_db_.store(s.preamp_target_db, std::memory_order_relaxed);
        preamp_applied_db_.store(s.preamp_applied_db, std::memory_order_relaxed);
        gain_target_db_.store(s.gain_target_db, std::memory_order_relaxed);
        gain_applied_db_.store(s.gain_applied_db, std::memory_order_relaxed);
        virtual_bass_target_.store(s.virtual_bass_target, std::memory_order_relaxed);
        virtual_bass_applied_.store(s.virtual_bass_applied, std::memory_order_relaxed);
        limiter_reduction_db_.store(s.limiter_reduction_db, std::memory_order_relaxed);
        sequence_.fetch_add(1, std::memory_order_release); // publish complete
    }

    bool read(AdaptiveDecisionSnapshot& out) const noexcept {
        for (int attempt = 0; attempt < 3; ++attempt) {
            const uint32_t before = sequence_.load(std::memory_order_acquire);
            if (before == 0 || (before & 1u)) continue;
            out.block_index = block_index_.load(std::memory_order_relaxed);
            out.bass_reasons = bass_reasons_.load(std::memory_order_relaxed);
            out.preamp_reasons = preamp_reasons_.load(std::memory_order_relaxed);
            out.gain_reasons = gain_reasons_.load(std::memory_order_relaxed);
            out.virtual_bass_reasons = virtual_bass_reasons_.load(std::memory_order_relaxed);
            out.source_peak_db = source_peak_db_.load(std::memory_order_relaxed);
            out.source_rms_db = source_rms_db_.load(std::memory_order_relaxed);
            out.track_short_rms_db = track_short_rms_db_.load(std::memory_order_relaxed);
            out.track_long_rms_db = track_long_rms_db_.load(std::memory_order_relaxed);
            out.track_bass_rms_db = track_bass_rms_db_.load(std::memory_order_relaxed);
            out.track_loudness_trend_db = track_loudness_trend_db_.load(std::memory_order_relaxed);
            out.track_bass_prominence_db = track_bass_prominence_db_.load(std::memory_order_relaxed);
            out.section_transition = section_transition_.load(std::memory_order_relaxed);
            out.section_transition_confidence = section_transition_confidence_.load(std::memory_order_relaxed);
            out.anticipatory_gain_hint_db = anticipatory_gain_hint_db_.load(std::memory_order_relaxed);
            out.gain_cut_confidence = gain_cut_confidence_.load(std::memory_order_relaxed);
            out.gain_cut_limit_db = gain_cut_limit_db_.load(std::memory_order_relaxed);
            out.budget_peak_db = budget_peak_db_.load(std::memory_order_relaxed);
            out.control_rms_db = control_rms_db_.load(std::memory_order_relaxed);
            out.output_rms_db = output_rms_db_.load(std::memory_order_relaxed);
            out.available_headroom_db = available_headroom_db_.load(std::memory_order_relaxed);
            out.bass_budget_db = bass_budget_db_.load(std::memory_order_relaxed);
            out.preamp_budget_db = preamp_budget_db_.load(std::memory_order_relaxed);
            out.gain_budget_db = gain_budget_db_.load(std::memory_order_relaxed);
            out.bass_target_db = bass_target_db_.load(std::memory_order_relaxed);
            out.bass_applied_db = bass_applied_db_.load(std::memory_order_relaxed);
            out.preamp_target_db = preamp_target_db_.load(std::memory_order_relaxed);
            out.preamp_applied_db = preamp_applied_db_.load(std::memory_order_relaxed);
            out.gain_target_db = gain_target_db_.load(std::memory_order_relaxed);
            out.gain_applied_db = gain_applied_db_.load(std::memory_order_relaxed);
            out.virtual_bass_target = virtual_bass_target_.load(std::memory_order_relaxed);
            out.virtual_bass_applied = virtual_bass_applied_.load(std::memory_order_relaxed);
            out.limiter_reduction_db = limiter_reduction_db_.load(std::memory_order_relaxed);
            const uint32_t after = sequence_.load(std::memory_order_acquire);
            if (before == after) return true;
        }
        return false;
    }

private:
    std::atomic<uint32_t> sequence_{0};
    std::atomic<uint32_t> block_index_{0};
    std::atomic<uint32_t> bass_reasons_{0}, preamp_reasons_{0}, gain_reasons_{0};
    std::atomic<uint32_t> virtual_bass_reasons_{0};
    std::atomic<float> source_peak_db_{-120.f}, source_rms_db_{-120.f};
    std::atomic<float> track_short_rms_db_{-120.f}, track_long_rms_db_{-120.f};
    std::atomic<float> track_bass_rms_db_{-120.f}, track_loudness_trend_db_{0.f};
    std::atomic<float> track_bass_prominence_db_{-120.f};
    std::atomic<uint32_t> section_transition_{kSectionSteady};
    std::atomic<float> section_transition_confidence_{0.f};
    std::atomic<float> anticipatory_gain_hint_db_{0.f};
    std::atomic<float> gain_cut_confidence_{0.f}, gain_cut_limit_db_{0.f};
    std::atomic<float> budget_peak_db_{-120.f};
    std::atomic<float> control_rms_db_{-120.f}, output_rms_db_{-120.f};
    std::atomic<float> available_headroom_db_{0.f}, bass_budget_db_{0.f};
    std::atomic<float> preamp_budget_db_{0.f}, gain_budget_db_{0.f};
    std::atomic<float> bass_target_db_{0.f}, bass_applied_db_{0.f};
    std::atomic<float> preamp_target_db_{0.f}, preamp_applied_db_{0.f};
    std::atomic<float> gain_target_db_{0.f}, gain_applied_db_{0.f};
    std::atomic<float> virtual_bass_target_{0.f}, virtual_bass_applied_{0.f};
    std::atomic<float> limiter_reduction_db_{0.f};
};

class AdaptiveController {
public:
    void reset() noexcept {
        smoothed_headroom_db_ = 0.f;
        transient_density_ = 0.f;
        track_short_ms_ = track_long_ms_ = track_bass_ms_ = 0.0;
        track_state_initialized_ = false;
        section_transition_confidence_ = 0.f;
        section_transition_candidate_ = 0;
        gain_reference_ms_ = 0.0;
        gain_reference_initialized_ = false;
        gain_cut_confidence_ = 0.f;
        initialized_ = false;
    }

    /*
     * Update compact rolling track state from post-EQ block mean-square
     * measurements. The fast/slow loudness envelopes expose section trends;
     * the bass envelope prevents one kick transient from defining content.
     */
    AdaptiveTrackState update_track_state(double source_mean_square,
                                          double bass_mean_square,
                                          float sample_rate,
                                          int frames) noexcept {
        const double dt = (sample_rate > 0.f && frames > 0)
            ? static_cast<double>(frames) / sample_rate : 0.01;
        const double source_ms = std::max(1.0e-30, source_mean_square);
        const double bass_ms = std::max(1.0e-30, bass_mean_square);
        const double fast_alpha = 1.0 - std::exp(-dt / kTrackFastSeconds);
        const double slow_alpha = 1.0 - std::exp(-dt / kTrackSlowSeconds);
        const double bass_alpha = 1.0 - std::exp(-dt / kTrackBassSeconds);
        if (!track_state_initialized_) {
            track_short_ms_ = source_ms;
            track_long_ms_ = source_ms;
            track_bass_ms_ = bass_ms;
            track_state_initialized_ = true;
        } else {
            track_short_ms_ += fast_alpha * (source_ms - track_short_ms_);
            track_long_ms_ += slow_alpha * (source_ms - track_long_ms_);
            track_bass_ms_ += bass_alpha * (bass_ms - track_bass_ms_);
        }
        AdaptiveTrackState out{};
        out.short_rms_db = static_cast<float>(10.0 * std::log10(std::max(1.0e-30, track_short_ms_)));
        out.long_rms_db = static_cast<float>(10.0 * std::log10(std::max(1.0e-30, track_long_ms_)));
        out.bass_rms_db = static_cast<float>(10.0 * std::log10(std::max(1.0e-30, track_bass_ms_)));
        out.loudness_trend_db = out.short_rms_db - out.long_rms_db;
        out.bass_prominence_db = out.bass_rms_db - out.short_rms_db;

        // Require sustained, meaningful fast/slow level divergence. A single
        // transient barely moves the rolling envelopes and cannot assert a
        // section transition. Confidence is diagnostic; it does not alter gain.
        const float trend_magnitude = std::fabs(out.loudness_trend_db);
        const int direction = trend_magnitude >= kTransitionDirectionFloorDb
            ? (out.loudness_trend_db > 0.f ? 1 : -1) : 0;

        // A direction reversal must earn confidence independently. Do not let
        // a rising section's accumulated confidence instantly label a fall.
        if (direction != 0 && section_transition_candidate_ != 0 &&
            direction != section_transition_candidate_) {
            section_transition_confidence_ = 0.f;
        }
        if (direction != 0) section_transition_candidate_ = direction;

        const float confidence_target = direction == 0 ? 0.f : std::max(0.f,
            std::min(1.f, (trend_magnitude - kTransitionTrendFloorDb) /
                              kTransitionTrendRangeDb));
        const double confidence_tau = confidence_target > section_transition_confidence_
            ? kTransitionConfidenceAttackSeconds
            : kTransitionConfidenceReleaseSeconds;
        const float confidence_alpha = static_cast<float>(
            1.0 - std::exp(-dt / confidence_tau));
        section_transition_confidence_ += confidence_alpha *
            (confidence_target - section_transition_confidence_);
        if (section_transition_confidence_ < 0.01f)
            section_transition_candidate_ = 0;
        out.section_transition_confidence = section_transition_confidence_;
        if (direction != 0 &&
            section_transition_confidence_ >= kTransitionConfidenceThreshold) {
            out.section_transition = direction > 0
                ? kSectionRising : kSectionFalling;
        }
        // Diagnostic-only feed-forward estimate. Positive trend suggests a
        // small anticipatory cut; negative trend suggests a small recovery.
        // It is deliberately not consumed by the gain servo at this stage.
        if (out.section_transition != kSectionSteady) {
            const float raw_hint = -out.loudness_trend_db *
                section_transition_confidence_ * kAnticipatoryGainSensitivity;
            out.anticipatory_gain_hint_db = std::max(
                -kMaxAnticipatoryGainHintDb,
                std::min(kMaxAnticipatoryGainHintDb, raw_hint));
        }
        return out;
    }

    /*
     * Permit gain reduction only when the bass-de-emphasized control level
     * has remained above the requested target. A slow reference rejects
     * short loud sections; section-transition confidence further eases cuts
     * while the programme is changing. Positive gain remains governed by the
     * existing headroom allocator and is unaffected by this policy.
     */
    float update_gain_cut_confidence(float control_rms_db,
                                     float target_rms_db,
                                     float transition_confidence,
                                     float sample_rate,
                                     int frames) noexcept {
        const float dt = (sample_rate > 0.f && frames > 0)
            ? static_cast<float>(frames) / sample_rate : 0.01f;
        const double control_ms = std::pow(10.0,
            static_cast<double>(std::max(-120.f, control_rms_db)) / 10.0);
        if (!gain_reference_initialized_) {
            gain_reference_ms_ = control_ms;
            gain_reference_initialized_ = true;
        } else {
            const double alpha = 1.0 - std::exp(-dt / kGainReferenceSeconds);
            gain_reference_ms_ += alpha * (control_ms - gain_reference_ms_);
        }
        const float sustained_rms_db = static_cast<float>(10.0 * std::log10(
            std::max(1.0e-30, gain_reference_ms_)));
        const float excess_db = sustained_rms_db - target_rms_db -
            kGainCutOnsetMarginDb;
        const float persistence = std::max(0.f, std::min(1.f,
            excess_db / kGainCutFullConfidenceRangeDb));
        const float transition = std::max(0.f, std::min(1.f,
            transition_confidence));
        const float transition_guard = 1.f -
            kGainCutTransitionAttenuation * transition;
        const float target_confidence = persistence * transition_guard;
        const float tau = target_confidence > gain_cut_confidence_
            ? kGainCutConfidenceAttackSeconds
            : kGainCutConfidenceReleaseSeconds;
        const float alpha = 1.f - std::exp(-dt / tau);
        gain_cut_confidence_ += alpha *
            (target_confidence - gain_cut_confidence_);
        gain_cut_confidence_ = std::max(0.f,
            std::min(1.f, gain_cut_confidence_));
        return gain_cut_confidence_;
    }

    /*
     * Allocate positive gain headroom from post-user-EQ peak and RMS. Isolated
     * high-crest events are discounted until recurring events build density.
     * The limiter remains the final safety boundary; this budget governs
     * slower enhancements and never replaces per-sample peak protection.
     */
    AdaptiveHeadroomBudget allocate_headroom(
        float source_peak_db,
        float source_rms_db,
        float ceiling_db,
        float safety_margin_db,
        float bass_weight,
        float preamp_weight,
        float gain_weight,
        float sample_rate,
        int frames) noexcept {

        const float dt = (sample_rate > 0.f && frames > 0)
            ? static_cast<float>(frames) / sample_rate : 0.01f;
        /*
         * High peak-to-RMS crest is initially treated as an isolated transient,
         * not sustained headroom pressure. Repeated high-crest blocks build
         * transient density over time. The limiter protects every sample.
         */
        const float crest_db = source_peak_db - source_rms_db;
        const float transient_excess = std::max(0.f, crest_db - kTransientCrestThresholdDb);
        const float density_tau = transient_excess > 0.f
            ? kTransientDensityAttackSeconds : kTransientDensityReleaseSeconds;
        const float density_alpha = 1.f - std::exp(-dt / density_tau);
        transient_density_ += density_alpha * ((transient_excess > 0.f ? 1.f : 0.f) -
                                                transient_density_);
        transient_density_ = std::max(0.f, std::min(1.f, transient_density_));
        const float budget_peak_db =
            source_peak_db - transient_excess * (1.f - transient_density_);

        const float reserve = std::max(0.f, safety_margin_db) + kTransientReserveDb;
        const float raw_headroom = ceiling_db - budget_peak_db - reserve;

        if (!initialized_) {
            smoothed_headroom_db_ = raw_headroom;
            initialized_ = true;
        } else {
            // Headroom contracts promptly but recovers gradually. This keeps
            // isolated transients from making bass/preamp controls pump.
            const float tau = raw_headroom < smoothed_headroom_db_
                ? kHeadroomAttackSeconds : kHeadroomReleaseSeconds;
            const float alpha = 1.f - std::exp(-dt / tau);
            smoothed_headroom_db_ += alpha * (raw_headroom - smoothed_headroom_db_);
        }

        AdaptiveHeadroomBudget out{};
        out.budget_peak_db = budget_peak_db;
        out.available_db = std::max(0.f, smoothed_headroom_db_);
        float bw = std::max(0.f, bass_weight);
        float pw = std::max(0.f, preamp_weight);
        float gw = std::max(0.f, gain_weight);
        float sum = bw + pw + gw;
        if (sum < 1.0e-6f) {
            bw = 0.5f; pw = 0.2f; gw = 0.3f; sum = 1.f;
        }
        out.bass_db = out.available_db * (bw / sum);
        out.preamp_db = out.available_db * (pw / sum);
        out.gain_boost_db = out.available_db * (gw / sum);
        return out;
    }

    /*
     * Smooth global auto-gain asymmetrically. Cuts are controlled quickly
     * enough to prevent overload, while recovery is deliberately gentler
     * to avoid audible level pumping. Time constants are independent of
     * callback block size (unlike a fixed per-block coefficient).
     */
    float smooth_gain(float current_db, float target_db,
                      float sample_rate, int frames) const noexcept {
        if (sample_rate <= 0.f || frames <= 0) return target_db;
        const float dt = static_cast<float>(frames) / sample_rate;
        const float tau = target_db < current_db
            ? kGainReductionSeconds : kGainRecoverySeconds;
        const float alpha = 1.f - std::exp(-dt / tau);
        return current_db + alpha * (target_db - current_db);
    }

    // Generic block-size-independent smoothing for bass, preamp and VB.
    // Reductions use the shorter time constant; increases ease in more slowly.
    float smooth_parameter(float current, float target, float sample_rate,
                           int frames, float increase_tau,
                           float decrease_tau) const noexcept {
        if (sample_rate <= 0.f || frames <= 0) return target;
        const float dt = static_cast<float>(frames) / sample_rate;
        const float tau = target < current ? decrease_tau : increase_tau;
        const float safe_tau = std::max(0.01f, tau);
        const float alpha = 1.f - std::exp(-dt / safe_tau);
        return current + alpha * (target - current);
    }

private:
    static constexpr double kTrackFastSeconds = 0.45;
    static constexpr double kTrackSlowSeconds = 3.0;
    static constexpr double kTrackBassSeconds = 1.2;
    static constexpr double kTransitionConfidenceAttackSeconds = 0.75;
    static constexpr double kTransitionConfidenceReleaseSeconds = 1.10;
    static constexpr float kTransitionTrendFloorDb = 1.5f;
    static constexpr float kTransitionTrendRangeDb = 6.f;
    static constexpr float kTransitionDirectionFloorDb = 2.0f;
    static constexpr float kTransitionConfidenceThreshold = 0.18f;
    static constexpr float kAnticipatoryGainSensitivity = 0.12f;
    static constexpr float kMaxAnticipatoryGainHintDb = 1.0f;
    static constexpr float kTransientReserveDb = 0.5f;
    static constexpr float kTransientCrestThresholdDb = 12.f;
    static constexpr float kTransientDensityAttackSeconds = 0.35f;
    static constexpr float kTransientDensityReleaseSeconds = 0.80f;
    static constexpr float kHeadroomAttackSeconds = 0.12f;
    static constexpr float kHeadroomReleaseSeconds = 0.45f;
    static constexpr float kGainReductionSeconds = 0.22f;
    static constexpr float kGainRecoverySeconds = 0.38f;
    static constexpr float kGainReferenceSeconds = 3.0f;
    static constexpr float kGainCutOnsetMarginDb = 1.5f;
    static constexpr float kGainCutFullConfidenceRangeDb = 6.0f;
    static constexpr float kGainCutTransitionAttenuation = 0.85f;
    static constexpr float kGainCutConfidenceAttackSeconds = 0.65f;
    static constexpr float kGainCutConfidenceReleaseSeconds = 1.25f;

    float smoothed_headroom_db_ = 0.f;
    float transient_density_ = 0.f;
    double track_short_ms_ = 0.0;
    double track_long_ms_ = 0.0;
    double track_bass_ms_ = 0.0;
    bool track_state_initialized_ = false;
    float section_transition_confidence_ = 0.f;
    int section_transition_candidate_ = 0;
    double gain_reference_ms_ = 0.0;
    bool gain_reference_initialized_ = false;
    float gain_cut_confidence_ = 0.f;
    bool initialized_ = false;
};

} // namespace dsp
