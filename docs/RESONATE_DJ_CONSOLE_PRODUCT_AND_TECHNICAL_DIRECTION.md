# Resonate DJ Console — Product & Technical Direction

**Status:** Product direction documented; DJ Workspace is watch-only; Phase 1 landscape visual foundation implemented, with all performance controls gated  
**Target branch:** `dj-workspace-development`  
**Parent experience:** Existing DJ Workspace  
**Primary form factor:** Landscape, with a deliberate portrait entry/rotation experience  
**Playback authority:** Existing Media3 production session and PlaybackControlArbiter  
**Relationship to current UI:** Additive. Preserve the standard player and current DJ Workspace.

## 1. Product intent

Resonate will offer a dedicated **DJ Console** mode entered from the existing **DJ Workspace**. The Console is a landscape-first, two-deck performance surface inspired by the interaction language of professional DJ applications such as VirtualDJ and Cross DJ. It must still feel like Resonate: polished, legible, responsive, and honest about what the playback engine is actually doing.

The core idea is not merely to make the player wider. The Console should let users both perform controlled two-deck transitions and understand the mechanics behind them: which deck is audible, which is being prepared, how tracks line up, when a transition is occurring, and when deck ownership changes.

This is a new presentation and interaction mode over the existing playback system—not a new audio engine.

## 2. Three complementary experiences

These experiences have distinct jobs and should remain separate:

1. **Standard Resonate Player — everyday listening.** Keep the familiar library, queue, artwork, playback controls, DSP access and system-media-control experience. Do not force DJ controls into the everyday player.
2. **DJ Workspace — watch-only observation.** Preserve the dual-deck workspace as a live control-room window: active/standby identity, live spectrum, incoming preparation, transition state and useful engine telemetry. It does not prepare decks, set live cue points, trigger manual crossfades or mutate transport. It is the overview and monitoring environment.
3. **DJ Console — hands-on performance.** A dedicated mode launched from DJ Workspace. It owns manual deck preparation, cueing, crossfader operation and other interactive performance controls, presented through two prominent decks, waveforms, jog controls and a central mixer in a landscape-oriented composition.

The existing DJ Workspace is not a temporary prototype to be replaced. It is a watch-only companion view that explains and exposes the underlying deck relationship; the Console is the more immersive instrument surface.

## 3. Entry, navigation and orientation

- Provide a clear **Open DJ Console** action from DJ Workspace once the Console route is implemented.
- Keep the DJ Workspace itself observational: no manual deck preparation, cue adjustment, crossfade triggering, jog manipulation or transport writes from its monitoring panels.
- Entering the Console must not start, pause, seek, preload or otherwise mutate playback by itself.
- Prefer landscape orientation while the Console is visible, subject to platform support and lifecycle correctness.
- Restore the prior orientation policy when leaving the Console. Handle back navigation, app backgrounding, interruptions and route disposal without leaving the app locked in landscape.
- If orientation locking is unavailable or inappropriate on a device, keep the layout usable through responsive adaptation rather than blocking entry.
- Provide an obvious return path to DJ Workspace. Returning must not reset the queue or alter the active track.
- The initial release should be designed for phone landscape, while keeping tablet and unusually narrow landscape widths in mind.

## 4. Console information architecture

### 4.1 Deck A and Deck B

Each deck should show, at minimum:

- Track title, artist and artwork where available.
- Actual elapsed and remaining time, plus duration when known.
- BPM and musical key only when reliable analysis metadata exists; unknown values must be represented honestly.
- A detailed waveform with a clear playhead and track-relative time scale.
- Deck state: active/audible, standby/preparing, ready, transitioning, unavailable or failed.
- Transport/performance affordances appropriate to the capabilities actually implemented.

Deck labels are logical presentation labels, not permanent physical-player identities. The UI must derive active and standby roles from the current native/session state (including the current `activeDeckId`) and must tolerate physical deck promotion and role swaps. Never assume Deck A is always the active player.

### 4.2 Jog wheels / platters

Use prominent, tactile platter visuals with restrained rotation and clear interaction feedback. Planned capabilities may include:

- Touch/drag seeking or temporary nudging.
- Fine position adjustment.
- Optional scratch-style manipulation only if a low-latency, safe native implementation is designed and validated.

A spinning animation must not imply that audio is being scratched or that platter speed is controlling playback when it is not. Do not ship inert controls that look operational. Each gesture must have a documented transport meaning, appropriate cancellation behavior, and tests for interruption and ownership loss.

### 4.3 Waveforms and beat display

Waveforms should be high quality, readable and data-driven:

- Use real track-derived amplitude/PCM analysis data where available, with caching and bounded memory/CPU cost.
- Render a stable playhead from actual playback position and duration.
- Support scrolling or fixed-waveform presentation with clear time/beat references.
- Add beat-grid and phrase markers only when analysis confidence supports them.
- Distinguish unavailable analysis from silence or zero amplitude.
- Do not fabricate waveform peaks, BPM, beat alignment or transition progress. A clearly labelled temporary placeholder may be used during development, but must not be presented as measured track data in a release.

Waveform generation is an explicit technical workstream; the existing live 32-band spectrum is not a substitute for a track waveform.

### 4.4 Central mixer

The visual center of the Console should contain a clear mixer with:

- Crossfader.
- Independent channel level controls.
- Three-band EQ per deck, where supported by the existing DSP control path.
- Filter controls, if a safe and well-defined DSP mapping is available.
- Level meters and transition/ownership indicators.

The mixer must make it clear which controls affect the live signal and which are unavailable for the current deck state. Avoid duplicating DSP processing or applying gain twice.

### 4.5 Performance and status layer

Expose useful engine state without turning the screen into a diagnostics dump:

- Incoming/standby readiness.
- Active deck and standby deck identity.
- Actual transition state and progress, where native telemetry provides it.
- BPM and beat alignment confidence.
- Signal level/spectrum where sourced from existing analysis.
- Clear unavailable, loading, error and authority-lost states.

Animations should be tied to real state or clearly identified as decorative. Respect reduced-motion settings and avoid high-frequency UI rebuilds.

## 5. Playback and architecture contracts

These are release-blocking constraints, not implementation preferences.

### 5.1 One production playback authority

- Media3 remains the sole production playback authority.
- Do not add a second player, parallel output path, or another controller that can mutate transport independently.
- Do not reintroduce a legacy player path into production Media3 construction.
- Existing Android system media controls remain integrated through the current media-session/service architecture; they are not a competing player.

### 5.2 PlaybackControlArbiter remains authoritative

Every transport mutation must be authorized by the existing lease/arbiter policy. The Console must not bypass lease acquisition, revocation, write authorization or cleanup. Manual Console actions must have a clearly specified priority relative to user transport and automatic DJ work. A revoked lease must fail closed; stale asynchronous work must not write after ownership has moved.

The current manual DJ preparation and automatic preload settlement audit remains relevant. Before Console transport interactions are enabled, verify that automatic preload, repeat-self preload and manual standby preparation cannot race or leave stale standby state.

### 5.3 Native Media3 owns deck transitions

- Native Media3 remains responsible for crossfade execution, equal-power gain envelopes and physical deck promotion.
- Flutter must not directly write `ExoPlayer.volume` or implement a competing crossfade envelope.
- The Console crossfader must map to an explicitly designed native transition/control contract. Do not assume a visual fader can safely take over the existing automatic crossfade mechanism.
- Standby must remain inaudible and must not request audio focus.
- Do not expose a standby Play action unless a separately reviewed native contract proves it safe.
- Use native/session identity and ordered occurrence mapping to reconcile provider and native queues. Native playable indices must not be treated as Flutter provider indices when unplayable items can be filtered.
- Deck promotion and DSP routing must follow the actual active physical deck identity.

### 5.4 DSP ownership

EQ, filter and channel controls should reuse the established DSP integration where possible. Keep signal routing and deck analysis hints aligned with the promoted active deck. Avoid direct gain manipulation from Flutter, duplicate EQ stages, or a second DSP chain. Each new control needs an explicit mapping, range, smoothing policy, ownership rule and bypass/failure behavior.

## 6. Interaction model and safety

- Every visible control must have a defined and testable effect. If a capability is not implemented, show it as unavailable or omit it.
- Transport actions must be rejected or disabled when playback authority is unavailable.
- During transition, deck promotion, queue mutation, interruption or app lifecycle changes, controls must reflect the real state and avoid issuing stale commands.
- Debounce or serialize high-frequency gestures where appropriate; never allow rapid UI events to create overlapping native transport mutations.
- Provide confirmation/feedback for destructive or discontinuous actions such as replacing a prepared incoming track.
- Handle missing files, unsupported formats, unavailable metadata, short tracks, seek bounds, queue changes and preparation failures.
- Keep the Console usable with touch targets suitable for landscape operation. Avoid controls that depend on hover or precision mouse input.

## 7. Visual and motion direction

The Console should feel like a professional instrument rather than a standard player rotated sideways:

- Two visually balanced decks with strong left/right identity.
- Waveforms and platter surfaces are the primary visual anchors.
- A central mixer that is visually distinct but does not overwhelm track information.
- Dark, high-contrast performance styling consistent with Resonate's design language.
- Crisp typography and clear numeric hierarchy for BPM and time.
- Smooth, purposeful transitions, subtle depth and responsive meter animation.
- No simulated values presented as live telemetry.
- Respect `MediaQuery.disableAnimationsOf(context)` and equivalent reduced-motion behavior already used in the DJ Workspace.

The design should scale from compact phone landscape to larger displays without shrinking critical touch targets excessively. Define a fallback layout for narrow widths.

## 8. Delivery plan

Work incrementally, with architecture and playback safety preceding visual complexity.

### Phase 0 — readiness and interaction contract

- Finish the outstanding automatic-vs-manual preload settlement audit.
- Map the existing DJ Workspace state, native session APIs, arbiter leases and DSP control surfaces.
- Specify each proposed Console control: state source, command path, lease requirement, cancellation behavior and unsupported-state handling.
- Identify gaps that require native Media3 or DSP work before exposing a control.
- Record baseline playback, queue, lifecycle and transition regression tests.

**Exit criteria:** no unresolved ownership ambiguity for any control included in the first interactive milestone.

### Phase 1 — visual Console foundation

**Current implementation:** landscape route and two-deck visual shell are present. Track title and timing follow the canonical provider session. Platter/mixer artwork is presentation-only; waveform preview is explicitly labelled as placeholder data. No manual transport or mixer actions are enabled yet.

- Add navigation from DJ Workspace into a dedicated Console route/mode.
- Implement orientation lifecycle handling and landscape-responsive layout.
- Build deck shells, artwork/metadata panels, platter visuals, mixer layout and status indicators.
- Connect read-only active/standby identity and real transport state.
- Use explicitly labelled visual placeholders only where data work has not yet landed.

**Exit criteria:** entering/leaving Console is playback-neutral; screen accurately reflects the existing engine and survives rotation, background/foreground and back navigation.

### Phase 2 — live deck and waveform integration

- Connect actual deck identity, track metadata, duration and position.
- Implement track waveform analysis, storage/cache policy and efficient rendering.
- Add beat-grid overlays only after analysis quality and confidence are validated.
- Ensure role swaps, queue edits and track replacement update both deck views correctly.

**Exit criteria:** waveform and playhead correspond to the correct media occurrence and real playback position; no stale deck identity after promotion or queue mutation.

### Phase 3 — safe performance controls

- Add the first supported jog/seek/nudge interactions.
- Integrate channel EQ and filter controls through the established DSP path.
- Define and implement crossfader semantics against native transition authority.
- Add cue/loop controls only after native support, precision and lifecycle semantics are specified.
- Add tempo/pitch controls only when actual time-stretch and BPM behavior is validated.

**Exit criteria:** every enabled control has a real, documented effect; no competing audio path, gain envelope or unleased transport write.

### Phase 4 — performance intelligence and polish

- Add confidence-aware beat alignment and BPM matching.
- Add useful transition visualization and performance feedback based on native telemetry.
- Tune animations, rendering performance, accessibility, reduced motion and larger-screen layouts.
- Validate sustained use, rapid gestures, interruptions, route changes and thermal/memory behavior.

**Exit criteria:** performance UI remains synchronized and responsive under realistic sessions without regressions to standard playback.

## 9. Test strategy and release gates

Every phase should include targeted tests plus the existing full CI suite.

Required coverage includes:

- Opening and closing Console does not alter playback, queue or focus.
- Active/standby role mapping before and after physical deck promotion.
- Manual Console action preempting lower-priority automatic DJ work safely.
- Revocation during preload, seek, gesture and transition.
- Queue insertion/removal/reorder and provider/native playable-item mapping.
- Standby remains silent and does not request audio focus.
- Crossfader behavior at both extremes, center, rapid movement and authority loss.
- DSP controls route to the correct active deck after promotion.
- Missing/unsupported media, preparation failure and stale metadata.
- Background/foreground, audio focus interruption, headset/system transport actions and route disposal.
- Reduced-motion behavior and narrow landscape layouts.
- No playback races, audible overlap, unexpected silence, crackling or regression in Repeat One/repeat behavior.

A verifying release APK is required after implementation changes. CI green is necessary but does not replace device testing of actual audio behavior.

## 10. Explicit non-goals for the initial Console foundation

- Replacing the standard Resonate player.
- Replacing or removing the existing DJ Workspace.
- Rewriting the Media3 playback engine.
- Introducing a second audio player or parallel output path.
- Shipping decorative controls that imply unsupported behavior.
- Claiming professional scratching, beatmatching, time-stretching, looping or cue performance before the underlying capability is implemented and measured.
- Treating the live spectrum visualization as a track waveform.
- Broad removal of legacy dependencies unrelated to the Console's playback authority and race-safety requirements.

## 11. Definition of success

A user can enter DJ Workspace, deliberately open DJ Console, and immediately understand the two-deck performance surface. The Console presents the real state of Resonate's playback engine, gives users reliable controls for the capabilities that are genuinely supported, and makes the process of preparing, monitoring and transitioning between tracks visible and engaging.

The standard player remains familiar. DJ Workspace remains valuable as the overview/monitoring environment. DJ Console adds a distinct, landscape-first performance experience without compromising the single-authority Media3 architecture.

---

**Implementation note:** This document records product direction and technical constraints. It does not claim that the proposed Console UI, waveform pipeline, jog behavior, mixer semantics or performance controls have already been implemented. Each capability must be validated against the current native and DSP contracts before being exposed.
