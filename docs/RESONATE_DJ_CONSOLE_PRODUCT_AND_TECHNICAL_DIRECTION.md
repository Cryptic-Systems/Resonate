# Resonate DJ Console — Product & Technical Direction

**Status:** DJ Workspace remains watch-only; landscape DJ Console supports physical A/B deck operation, manual standby preparation/cue/equal-power handoff, bounded active-deck jog seeking, native-readback tempo/pitch, per-deck EQ/filter/channel gain, lease-protected continuous crossfader control, and native per-deck A/B loop ranges; scratch remains gated pending a dedicated low-latency PCM/media-clock implementation and device validation  
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

### 5.5 Playback speed, pitch and key lock

- Media3 exposes `PlaybackParameters(speed, pitch)` through the existing ExoPlayer decks. Resonate's custom `DefaultAudioSink` retains the deck DSP processors and forwards Media3's audio-track playback-parameter capability flag.
- Existing shared speed and pitch commands apply to both logical decks; automatic DJ handoff already has a separate active/standby speed command.
- The Console requires an atomic per-deck speed/pitch command so changing one deck cannot silently alter the other. The native service applies complete parameters to the current logical active and standby players; parameters remain attached to the player instance through physical A/B promotion.
- Native crossfade telemetry now reports active/standby speed and pitch from the actual ExoPlayer instances. These values flow through the typed Media3 state, playback snapshot and provider shadow state; missing or malformed values remain unavailable rather than being replaced with unity defaults.
- `MusicProvider.setPreparedManualDjDeckParameters` is the only manual-DJ write entry point. It requires the current interactive lease, verified prepared queue occurrences, active Media3 session, playing state and an idle `ready` crossfade state; it rechecks lease and queue identity after the native call. User transport retains higher priority and can pre-empt the manual lease.
- The initial manual tempo-fader policy is limited to ±6%, matching the existing automatic DJ stretch ceiling. With key lock enabled, tempo changes retain pitch at 1.0; with key lock disabled, pitch follows the speed multiplier. The native transport API retains its wider 0.5–2.0 validation envelope for compatibility, but the Console policy must not expose that full range.
- Pitch preservation and sound quality remain device/codec dependent. CI can validate parameter routing and policy, but only physical-device listening can validate artifacts, transient quality and audible pitch stability.
- Tempo/pitch controls coordinate promotion with native readback so the incoming deck's selected speed/pitch is not silently normalized or misrepresented after handoff. Automatic DJ tempo matching must not override an active manual lease. Controls are exposed only while a prepared-deck lease is current, native readback is complete and the transition state is ready; device validation of sound quality and recovery remains a release gate.

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

**Current implementation:** landscape route, two-deck shell, measured progressive waveform pipeline and live deck identity are present. The Console supports independent physical A/B transport and deck loading/clearing; lease-protected manual standby preparation, cueing and native equal-power handoff; one-shot active-deck jog seeking; native-readback tempo/pitch; per-deck three-band EQ, filter and channel gain; a continuous crossfader whose drag retains interactive authority and drains accepted writes before user-transport preemption; and manual A/B loop ranges scheduled against each deck's native Media3 media clock. Scratch emulation remains gated because it needs a separate low-latency PCM/media-clock interaction contract and device validation.

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

**Implemented:** bounded active-deck jog seeking; manual standby cue and native handoff; native-readback per-deck tempo/pitch; per-deck three-band EQ and LP/HP filter controls; independent channel gain; a continuous equal-power crossfader with a retained interactive lease; and manual per-deck A/B loop points. Loop boundaries are scheduled by native Media3 `PlayerMessage` events on the selected player's application looper, not by Flutter timers. Loop state follows physical A/B identity through promotion, survives pause/resume, and is cleared on deck replacement, track change or an explicit seek outside the range. The loop range is checked against the current media identity, seekability and duration. Native Media3 remains the sole playback authority.

**Still intentionally gated:** scratch-style platter manipulation and beat nudging. The current `DspEngineAudioProcessor` receives decoded PCM ahead of the audible media position, while Media3 playback parameters do not provide reverse playback. Rapid `seekTo` calls are not an acceptable substitute. A real scratch implementation needs a bounded per-deck PCM ring buffer, a reliable mapping between buffered frames and media time, bidirectional platter-rate control, deterministic catch-up/seek on release, and cancellation on transport preemption, deck promotion, pause, interruption and track replacement. It must remain inside the existing Media3 audio-sink path and prove that it introduces no competing output, dropouts or DSP-state leakage.

**Exit criteria:** every enabled control has a real, documented effect; no competing audio path, gain envelope or unleased transport write. CI validates policy and command routing; physical-device listening remains required to verify loop-boundary audibility, scratch latency, sound quality, clipping/crackle and transition behaviour.

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

## 2026-11-23 — active platter motion (visual-only)

The Console platters now rotate at an approximately 33⅓ RPM presentation rate only when the canonical player state reports playback and the corresponding physical deck is verified as active. They stop when playback pauses or the deck is no longer active, and reset their visual phase when the verified song identity changes. This is a visual status cue only: it does not expose touch/jog input, alter playback speed, seek, cue, or write transport state. Standby and identity-unknown decks remain stationary. Physical-device review is still required for visual smoothness and compact landscape sizing.



## 2026-11-23 — manual Deck B controls and bounded jog seeking

The Console now exposes the existing Media3-backed operator workflow for selecting and preparing a standby queue occurrence, setting its cue position, cancelling preparation, and performing a native equal-power handoff. The provider retains an interactive playback-control lease while the incoming deck is reviewed; user transport can preempt it. The UI reads lease-validated prepared-deck state and does not create a second player or write deck gain directly.

The active physical deck's platter now accepts a touch-and-drag seek gesture. Rotation is translated into a preview only while the verified active deck is playing in an active Media3 session and no transition is underway. One full platter revolution represents eight seconds. A single existing MusicProvider.seek command is issued on release, using user-transport priority and the existing arbiter; there are no per-frame seek writes. The gesture is discarded on cancellation, track identity change, loss of active-deck eligibility or transition state. This is bounded seeking, not scratch emulation, pitch control, nudging or time-stretching.

Jog seek policy tests cover forward/reverse movement, angle wrap, track-boundary clamping and non-finite input. CI and physical-device interaction/audio review remain required; CI does not establish tactile latency or hardware behaviour.


## 2026-11-23 — native-readback per-deck tempo controls

The Console now includes a bounded ±6% tempo fader and key-lock toggle on each physical deck panel. Each control resolves physical A/B identity against the latest native active-deck ID on every build and commit; after promotion, the same physical player retains its own settings and its UI role changes from standby to on-air (or vice versa). Values are sourced from native active/standby speed and pitch telemetry. Missing, malformed or out-of-range readback disables the control rather than substituting unity values.

Tempo writes are committed once when the slider is released, not continuously during drag. The provider requires the current manual interactive lease, verified prepared queue occurrences, active Media3 session, playback and a ready/non-transitioning native state. The write updates both complete deck parameter pairs atomically while changing only the selected physical deck's values. Key lock is enabled by default; when enabled pitch remains 1.0, and when disabled pitch follows the speed multiplier. The fader does not claim scratch, nudge or beatmatching support.

`PlaybackParameters` remain attached to the physical ExoPlayer across promotion. Manual handoff no longer normalizes both decks to unity after promotion. Standby cleanup restores only the muted standby deck to unity while preserving the active deck's current speed and pitch, and only when valid native active-deck readback is available. CI coverage includes physical A/B role swapping; real-device listening is still required to validate pitch quality, artifacts and audible tempo transitions.

## 2026-11-24 — native crossfader single-deck safety

The native DJ gain path now pins the only audible physical deck to unity crossfader gain (while retaining its independent channel-gain factor) whenever the peer deck is empty or not playing. This avoids the previous equal-power center position attenuating a solo active deck by approximately 3 dB during DJ-mode entry or standby preparation. Native crossfader writes are rejected unless DJ dual-deck mode is active, both physical decks contain media and are playing, and no native transition currently owns the gain envelope. This is a native safety prerequisite only: the continuous crossfader UI remains gated until the provider-level interactive lease, cancellation/authority-loss behavior, and physical-device transition behavior are fully validated.


## 2026-11-26 — continuous DJ mixer controls and final state consistency

The Console now exposes the native Media3-backed physical-deck workflow for A/B loading, play/pause, seek, cue preparation, tempo/pitch, three-band EQ, filter and channel gain, alongside the lease-protected continuous crossfader. The crossfader retains interactive arbiter authority for the full drag, drains accepted native writes before higher-priority user transport proceeds, and rejects later writes from a preempted gesture. Native Media3 remains the sole gain-envelope and deck-promotion authority. A provider-state defect was also corrected so clearing a deck's EQ resets the visible three-band gains only after the native reset succeeds. Scratch and looping remain gated; neither is represented as implemented. CI green does not replace physical-device validation of sound quality and gesture feel.


### 2026-11-26 — Native loop-control pass

The DJ Console now has native per-deck A/B loop-range commands and loop-state readback. The service validates the selected physical deck, exact current media ID, seekability, known duration, minimum loop span and a guard before track end. Boundary callbacks are scheduled against the Media3 player's media clock; loop state is retained by physical A/B identity across canonical promotion and cleaned up on deck/track replacement, mode exit or an explicit seek outside the range. Flutter owns only the A/B point selection and UI; all boundary execution remains native. This is a first loop-control implementation, not a claim of sample-perfect/gapless loop seams: verify local and content-provider media on physical devices before release.

Scratch remains gated. The existing decoded-PCM processor does not receive media timestamps for every input buffer, so a safe scratch design must first solve frame-to-media-clock mapping and bounded bidirectional playback without issuing high-frequency decoder seeks.

### 2026-11-26 — scratch audio-path investigation

The first scratch engineering pass inspected the actual Media3 renderer and DSP sink wiring. No scratch gesture or audio effect has been enabled yet.

**Verified current path**
- Each physical ExoPlayer is built with a `DefaultAudioSink` whose processor chain is supplied by `DspEngineSinkHook.createProcessors(deckId)`.
- The current chain contains one `DspEngineAudioProcessor`; it receives decoded PCM through `BaseAudioProcessor.queueInput(ByteBuffer)`, applies the deck's native DSP engine and fails open to the original PCM on processing errors.
- `AudioProcessor.queueInput` itself carries no presentation timestamp. Decoder output can be queued ahead of audible playback, so reading `Player.currentPosition` from that callback would not provide a valid timestamp for the PCM block being processed.
- The custom `DefaultAudioSink` construction point is a potential place to introduce a timestamp-aware sink adapter, because the `AudioSink.handleBuffer` contract carries a presentation timestamp. That is only a candidate integration point: it must be verified against Media3 1.5.1's buffering/retry and processor-drain behaviour before relying on a thread-local or side-channel timestamp association.

**Implementation sequence required before enabling platter scratching**
1. Verify the exact Media3 1.5.1 `AudioSink.handleBuffer` and `DefaultAudioSink` call lifecycle, including partial buffer consumption, processor drain, flush, discontinuity and playback-parameter changes.
2. Add a per-physical-deck timestamp/frame ledger at the sink boundary. It must account for PCM frame offsets, sample rate, channel count, playback speed, partial writes and processor latency; stale mappings must be invalidated on seek, flush, format change, track replacement and deck retirement.
3. Add a bounded PCM ring buffer and an audio-thread-owned read cursor. Platter movement may change cursor direction and rate only within buffered, timestamp-mapped media. The render path must remain bounded and allocation-free.
4. On release, derive a deterministic media position from the actual scratch cursor and hand control back to normal Media3 decoding through one controlled seek/catch-up operation. Do not issue repeated decoder seeks during the gesture.
5. Insert the scratch stage into the existing per-deck Media3 sink chain without creating a second player, AudioTrack or output path. Preserve the native DSP stage and fail-open behaviour.
6. Add deterministic tests for ring bounds, cursor direction/rate, timestamp mapping, partial buffer retries, pause/resume, seek/flush invalidation, track replacement, cancellation, physical-deck independence and release/catch-up.
7. Only expose the platter scratch gesture after CI and physical-device testing verify latency, pitch/rate response, reverse audio, clipping, crackle, underruns and seamless recovery.

**Status at the end of this investigation:** the platter gesture remained bounded one-shot seek; it was not scratch. The timestamp/frame ledger and processor probe were subsequently implemented in the next section below. No simulated scratch, reverse-speed shortcut or repeated-seek implementation has been added.

**Media3 1.5.1 source verification:** the pinned `AudioSink.handleBuffer(ByteBuffer, presentationTimeUs, encodedAccessUnitCount)` API does expose the input buffer's media presentation timestamp. In the pinned `DefaultAudioSink`, a new input buffer is accepted once, then `processBuffers(presentationTimeUs)` drains any prior processor output before queueing the current input into the `AudioProcessingPipeline`. The same input buffer is retained across back-pressure retries; `handleDiscontinuity()` marks media-time resynchronization, and `flush()` resets sink state. This confirms a sink-boundary timestamp/frame ledger is technically plausible, but not that a simple thread-local timestamp is sufficient: the implementation must prove one-to-one association between each processor input block and its originating timestamp, including processor output buffering and drain calls. The verified source is the exact Media3 1.5.1 `AudioSink.java` and `DefaultAudioSink.java` used by the Android dependency.

### 2026-11-26 — scratch timestamp/frame-ledger foundation

Implemented the first runtime foundation on the existing Media3 output path:

- Each physical deck's `DefaultAudioSink` is now wrapped by `TimestampedDjAudioSink`, which records the media PTS against the exact `ByteBuffer` identity passed to `AudioSink.handleBuffer`.
- The wrapper delegates all other `AudioSink` operations unchanged. `flush()` and `reset()` invalidate pending timestamp associations; ordinary discontinuity notifications do not discard earlier queued-buffer mappings.
- A first-in-chain `DjScratchTimestampProcessor` consumes the matching timestamp when Media3's processor pipeline queues that exact PCM input buffer, then passes the PCM through unchanged before the existing native DSP processor.
- The ledger derives frame count from PCM16 channel layout and maps frame offsets to media time using the configured sample rate. It rejects unsupported channel layouts, invalid rates and non-frame-aligned buffers.
- The identity map is capped at 64 outstanding entries to bound memory if an input path bypasses processor consumption.
- Unit tests cover identity vs content equality, repeated handleBuffer retries, one-time consumption, frame/time mapping, malformed PCM and invalidation.

**Scope and limits:** this is a timestamp/frame association layer, not the scratch engine. It does not alter audio, change playback speed, reverse samples, or expose a scratch gesture. The probe retains the most recently consumed block metadata only; no PCM ring buffer/cursor exists yet. Before building the ring, validate the adapter against the real Media3 sink lifecycle and add processor-level tests for format changes, partial writes and flush/drain ordering. Device latency and audible behaviour remain unverified.


### 2026-11-26 — bounded scratch PCM history and cursor foundation

The next scratch foundation is now implemented as an isolated, testable native component:

- `DjScratchPcmRingBuffer` stores interleaved PCM16 samples in fixed-capacity arrays, with a hard maximum of 192,000 frames (four seconds at 48 kHz). It does not resize or allocate per frame.
- Absolute frame indices remain monotonic across wrap and clear operations. The ring tracks the first still-valid frame explicitly, so a stale cursor cannot silently alias newly captured audio after a flush; invalidation is O(1), with no large-array clear on the audio thread.
- Each retained frame has its own source-media timestamp. This preserves timestamp discontinuities between input blocks rather than assuming decoder output is always contiguous.
- Oversized input blocks retain only the newest frames; malformed, unaligned and negative-PTS blocks are rejected.
- `DjScratchFrameCursor` provides bounded forward, hold and reverse cursor math with finite-value validation and a maximum velocity. It is control math only, not an audio renderer.
- The timestamp processor now passively copies each timestamped PCM16 block into a per-physical-deck ring before the unchanged native DSP stage. The output buffer is still passed through unchanged. Unsupported layouts do not allocate a ring; processor flush clears history and reset releases it.
- Tests cover stereo interleaving, wrap/overflow, per-frame PTS, discontinuous blocks, clear invalidation, cursor direction and bounds, and byte-exact processor pass-through.

**Scope and safety:** no scratch gesture is exposed and no cursor is currently allowed to alter audible output. The ring is a bounded capture history only. The next pass must add the audio-thread control handoff and a deterministic render/read policy, then prove normal playback, flush/seek/format changes, pause/resume and cancellation before any scratch audio is enabled. Physical-device latency and sound-quality validation remain outstanding.


### 2026-11-28 — scratch gate reassertion and Media3 1.5.1 source audit

The previous scratch experiment had progressed beyond the documented gate: the platter was publishing native scratch commands and the timestamp processor could replace audible PCM, even though the release/catch-up contract and physical-device validation were not complete. This was premature and has been corrected.

- The platter gesture is again a bounded one-shot seek preview committed once on release. Cancellation, pause, track replacement and transition do not commit a seek.
- The native service rejects scratch commands while the feature gate is closed. The timestamp processor continues passive PCM capture but always passes the original PCM through unchanged. Renderer-policy unit tests remain algorithm tests; they are not evidence that audible scratching is enabled.
- The DJ DefaultAudioSink now explicitly disables float output. In the pinned Media3 1.5.1 source, selecting float output constructs a pipeline containing only the float conversion processor and omits the configured user AudioProcessor chain. Resonate's native DSP and timestamp stages require the PCM16 user-processor path; relying on the renderer-factory float flag could therefore bypass both.
- Source inspection also confirms that Media3's built-in trim, channel-map and PCM conversion processors run before the configured user processors, while silence skipping and Sonic speed adjustment run after them. The timestamp ledger currently records PTS at AudioSink.handleBuffer, before those transformations. Identity/FIFO association alone does not yet prove correct frame provenance through encoder-delay trimming, channel mapping, PCM conversion, processor drain/back-pressure or playback-speed changes.
- The current release policy fades toward the live Media3 input, but Media3 continues decoding while scratch output is substituted. That is not a deterministic handoff to the scratch cursor's media position. Release must instead be coordinated with the actual audible output boundary and one controlled native seek/catch-up, without flushing the stream before the release envelope is heard.

**Next implementation gate:** replace the one-buffer identity/FIFO assumption with a frame-span timeline that accounts for the configured PCM format, encoder-delay trimming, channel mapping, buffer conversion and retries; prove its association under the pinned 1.5.1 pipeline; then solve speed-stage placement and audible-boundary release/catch-up. Only after those tests pass may the scratch feature gate be opened. No physical-device validation is claimed by this source audit or by CI.


### 2026-11-28 — frame-span timestamp association foundation

The sink timestamp ledger has been advanced from buffer-identity/FIFO lookup to a bounded FIFO frame-span timeline:

- `TimestampedDjAudioSink.configure` captures the accepted raw PCM source sample rate, channel count, PCM frame size and encoder delay from the Media3 `Format`. Non-raw sink formats are not treated as PCM history.
- Each sink input buffer contributes a frame span. Retry calls for the same `ByteBuffer` retain the original PTS and do not enqueue a duplicate span.
- The first user processor consumes output frame counts from those spans in FIFO order. The timeline skips configured encoder-delay frames across input-buffer boundaries, tolerates channel remapping, and accounts for source sample-width conversion (including float-to-PCM16) without assuming source and processor bytes-per-frame are identical.
- A processor output spanning a non-contiguous PTS range, an unsupported sample rate/layout, or a bounded-queue overflow invalidates the timeline. The ledger stays fail-closed until a new format, flush or explicit discontinuity; it never shifts later PCM onto stale metadata.
- Sink flush restores the configured encoder-delay trim because Media3 flushes its trimming processor. Explicit discontinuity clears queued spans without reapplying the initial encoder delay.

Regression coverage now includes contiguous multi-buffer spans, encoder delay crossing buffer boundaries, stereo-to-mono mapping, float-to-PCM16 frame-size conversion, retried input buffers, discontinuity, flush, non-contiguous PTS rejection and queue invalidation. These tests validate the ledger model; they do not yet prove every codec/renderer combination or enable audible scratch.

**Still outstanding before scratch enablement:** confirm the exact `DefaultAudioSink` lifecycle under partial writes, processor drain/back-pressure and format changes on the supported Media3 renderer configurations; account for playback-speed processing and the actual audible output clock; implement deterministic release/catch-up; then complete physical-device latency, reverse-audio, crackle, underrun and recovery validation.


### 2026-11-28 — scratch PCM history generation invalidation

The per-deck scratch mailbox now carries an atomic generation alongside its latest control snapshot. A clear operation advances that generation and removes the old command in one compare-and-set state transition. This makes the invalidation boundary race-safe: a concurrent new publish is either retired before the clear or tagged with the new generation after it, never silently erased or attached to the previous timeline.

At the first Resonate user-processor callback after a generation change, the audio thread clears that deck's PCM history and render cursor before appending the next timestamped PCM block. This retires buffered history on existing native clear boundaries, including seek, media-item/queue occurrence transition, manual physical-deck promotion and other explicit scratch cancellation paths. It also handles repeated queue occurrences that reuse the same media ID, because invalidation is generation-based rather than media-ID-based.

Diagnostics now expose the observed mailbox generation and the number of history-generation resets. Tests cover generation advancement with and without a current command, replacement-track protection, and publishing into the new generation.

**Scope and limits:** this hardens lifecycle invalidation; it does not solve the audible playback-speed clock or release/catch-up. Media3 Sonic/AudioTrack speed processing remains downstream of the current user-processor insertion point, so scratch rendering remains disabled. The next gate is to define and test the relationship between the cursor's media-time rate and downstream speed processing, then coordinate a release handoff at an actual audible output boundary. No physical-device validation or audible scratch enablement is claimed.


### 2026-11-28 — downstream playback-speed compensation policy

The scratch processor is positioned among Resonate's Media3 user processors, before Media3's downstream Sonic/AudioTrack playback-speed stage. A cursor rate sent directly from the platter would therefore be multiplied again by the user's normal playback speed. Added a bounded mapping policy:

- Requested audible platter velocity is converted to pre-speed-stage cursor velocity by dividing by the current physical deck's PlaybackParameters.speed.
- Reverse direction is preserved; unity speed is unchanged.
- Invalid, non-positive or non-finite playback speeds are rejected.
- A mapping that would exceed the bounded cursor velocity is rejected rather than clamped, so the requested platter rate is never silently altered.
- The native service samples the selected physical deck's current speed when validating/publishing a scratch command. Inactive/release commands remain normalized and do not depend on the speed mapping.
- Unit tests cover unity, faster/slower playback, reverse direction, invalid values and out-of-range compensation.

The CI test fixture was also updated for the mailbox generation field introduced in the preceding lifecycle pass.

**Scope and limits:** this is the rate-compensation contract for the current processor placement, not proof of audible scratch. It assumes the downstream stage's effective time scaling corresponds to the player's reported playback speed; device-specific AudioTrack behaviour, Sonic buffering/latency and playback-parameter changes during an active gesture still require validation. The feature gate remains closed. The next step is to coordinate playback-speed changes with an active cursor and define a release/catch-up handshake against the audible output boundary, then validate on physical devices.


Playback-parameter changes during a published active scratch command now retire that command and advance the mailbox generation. The audio thread consequently discards the old cursor/history at its next processor block; the next platter update must be remapped using the new native playback-speed readback. This intentionally fails closed rather than allowing a stale cursor multiplier to continue through a changed Sonic/AudioTrack rate. The feature remains gated, and the callback-to-audible-boundary timing still needs physical-device verification.

### 2026-11-28 — deterministic scratch release/catch-up protocol foundation

Added a pure native release-handoff state machine with explicit phases: scratching, release requested, seek issued, waiting for aligned post-seek PCM, crossfade ready, complete, and aborted.

The protocol freezes one cursor-derived media timestamp as the only permitted catch-up seek target. It permits that seek to be claimed once, rejects stale generation/media identities, and refuses to declare the release crossfade ready until a timestamped PCM block is within a bounded tolerance of the frozen target. Transport invalidation advances the generation and aborts the handoff.

Regression tests cover one-shot seek claiming, stale decoder output rejection, alignment tolerance, completion ordering, invalid targets and stale-generation aborts.

**Important integration boundary:** this is the deterministic protocol model, not yet wired to the Media3 service/audio thread. The existing render-policy fade toward the current live decoder stream is not a valid catch-up implementation because that stream may be ahead of the substituted scratch cursor. It must not be enabled. The next implementation stage must bridge the processor's cursor-derived media timestamp to a main-thread one-shot native seek, preserve a bounded scratch tail across Media3's seek/flush, detect the first matching post-seek PCM span, and only then crossfade. The scratch feature gate remains closed; no audible scratch or gapless release is claimed.

### 2026-11-28 — cursor-to-media-clock release target

The PCM ring now maps a fractional absolute cursor frame back to source media time, rejecting out-of-window frames, non-monotonic history and timestamp gaps. The render policy exposes the media timestamp immediately after the last rendered scratch frame. The timestamp processor publishes that value as a volatile diagnostic (`cursorMediaTimeUs`) and clears it on processor flush/reset or when the block is not rendered.

Regression coverage verifies fractional frame-to-PTS mapping, discontinuity rejection, and the cursor's post-render timestamp. This is the correct media-clock source for a future release seek; `Player.currentPosition` is not interchangeable because Media3 may decode and queue PCM ahead of audible output.

**Integration remains intentionally incomplete:** the service does not yet issue a seek from this diagnostic. A seek currently flushes the Media3 sink and processor history, so simply wiring a seek here would discard the outgoing scratch tail and create an uncontrolled gap. The next gate must establish a bounded release-tail/dual-output strategy and a generation-safe audio-thread-to-main-thread request/acknowledgement path before connecting the one-shot seek. Audible scratch remains disabled.

### 2026-11-28 — bounded scratch release-tail capture

Added a fixed-capacity PCM16 release-tail buffer sized for 250 ms by default (with a hard 500 ms maximum at 48 kHz). It retains the newest emitted scratch frames, performs no per-frame allocations, rejects malformed partial frames, and supports a one-way seal/drain ownership transfer for a future independent output renderer. Regression tests cover bounded retention, stereo ordering, partial drains, malformed input, sealing, and generation reset.

This is currently an isolated, unit-tested buffer primitive; it is not yet wired into the timestamp processor or a production output path. That separation is intentional: simply retaining the buffer inside the processor is not sufficient, because a seek/flush and a subsequent mailbox-generation change can race the tail's ownership and lifetime. The audio-thread capture owner, flush-time seal, cross-thread transfer, and consumer drain must be designed as one explicit protocol before integration.

**Important boundary:** audible scratch rendering is still compile-time disabled, and no secondary output renderer consumes this buffer. This is a bounded buffer component, not proof that PCM is audible across a seek, not a gapless handoff, and not permission to issue the catch-up seek. The next gate must add a separately owned renderer/output path with explicit audio-route, timestamp, gain, cancellation and drain-completion handling; it must not commandeer either A/B deck or reuse the main deck's sink. Physical-device validation remains mandatory.


### 2026-11-28 — release-tail output ownership protocol

Added a control-plane state machine for the ownership boundary between the scratch PCM capture buffer and a future independent release renderer:

- Capture begins only for a fresh generation, a concrete media occurrence, and a fully specified output contract.
- The capture owner must seal a non-empty tail before ownership can transfer.
- Transfer is one-shot and binds the consumer to the exact PCM sample rate/channel layout, AudioSession ID, route generation and Resonate processing-chain identity. A consumer on a different route/session or a raw output path is rejected.
- Only the named consumer can claim draining. Drain accounting accepts only positive frame counts within the retained remainder, and the lifecycle reaches `DRAINED` only when all frames have been accepted.
- A transport, track, route or output interruption can abort the generation. Stale consumers and stale generation messages cannot resume or drain an aborted tail.

Regression tests cover legal ownership progression, duplicate consumer rejection, route/session/format/processing-chain mismatch, stale generations, invalid drain counts, abort and fresh-generation restart.

**Integration boundary:** this is a control-plane contract only. It does not create an AudioTrack, route audio, apply DSP/gain, transfer the PCM buffer across threads, issue the Media3 catch-up seek or enable audible scratch. The output contract deliberately requires the same Resonate processing-chain identity; a plain secondary AudioTrack that bypasses the DSP path cannot satisfy it. The next stage must identify or implement a genuinely independent output renderer that shares the app's DSP, gain, audio-session and route lifecycle, then connect buffer transfer and drain acknowledgements without blocking the audio callback. Until that path and physical-device validation exist, the scratch feature gate remains closed.


### 2026-11-28 — post-DSP release-tail capture stage

Added an opt-in DjScratchReleaseTailCaptureProcessor as the final stage in each Media3 A/B user-processor chain, after DspEngineAudioProcessor. It copies PCM16 into a bounded 250 ms per-deck tail while passing the original PCM unchanged to Media3. The retained samples are therefore already processed by the same native DSP engine as the audible deck; they must not be sent through DSP a second time.

Capture is disabled by default. The processor prepares and seals buffers only on explicit control-plane calls. Sealing atomically detaches the active generation, waits on the control thread for any already-started bounded copy to finish, then publishes the immutable tail. The real-time callback does not wait for control operations, allocate a new PCM buffer, or change the output bytes. Format validation is limited to the supported PCM16 mono/stereo path.

The sink hook now exposes per-physical-deck begin, seal and sealed-tail accessors. Regression tests verify exact pass-through output, opt-in capture, sealed-tail publication and frame counts.

**Not yet the independent renderer:** this stage establishes a correctly processed PCM source, but it does not yet write the tail to an independent output device, share the active AudioSession/route, reproduce the deck's composed output gain, coordinate the Media3 catch-up seek, or verify audible alignment. The service does not arm capture or start a secondary output, and the compile-time scratch gate remains closed. No audible scratch claim is made.


### 2026-11-28 — timestamped post-DSP release-tail frames

The post-DSP tail capture now carries the source-media PTS from the preceding timestamp processor into the bounded PCM buffer. Each retained PCM frame stores its media timestamp at the configured sample rate, including correct timestamps when the ring overwrites older frames.

The sealed tail exposes a deliberately strict splice-preparation operation:

- discardBeforeMediaTimeUs is allowed only after sealing and only when every captured block had valid timestamp provenance.
- It discards frames strictly earlier than a separately measured audible Media3 media-time boundary.
- The next retained frame timestamp is observable for alignment checks.
- If even one captured block lacks timestamp provenance, trimming fails closed and the tail cannot claim a valid timestamped handoff.

The capture processor still passes every PCM byte unchanged to Media3 and remains opt-in. The timestamp is carried after native DSP; the PCM must not be processed through DSP again.

**Important remaining boundary:** this does not itself measure the audible output clock. The renderer must not call the trim operation with Player.currentPosition or another decoder/queue position and assume it is audible. A reliable AudioTrack playback-head/media-time correlation is still required, along with session/route/gain parity, the independent output writer, one-shot catch-up seek, post-seek alignment and crossfade. No secondary renderer is active and scratch remains gated.


### 2026-11-28 — Media3 audible output-clock access

The timestamped sink wrapper now exposes the position reported by Media3's AudioSink playback-head tracker for each physical A/B deck. The service retains the corresponding sink wrapper and includes the nullable audible media-time values in its native audio diagnostics.

- The value is read from AudioSink.getCurrentPositionUs(false), not ExoPlayer.currentPosition.
- Unset, negative and released-sink values are reported as unavailable rather than guessed.
- The wrapper marks itself unavailable on sink reset and becomes valid again only after a successful configure.
- The service keeps the clock associated with the physical deck, so canonical-player promotion does not relabel A/B sink ownership.

This supplies the clock source needed to calculate which timestamped release-tail frames are already behind the audible output boundary. It is not yet a complete clock-correlation proof: device/route changes, AudioTrack latency behaviour and exact frame alignment still require validation. The renderer, shared session/route contract, output gain parity, catch-up seek and crossfade are still outstanding. The feature gate remains closed.


### 2026-11-28 — per-deck output contract and route generation

The service now observes Android output-device topology with AudioManager.AudioDeviceCallback. Any output device add/remove event advances a monotonic route generation; the callback is registered with the service and unregistered during teardown. The generation is exposed in audio diagnostics.

A per-physical-deck candidate release-output contract is now available when that deck has a configured post-DSP PCM stage and a live Media3 AudioSession ID. It binds:

- Post-DSP PCM16 sample rate and channel count.
- The physical deck's actual Media3 AudioSession ID.
- Current output-device topology generation.
- The named Resonate post-DSP processing-chain identity.

The candidate contract is exposed separately for physical A and B in diagnostics. It resolves the player by physical deck identity rather than assuming the canonical active player is always deck A.

**This is not yet renderer authorization.** The PCM format is measured at the post-DSP processor boundary, not asserted to be the final hardware AudioTrack format. Device add/remove notifications conservatively invalidate a route generation but do not independently identify the selected output device. Before transfer, the independent AudioTrack must be built with the exact deck session and audio attributes, verify its actual routed device/format, and reject a stale route generation. No independent AudioTrack is created by this stage; no release-tail transfer is active and manual scratch remains gated.


### 2026-11-28 — fail-closed independent PCM release renderer

Added the independent Android PCM release-renderer primitive. It builds a dedicated streaming `AudioTrack` using the exact Media3 deck AudioSession ID, media/music audio attributes, PCM16 sample format and caller-supplied output-device identity. It starts muted, requests that exact preferred device, and verifies the actual routed device plus route-generation stability before setting the deck gain or accepting PCM. A missing/mismatched route, stale route generation, invalid session, unsupported format, or failed route request releases the track without writing audio.

The renderer drains only a sealed, timestamped release tail into a caller-owned direct buffer and handles partial blocking writes on its control thread. It never creates a Media3 player, never applies the DSP chain a second time, and never writes before route verification. The deck's effective output gain is supplied explicitly because the post-DSP PCM capture is upstream of Media3's AudioTrack volume. The renderer reports frames actually accepted by AudioTrack; ownership acknowledgement remains a separate control-plane action.

This is deliberately not yet armed by `Media3PlaybackService`: the current Media3 sink wrapper does not expose its selected `AudioTrack.routedDevice`, so the service cannot yet supply a trustworthy matching route-device ID. The new renderer therefore cannot be started by production scratch flow until that missing Media3 route observation is implemented. Scratch remains gated. CI tests validate route mismatch, route-generation invalidation, muted-before-verification behavior, partial writes, and exact PCM/session contract handling; physical-device route and audible handoff validation remain required.


### 2026-11-28 — actual Media3 AudioTrack route observation

The per-deck Media3 sink now supplies a delegating `DefaultAudioSink.AudioTrackProvider` that uses Media3's own default provider to construct the platform `AudioTrack`, while retaining a reference to the exact track instance and its output configuration. The service can report the actual Android-routed output device ID, AudioSession ID, sample rate, channel count, PCM encoding, and whether the track is tunneling or offloaded. Route snapshots are withheld until the platform track is initialized, Android reports a selected routed device, and the observed session matches the requested session. The reference is invalidated on sink reconfiguration, flush, and reset.

This removes the prior route-identity blind spot without replacing Media3's output path or creating a second track. It does not yet authorize release-tail transfer: the output contract still needs to bind the exact route-device ID, confirm the captured post-DSP format matches the actual platform output configuration, and coordinate route-generation invalidation through the transfer and drain lifecycle. Scratch remains gated; no renderer is armed and no claim of audible scratch is made. Unit tests cover the route-snapshot eligibility policy, including rejection of missing identity, non-PCM16 output, tunneling, and offload.
