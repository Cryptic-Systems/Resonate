# Resonate — Complete Product & Technical Audit and Ecosystem Roadmap

> **Baseline:** `Resonate-True-Apk`  
> **Intent:** Preserve the functioning Android music player, stabilize its playback foundation, and evolve it into a distinctive, coherent music ecosystem.  
> **Evidence status:** This document consolidates static repository review and product planning. Runtime validation must be performed against the exact candidate commit; this document does not claim tests or device checks have passed.

## 1. Executive direction

Resonate should grow from a capable local-first Android music player into a **personal music environment**: one that makes a listener's own music sound better, feel more personal, and become easier to explore and mix.

The immediate engineering priority is to protect the working application and complete the Android playback-engine transition to one reliable Media3 authority. Feature expansion and ecosystem services should follow—not compete with—that stabilization work.

**Product promise:** *Your music. Your sound. Your flow.*

### Product principles

1. **Local-first:** Core library and playback work without an account or network connection.
2. **Playback before intelligence:** Analysis, visualizers, recommendations, and AI must never make ordinary playback fragile.
3. **One source of truth:** One authoritative owner for queue, transport, current item, and playback lifecycle.
4. **User agency:** Automation is opt-in, explainable, reversible, and subordinate to explicit user actions.
5. **Sound integrity:** DSP changes are measurable, bounded, and consistent across supported playback routes.
6. **Progressive complexity:** Basic listening stays simple; advanced DSP, DJ, and intelligence tools remain discoverable.
7. **Privacy by design:** Local data stays local unless the user explicitly chooses backup, sync, or another connected service.
8. **Incremental delivery:** Preserve working behavior; ship small, testable improvements rather than replacing the app wholesale.

## 2. Current product and codebase assessment

The mature product baseline for this work is `Resonate-True-Apk`, not the older/incomplete default `main` tree. Keep this distinction explicit in engineering, CI, and release workflows.

### Existing capability surface

The mature application and its documentation describe:
- Local audio scanning, folder selection, library browsing, search, playlists, favorites, sorting/filtering, and duplicate discovery.
- Queue management, shuffle/repeat, per-track resume, sleep timer, Bluetooth/media controls, and crossfade behavior.
- Equalizer and sound controls including preamp, bass/width/reverb-related processing, loudness recommendations, and audio automation.
- Native audio/DSP components, including C++ processing paths.
- Optional DJ analysis and transition planning, beat-grid/profile analysis, drift correction, transition risk evaluation, Autopilot, and transition memory.
- Listening modes, visualizations, and the Ask Resonate/orb experience.
- Android background playback and media controls.

These are product assets. Validate and refine them; do not casually discard them.

### Architectural risks and review findings

| Area | Finding / risk | Why it matters |
|---|---|---|
| Playback ownership | Media3 migration work is in progress; the working product branch still has legacy playback integration in its production dependency/provider path. | Two playback authorities can diverge in queue, state, audio sessions, focus, and lifecycle. |
| Provider complexity | Earlier source review measured the central MusicProvider at roughly 3,400 lines, with substantial crossfade logic in an extension file. | File splitting alone does not establish independent ownership or remove shared mutable state. |
| Crossfade/DJ | Prior audit notes identified a possible pre-fade dip and an incoming-deck stall around a reported 335 ms point. | These are reproduction targets, not confirmed current defects until measured on supported hardware. |
| Library scanning | Android MediaStore scanning is reachable through a MethodChannel; verify large queries are dispatched away from the UI thread. | Main-thread scanning can cause jank and ANRs. |
| Scan result semantics | A native scan failure may be represented as an empty result. | Empty library, permission denial, and scan failure must be distinguishable. |
| DSP integration | Sound controls span Flutter, persistence, platform bridges, and native DSP state. | UI state can diverge from the active signal path; dual decks can receive inconsistent settings. |
| Lifecycle/recovery | Audio focus, route changes, background service, and process/service recreation must agree on one playback session. | Reliability must hold outside the foreground screen. |
| Privacy/permissions | Manifest permissions, backup behavior, diagnostics, and optional spectrum capture need clear purpose and consent. | Minimize data access and keep optional features genuinely optional. |
| Release governance | Branches and PRs have used differing integration bases. | A canonical integration branch and release-candidate process prevent accidental regressions. |

### Evidence discipline

Label findings consistently:
- **Source-confirmed:** directly visible in current code/configuration.
- **Runtime-reproduced:** demonstrated with repeatable steps, logs, tests, or device evidence.
- **Risk to validate:** plausible from architecture or earlier review, not yet reproduced.
- **Product proposal:** future capability, not an existing feature.

Do not present a risk as a confirmed defect without a reproducer. Record device model, Android version, app commit, output route, source files, steps, expected/actual behavior, and logs for playback defects.

## 3. Target architecture and ownership

The objective is clear ownership and testable boundaries, not abstraction for its own sake.

| Domain | Owns | Must not own |
|---|---|---|
| App shell | Navigation, lifecycle coordination, dependency wiring | Playback internals |
| Library | Scanning, permissions, indexed metadata, folders, artwork references | Active transport |
| Playback coordinator | Queue, current occurrence, transport policy, repeat/shuffle, recovery policy | UI presentation or AI decisions |
| Android playback adapter | Media3 player/service, audio focus, MediaSession, notifications, audio session IDs | Product-level playlist policy |
| Audio/DSP | Processing graph, parameter validation, gain staging, per-deck DSP configuration | Queue and navigation |
| DJ/transition engine | Analysis, candidate selection, transition plans, beat alignment, preview | Direct player ownership |
| Modes/experience | Listening-mode policy, visualizer state, presentation | Independent playback truth |
| History/analytics | Playback events, resume positions, listening summaries | Playback command authority |
| Intelligence | Natural-language interpretation, recommendations, smart playlist proposals | Hidden playback mutation |
| Persistence | Versioned storage, migrations, import/export, backup policy | In-memory playback authority |

### Canonical playback contract

Define one typed playback snapshot and command interface containing at least:
- Queue identity and ordered entries, including stable occurrence identity for duplicate tracks.
- Current queue occurrence and native/player index mapping.
- Current media item, duration, position, playback speed, transport state.
- Repeat/shuffle policy and user-visible error/recovery state.
- Active/incoming deck identity where dual-deck behavior is supported.
- Audio session identity for the active output path.
- Playback lifecycle, audio-focus/interruption state, and service/MediaSession availability.
- A monotonic session/queue revision so observers can reject stale events.

Screens and feature engines observe this contract and issue commands through the coordinator. They must not mutate player state independently.

## 4. Product pillars and ecosystem vision

### Listen — dependable personal library

Strengthen incremental/cancellable scanning, folder inclusion/exclusion, permission recovery, metadata/artwork, sorting/filtering, duplicate handling, queue, playlists, favorites, resume, sleep timer, background playback, and import/export.

### Experience — a personal listening space

Build a coherent Now Playing experience with clear artwork and metadata, queue access, transport, a discoverable DSP panel, listening-mode context, visualizer controls, consistent themes, accessibility labels, scalable text, and restrained motion. Add lyrics/richer metadata only where licensing and source reliability are clear.

### Create — DJ and sound craft

Evolve DJ features into a focused DJ Studio:
- BPM and beat-grid confidence, phrase alignment, and transition preview.
- Harmonic compatibility only when key-detection confidence is adequate.
- Energy progression, transition duration, and fade-curve controls.
- Manual override, cue/preview, and explainable transition risk.
- Session history and reusable transition preferences.
- Safe Autopilot: preview or ask before queue mutation unless the user explicitly enabled a scoped automation policy.

### Discover — intelligence that assists

Potential capabilities:
- Natural-language requests such as “make a 40-minute warm-up set” or “find tracks like this one in my library.”
- Smart playlists based on tempo, energy, recency, rating, tags, or listening patterns.
- Rediscovery of neglected tracks and local-library similarity.
- Explainable transition and listening-mode suggestions.
- Personal listening insights computed locally where possible.

Intelligence proposes actions through public app APIs; it must not become a second playback controller.

### Connect — optional ecosystem services

After the local experience is reliable:
- User-controlled backup and restore.
- Optional cross-device settings and playlist sync.
- Metadata/artwork enrichment providers.
- Desktop companion or library-management workflow.
- Carefully scoped external integrations.

Keep cloud accounts optional for core listening. Define data portability and deletion before introducing account-bound data.

## 5. Priority register

### P0 — protect the working player and complete Media3

1. Treat `Resonate-True-Apk` as the canonical product baseline for this effort.
2. Complete the Media3 cutover as one ownership migration, not a partial adapter swap.
3. Establish one production playback authority; retire the legacy `just_audio` path only after parity and rollback criteria are met.
4. Validate queue mapping, transport, observations, focus/interruption, audio session IDs, gain/DSP, crossfade, DJ/preload, notifications/MediaSession, history/resume, modes, watchdog/recovery, and disposal.
5. Reproduce or close the crossfade dip and DJ incoming-deck stall reports with device evidence.
6. Run automated checks and physical-device regression before merge.
7. Preserve a known-good build and document rollback.

**Exit gate:** no unresolved P0 playback regression; CI green; device evidence attached; one authoritative playback state; rollback path documented.

### P1 — reliability, sound correctness, UX quality

- Verify each DSP control from UI through persistence/bridge to the active native output graph.
- Ensure both decks receive consistent DSP and gain configuration during transitions.
- Validate headroom, limiter behavior, clipping, loudness normalization, EQ boosts, bass enhancement, and route changes.
- Move large scans off the Android main thread; add cancellation and progress.
- Distinguish empty library, permission denied, unsupported files, and scan failure.
- Audit manifest permissions and optional capture flows.
- Decide and document Android backup inclusion/exclusion.
- Add database migration, duplicate identity, and import/export tests.
- Validate visualizer behavior without coupling it to playback correctness.
- Audit accessibility, tap targets, loading/error/empty states, and all visible controls.
- Measure CPU, memory, battery, and thermal impact for DJ analysis and DSP profiles.

### P2 — ecosystem expansion

- Backup/restore and portable library metadata.
- Optional sync for playlists, preferences, and listening history.
- Metadata/artwork editing and enrichment.
- Smart playlists, listening insights, and local recommendations.
- Ask Resonate improvements and DJ Studio.
- Optional lyrics and richer artist/album context.
- Desktop companion and deeper integrations.

## 6. Sound quality and DSP validation

Use repeatable signal sources: silence, 1 kHz tone, pink noise, bass sweep, transient-rich tracks, speech, and representative music. Capture output/loopback where possible.

Validate:
1. Flat/default output and bypass equivalence.
2. Positive/negative EQ bands, including extreme settings.
3. Preamp compensation and headroom.
4. Bass enhancement, stereo width, reverb, and limiter interaction.
5. Loudness normalization and track-to-track gain transitions.
6. Parameter changes during playback and crossfade.
7. Active and incoming deck parity.
8. Wired, Bluetooth, speaker, and route-change behavior.
9. Sample-rate/channel-format changes and pause/resume.
10. CPU, latency, memory, and thermal cost.

Evaluate the five sound-profile concepts in existing product planning—Resonate Signature, Warmth, Clarity, Afterhours, and Pulse—as proposed presets with documented intent. Presets must respect headroom and provide a reliable reset; they should not replace manual controls.

## 7. Library and data integrity

- Keep scans incremental, cancellable, and off the UI thread.
- Model permission state independently from scan state.
- Surface progress and actionable failure reasons.
- Use stable media identity while accounting for moved files, URI changes, and duplicates.
- Make playlist and history writes transactional.
- Version schemas and test upgrades from representative prior versions.
- Define behavior for deleted/unavailable files without silently corrupting queue order.
- Provide user-controlled export and deletion for local metadata and history.

## 8. UX information architecture

A candidate navigation model:
- **Home:** continue listening, recent items, useful local recommendations.
- **Library:** tracks, albums, artists, folders, playlists, favorites.
- **Now Playing:** primary playback surface and queue.
- **Studio:** DJ tools, transition planning, sound profiles, advanced DSP.
- **Explore / Settings:** local discovery, listening insights, app configuration, privacy, backup, integrations.

This is a proposal, not a mandate to replace current navigation wholesale. Validate against current navigation and user behavior. Keep frequent playback actions reachable and avoid burying essential transport in settings.

## 9. Privacy, security, licensing

Before introducing accounts, sync, or payments:
- Inventory permissions and map each to a user-facing feature.
- Make microphone/spectrum capture optional, explain its purpose, and provide a clear off state.
- Review Android backup configuration and exclude sensitive/non-portable data as appropriate.
- Minimize diagnostics; obtain consent where needed and define retention.
- Provide local-data export and deletion.
- Threat-model account, sync, entitlement, and payment flows before implementation.
- Review the Restricted Use License and every bundled dependency/asset license; the project license does not supersede third-party terms.
- Keep secrets out of source, logs, crash reports, and client builds.

## 10. Quality gates and release discipline

### Automated gates

- Flutter formatting, static analysis, unit/widget tests.
- Kotlin unit and Android instrumentation tests.
- C++ DSP unit/stress tests and native memory-safety checks where supported.
- Adapter contract tests for queue mapping, duplicate occurrences, event ordering, and stale observations.
- Debug and release build verification.
- Dependency, license, secret, and vulnerability scans.
- Artifact size budget and release metadata validation.

### Physical-device matrix

At minimum:
- Android at declared minimum, current stable, and one major OEM variant.
- Internal speaker, wired output where available, Bluetooth headphones/speakers, route switching.
- Screen-off/background/foreground, notification, lock screen, headset controls, process/service recreation.
- Calls, alarms, audio-focus loss/duck/gain, Bluetooth disconnect/reconnect.
- Short/long tracks, corrupt/unsupported media, empty folders, large libraries, duplicates, missing files.
- Crossfade on/off, repeat/shuffle, DJ transitions, preload invalidation, manual intervention during automation.
- DSP changes during playback and transitions.

### Release sequence

1. Freeze a known-good baseline and record commit/build.
2. Land Media3 only after explicit acceptance gates.
3. Run full regression and collect device evidence.
4. Produce a release candidate and test upgrade behavior.
5. Publish release notes, known issues, privacy/licensing notes, rollback instructions.
6. Expand ecosystem features only after stability remains healthy.

## 11. Delivery roadmap

| Phase | Focus | Deliverable |
|---|---|---|
| 0 | Baseline and ownership | Canonical branch, architecture map, known-good build, issue register |
| 1 | Media3 completion | Single playback authority with parity and device evidence |
| 2 | Audio and library correctness | DSP validation, scan reliability, lifecycle and data integrity |
| 3 | UX coherence | Strong Now Playing, accessible controls, unified modes/visualizer |
| 4 | Intelligence and DJ Studio | Explainable recommendations, smart playlists, safe transition workflow |
| 5 | Ecosystem services | Optional backup, sync, metadata, desktop, integrations |
| 6 | Release and scale | Stable release train, consent-based diagnostics, support and compatibility process |

## 12. Decisions and immediate next actions

- Continue from `Resonate-True-Apk`; do not rebuild from the old default branch.
- Media3 cutover is the next engineering milestone.
- Keep the current app usable throughout migration; no broad rewrite.
- Do not merge a playback migration solely because it compiles. Require behavioral parity, device evidence, and rollback.
- Reconcile current Media3 work against the production branch and the ownership checklist in the companion execution plan.
- Create a reproducible defect matrix for crossfade, DJ transitions, audio focus, Bluetooth, and background lifecycle.
- After Media3 acceptance, execute P1 reliability work before P2 ecosystem expansion.

## 13. Audit limitations

This document consolidates static source review and product/engineering direction. It does **not** assert that the current branch has just passed `flutter analyze`, Flutter tests, Gradle builds, Kotlin tests, C++ tests, physical-device testing, or listening tests. Run those against the exact proposed merge commit and record outputs. Re-check branch and PR state before acting because repository state changes.
