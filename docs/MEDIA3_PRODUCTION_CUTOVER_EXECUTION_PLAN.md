# Resonate — Media3 Production Cutover Execution Plan

> **Target integration branch:** `Resonate-True-Apk`  
> **Migration work:** Previously reviewed as Media3 cutover PR #219. Refresh live PR head/base/checks and branch ancestry before integration.  
> **Objective:** Move the working Android player to one production playback authority without losing current user-visible behavior.

## 1. Non-negotiable rule

**Do not ship a half-migration.** Moving commands to Media3 while observations still come from the legacy player—or moving observations while legacy playback still owns transport—creates two competing truths.

The migration is complete only when the production app has:
- One authoritative Android playback engine/session.
- One canonical playback state projection consumed by Flutter.
- One queue/transport command path.
- Consistent audio focus, audio session, DSP, crossfade, DJ, notification, and lifecycle behavior.
- No reachable production fallback that can unexpectedly start a second player.

Preserve a known-good build and rollback path until the new path passes acceptance.

## 2. Scope inventory

| Responsibility | Required outcome |
|---|---|
| Player lifecycle | Creation, preparation, release, service ownership, process recreation, and disposal are deterministic. |
| Queue | Flutter/native queue identity and order agree; duplicate tracks use occurrence identity, not media ID alone. |
| Index mapping | Unplayable entries, filtering, and native index mapping cannot select the wrong item or corrupt visible queue order. |
| Transport | Play, pause, seek, next, previous, stop, speed, repeat, shuffle use the same authority. |
| Observations | Current item, position, duration, playing/buffering/ended/error state, and queue changes are emitted from Media3 and safely ordered. |
| Audio focus | Gain, loss, transient loss, ducking, and resume policy are deterministic and tested. |
| Audio session | Active deck/session ID is exposed accurately; session changes propagate to DSP/effects. |
| Gain/DSP | Volume, per-deck gain, preamp, EQ, loudness, limiter, and supported processing remain coherent across decks/transitions. |
| Crossfade | Preload, start, equal-power curve, cancellation, pause/resume, seek, queue mutation, and completion are correct. |
| DJ | Planner/executor target the active Media3 session; preload invalidation and manual override are safe. |
| MediaSession | Notification, lock-screen, headset, Bluetooth, and external controls reflect the same state. |
| History/resume | Track starts, progress, completion, and resume positions are neither duplicated nor lost. |
| Modes | Speech/chapter and other mode policies are preserved, including intentional crossfade restrictions. |
| Recovery | Watchdog, error handling, service restart, stale-event rejection, and disposal do not resurrect stale playback. |

## 3. Architecture and ownership contract

### Flutter

Flutter interacts with one playback coordinator/repository contract. UI code must not depend directly on legacy player types or Android Media3 implementation details.

The coordinator owns:
- User-facing queue and transport policy.
- Mapping between library entries, queue occurrences, and native media items.
- Canonical playback snapshot.
- Command serialization and error reporting.
- History/resume event policy.
- Recovery and feature coordination.

It does not decode audio or maintain a second native player.

### Android

The Android service/adapter owns:
- Media3 player instance(s) and lifecycle.
- Android MediaSession and notification integration.
- Audio focus and interruption handling.
- Media-item preparation and native queue execution.
- Audio session IDs and native playback observations.
- Dual-deck orchestration where crossfade/DJ requires it.

Expose a narrow, versioned contract to Flutter. Avoid leaking mutable player internals across the channel.

### State/event rules

1. Every queue entry has a stable occurrence key, even if multiple entries refer to the same file.
2. Every native event is attributable to the current session and, where relevant, current queue revision.
3. Reject stale observations from a released/replaced player or obsolete queue revision.
4. Serialize conflicting commands: seek, skip, queue replacement, preload, crossfade start/cancel, and disposal.
5. Publish state only after the authoritative native operation reaches a defined outcome.
6. Errors are typed and actionable; do not translate every failure into an empty queue or silent no-op.
7. Manual user actions take precedence over DJ/Autopilot work already in progress.
8. Disposal invalidates pending callbacks, preload work, and delayed transition actions.

## 4. Adapter and queue-mapping review

Previous migration review identified adapter behavior worth preserving and covering with tests:
- Filtering unplayable entries while preserving original/native index mapping.
- Duplicate-ID occurrence handling rather than assuming media IDs are unique.
- Rejecting ambiguous matches instead of silently selecting the wrong occurrence.
- Mapping file/content URIs correctly.
- Transactional serialization of partial gain updates.
- Validating that a preloaded crossfade item still matches the intended queue occurrence.

### Queue contract tests

- Empty queue → one item → play.
- One item with repeat-one and repeat-off.
- Duplicate same-file entries at different queue positions.
- Missing/unplayable entry between playable entries.
- Replace queue while a track is playing.
- Insert/remove/move around current occurrence.
- Toggle shuffle while playing and while preload exists.
- Skip/seek while buffering.
- Queue mutation during crossfade.
- Same URI with changed metadata and distinct occurrence keys.
- Content URI permission loss or file removal.
- Rapid repeated next/previous commands.
- Restore queue after process/service recreation.

**Acceptance:** current occurrence and next/previous always match the user-visible queue; no stale preload can play after queue mutation.

## 5. Dual-deck, crossfade, and DJ acceptance

Crossfade is high-risk because both decks, their gain envelopes, and user-visible current-track state must remain synchronized.

### Required behavior

- Preload incoming media without audible output.
- Validate incoming occurrence against latest queue revision before transition.
- Start outgoing/incoming envelopes with intended curve and timing.
- Maintain headroom and avoid clipping or a perceptible gain hole.
- Keep active deck/session identity correct throughout transition.
- Handle pause/resume, seek, skip, cancel, queue replacement, repeat, and backgrounding mid-transition.
- Release/recycle old deck without clicks, stale callbacks, or leaked players.
- Keep notification and history semantics consistent about when current track changes.
- Apply equivalent DSP/gain settings to both decks or document intentional differences.

### Prior reports to reproduce

Earlier review notes called out:
1. A possible audible pre-fade dip near the transition boundary.
2. A DJ incoming-deck stall around a reported 335 ms point.

These are **reproduction targets**, not assumed current defects. For each:
- Record app commit and Android build.
- Record device, Android version, output route, source files, and transition settings.
- Capture preload-ready, transition-start, envelope-update, active-deck-switch, and completion timestamps.
- Capture audio or a reliable output-level trace.
- Repeat at least 20 times per configuration.
- Compare with crossfade disabled and a known-good build.
- Fix underlying timing/state issues, not only visible symptoms.

### Crossfade scenario matrix

| Scenario | Expected result |
|---|---|
| Short track / long crossfade | Explicit policy; no negative or unstable timing. |
| Incoming track fails to prepare | Outgoing continues; error is surfaced; no silence. |
| Pause during fade | Both decks pause consistently and resume correctly. |
| Skip during fade | Transition is safely cancelled/settled and requested occurrence plays. |
| Seek during fade | Defined policy; no stale envelope continues. |
| Queue changes during preload | Old preload is invalidated. |
| Bluetooth route changes | Transition remains coherent or safely cancels. |
| Audio focus loss | Both decks obey the same focus policy. |
| DJ plan becomes stale | Transition is cancelled before affecting playback. |
| Service is disposed | No delayed callback restarts playback. |

## 6. DSP, audio session, and gain staging

A Media3 cutover is not complete if Flutter controls still target a legacy audio session or only one of two active decks.

Validate the full path:

`UI control → coordinator → persistence/policy → platform bridge → active Media3 deck(s) → DSP/effects output`

For each setting verify:
- Read-back equals applied value.
- Persistence and restore work.
- Values are clamped and validated at the boundary.
- Changes reach active and incoming decks as appropriate.
- Session ID changes reconnect session-bound effects.
- Repeated updates do not race or partially overwrite unrelated parameters.
- Errors are visible and recoverable.

Test neutral output, EQ boosts/cuts, preamp, loudness, limiter, bass enhancement, stereo effects, and route changes. Measure clipping/headroom with controlled signals. Confirm disabling optional DSP returns to expected baseline.

## 7. Audio focus, interruptions, and lifecycle

Test:
- Focus gain.
- Transient focus loss and regain.
- Permanent focus loss.
- Duck request and recovery.
- Calls/alarms/assistant interactions where supported.
- Wired headset unplug.
- Bluetooth disconnect, reconnect, and device switch.
- App background/foreground and screen off.
- Notification and lock-screen commands.
- Service/app process recreation and process death.
- Permission revocation and media file removal.
- Rapid user commands during recovery.

Specify expected behavior per case. Do not automatically resume after every focus loss when Android or user intent indicates playback should remain paused.

## 8. MediaSession and external controls

Verify MediaSession reports correct:
- Title, artist, album, artwork, duration, and active item.
- Play/pause state and supported actions.
- Position and playback speed.
- Next/previous behavior under repeat/shuffle.
- State during crossfade and after DJ transition/manual skip.
- State after service disposal, without ghost notifications or stale sessions.

Test Bluetooth headset buttons, car/head-unit controls where available, notification controls, lock screen, and Android system media output UI.

## 9. Legacy engine retirement

Do not remove the legacy dependency or code merely because a Media3 adapter exists.

Retirement sequence:
1. Inventory all production and test references: dependency declarations, provider construction, extensions, tests, and platform channels.
2. Prove all user-visible behavior is served by Media3.
3. Remove legacy production construction and command/observation paths.
4. Remove obsolete adapters and dependency only after no reachable production references remain.
5. Update documentation, dependency/license inventory, and CI.
6. Add a guard test/static check preventing accidental reintroduction of a second production player.

If a temporary fallback is required, it must be explicit, observable, mutually exclusive, and removable. Never allow both engines to own playback concurrently.

## 10. Automated validation gates

Run and record exact repository commands against the candidate commit:
- Flutter format check, static analysis, unit tests, widget tests.
- Android Gradle debug and release builds.
- Kotlin unit and relevant instrumentation tests.
- C++ DSP unit/stress tests.
- Media3 adapter contract tests.
- Queue mapping and duplicate-occurrence tests.
- Crossfade/DJ state-machine tests using deterministic fake clocks where practical.
- Dependency/license checks.
- Release APK size and manifest/permission review.

A green build is necessary but not sufficient. Attach logs or CI links to the migration PR. Do not report tests as passing unless they were run on the exact candidate commit.

## 11. Physical-device acceptance checklist

- [ ] Clean install on supported Android device.
- [ ] Upgrade from last known-good build without losing user data.
- [ ] Scan small and large libraries.
- [ ] Play local files from all supported URI types.
- [ ] Verify queue, duplicate entries, shuffle, repeat, next/previous, seek, speed, resume.
- [ ] Verify background/screen-off playback, notification, lock screen, headset controls.
- [ ] Verify audio focus, ducking, calls/alarms, and recovery.
- [ ] Verify wired/Bluetooth route changes.
- [ ] Verify crossfade repeatedly with varied track lengths/formats.
- [ ] Verify DJ transitions, preload invalidation, and manual override.
- [ ] Verify DSP/gain on both decks during transitions.
- [ ] Verify history/resume correctness without duplicate events.
- [ ] Verify listening modes and intentional crossfade restrictions.
- [ ] Verify missing/corrupt/unsupported media errors.
- [ ] Verify service disposal and recreation.
- [ ] Compare output against known-good build and investigate audible regressions.

Record device model, Android version, app SHA/version, route, test case, result, logs, and any recording for every failure.

## 12. Merge and rollback protocol

### Before merge

1. Confirm target branch is exactly `Resonate-True-Apk`.
2. Confirm migration PR head/base; do not assume an old PR base remains correct.
3. Reconcile ancestry and resolve conflicts on a dedicated integration/PR branch.
4. Review every changed file, including dependency, service, and manifest changes.
5. Confirm CI green and required reviews complete.
6. Complete physical-device acceptance and attach evidence.
7. Confirm no production code path constructs or observes the legacy player.
8. Preserve the last known-good artifact/commit and document rollback.

### Merge

Merge only after all gates pass and the target branch is confirmed. Follow branch protection and repository merge policy. Do not force-push or overwrite the target branch as a shortcut.

### Rollback

- Keep previous known-good artifact and commit reference.
- Define whether rollback is code revert, release rollback, or feature-flag rollback.
- Preserve user library/history data across rollback.
- If persisted data changes, provide a backward-compatible schema or explicit rollback migration.
- Record failure, affected devices/routes, and corrective action before retrying.

## 13. Definition of done

- [ ] Media3 is the sole production playback authority.
- [ ] Queue/transport parity is demonstrated, including duplicate occurrences.
- [ ] Flutter observes one canonical playback snapshot.
- [ ] Audio focus, interruption, service lifecycle, and recovery pass device tests.
- [ ] MediaSession, notification, lock-screen, and Bluetooth controls are correct.
- [ ] Audio session IDs and DSP connect to the active output path.
- [ ] Both decks behave consistently during crossfade and DJ transitions.
- [ ] Crossfade/DJ edge cases have automated coverage and physical-device evidence.
- [ ] History, resume, modes, shuffle, and repeat remain correct.
- [ ] Legacy production playback references/dependency are retired or explicitly justified as test-only.
- [ ] CI, release build, dependency/license checks, and required reviews pass.
- [ ] Known-good artifact and rollback procedure are documented.
- [ ] No unresolved P0 regression remains.

## 14. Immediate work order

1. Refresh current `Resonate-True-Apk` and Media3 migration PR state.
2. Build a source ownership map: every player construction, queue mutation, observation, session ID, focus handler, DSP bridge, crossfade/DJ path, and notification update.
3. Compare migration branch behavior against the working app, not only against migration-branch tests.
4. Close missing ownership items and add contract tests.
5. Reproduce the transition reports on device and fix with measurable evidence.
6. Run automated and physical-device matrix.
7. Review and merge into `Resonate-True-Apk` only when the definition of done is satisfied.
8. After stabilization, execute P1 work in `RESONATE_COMPLETE_AUDIT_AND_ECOSYSTEM_ROADMAP.md`.

**Status note:** This plan does not claim the migration has been built, tested, or merged. It defines the work and evidence required to do so safely.


## 15. Live repository snapshot — 2026-11-12

This section records the repository state checked while preparing this plan. Refresh it before any integration because branch and CI state can change.

| Item | Observed state |
|---|---|
| Target branch | `Resonate-True-Apk` |
| Migration PR | [#219](https://github.com/Cryptic-Systems/Resonate/pull/219) |
| PR state | Open, draft, not merged |
| PR base | `media3-playback-observation-contract` |
| PR head | `media3-remove-just-audio-cutover` at `46e33ba6b93f02745d3491a9cc22d9c7df9df094` |
| PR scope | 170 commits, 31 changed files relative to its current PR base |
| Observed workflow | One `Resonate CI` run for the head, run #1365, completed successfully |
| Combined commit status API | Returned no individual status entries in this check |

### Important integration finding

A direct comparison of `media3-remove-just-audio-cutover` against `Resonate-True-Apk` reported divergent history: 345 commits ahead and 5 behind. The compare also included files that are not part of PR #219's own changed-file list. **Do not retarget or merge PR #219 directly into `Resonate-True-Apk` without first reconciling the branch ancestry and reviewing the complete target-relative diff.**

The PR's isolated Media3 session/runtime/adapter work and Kotlin queue/crossfade additions are useful progress. However, at the reviewed head:
- The production `MusicProvider` still constructs `EnginePair` and exposes the legacy `AudioPlayer` instances.
- The provider still imports `just_audio`; the PR head's `pubspec.yaml` also still contains `just_audio` as a transitional dependency.
- The PR's changed-file list does not include `lib/providers/music_provider.dart` relative to its PR base. The target-relative comparison shows only a small provider change associated with the observation boundary; it does not establish complete production provider injection.
- Crossfade and DJ orchestration in the production provider still consumes outgoing/incoming legacy player objects. The Media3 session needs an explicit per-deck transition/effects contract before those paths can be safely transferred.

Therefore, the successful workflow run is evidence that the PR head passed that workflow—not evidence that production playback has cut over, that the legacy engine is removed, or that device behavior is correct.

### Next integration action

Create or use a dedicated integration branch **from the current `Resonate-True-Apk` tip**, then port/reconcile the Media3 work in controlled slices. First wire a testable session boundary into production provider construction and observations; then move transport/queue; then focus/audio-session/DSP; then crossfade/DJ and media controls; finally remove legacy engine references and dependency. At every slice, preserve a known-good build and run the relevant tests. Do not import unrelated branch history simply to make the old PR mergeable.


## 16. Release diagnostics review — 2026-11-12

Source: user-supplied Resonate Android release diagnostics, report version 5, session `1792939478018408_android`, created 2026-11-12. The report contains 4,000 events spanning 2026-11-10 20:06 through 2026-11-12 13:49. This is runtime evidence from the currently installed release build, not a Media3 migration build or a controlled laboratory test.

### Observed healthy behavior

| Signal | Report evidence | Migration implication |
|---|---|---|
| Crashes/errors | 0 crashes; `topErrors` empty | No crash-driven emergency patch is justified by this report. |
| Playback start | 21 begin → source-start → source-done → play-loop-start → play-loop-end sequences; 21 handoffs report `playing=true`; no play timeouts | Preserve the successful start/handoff contract and compare Media3 against it. |
| Intent consistency | 0 `wantPlay` mismatches; 0 stops while upcoming songs remain | Keep desired-play intent and queue progression explicit in the canonical session state. |
| Crossfade | 6 transitions committed; each pre-fade check reports outgoing volume 1.0, incoming volume 0.0, and outgoing delta 0.0; all six final active decks are playing at volume 1.0 | The earlier suspected pre-fade dip is not reproduced in these six captured transitions. Retain as a regression scenario, not a confirmed current defect. |
| DJ | 5 V2 executions and 5 V2 handoffs prepared; 10 applied, 1 skipped, 0 failures; health hint says handoffs OK | Do not prioritize a speculative incoming-deck stall fix. Preserve planner/executor and manual-override semantics in the migration. |
| Completion | 5 completion detections; 4 recovered by continuing the committed track; the one separately logged queue-advance attempt advanced successfully with 0 failed tracks | Test Media3 completion callbacks against both crossfade-committed and ordinary completion paths. |

The 21 observed source preparations took 517–1,970 ms from `set_source_start` to `set_source_done` (median approximately 738 ms). These are measurements from this diagnostic session and should be treated as a baseline for same-device comparisons, not as a universal performance target.

### Areas to investigate, not confirmed defects

1. **Audio focus and route lifecycle.** Fourteen `audio_focus_pause` records all show `userWantsPlaying=false` and `preservedIntent=false`; the report does not establish that these were unexpected focus losses. Ten route-change records are present: nine while the app reports playback not wanted/not playing, and one while playback is wanted/playing. That playing route change is followed by one successful recovery record (`playing=true`, volume 1.0). Add structured focus-change reason/type, focus request result, route identity, and resume-decision reason to the migration acceptance telemetry.
2. **Diagnostics coverage.** The report contains zero playback checkpoints and zero player snapshots. It therefore cannot independently prove continuous player state between handoffs or diagnose an intermittent silent-output report. Add bounded, privacy-safe checkpoints around focus, route, deck activation, MediaSession state, and recovery. Avoid logging personal media metadata.
3. **Intelligence workload.** There are 1,651 `intelligence_recommendations_generated` events, with hourly concentrations of 396 and 275 in two observed hours. This may reflect intended Autopilot reevaluation; the report alone cannot establish CPU/battery impact or a bug. Profile recommendation generation and add reason/trigger, duration, cache-hit, and result-change telemetry before changing its cadence.
4. **DJ metadata coverage.** There are 133 `no_tags` outcomes, plus one risk-based fallback and one BPM-delta skip. These are not counted as DJ failures. Preserve safe fallback behavior and separately measure metadata availability so missing tags are not mistaken for engine failures.

### Updated migration priorities from this report

- **P0 — maintain single ownership:** the report supports retaining the legacy production path until Media3 can reproduce the observed queue, handoff, crossfade, completion, focus, and route behavior under one authority. Do not swap transport alone.
- **P0 — add parity tests:** use the six successful crossfades, 21 successful handoffs, five completion detections, and route/focus cases above as regression scenarios. Include repeat-all and the committed-track completion recovery path.
- **P1 — observability parity:** Media3 diagnostics must expose canonical desired-play intent, active deck/session ID, queue occurrence/revision, actual playing/processing state, focus decision, route, preload state, and transition phase. Add checkpoints/snapshots because this report currently has none.
- **P1 — performance measurement:** compare source preparation and preload readiness on the same device/build/route; profile the Autopilot recommendation bursts before tuning them.
- **Not currently evidenced as defects:** pre-fade volume dip, DJ incoming-deck stall, playback timeout, queue stop with upcoming items, player desired-state mismatch, or crash.

### Acceptance additions

- [ ] Reproduce six representative crossfades and verify outgoing remains at intended gain until fade start, incoming is silent before fade, and active deck ends playing at unity gain.
- [ ] Exercise at least 20 deck handoffs and verify every handoff resolves to the intended queue occurrence and correct active audio-session ID.
- [ ] Test completion while a crossfade is in flight; ensure the committed incoming track is not skipped or advanced twice.
- [ ] Test normal completion, repeat-all, and empty/end-of-queue behavior independently.
- [ ] Test explicit pause, transient focus loss, permanent focus loss, ducking, focus regain, route change while paused, and route change while playing. Assert user intent is never overridden.
- [ ] Capture player checkpoints/snapshots and focus/route decision reasons without exposing media titles or personal library content.
- [ ] Compare source preparation/preload latency and recommendation CPU/battery cost on the same physical device and release configuration.

**Interpretation limit:** these diagnostics describe the existing release build only. They do not prove Media3 parity, audio quality, absence of brief audible gaps, OS-level focus correctness, battery impact, or behavior on other devices. No migration code or device test is validated by this report alone.


## 17. Integration foundation port — 2026-11-12

A production-based integration slice has now been ported to `media3-cutover-integration` and opened as draft PR [#220](https://github.com/Cryptic-Systems/Resonate/pull/220).

| Item | Current state |
|---|---|
| Base | `Resonate-True-Apk` at `9319e0c853b5ba3289737dbd9258e5bb70f32a71` |
| Integration branch | `media3-cutover-integration` |
| Draft PR | #220, targets `Resonate-True-Apk` |
| Branch ancestry | 22 commits ahead, 0 behind at comparison time |
| PR contents | 22 files; isolated runtime/backend/session contracts, native service/bridge, queue reconciliation, and tests |
| Production provider | Unchanged; still uses `EnginePair` / `just_audio` |
| Dependency retirement | Not attempted |
| CI | No workflow run or status was visible at the time this section was written; do not treat the port as validated |

The integration slice includes:
- Engine-neutral `PlaybackBackend`, `PlaybackObservationSource`, `PlaybackSnapshot`, and `PlaybackEngineSession` contracts.
- Serialized `Media3PlaybackRuntime`, `Media3ProviderStateBridge`, `Media3ProviderSession`, and `Media3MusicProviderAdapter`.
- The expanded typed Dart client, native Media3 bridge/service, crossfade clock, gain policy, and queue reconciliation policy.
- Adapter, client, runtime, session, state-bridge, and native queue-policy tests.

The existing production baseline already contains the Android Media3 dependency declarations, service manifest entry, and MainActivity bridge registration required by this isolated backend. The port therefore does not alter those files. The older isolated client/bridge/service prototypes were upgraded in place on the integration branch; no production `MusicProvider` import or construction was changed.

### Gate before the next slice

1. Obtain CI results for draft PR #220 on the exact head commit.
2. Resolve any analyzer, Kotlin, JVM test, or Android build failures before provider work.
3. Review queue occurrence mapping, service startup/reconnect, crossfade cancellation, active audio-session changes, and DSP gain composition against the report-derived acceptance cases in section 16.
4. Only then introduce an injectable session ownership seam in `MusicProvider`; do not switch the production authority in that same change.
5. Keep PR #220 draft and do not merge until provider integration and device acceptance are complete.
