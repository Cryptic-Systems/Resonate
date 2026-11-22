# Resonate — Known Issues and Quality Register

**Status:** Active engineering register  
**Target branch:** `dj-workspace-development`  
**Last reviewed:** 2026-11-22

This register consolidates user-observed playback quality concerns and engineering observations. An observation is not promoted to a confirmed root cause without reproducible evidence. Items remain open until their exit criteria are met on CI and, where required, verified on a physical device.

## Severity and evidence policy

- **P0 — release blocker:** data loss, crash loop, unsafe output, or loss of playback authority.
- **P1 — high:** repeatable playback corruption, audible artifact, or core transport defect.
- **P2 — medium:** intermittent UX/state defect or missing expected automation.
- **P3 — tracked enhancement:** quality improvement with a safe workaround.

Evidence labels:
- **User-observed:** reported during real-device use; exact reproduction may still be pending.
- **Diagnostics-observed:** supported by a diagnostics event or trace.
- **Engineering hypothesis:** plausible code-level explanation, not yet proven.
- **Confirmed:** reproduced and isolated with a regression test.

---

## RQ-001 — Crackling during complex DJ transitions

**Priority:** P1  
**Status:** Open — investigation required  
**Evidence:** User-observed; one diagnostics underrun was observed, but it did not occur during an active fade.

**Observed behavior**

Audible crackling persists most noticeably during complex transitions, particularly phrase-aware and beat-match crossfades. The application otherwise performed well during the user's latest test session.

**What diagnostics currently establish**

- The report contained 63 crossfade starts, 60 commits, one fallback and one recorded native audio underrun.
- The recorded underrun occurred after a completed transition, not during an active fade. It does not establish that a crossfade caused the underrun.
- Gain-discontinuity events may compare logical active/standby roles across physical deck promotion rather than the same physical player's gain. Verify instrumentation before interpreting these as audible gain jumps.

**Engineering hypotheses to test**

1. DSP engine creation/activation or destruction occurs synchronously on deck-role changes and may contend with the PCM processing lock.
2. Both deck processors are active during the fade, increasing simultaneous native processing load.
3. Phrase/beat-match SFX, EQ overlays, auxiliary samples or automation may add transient work at the same time.
4. The output route/device may contribute; compare Bluetooth and built-in/wired output without assuming route causality.

**Required work**

- Instrument bounded per-deck DSP process duration and lifecycle timings with low diagnostic overhead.
- Verify gain telemetry against physical deck IDs.
- Isolate a standard fade from phrase/beat-match fades and compare with transition effects disabled.
- Move expensive lifecycle work away from the transition boundary only if native handle lifetime and PCM-thread safety can be proven.
- Preserve standby mute/no-focus behavior, Media3 sole playback authority and equal-power native gain policy.

**Exit criteria**

Reproducible transition tests show no processor lifecycle race; telemetry can identify real physical-deck gain discontinuities; device testing confirms whether the reported crackle is resolved across the affected transition types.

---

## RQ-002 — DSP intelligence reacts too aggressively and ducks too often

**Priority:** P1  
**Status:** Open — behavior redesign required  
**Evidence:** User-observed.

**Observed behavior**

DSP intelligence can become overwhelmed, apply frequent or excessive ducking, and surprise the listener with audible changes or distortion risk.

**Code-level finding to validate**

The current native auto-DVC path targets a short-term RMS level (default target -18 dB, default analysis window 400 ms) and permits up to 12 dB of cut by default. That can make a dense or temporarily loud passage pull gain down noticeably. This is a concrete candidate for the reported frequent ducking, but we still need to confirm the active Resonate settings and whether other gain controllers are contributing.

The silence-hygiene block also decays the applied auto-gain during sustained low RMS, but the auto-DVC target calculation runs immediately afterward in the same processing block. Since silence produces a very low RMS reading, the controller can request positive gain again. This weakens the intended silence-hygiene behavior and may leave gain elevated when signal returns. Add a regression test before changing the policy.

**Desired behavior**

DSP should look ahead, assess confidence and intervene proportionally. It must distinguish a genuine clipping/distortion risk from a short transient, a dense musical passage, a quiet breakdown or an intentional mix decision. Protective gain reduction must be bounded, smoothed and reversible; low-confidence analysis should not trigger aggressive changes.

**Required work**

- Audit auto-gain, auto-preamp, auto-bass, DVC, limiter and analysis-hint interactions as a single gain-staging system.
- Identify overlapping controllers that may each reduce gain for the same event.
- Define look-ahead windows, confidence thresholds, maximum correction, attack/release smoothing and hysteresis.
- Ensure sustained silence suppresses positive auto-gain accumulation until a stable signal has returned; validate the resume ramp against transient material.
- Ensure the limiter is the final safety boundary and upstream intelligence does not create gain oscillation.
- Add telemetry for decision reason, confidence, requested/applied gain and limiter activity.
- Test dense transients, sustained bass, quiet passages, clipping-prone material and rapid track changes.

**Guardrail**

Do not simply disable protection or raise thresholds to reduce ducking. Prevent distortion while avoiding unnecessary audible intervention.

**Exit criteria**

A documented gain budget and decision policy, deterministic tests for each controller interaction, and device listening tests show fewer unnecessary ducking events without clipping or distortion.

---


### DSP work started — sustained-silence auto-gain gate

A targeted native DSP change is now on the development branch: after the configured silence threshold and hold duration are met, auto-DVC targets unity gain instead of interpreting sustained silence as a request for positive gain. The gate releases only after the running RMS clears the silence threshold with 3 dB hysteresis. Disabling silence hygiene clears the gate state. A native regression test covers sustained silence and signal recovery.

**Status:** Implemented; awaiting CI validation. This is a narrow correction to the existing silence-hygiene/auto-gain interaction. It is not the full look-ahead redesign and does not resolve the user's separate request for track-silence-aware crossfades.

## RQ-003 — Pause control briefly becomes stale after library track selection

**Priority:** P2  
**Status:** Open — reproduce and trace state synchronization  
**Evidence:** User-observed; reported to self-correct without another action.

**Observed behavior**

After tapping a track in the library, the pause control can briefly display stale state before correcting itself.

**Investigation**

Trace the selected-song intent, Media3 timeline/metadata publication, provider reconciliation, `isPlaying` updates and the UI's selected-track binding. Distinguish a stale visual state from a delayed or incorrect transport command.

**Required work**

- Capture a timestamped state sequence for rapid library selection while playing, paused and transitioning.
- Ensure the selected occurrence is fenced from stale previous-item snapshots.
- Keep the transport icon derived from canonical session state, with an explicit pending-selection state where needed.
- Do not optimistically claim a pause/play result that the canonical session has not confirmed.

**Exit criteria**

A regression test covers library selection from playing and paused states, including delayed Media3 timeline publication; device testing confirms the control never visibly reports the prior track's transport state after the selection settles.

---

## RQ-004 — Silence-aware transition trigger is missing or unreliable

**Priority:** P2  
**Status:** Open — requirements and detection design  
**Evidence:** User-observed.

**Observed behavior**

Resonate does not reliably recognize track silence and trigger an appropriate crossfade.

**Required distinction**

- **Silence detected:** measured signal remains below a defined threshold for a sustained interval.
- **Safe transition opportunity:** silence is judged to be a suitable transition point after considering track position, remaining duration, queue/transition state, and confidence.

Silence alone must never be sufficient to start a transition. Quiet intros, breakdowns, pauses, sparse passages and intentionally silent sections must not cause premature track changes.

**Required work**

- Define a robust energy/RMS-based detector with configurable threshold, hold duration, hysteresis and confidence.
- Use look-ahead or buffered analysis where available; do not block the audio thread.
- Scope detection to the current media identity and reset it on seek, track change, route/session reset and ownership changes.
- Gate automatic transitions through existing PlaybackControlArbiter and CrossfadeTransitionGuard contracts.
- Add negative tests for quiet music, breakdowns, silence at the beginning, short gaps and user pause/seek.

**Exit criteria**

Detection is identity-scoped and deterministic; only a separately validated safe-transition decision can request a crossfade; user transport always preempts it.

---

## RQ-005 — DSP lifecycle contention at crossfade activation

**Priority:** P1 investigation item  
**Status:** Engineering hypothesis — not confirmed  
**Evidence:** Code inspection.

The current processor synchronizes PCM processing and deck activation/deactivation on the same per-processor lock. Deck activation may create a native engine, while deactivation may destroy it. This is a plausible source of contention near a transition boundary, but there is not yet evidence that it causes the reported crackling.

**Required work**

Measure lock wait, native create/destroy duration and process duration. Any lifecycle redesign must prove native-handle lifetime safety and preserve pass-through fallback. Do not introduce an unsafe lock-free handle swap.

---

## RQ-006 — Gain discontinuity telemetry may be role-mapped

**Priority:** P2  
**Status:** Open — instrumentation validation  
**Evidence:** Diagnostics interpretation.

At promotion, physical decks exchange logical active/standby roles. A before/after comparison that follows logical roles can report a large gain change even when each physical player's gain changes correctly. Confirm whether the event compares physical deck A/B or logical active/standby values; correct the instrumentation if required.

**Exit criteria**

A test proves the telemetry compares the same physical player across promotion and reports genuine gain discontinuities only.

---

## RQ-007 — PCM analysis drops non-zero-offset decoder output

**Priority:** P1 analysis correctness  
**Status:** Targeted fix implemented; CI passed in build #2497; device codec coverage pending  
**Evidence:** Code inspection and timestamp-boundary regression tests.

The native PCM decoder bounded output timestamps against the window duration alone, even though `MediaCodec.BufferInfo.presentationTimeUs` is on the track timeline. Consequently, decoded buffers from windows beginning after that relative duration could be discarded. The decoder now checks the requested absolute window, allows at most 10 seconds of seek preroll for `SEEK_TO_CLOSEST_SYNC`, returns the first included output timestamp, and the Dart profile builder uses that measured timestamp instead of assuming the requested seek position was the actual decode start. The preroll bound also prevents a failed seek from silently returning audio from the beginning of the track.

**Validation:** Pure Kotlin tests cover non-zero offsets, inclusive window end, out-of-window timestamps and invalid inputs. Device codec coverage remains required.

---



## RQ-008 — DJ Console waveform coverage is sparse by design

**Priority:** P2 product capability  
**Status:** First measured-window implementation complete; full-track streaming waveform deferred  
**Evidence:** Analyzer and serializer implementation with focused tests.

The current PCM profile analyzer decodes up to four distributed short windows per track. The Console now renders bounded peak envelopes derived from those actual PCM16 samples. Each segment retains its measured track-relative start/end time, and gaps are not interpolated or represented as audio. The profile serializer treats waveform segments as optional so older cached profiles remain readable. Idle analysis detects profiles without waveform data and can refresh them when playback is idle, with a retry cooldown.

**Known limitation**

This is a sampled waveform preview, not a continuous full-track waveform. Full-track coverage requires a separate streaming decoder with bounded memory, cancellation, cache persistence and CPU policy. It must not run synchronously on Console entry or compete with active playback.

**Exit criteria for the next waveform milestone**

- Keep sparse-window rendering honest and identity-scoped.
- Add measured beat/phrase overlays only where beat-grid confidence supports them.
- Design and benchmark a bounded-memory streaming decode/cache path before claiming full-track coverage.

## DJ Console — gated parallel workstream

The landscape DJ Console visual foundation may proceed in parallel with playback hardening. It must not create another player or output path. The initial visual shell is observational. Sampled PCM peak envelopes are now derived from the existing distributed decode windows, persisted as optional sparse segments, and rendered only against the verified active physical deck. Unanalysed gaps remain visibly empty; no full-track waveform is implied. Existing cached profiles without waveform segments are backfilled by the idle analysis scan, subject to its retry cooldown. Manual deck preparation, cueing, jog/scratch, channel gain and crossfader actions remain unavailable until their Media3/DSP command contracts, lease behavior, cancellation rules and regression tests are implemented.

## Release discipline

- All implementation commits target `dj-workspace-development`.
- Keep PR #221 open; do not merge without explicit user approval.
- Keep `Resonate-True-Apk` untouched.
- CI success is not a substitute for physical-device listening and interaction tests.

## Today's scope boundary — 2026-11-22

**Authorized workstreams for this session:**
1. DSP intelligence/audio-quality work, with conservative changes and regression coverage.
2. DJ Console visual foundation and safe architecture preparation.

**Documented but explicitly deferred today:**
- RQ-003 stale pause display after library selection.
- RQ-004 silence-aware automatic transition trigger.
- Any unrelated playback refactor, player migration, transport-state rewrite or broad cleanup.

These deferred items remain in the register and must not be opportunistically changed during today's work. If DSP investigation touches a shared path, make only the minimum isolated change required for the DSP objective, preserve existing Media3 ownership and playback-arbiter behavior, and stop rather than broaden scope if a safe boundary cannot be established.

**Risk policy:** no speculative real-time threading/lock-free changes, no second playback path, no standby audio-focus changes, no changes to production branch, and no merging PR #221. Every implementation change requires focused tests and CI; device-only behavior must remain explicitly unverified until tested on hardware.
