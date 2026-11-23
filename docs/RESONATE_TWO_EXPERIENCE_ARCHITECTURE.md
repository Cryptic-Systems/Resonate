# Resonate Two-Experience Architecture and Migration Blueprint

**Status:** Phase 0 repository audit completed; dual-deck direction approved  
**Audited branch:** `dj-workspace-development`  
**Audited commit:** `dad53206153a5f537a4e40c66b91d9099c6c9df8`  
**Production branch:** `Resonate-True-Apk` (out of scope; do not modify)  
**PR #221:** remains open and unmerged  
**Implementation status:** No runtime implementation is part of this document.

## 1. Product decisions

Resonate will provide two mutually exclusive user experiences over one shared audio platform and one strictly exclusive deck-usage policy. Exactly one deck policy may be active at a time: single-deck Player policy or dual-deck DJ policy. A policy transition temporarily authorizes neither experience to issue deck commands.

1. **Resonate Player** — everyday listening, the existing player/library experience, current automatic DJ behavior, DSP, Intelligence, Ask Resonate, voice and feedback. It does not expose manual DJ Console controls.
2. **Resonatix DJ** — a dedicated DJ performance environment with its own workspace, Console and integrated library browser. It uses the same shared library records and playback foundation. A fresh DJ session starts with both deck slots empty.

Locked behavior:

- The app remembers the last selected experience and opens it on subsequent launches.
- Switching experiences stops playback and opens the destination cleanly.
- DJ automation has three levels: Intelligence Only, Assisted Performance and Automatic Performance.
- A fresh DJ session defaults to Intelligence Only (manual-first). Higher automation is an explicit operator choice.
- The DJ library is an integrated browser over the existing Resonate library; it is not a second media database.
- Settings are shared at the app level, with experience-specific sections where appropriate.

## 2. Repository audit: existing capabilities to reuse

The audit was performed against the development branch at the commit above. The following are existing systems, not proposed new features.

### 2.1 Production playback and audio

| Existing component | Current responsibility | Migration decision |
|---|---|---|
| `MusicProvider` | Public playback facade, queue/transport policy, state reconciliation and DJ handoff entry points | Retain as the single Flutter playback facade |
| `PlaybackControlArbiter` | Serialized exclusive controller leases, priorities, revocation and fail-closed write authorization | Reuse; do not create another arbiter |
| `Media3ProviderSession` | Provider-owned canonical session and state projection | Reuse |
| `Media3PlaybackRuntime` | One backend, serialized commands, queue and reconciled state | Reuse; do not instantiate a second runtime for DJ |
| `Media3MusicProviderAdapter` / `Media3PlaybackClient` | Song-to-native mapping and platform command/state boundary | Reuse |
| `Media3PlaybackBridge` | Flutter-to-native Media3 session bridge | Reuse |
| `Media3PlaybackService` | Native MediaSession and ExoPlayer lifecycle | Reuse |
| `DspEngineSinkHook`, `DspEngineRegistry`, `AudioEffectsProvider` | Native DSP processing and active/standby deck routing | Reuse; do not duplicate DSP |
| Existing audio focus and MediaSession integration | System focus, notification, Bluetooth and external transport behavior | Preserve and validate |

The application composition root constructs one `PlaybackControlArbiter` and injects it into `MusicProvider`. It constructs one `Media3ProviderSession` for that provider. The startup lifecycle restores saved audio settings before preparing the Media3 session and committing the provider handoff.

The native service creates a canonical active ExoPlayer (initial physical deck A) and creates the second physical player as a muted standby when a preload is requested. The service also contains auxiliary sound and isolated transition-preview players for their bounded, non-canonical purposes. These are not reasons to add another production playback engine or another MediaSession. Auxiliary/preview players are not user-facing deck capacity and must never be treated as a way around the active deck-usage policy.

The `just_audio` compatibility/fallback code remains in the repository, but the injected Media3 session prevents lazy legacy-engine construction while Media3 owns or is preparing playback. The handoff retires the legacy EnginePair after Media3 has been configured and verified. Do not remove the dependency or fallback wholesale as part of this architecture split; only retire a specifically proven reachable competing path in a separately scoped change.

**Documentation discrepancy to reconcile later:** some older comments and migration documents still describe the Media3 runtime/bridge as an isolated prototype or describe the pre-cutover migration state. The current app composition and provider handoff show that the Media3 session is wired into the application startup path. Update stale documentation only after verifying the current runtime path and release configuration; do not infer production status from an old comment alone.

### 2.2 Playback ownership

The existing arbiter priorities are:

- background
- automatic
- interactive
- safety override
- user transport

A lease is generation-bound. Revocation invalidates the lease before asynchronous cleanup, and stale leases cannot authorize subsequent writes. Manual DJ handoff already uses an interactive lease, with user transport able to preempt it. Pending preload and tempo operations are settled before cleanup completes.

**Decision:** retain this arbiter as the sole playback-controller arbitration mechanism. Separately, introduce one authoritative `DeckUsagePolicyCoordinator` (or equivalent policy owner) for the mutually exclusive deck configuration: `PLAYER_SINGLE_DECK` or `DJ_DUAL_DECK`. This is a policy gate/configuration owner, not a command arbiter: it must not schedule/prioritize competing controllers, issue playback commands, or replace `PlaybackControlArbiter`. Every deck command must satisfy both the active deck policy and the existing arbiter's valid lease/authorization rules. The top-level experience coordinator remains a lifecycle/router coordinator, not a playback authority. None of these coordinators may own ExoPlayer, DSP or audio focus.

### 2.3 DJ features already present

| Existing component | Current capability | Reuse boundary |
|---|---|---|
| `DjModeProvider` / `DjModeSettingsStore` | DJ feature settings, beat alignment, tempo match, harmonic mix, confidence/aggressiveness, SFX and idle analysis | Extend only where the three-level automation setting is genuinely missing |
| `DjAnalysisService` | Cached BPM/key/profile analysis, SQLite persistence, waveform profile access | Reuse |
| `DjEngine` | Transition candidate generation, scoring, risk analysis and execution planning | Reuse |
| `DjAutopilotPlanner` | Candidate ranking with transition memory | Reuse |
| `DjSessionCoordinator` | Reviewable suggestion mixes without directly mutating playback | Reuse |
| `DjWorkspaceScreen` | Watch-only monitoring of Media3 deck and transition state | Retain inside Resonatix DJ |
| `DjConsoleScreen` | Landscape performance surface, measured waveforms, deck status, active-deck jog seek and manual controls | Retain and evolve |
| Manual DJ handoff in `MusicProvider` | Deck B preparation, cue, tempo parameters, crossfade, cancellation and lease cleanup | Reuse; extend only for the empty-session workflow |

The existing Console is intentionally honest about implemented controls. Jog interaction is a one-shot seek on the verified active deck; it is not scratching or continuous platter-speed control. Tempo writes are per physical deck and require a valid manual lease and prepared standby state.

### 2.4 Existing Intelligence Autopilot is not the DJ automation selector

`IntelligenceProvider` and `AutopilotController` already implement a separate listening/recommendation autonomy model, including Suggestions only, Assist me and Autopilot, explicit consent, recommendation selection and queue/track mutation.

That system must not be duplicated or casually renamed as the DJ's three-level performance control. The Resonatix DJ automation selector governs DJ transition behavior:

- **Intelligence Only:** analysis, risk feedback, recommendations and voice feedback; no transport writes by the DJ automation layer.
- **Assisted Performance:** prepare and recommend; operator confirmation is required before performance execution.
- **Automatic Performance:** eligible DJ transitions may execute only while explicitly enabled and authorized. Manual operator input preempts automatic execution.

The existing transition planner, risk engine, Media3 transition operations and arbiter should be reused. The automation-level policy/state is the actual gap to design and test.

### 2.5 Library and persistence

- `LibraryProvider` exposes the existing library and filtering.
- `DatabaseHelper` owns the existing SQLite database (schema version 9 in the audited branch), including songs, playlists, favorites, DJ analysis/profiles and progressive waveform chunks/manifests.
- `PlaylistProvider` and existing playlist persistence remain shared.
- `DjAnalysisService` reads/writes the existing DJ analysis tables.

The DJ browser must query these existing providers/stores. Do not create a second song catalog, scanner, media permission flow, analysis database or waveform store.

A DJ performance queue/session is not a second library. If required to keep the Player's queue intact while DJ decks are selected independently, it should be a lightweight session-level collection of stable song references and occurrence identities, not a duplicated library or a second authoritative playback queue.

## 3. Current product/navigation gap

The audited app currently creates a single `HomeScreen` from `_LifecycleHome`. That shell has For You, Library, Player and Settings tabs. DJ Workspace and DJ Mode settings are currently reached from the shared Settings area; DJ Workspace opens DJ Console as a nested route.

There is no top-level persisted choice between Resonate Player and Resonatix DJ in the app root.

The existing `ModeProvider` is not that selector. Its `ResonateMode` values (Normal, Running, Workout, Driving, Work, Podcast, Motivation, Audiobook and Sleep) are listening-context policies. Keep that feature intact and separate from the new product-experience selection.

The existing `DjModeProvider` is also not the top-level selector. It is an optional DJ feature/configuration layer and analysis coordinator. Keep it as shared DJ capability state, with experience-specific UI access.

## 4. Critical deck-lifecycle finding

The current native Media3 implementation has two physical ExoPlayer objects, but its production contract is currently a canonical active player plus a muted standby player. The current manual DJ provider API is specifically an incoming-deck handoff API:

- it requires an active Media3 provider session;
- it requires the outgoing deck to be playing;
- it maps the selected incoming item to an occurrence in the current provider/native queue;
- it prepares the standby player, waits for native readiness, retains an interactive lease, and supports cue, tempo, cancellation and equal-power crossfade promotion.

The native service can load a new canonical queue and can prepare a standby queue, but the current Dart manual-DJ entry point does not expose a clean empty-session workflow. The current UI's empty state also tells the user to start playback from the normal library.

Therefore, independent DJ startup is a real gap. It is not evidence that another audio engine is needed.

### Required design before deck implementation

1. Start Resonatix DJ with no selected tracks and no audible output.
2. Select Deck A from the existing library and prepare the existing canonical Media3 active player without requiring the Player experience to start playback first.
3. Select Deck B from the same library and prepare the existing native standby player, muted and without audio focus.
4. Preserve stable song identity and queue-occurrence mapping even when tracks repeat.
5. Define what promotion means for the session queue and how the next standby is selected.
6. Keep MediaSession, MusicProvider state, physical deck identity and DSP routing synchronized through promotion.
7. Ensure a fresh DJ session cannot overwrite the saved Resonate Player queue. Use a session-level DJ set/queue snapshot or a carefully designed queue-context boundary; do not create a second playback engine or library database.
8. The approved product target is independent dual-deck performance, not just incoming-track handoff. Do not expose independent Play, pause, channel gain, crossfader, cue-monitoring or scratch controls until their native semantics are explicitly implemented and validated. The existing standby is not yet an independently audible channel outside the native crossfade envelope. Scratching remains a separate capability requiring its own validated low-latency control path.

A focused native/API spike must establish whether the existing two physical players can be evolved into independently controlled, concurrently audible deck channels while retaining a single app output policy and safe DSP routing. It must also establish whether independently selected MediaItems can be loaded without changing the Player queue. Prefer a narrow extension of the existing Media3 service and bridge. Do not add another ExoPlayer service, MediaSession, audio focus owner or DSP chain.

## 4.1 Approved performance target: traditional dual-deck DJ operation

**Decision: Resonatix DJ is designed toward a traditional, independently operable two-deck performance model.** The current active-plus-muted-standby handoff behavior is not the final product boundary.

The intended operator capabilities are:

- Load or replace either physical deck independently from the integrated library.
- Start, pause, seek/cue and prepare each deck independently.
- Keep both decks running simultaneously when the operator chooses.
- Control each deck's tempo/playback parameters independently within validated limits.
- Apply independent channel/deck gain and a shared crossfader/master mix. The DJ crossfader is operator-controlled/manual; DJ automation must not move it or silently blend channels on the operator's behalf.
- Prelisten/cue only if a safe, explicitly designed monitoring route is available; do not silently route cue audio to the master output.
- Keep track identity, position, readiness, buffering, errors and physical deck roles independently observable.
- Preserve one shared output/audio platform, system audio focus ownership and app-level master output policy.

### 4.2 Strict, mutually exclusive deck-usage policy

**Locked invariant: exactly one deck-usage policy exists as active at any instant.** This is enforced by the shared audio architecture, not merely by hiding UI controls.

| Active policy | Permitted deck configuration | Prohibited behavior |
|---|---|---|
| `PLAYER_SINGLE_DECK` | One canonical audible deck for Resonate Player | No second audible/prepared DJ channel, no DJ crossfader, no Deck B performance commands |
| `DJ_DUAL_DECK` | Two independently loaded/operable DJ decks with operator-controlled manual crossfade and one shared master output | No Player single-deck policy or Player shell deck commands; no automatic crossfader movement |
| `SWITCHING` / no policy | No experience may issue deck commands while outgoing work is quiesced and the policy is being replaced | No overlap, no early destination commands, no stale outgoing writes |

The policy owner is a single source of truth for the permitted deck topology and active experience binding. It must:

1. Grant exactly one policy (`PLAYER_SINGLE_DECK` or `DJ_DUAL_DECK`) and bind it to a monotonically increasing generation/token so stale commands from an earlier policy are rejected.
2. Reject Deck B load, prepare, start, parameter, gain and crossfader commands while `PLAYER_SINGLE_DECK` is active, including commands originating from hidden/background DJ controllers.
3. Permit Deck A/Deck B operation only under `DJ_DUAL_DECK`; both decks may be audible simultaneously only through the validated shared mix/output path.
4. Keep the DJ crossfader manual and operator-owned. Automation may analyze, warn, recommend and perform only separately authorized preparation/execution actions; it must never write crossfader position or override a manual crossfade gesture.
5. Enforce the same policy at the native Media3 command boundary as well as the Flutter/Dart boundary. UI visibility is not a security or correctness boundary.
6. Require every mutating deck command to pass both the active policy-generation check and the existing `PlaybackControlArbiter` lease authorization. The policy coordinator must not become a second arbiter.
7. On policy switch, enter a no-policy/quiescing state, reject new commands, settle/cancel outgoing work, stop all outgoing audible decks, clear temporary deck state, verify old-generation commands can no longer mutate audio, then grant the destination policy. Never grant the destination before outgoing cleanup succeeds.
8. If cleanup or native acknowledgement fails, remain fail-closed with no active deck policy and no audible playback; surface a recoverable error rather than activating both or guessing.
9. Treat auxiliary sound/preview paths as bounded non-deck facilities; they cannot be used to bypass the single-deck Player rule or create an additional DJ channel.

A policy switch is not an engine/service restart. It reconfigures the permitted use of the same Media3 service, two existing physical deck players, DSP path, MediaSession, audio-focus owner and shared provider graph.

### Reuse-first implementation constraint

The repository already has two physical ExoPlayer deck objects in the existing Media3 service lifecycle: one canonical active player and a second player currently used as muted standby. The approved direction is to investigate and evolve those existing physical deck players and their service/bridge APIs. It is **not** approval to instantiate another ExoPlayer, MediaSession, Media3 service, DSP engine, audio-focus owner or playback arbiter.

The fact that two ExoPlayer objects exist does not prove they are already independent DJ channels. Current standby semantics, queue ownership, audio-session routing, DSP sink attachment, gain handling and promotion logic must be audited before exposing dual-deck controls.

### Required technical design spike

Before changing the current native deck lifecycle, document and test:

1. Whether both existing ExoPlayer instances can render concurrently through the current Android output path without unexpected audio-focus, session or latency behavior.
2. How the current DSP sink is attached and whether it processes both physical deck outputs. Do not claim per-deck DSP simply because two deck players exist.
3. A single authoritative mix/gain path for per-deck gain, crossfader curve and master output. Avoid competing Flutter/native gain writers; native Media3/mixer policy remains authoritative.
4. Per-deck transport and playback-parameter commands, including serialization, stale-command fencing and lease authorization.
5. Independent deck media-item/queue ownership and stable occurrence identity, without overwriting the Resonate Player queue.
6. Audio-session IDs, effects routing, Bluetooth/device changes, focus loss, interruptions, notification/system transport semantics and recovery when one deck fails.
7. Crossfader behavior when one deck is stopped, buffering, unprepared or revoked; no unexpected gain jumps or audible standby leakage.
8. Whether the existing DSP architecture can safely support the desired two-channel signal path. If a genuine limitation is found, propose the smallest safe extension to the existing DSP/output path. Do not create a parallel DSP engine.

Until this spike proves the required behavior, the current muted-standby crossfade remains the only validated behavior. The product target is traditional dual-deck operation, but UI controls must not claim capabilities before native behavior and DSP routing are implemented and tested.

## 5. Target application architecture

### 5.1 Shared application services

Create/retain one app-lifetime provider graph:

- one `MusicProvider`;
- one `PlaybackControlArbiter`;
- one exclusive deck-usage policy owner, enforcing exactly one active policy (single-deck Player or dual-deck DJ) without acting as a second command arbiter;
- one `Media3ProviderSession` and its existing runtime/backend/client/bridge;
- one `LibraryProvider`, `PlaylistProvider` and shared database;
- existing Intelligence, DJ analysis, DSP/effects, visualization, Bluetooth and diagnostics providers.

These services must not be re-created when switching the visible experience. A mode switch changes the active product shell, not the audio engine or the app's shared provider graph.

### 5.2 Experience selection and routing

Add only the missing product-level concept: a persisted experience selection with two values, Player and Resonatix DJ.

- Load the saved value before choosing the initial shell.
- If no value exists, show a first-run experience chooser.
- Persist the user's selection and remember it.
- Settings in either shell must provide a way to switch experiences.
- A switch must stop playback and perform the safe outgoing-controller cleanup before replacing the shell.
- Keep the selected experience distinct from `ResonateMode` listening-context profiles.

A small experience preference/store and lifecycle coordinator are acceptable new app-level components because this concept does not currently exist. They must not create playback objects or duplicate authority.

### 5.3 Resonate Player shell

Reuse the current HomeScreen and its tabs as the starting point. Remove DJ Console/manual performance entry points from this shell. Keep existing automatic DJ, Intelligence, DSP, voice and normal playback behavior. Shared Settings remains reachable.

### 5.4 Resonatix DJ shell

Build a dedicated shell around existing DJ screens and providers:

- DJ Workspace remains the monitoring/overview surface.
- DJ Console remains the hands-on performance surface.
- Integrated DJ browser uses `LibraryProvider`, `PlaylistProvider` and existing database/analysis services.
- Track selection can target Deck A or Deck B directly.
- The shell starts with empty deck slots and Intelligence Only automation.
- DJ-specific settings are presented within the shared Settings destination or its Resonatix-specific section.

Do not simply add another skin to the Player shell. The navigation and deck-loading workflow must be independent of the normal Player screen.

### 5.5 Settings

Keep one shared Settings system and one copy of global preferences. Organize settings into global, Resonate Player and Resonatix DJ sections. Existing DSP, audio focus, library scanning, voice, theme and diagnostics settings must not be duplicated.

## 6. Safe experience-switch contract

The initial implementation intentionally stops playback; seamless cross-experience handoff is out of scope.

Proposed serialized transition:

1. Mark the outgoing experience as switching so its UI rejects new performance commands.
2. Cancel or settle automatic transition/preload work through existing MusicProvider mechanisms.
3. If leaving Resonatix DJ, cancel manual prepared-deck work and await pending preload/tempo operations using the existing cleanup path.
4. Stop canonical Media3 playback through the existing MusicProvider/session path; do not dispose/recreate the Media3 service.
5. Normalize temporary DJ-only playback parameters/overlays where the existing cleanup contract requires it.
6. Verify the outgoing experience has no outstanding command capable of mutating the new session.
7. Change the persisted selected experience only after successful cleanup.
8. Mount the destination shell and restore its own UI/session preferences.
9. If cleanup fails, do not mount the destination as an active controller. Keep the current experience in a safe, stopped/error state and report the failure.

Use the existing PlaybackControlArbiter for individual transport/DJ mutations. The experience coordinator must not become another arbiter. Do not release the shared Media3 session or recreate shared providers on a normal mode switch.

## 7. Migration phases and acceptance gates

### Phase 0 — repository inventory and architecture blueprint
**Status: completed in this audit.**

Deliverables: component inventory, ownership map, existing-vs-gap matrix, target architecture and staged migration plan.

### Phase 1 — product experience state and root routing
Add the persisted Player/Resonatix DJ selection, first-run chooser and root shell routing. Reuse the existing provider graph. Do not change playback engine/session construction.

Acceptance:
- Existing installs with no experience key receive a safe first-run selection.
- Selection persists across restart.
- Existing listening-context Modes remain unchanged.
- Shared providers are constructed once and remain alive across shell changes.
- No new player, MediaSession, DSP, audio focus owner or arbiter is introduced.

### Phase 2 — Resonate Player isolation
Retain current HomeScreen behavior and remove manual DJ performance entry points from the Player shell. Preserve automatic DJ and all existing Player functionality.

Acceptance: Player regression suite and existing playback/Media3/DSP tests remain green; DJ Console is not reachable from Player navigation.

### Phase 3 — Resonatix DJ shell and integrated browser
Create dedicated DJ navigation and connect existing library/playlist/analysis providers. Preserve Workspace and Console rather than recreating them.

Acceptance: DJ shell can browse the existing library and choose a target deck without entering the Player experience. No duplicate library database/scanner/permission flow.

### Phase 4 — independent dual-deck lifecycle and mix path
First complete the native/API design spike and implement/test the strict deck-usage policy gate at both Dart and native boundaries. Then evolve the existing two physical Media3 deck players and existing DSP/output path to support independent DJ deck loading, transport and concurrent audibility, with one shared master mix path and a manually operated crossfader. Player policy must remain strictly single-deck. Resolve session queue isolation and occurrence mapping before implementation. Do not create a new player or audio engine.

Acceptance: empty launch; independently load/replace/unload A and B; independent start/pause/seek/cue/tempo; verified simultaneous playback; independent channel gains; tested crossfader curve and master output; correct focus/session/effects behavior; safe single-deck and dual-deck recovery; state/DSP routing for both physical decks; no Player queue corruption; stale-command and lease tests; all cleanup paths tested. Standby mute remains enforced whenever a deck is in a prepared-but-not-playing state.

### Phase 5 — three-level DJ automation
Add the missing automation-level policy to existing DJ state/orchestration. Reuse DJ planner, risk engine, analysis and Media3 transition APIs. Keep Intelligence Autopilot separate.

Acceptance:
- Intelligence Only never writes transport.
- Assisted Performance never executes without an explicit operator confirmation.
- Automatic Performance requires explicit enablement and valid authority.
- Manual input preempts automatic execution.
- Risk rejection, stale plan, lease revocation and missing analysis all fail safely.

### Phase 6 — shared settings and safe switching
Expose experience switching and shared/global plus mode-specific settings. Implement the safe-switch contract above, including atomic release/regrant of the mutually exclusive deck policy and fail-closed no-policy state during switching.

Acceptance: switch while playing, paused, transitioning, DJ standby-ready, manual tempo-write pending and automatic work pending. No overlapping controller authority, stale callback writes or audio-engine recreation.

### Phase 7 — UI refinement and regression
Polish both shells, responsive layouts, Console, waveforms, orientation lifecycle, empty/error/loading states and accessibility.

### Phase 8 — release readiness
Run Flutter analysis/tests, native Media3 tests, DSP tests, Android build and artifact integrity checks. Complete real-device validation for both experiences. CI green is not a substitute for device testing.

## 8. Explicit non-goals and prohibited duplication

This migration must not:

- create another audio engine, Media3 service, MediaSession or canonical player;
- create another DSP engine, processor chain or gain/crossfade implementation;
- create a second library database, media scanner, playlist store or waveform store;
- create another audio-focus owner;
- create a second PlaybackControlArbiter;
- allow Player and DJ deck policies to be active simultaneously;
- allow Deck B or crossfader commands under the Player single-deck policy;
- let DJ automation write or override the manual crossfader;
- repurpose `ResonateMode` as the Player/Resonatix selector;
- duplicate Intelligence Autopilot as DJ automation;
- remove `just_audio` wholesale without a separate production-reference audit;
- claim independent audible deck controls that the native service does not actually implement;
- merge PR #221 or modify `Resonate-True-Apk`.

## 9. Phase 0 exit decision

The repository already contains the shared audio foundation, DJ intelligence, analysis, library, Workspace, Console and manual handoff mechanisms. The architecture split should be implemented by adding the missing top-level experience lifecycle and the missing empty-session DJ deck workflow, then adapting existing screens and settings.

**The next implementation gate is Phase 1.** The traditional dual-deck performance target is approved. Before Phase 4 implementation, the native/API spike must prove how the existing two physical deck players, DSP signal path and output mixing can safely deliver that target. The queue-isolation strategy must also be settled so a DJ performance session cannot corrupt the saved Resonate Player queue.
