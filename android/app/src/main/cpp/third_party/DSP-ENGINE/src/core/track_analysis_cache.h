/*
 * Psychic bounded in-memory cache for completed local track analysis.
 *
 * Host/background-only. The host supplies stable identity and revision
 * metadata; Psychic does not inspect paths, files, tags, or filesystem state.
 */
#pragma once

#include "track_scan_session.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

namespace dsp {

struct TrackCacheIdentity {
    std::string stable_id;
    uint64_t file_size_bytes = 0;
    int64_t modified_time_ns = 0;
    std::string content_fingerprint;

    bool valid() const noexcept { return !stable_id.empty(); }

    bool same_revision(const TrackCacheIdentity& other) const noexcept {
        return stable_id == other.stable_id &&
               file_size_bytes == other.file_size_bytes &&
               modified_time_ns == other.modified_time_ns &&
               content_fingerprint == other.content_fingerprint;
    }
};

struct TrackAnalysisCacheStats {
    std::size_t entries = 0;
    std::size_t capacity = 0;
    uint64_t hits = 0;
    uint64_t misses = 0;
    uint64_t stale_invalidations = 0;
    uint64_t evictions = 0;
};

/*
 * Bounded LRU cache of completed scan snapshots. No persistence is performed;
 * the host remains responsible for durable storage and media-library events.
 * All methods are synchronized and non-real-time.
 */
class AdaptiveTrackAnalysisCache {
public:
    explicit AdaptiveTrackAnalysisCache(std::size_t capacity = 256) noexcept
        : capacity_(std::max<std::size_t>(1, capacity)) {}

    bool lookup(const TrackCacheIdentity& identity,
                TrackScanSnapshot& out) noexcept {
        if (!identity.valid()) return false;
        std::lock_guard<std::mutex> lock(mutex_);
        for (auto it = entries_.begin(); it != entries_.end(); ++it) {
            if (it->identity.stable_id != identity.stable_id) continue;
            if (!it->identity.same_revision(identity)) {
                entries_.erase(it);
                ++stale_invalidations_;
                ++misses_;
                return false;
            }
            it->last_access = ++clock_;
            out = it->snapshot;
            ++hits_;
            return true;
        }
        ++misses_;
        return false;
    }

    // May allocate while copying host identity or growing the bounded vector;
    // intentionally not noexcept. Call only from host/background code.
    bool store(const TrackCacheIdentity& identity,
               const TrackScanSnapshot& snapshot) {
        if (!identity.valid() ||
            snapshot.state != TrackScanState::Completed ||
            !snapshot.report_ready)
            return false;

        std::lock_guard<std::mutex> lock(mutex_);
        for (auto it = entries_.begin(); it != entries_.end(); ++it) {
            if (it->identity.stable_id != identity.stable_id) continue;
            it->identity = identity;
            it->snapshot = snapshot;
            it->last_access = ++clock_;
            return true;
        }

        Entry entry{};
        entry.identity = identity;
        entry.snapshot = snapshot;
        entry.last_access = ++clock_;
        // Append before eviction so an allocation failure preserves the
        // existing cache contents.
        entries_.push_back(std::move(entry));
        if (entries_.size() > capacity_) {
            const auto oldest = std::min_element(entries_.begin(), entries_.end(),
                [](const Entry& a, const Entry& b) {
                    return a.last_access < b.last_access;
                });
            if (oldest != entries_.end()) {
                entries_.erase(oldest);
                ++evictions_;
            }
        }
        return true;
    }

    bool invalidate(const std::string& stable_id) noexcept {
        if (stable_id.empty()) return false;
        std::lock_guard<std::mutex> lock(mutex_);
        const auto it = std::find_if(entries_.begin(), entries_.end(),
            [&](const Entry& entry) {
                return entry.identity.stable_id == stable_id;
            });
        if (it == entries_.end()) return false;
        entries_.erase(it);
        return true;
    }

    void clear() noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        entries_.clear();
    }

    TrackAnalysisCacheStats stats() const noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        TrackAnalysisCacheStats out{};
        out.entries = entries_.size();
        out.capacity = capacity_;
        out.hits = hits_;
        out.misses = misses_;
        out.stale_invalidations = stale_invalidations_;
        out.evictions = evictions_;
        return out;
    }

private:
    struct Entry {
        TrackCacheIdentity identity;
        TrackScanSnapshot snapshot;
        uint64_t last_access = 0;
    };

    const std::size_t capacity_;
    mutable std::mutex mutex_;
    std::vector<Entry> entries_;
    uint64_t clock_ = 0;
    uint64_t hits_ = 0;
    uint64_t misses_ = 0;
    uint64_t stale_invalidations_ = 0;
    uint64_t evictions_ = 0;
};

} // namespace dsp
