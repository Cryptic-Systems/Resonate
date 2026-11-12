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
