#pragma once
/*
 * Psychic deterministic, advisory-only whole-track intelligence.
 * Host/background-only; never referenced by the audio callback.
 */
#include "track_analyzer.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace dsp {
enum class TrackTrait : uint32_t {
    LowLevelQuiet, ConsistentlyLoud, HighDynamicRange,
    BassProminent, TransientRich, SectionVariable
};
enum class TrackRecommendation : uint32_t {
    ReviewPlaybackLevel, UseConservativeGainControl, PreserveDynamicRange,
    ReviewLowFrequencyEnhancement, KeepTransientProtection,
    ReviewSectionAwareBehaviour
};
struct TrackIntelligenceFinding {
    TrackTrait trait = TrackTrait::LowLevelQuiet;
    float confidence = 0.f;
    float primary_evidence = 0.f;
    float secondary_evidence = 0.f;
};
struct TrackIntelligenceAdvice {
    TrackRecommendation recommendation = TrackRecommendation::ReviewPlaybackLevel;
    float confidence = 0.f;
    TrackTrait supporting_trait = TrackTrait::LowLevelQuiet;
};
struct TrackIntelligenceReport {
    bool sufficient_data = false;
    std::size_t finding_count = 0;
    std::size_t recommendation_count = 0;
    std::array<TrackIntelligenceFinding, 6> findings{};
    std::array<TrackIntelligenceAdvice, 6> recommendations{};
};

class AdaptiveTrackIntelligence {
public:
    static TrackIntelligenceReport analyze(const TrackAnalysisSummary& s) noexcept {
        TrackIntelligenceReport out{};
        if (!valid_summary(s)) return out;
        if (s.active_seconds < kMinimumActiveSeconds ||
            s.duration_seconds < kMinimumDurationSeconds) return out;
        out.sufficient_data = true;

        add(out, TrackTrait::LowLevelQuiet,
            ramp(kQuietStartDb - s.integrated_rms_db, 0.f, kQuietRangeDb),
            s.integrated_rms_db, s.loudness_p50_db);

        const float loudness_score = ramp(s.loudness_p50_db - kLoudStartDb,
                                          0.f, kLoudRangeDb);
        const float consistency_score = 1.f - ramp(s.loudness_range_db -
            kConsistentRangeStartDb, 0.f, kConsistentRangeWidthDb);
        add(out, TrackTrait::ConsistentlyLoud,
            std::min(loudness_score, consistency_score),
            s.loudness_p50_db, s.loudness_range_db);

        add(out, TrackTrait::HighDynamicRange,
            ramp(s.loudness_range_db - kDynamicRangeStartDb, 0.f,
                 kDynamicRangeWidthDb), s.loudness_range_db, s.mean_crest_db);

        add(out, TrackTrait::BassProminent,
            ramp(s.bass_prominence_db - kBassStartDb, 0.f, kBassRangeDb),
            s.bass_prominence_db, s.bass_rms_db);

        const float crest_score = ramp(s.crest_p90_db - kCrestStartDb,
                                       0.f, kCrestRangeDb);
        const float density_score = ramp(s.high_crest_seconds_ratio -
            kCrestDensityStart, 0.f, kCrestDensityRange);
        add(out, TrackTrait::TransientRich, std::min(crest_score, density_score),
            s.crest_p90_db, s.high_crest_seconds_ratio);

        const float transition_ratio = static_cast<float>(
            s.transition_seconds / std::max(0.001, s.active_seconds));
        const float transition_score = ramp(transition_ratio -
            kTransitionRatioStart, 0.f, kTransitionRatioRange);
        add(out, TrackTrait::SectionVariable, std::min(transition_score,
            ramp(static_cast<float>(s.transition_seconds) -
                 kTransitionSecondsStart, 0.f, kTransitionSecondsRange)),
            transition_ratio, static_cast<float>(s.transition_seconds));

        for (std::size_t i = 0; i < out.finding_count; ++i)
            recommend(out, out.findings[i]);
        return out;
    }

    static const char* trait_name(TrackTrait t) noexcept {
        switch (t) {
        case TrackTrait::LowLevelQuiet: return "low_level_quiet";
        case TrackTrait::ConsistentlyLoud: return "consistently_loud";
        case TrackTrait::HighDynamicRange: return "high_dynamic_range";
        case TrackTrait::BassProminent: return "bass_prominent";
        case TrackTrait::TransientRich: return "transient_rich";
        case TrackTrait::SectionVariable: return "section_variable";
        }
        return "unknown";
    }
    static const char* recommendation_text(TrackRecommendation r) noexcept {
        switch (r) {
        case TrackRecommendation::ReviewPlaybackLevel:
            return "Review playback level; do not assume normalization is needed.";
        case TrackRecommendation::UseConservativeGainControl:
            return "Use conservative gain reduction and verify by listening.";
        case TrackRecommendation::PreserveDynamicRange:
            return "Preserve level variation; avoid aggressive compression.";
        case TrackRecommendation::ReviewLowFrequencyEnhancement:
            return "Review bass enhancement against existing low-frequency energy.";
        case TrackRecommendation::KeepTransientProtection:
            return "Retain transient headroom and verify limiter behaviour.";
        case TrackRecommendation::ReviewSectionAwareBehaviour:
            return "Review section-aware control so intentional dynamics are preserved.";
        }
        return "Review measurements before changing processing.";
    }

private:
    static constexpr double kMinimumActiveSeconds = 3.0;
    static constexpr double kMinimumDurationSeconds = 5.0;
    static constexpr float kFindingConfidenceFloor = 0.25f;
    static constexpr float kQuietStartDb = -22.f, kQuietRangeDb = 14.f;
    static constexpr float kLoudStartDb = -14.f, kLoudRangeDb = 7.f;
    static constexpr float kConsistentRangeStartDb = 8.f, kConsistentRangeWidthDb = 5.f;
    static constexpr float kDynamicRangeStartDb = 10.f, kDynamicRangeWidthDb = 10.f;
    static constexpr float kBassStartDb = -8.f, kBassRangeDb = 6.f;
    static constexpr float kCrestStartDb = 8.f, kCrestRangeDb = 8.f;
    static constexpr float kCrestDensityStart = 0.08f, kCrestDensityRange = 0.27f;
    static constexpr float kTransitionRatioStart = 0.08f, kTransitionRatioRange = 0.27f;
    static constexpr float kTransitionSecondsStart = 1.5f, kTransitionSecondsRange = 5.f;

    static bool finite_in(float value, float low, float high) noexcept {
        return std::isfinite(value) && value >= low && value <= high;
    }
    static bool valid_summary(const TrackAnalysisSummary& s) noexcept {
        if (!std::isfinite(s.duration_seconds) ||
            !std::isfinite(s.active_seconds) ||
            !std::isfinite(s.silence_seconds) ||
            !std::isfinite(s.rising_seconds) ||
            !std::isfinite(s.falling_seconds) ||
            !std::isfinite(s.transition_seconds)) return false;
        if (s.duration_seconds < 0.0 || s.active_seconds < 0.0 ||
            s.silence_seconds < 0.0 || s.active_seconds > s.duration_seconds ||
            s.silence_seconds > s.duration_seconds ||
            s.transition_seconds < 0.0 ||
            s.transition_seconds > s.active_seconds ||
            s.rising_seconds < 0.0 || s.falling_seconds < 0.0 ||
            s.rising_seconds + s.falling_seconds > s.transition_seconds + 0.01)
            return false;
        if (!finite_in(s.integrated_rms_db, -120.f, 24.f) ||
            !finite_in(s.bass_rms_db, -120.f, 24.f) ||
            !finite_in(s.bass_prominence_db, -144.f, 144.f) ||
            !finite_in(s.sample_peak_db, -120.f, 24.f) ||
            !finite_in(s.mean_crest_db, -144.f, 144.f) ||
            !finite_in(s.max_crest_db, 0.f, 144.f) ||
            !finite_in(s.crest_p90_db, 0.f, 36.f) ||
            !finite_in(s.high_crest_seconds_ratio, 0.f, 1.f) ||
            !finite_in(s.loudness_p10_db, -120.f, 24.f) ||
            !finite_in(s.loudness_p50_db, -120.f, 24.f) ||
            !finite_in(s.loudness_p95_db, -120.f, 24.f) ||
            !finite_in(s.loudness_range_db, 0.f, 144.f)) return false;
        return s.loudness_p10_db <= s.loudness_p50_db &&
               s.loudness_p50_db <= s.loudness_p95_db;
    }
    static float ramp(float v, float start, float width) noexcept {
        return std::max(0.f, std::min(1.f, (v - start) / width));
    }
    static void add(TrackIntelligenceReport& r, TrackTrait t, float c,
                    float primary, float secondary) noexcept {
        c = std::max(0.f, std::min(1.f, c));
        if (!std::isfinite(c) || c < kFindingConfidenceFloor ||
            r.finding_count >= r.findings.size()) return;
        r.findings[r.finding_count++] = TrackIntelligenceFinding{t,c,primary,secondary};
    }
    static void recommend(TrackIntelligenceReport& r,
                          const TrackIntelligenceFinding& f) noexcept {
        TrackRecommendation a;
        switch (f.trait) {
        case TrackTrait::LowLevelQuiet: a=TrackRecommendation::ReviewPlaybackLevel; break;
        case TrackTrait::ConsistentlyLoud: a=TrackRecommendation::UseConservativeGainControl; break;
        case TrackTrait::HighDynamicRange: a=TrackRecommendation::PreserveDynamicRange; break;
        case TrackTrait::BassProminent: a=TrackRecommendation::ReviewLowFrequencyEnhancement; break;
        case TrackTrait::TransientRich: a=TrackRecommendation::KeepTransientProtection; break;
        case TrackTrait::SectionVariable: a=TrackRecommendation::ReviewSectionAwareBehaviour; break;
        }
        if (r.recommendation_count < r.recommendations.size())
            r.recommendations[r.recommendation_count++] =
                TrackIntelligenceAdvice{a,f.confidence,f.trait};
    }
};
} // namespace dsp
