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

## DJ Console — gated parallel workstream

The landscape DJ Console visual foundation may proceed in parallel with playback hardening. It must not create another player or output path. The initial visual shell is observational and must label any placeholder visualization honestly. Manual deck preparation, cueing, jog/scratch, channel gain and crossfader actions remain unavailable until their Media3/DSP command contracts, lease behavior, cancellation rules and regression tests are implemented.

## Release discipline

- All implementation commits target `dj-workspace-development`.
- Keep PR #221 open; do not merge without explicit user approval.
- Keep `Resonate-True-Apk` untouched.
- CI success is not a substitute for physical-device listening and interaction tests.
