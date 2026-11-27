# Resonate hardening and device validation

Target branch: `resonate-voice-audit`

This is a release-readiness checklist, not a feature roadmap. Keep the current Resonate sound and controls intact. Prefer narrow fixes backed by a reproduced defect and regression test; do not retune DSP or rewrite playback ownership speculatively.

## Evidence boundaries

- **CI** validates the configured static analysis, automated tests, native DSP stress tests, Android unit tests, release APK build, and 100 MiB APK ceiling.
- **Automated tests** validate the individual contracts they exercise; they cannot prove audio output or OEM-specific audio-session behavior.
- **Device testing** must separately confirm playback continuity, audible DSP behavior, notification behavior, screen-off operation, and route changes.
- A successful fallback after a crossfade failure is recovery, not proof the transition itself succeeded.

## Current known edge to validate

The 2026-10-22 diagnostics captured one DJ crossfade where the incoming engine remained at 335 ms while the transition progressed. The monitor retried playback and then emitted `DJ incoming position stalled during transition`. The provider then entered its ordinary playback fallback and diagnostics showed the incoming track active and playing. This is a contained recovery in the captured session, but the stalled transition itself remains an unresolved reliability edge until it is reproduced or ruled out on device.

Two `audio_focus_pause` entries in that diagnostic session followed explicit player pause commands and were followed by explicit play commands. They are not, by themselves, evidence of an unsolicited focus interruption. Do not alter pause/focus policy based only on those entries.

## Device test matrix

Run these against the release APK built from a green merge commit. Record pass/fail and attach diagnostics for any failure.

### Playback and transport
- [ ] Play, pause, resume, seek, next, previous, and rapid repeated commands.
- [ ] Lock screen / screen off for at least 20 minutes; verify audio and notification controls.
- [ ] Force-stop and relaunch; verify queue/current track restore behavior.
- [ ] Switch Bluetooth/headphones/speaker routes during playback and near a transition.
- [ ] Receive notification/navigation ducking and restore; test call and another-player focus loss; confirm no unexpected resume.
- [ ] Pause/resume fade on and off; confirm no lingering duck or gain jump.

### Crossfade and queue
- [ ] Several consecutive crossfades in Normal mode.
- [ ] Several consecutive DJ transitions, including content-URI tracks.
- [ ] Press Next/Previous and seek during an active fade; latest user command must win.
- [ ] Repeat One loops the same track with matching title/audio; changing repeat policy during a fade takes effect once.
- [ ] Repeat All wraps once at queue end; Repeat Off stops at queue end.
- [ ] A missing/unreadable source is skipped without a stuck spinner or silent player.
- [ ] If an incoming DJ engine stalls, playback recovers to one audible track, UI/queue identity matches the audio, and pause intent is respected.

### DSP and sound identity
- [ ] Switch Resonate Signature, Warmth, and Clarity; restart and confirm the chosen profile persists.
- [ ] Adjust EQ bands and preamp; confirm audible changes and no clipping/gain jump.
- [ ] Change DVC while playing, then during an A/B transition; confirm both engines remain consistent.
- [ ] Compare leveling on quiet/loud tracks and on speaker/headphones/Bluetooth.
- [ ] Verify limiter behavior on peaks; treat crossover as protection processing, not tone shaping.
- [ ] Verify new engines inherit EQ, DVC, preamp, leveling, and limiter settings.

### UI, modes, and resources
- [ ] Switch all nine modes; verify controls, queue identity, and current track remain aligned.
- [ ] Inspect Now Playing artwork crops, text contrast, narrow screens, and large text.
- [ ] Scroll For You and Library; verify no noticeable stutter and current-row position remains stable.
- [ ] Test visualizer/orb on silence, pause, track change, and crossfade; motion should respond to real spectrum input and clear when capture stops.
- [ ] Check Settings, About, and media notification branding; verify the existing Resonate notification icon remains.
- [ ] Confirm release APK remains below 100 MiB in CI. Installed size is a separate measurement.

## Change policy

1. Keep each fix small and isolated.
2. Add a deterministic regression test for a reproducible state/logic bug before changing runtime behavior where practical.
3. Run the complete repository CI, including release-size gate.
4. Keep device/listening results separate from CI claims.
5. Avoid new features, generic preset cards, broad DSP retuning, or dependency additions during this pass.

## 2026-11-27 — crossfade, transport and platter regression pass

### Automatic incoming-track entry
- [ ] Use tracks with a late breakdown/drop section and verify unreviewed automatic candidates never preload beyond the opening-entry policy (15% of duration, capped at 45 seconds).
- [ ] Verify a late beat/phrase-alignment result falls back to the incoming beginning and does not retain the rejected tempo stretch.
- [ ] Verify an explicitly reviewed pair preset can retain its approved later cue.
- [ ] Read the native standby position before fade, during fade and after promotion; confirm the requested cue is not applied twice and the promoted deck advances only by elapsed fade playback.

### Pause-state convergence
- [ ] Select a track while playing, paused and during a transition; tap pause immediately and verify the control reflects the canonical Media3 pause after command acknowledgement.
- [ ] Repeat with delayed native state publication and rapid play/pause commands; stale snapshots must not reverse the latest transport intent.
- [ ] Repeat from Player, mini-player, notification and headset controls where available.

### DJ platter scratch
- [ ] Verify the Media3 processor factory installs timestamp capture/scratch rendering before native DSP on both physical decks.
- [ ] Verify forward, reverse, hold, variable-speed strokes and release-to-live-audio are audible on each playing deck.
- [ ] Verify seek, hot-cue, track replacement, pause, crossfade start and workspace teardown retire stale platter commands.
- [ ] Confirm a rejected/late timestamp anchor fails closed to the untouched PCM block and never emits partial audio.
- [ ] Confirm normal playback is byte-for-byte pass-through when scratch is inactive and DSP remains active.

CI proves software contracts only. The audible scratch response, transition entry point and pause-control convergence require physical-device testing on more than one Android output/device configuration before release acceptance.


### Queue completion during an interrupted crossfade
- [ ] Complete the outgoing deck during a successful crossfade; verify exactly one incoming queue commit.
- [ ] Force a crossfade timeout after the outgoing deck reports completion; verify the watchdog recovers to the next playable queue item.
- [ ] Preempt a crossfade with manual Next/Previous after completion; verify the manual command wins and no watchdog double-advance occurs.
- [ ] Exercise Repeat One, Repeat All, final queue item, and an unreadable incoming source.
- [ ] Confirm a completion observation is retained for the expected song occurrence, but cannot advance after the current song/index has changed.
- [ ] Confirm diagnostics show exactly one terminal outcome: committed, recovered, preempted, or exhausted.


### Repeat One and automatic DJ replay separation
- [ ] With Repeat One enabled and crossfade enabled, verify the current track loops on the same source without preloading/promoting the same track on the standby deck.
- [ ] With Repeat Off, verify track completion does not restart the current item.
- [ ] With Repeat All, verify the next distinct queue item starts and the queue wraps only at its end.
- [ ] Verify ordinary automatic A-to-B crossfades between distinct queue items remain unchanged.
- [ ] Verify manual DJ deck preparation/crossfade remains available and is not treated as automatic repeat-self.

### Scratch timestamp and history hardening
- [ ] Verify exact-buffer timestamp matching remains preferred and retries do not duplicate pending entries.
- [ ] Verify a duplicate/sliced processor buffer consumes the oldest pending timestamp in FIFO order.
- [ ] Verify the ring retains four seconds at 44.1/48 kHz within its bounded capacity.
- [ ] On device, record timestamp match/miss counts, valid-anchor count, render count and fallback count while scratching each playing physical deck.
- [ ] Verify audible forward, reverse, hold and release behavior; fail closed to live PCM on invalid anchors.
