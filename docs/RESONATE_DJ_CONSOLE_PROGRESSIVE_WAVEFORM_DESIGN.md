# Resonate DJ Console — Progressive Full-Track Waveform Design

**Status:** Phases A–C CI-green (Phase C validated by CI #2590); Phase D scheduling and retention not yet implemented  
**Target branch:** `dj-workspace-development`  
**Scope:** Offline DJ analysis and Console presentation only

## 1. Objective

Replace the current sparse, sampled-window waveform with a progressive, track-wide measured peak envelope. The Console should show useful waveform coverage before a full analysis pass finishes, then converge to complete coverage without decoding on the playback path or retaining decoded PCM in memory.

This is offline analysis only. It must not add a player, alter Media3 state, request audio focus, change DSP routing, or issue transport commands.

## 2. Current baseline

The existing pipeline extracts up to four distributed PCM windows (approximately eight seconds each), converts them into at most 192 normalized peak bins per window, persists those segments in the V2 DJ profile JSON, and renders only measured track-relative intervals. Missing intervals are intentionally left blank. Idle analysis can backfill profiles without waveform coverage.

That design is safe and bounded but cannot guarantee continuous full-track coverage. The current serializer limits waveform segments to 32 and each segment to 256 peaks; the in-memory profile cache is currently an unbounded map. The native PCM method channel returns decoded window bytes to Dart, so a streaming design must not accumulate the whole track's PCM or a whole-track list of intermediate windows.

## 3. Proposed architecture

### 3.1 Chunked extraction

- Decode a track as a sequence of fixed-duration windows, initially targeting 8 seconds per window to align with the existing decoder and seek policy.
- Process each window independently: validate decoder metadata and actual first included presentation timestamp; compute peak bins across all channels; discard the PCM byte buffer before requesting the next window.
- Commit a chunk only after its PCM window has been validated and converted. A failed or unsupported window remains a visible coverage gap; never synthesize peaks.
- Keep peak resolution bounded per chunk (initial target 192 bins; hard cap 256). Store track-relative start/end times from actual decoded timestamps and frame count.
- Use a deterministic chunk index derived from the requested interval, but retain actual decoded interval separately. This allows retrying a missing chunk without pretending seek output began at the requested timestamp.

### 3.2 Persistent storage

Do not keep growing the single profile JSON array as the primary waveform store. Introduce a dedicated waveform-chunk table keyed by `songId + analysisVersion + chunkIndex`, with:
- requested start/end;
- actual decoded start/end;
- sample rate and channel count (for provenance/validation);
- bounded peak payload;
- source fingerprint / duration identity;
- completion timestamp and schema version.

Use a transaction for each chunk write. Partial analysis is durable and can resume after process death. A unique key makes retries idempotent. A completed manifest records expected chunk count and completed chunk indices; it must not label a track complete while any required chunk is missing.

The existing DJ profile remains the home for beat grid, key, sections and other compact metadata. Waveform reads should return only the visible time range plus a small overscan margin, not every chunk for every track.

### 3.3 Progressive rendering

- On Console entry, load cached chunks for the active verified song identity and current visible range.
- Render measured chunks immediately, preserving blank gaps for missing coverage.
- As additional chunks arrive, publish only the changed range or a lightweight immutable snapshot; do not rebuild or deserialize the entire track profile on every chunk.
- Keep the existing canonical playback-position playhead. Waveform scroll/zoom is presentation state and must not seek or mutate playback.
- A stale song identity, changed file fingerprint, changed duration beyond the existing tolerance, or incompatible waveform schema invalidates the affected cache before display.
- Active-deck identity must remain verified by Media3's physical deck mapping; standby never borrows the active deck's waveform.

## 4. Scheduling, cancellation and CPU policy

### 4.1 Eligibility

Waveform generation runs only through the explicit DJ idle-analysis policy. It must not start because the Console was opened, a track was selected, or playback began. Initial policy:
- no active playback;
- no transition in progress;
- app foregrounded and not in lifecycle teardown;
- one decode job globally, one chunk at a time;
- conservative per-session song/chunk budget;
- yield between chunks so UI and other app work can run.

Do not run full-track waveform decoding while Media3 is playing. Do not run two tracks or two chunks concurrently.

### 4.2 Cancellation and identity fencing

The current native decoder exposes a best-effort cancel method and the Dart analysis service uses a generation counter to prevent subsequent windows and stale persistence. Before chunk streaming is implemented, native cancellation must be audited to determine whether it interrupts the current MediaExtractor/MediaCodec operation or only prevents later work.

Every job carries an immutable identity tuple: song ID, file identity/fingerprint, duration, analysis schema version and job generation. Check it before opening a decoder, after decoder completion, before chunk persistence and before notifying the Console.

A stop request must prevent the next chunk from starting. If an in-flight decoder cannot be interrupted safely, await its settlement and discard its output when the generation or identity is stale. Never use Future.timeout as cancellation.

### 4.3 Memory bounds

- One decoded PCM window at a time; release references immediately after peak extraction.
- No retained PCM in service fields, provider state, database objects or UI models.
- Peak arrays capped at 256 values per chunk.
- Query and render only the visible chunk range plus bounded overscan.
- Bound in-memory waveform chunk cache by both chunk count and approximate bytes; evict least-recently-used chunks while preserving persisted data.
- Bound profile metadata cache separately; avoid allowing a new per-track cache to grow indefinitely.
- Large tracks must not produce a single giant JSON object or a single giant Dart list.

## 5. Cache lifecycle and invalidation

A chunk is reusable only when song ID, source fingerprint (when available), duration identity, analysis version and waveform schema all match. Content URIs may lack a stable filesystem size; use the strongest available source identity and invalidate conservatively when the library reports a changed media identity.

Schema migration must be additive and safe for existing installations. Existing sparse `waveformSegments` remain readable during rollout. The new chunk store can be populated incrementally from idle analysis; it must not force eager migration or re-decode on application startup.

Provide bounded cleanup for orphaned chunks when a song is deleted or replaced. Retention policy must cap storage usage (both per-track and total-library) and must never delete compact DJ profile metadata as a side effect of waveform eviction.

## 6. Failure and UI states

The Console must distinguish:
- no waveform available yet;
- partial measured coverage;
- full measured coverage;
- analysis queued / paused because playback is active;
- unsupported or inaccessible source;
- cancelled / stale identity;
- retryable chunk failure.

A blank region means unknown/unmeasured, not silence. Zero-height measured peaks are valid only when the decoder actually measured zero-valued PCM. No interpolation across gaps and no illustrative waveform presented as measured data.

## 7. Delivery phases and gates

### Phase A — storage and policy primitives
- [x] Define chunk model, manifest and schema migration.
- [x] Add pure validation/identity/cache-budget policies.
- [x] Add focused tests for invalid ranges, mismatched identity, partial manifests and cache bounds.
- [x] Add additive database v9 chunk/manifest tables and range index; preserve the existing profile JSON untouched.
- [x] Delete waveform rows/manifests and existing DJ metadata when a song is explicitly deleted.
- [x] Add database migration/duplicate-write integration coverage and verify deletion cleanup in SQLite tests.
- [x] Audit current native cancellation semantics before enabling long jobs.

**Cancellation audit:** `PcmAnalysisHandler` uses a single-thread executor and a generation token. `cancel()` increments the token; the decoder loop checks it between MediaCodec dequeue operations and checks again before returning PCM. The codec and extractor are released in `finally`. Cancellation does not directly interrupt/stop the currently executing codec call; it is cooperative/best-effort and queued work is invalidated when it starts. Future chunk streaming must await the active window's settlement, discard its result when stale, and never start the next chunk after cancellation. No `Future.timeout` should be used as a substitute.

**SQLite integration coverage:** `test/dj_waveform_database_integration_test.dart` exercises the v8-to-v9 additive migration while preserving legacy song rows, duplicate chunk-key replacement (including changed source fingerprint), SQLite range constraints, and song deletion cleanup. `deleteSong` now performs all dependent-row cleanup and the parent-row deletion in one SQLite transaction, so a failed child cleanup rolls the operation back.

**Gate:** no decoder integration until the focused integration suite and the full CI workflow pass. Device validation is not part of this database-only phase.

### Phase B — chunk extraction and resumability
- [x] Extract one chunk at a time using the existing PCM decoder.
- [x] Convert and persist immediately; drop PCM before the next chunk.
- [x] Resume only missing chunks; stop cleanly between chunks.
- [x] Test non-zero offsets, decoder preroll, short final chunks, failed seeks, malformed PCM, cancellation and process interruption.

**Implementation checkpoint:** `DjWaveformChunkService` is serial, budgeted and explicitly invoked with an eligibility predicate; it does not schedule itself or run when Console opens. The source identity is rechecked before persistence, cancellation is generation-fenced, and SQLite rolls back a chunk plus manifest update if cancellation occurs during the transaction. Decoder coverage must fully cover the requested interval before a manifest index is committed. CI #2566 passed on commit `b88db82936675f6835f240a2265dc1ab6cf9ad47`. Device codec coverage and real-device resource impact remain unverified.

**Gate:** memory bound is demonstrable from code and tests; no concurrent decode; no playback code touched.

### Phase C — range query and progressive Console rendering
- [x] Add visible-range chunk queries with bounded overscan (hard cap: 96 returned chunks / 256 KiB cache budget).
- [x] Render persisted measured chunk intervals in the active verified deck; preserve blank gaps and retain legacy sparse-profile fallback.
- [x] Fence async waveform snapshots by song ID, duration, source path and active physical-deck mapping.
- [x] Add widget tests and coverage classification for loading, partial, complete, stale and unsupported states.
- [x] Add horizontal waveform viewport with chunk-aligned visible-range requests; query only the visible interval plus bounded DB overscan.
- [x] Add pure viewport geometry tests for initial view, scrolled view, short tracks, overscroll and invalid geometry.

**Current UI scope:** the Console waveform is horizontally scrollable at a bounded 3 px/second scale. It requests only the visible time interval, rounded to the 8-second chunk grid; the database adds no more than two chunks of overscan on either side and retains the 96-chunk / 256 KiB hard result bounds. Short tracks fit the viewport and load their full interval. Playback position updates do not invalidate the waveform query; song, source path or duration changes do. The viewport is presentation-only and does not seek or alter playback. Coverage labels describe the visible interval only, never imply whole-track completion. It does not decode or schedule analysis. Widget tests cover pending, partial, complete visible range, stale-song and decoder/storage-error states; viewport policy tests cover initial/scrolled ranges, short tracks, overscroll and invalid geometry.

**Gate:** passed in CI #2590 (commit `af180b402d5042748f03cc2d9fc13aa3097614f1`). Flutter analysis/tests, native DSP compile/unit/integration smoke tests, Android DSP tests, release APK build, integrity/size verification and artifact upload all succeeded. This validates CI behavior only; device codec coverage and playback impact remain unverified.

### Phase D — idle scheduling and retention

**Pre-implementation audit (2026-11-23):**
- `DjIdleAnalysisService` already processes songs serially and awaits each profile analysis; it intentionally avoids `Future.timeout` because that would abandon native work without cancelling it.
- `DjModeProvider` starts the existing profile scan when idle and calls `stop()` when playback begins. The scan is not currently wired to `DjWaveformChunkAnalysisService`, so persisted waveform chunks are not yet progressively generated by the idle loop.
- `DjWaveformChunkAnalysisService` already has a per-invocation chunk budget (default 2, hard cap 4), an idle predicate, generation cancellation, source identity checks and transactional cancellation fencing. Its caller must still provide the authoritative playback/lifecycle predicate and must await each batch.
- The current range reader returns a bounded query result but there is no dedicated in-memory LRU chunk cache. The existing policy has deterministic cache-budget calculations, not an actual cache implementation.
- The database currently has per-track chunk-count bounds and song-deletion cleanup, but no global waveform-storage retention policy. Do not delete profile metadata while evicting waveform chunks.

**Implementation order:**
1. Integrate the chunk producer into the existing serial idle loop, with a hard per-session budget and a live `isStillIdle` predicate; stop and invalidate both profile and chunk work on playback.
2. Add lifecycle foreground gating only after identifying the app's authoritative lifecycle owner; do not infer foreground state from Console visibility.
3. Implement a small LRU for queried peak chunks, bounded by both count and bytes; persisted SQLite rows remain authoritative.
4. Add transactional per-track/global retention with tests proving only waveform rows are evicted.
5. Add diagnostics for eligibility, processed chunks, cancellation, budget exhaustion and retention.

**Gate:** diagnostics prove serial idle work and bounded resource use; user device testing confirms no playback impact. No waveform analysis may start on Console open or while playback/transition is active.

## 8. Explicit non-goals

- No Media3 player, decoder, audio sink or output changes.
- No DSP processing, crossfade, transport, cue, jog, pitch or mixer behavior.
- No full-track decode on Console open.
- No parallel analysis workers.
- No waveform interpolation or synthetic coverage.
- No schema-breaking replacement of existing profile JSON before compatibility tests.

## 9. Acceptance criteria

1. A long track is represented by bounded independent chunks, not a retained whole-track PCM buffer or giant profile JSON.
2. Each committed peak chunk is traceable to a validated decoded PCM interval.
3. Missing/failed intervals remain gaps and are resumable.
4. Cancellation and identity changes cannot persist or display stale chunks.
5. Analysis is serial, idle-only, budgeted and does not begin on Console open.
6. Console progressively renders only the visible range and verified active track.
7. Existing sparse profile caches remain readable during migration.
8. CI covers migration, extraction policy, cache bounds, cancellation, identity fencing and UI states.
9. Physical-device testing confirms the analysis does not affect playback stability or audible output.
