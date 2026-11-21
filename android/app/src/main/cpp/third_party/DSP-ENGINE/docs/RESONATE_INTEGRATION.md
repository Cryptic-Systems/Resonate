# Resonate ↔ DSP-ENGINE Integration Guide

**Engine version:** 0.6.0  
**Scope:** Intelligent headroom (Path A/B), auto-bass, auto-DVC, meters, UI, and host responsibilities.

This document lists everything Resonate must implement on the **host / JNI / UI** side so the engine’s intelligence is visible and useful. The engine already provides the DSP; Resonate owns decode, cache, UX, and lifecycle.

---

## 1. Architecture overview

```
┌─────────────────────────────────────────────────────────────────┐
│ Resonate (Flutter / Kotlin / Media3)                            │
│  • Track load → optional offline scan (Path A)                  │
│  • Per-track analysis cache                                     │
│  • User targets: bass, loudness bias, margin, profiles          │
│  • UI meters: headroom, GR, applied bass, applied gain, RMS     │
│  • JNI bridge → C ABI (dsp_*)                                   │
└────────────────────────────┬────────────────────────────────────┘
                             │ process_pcm16 / control mailbox
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ DSP-ENGINE                                                      │
│  EQ → auto-bass shelf → speaker/VB → preamp → DVC(auto-gain)    │
│       → limiter → dither                                        │
│  Meters: in-peak, TP, post-EQ, bass-band, headroom, short RMS   │
│  Offline: dsp_analyze_buffer / dsp_probe_max_bass_gain_db       │
└─────────────────────────────────────────────────────────────────┘
```

**Rules**

- One audio thread calls `dsp_process` / `dsp_process_pcm16` only.
- UI / main thread may call all setters and getters (mailbox + snapshot meters).
- Never allocate on the audio callback; scan offline on a background isolate/thread.
- Limiter stays **on** whenever processing is on — auto-bass/auto-gain only *shape* level.

---

## 2. Engine API map (what Resonate calls)

### 2.1 Lifecycle

| API | When |
|-----|------|
| `dsp_create(cfg)` | Player init / engine bind |
| `dsp_destroy` | Unbind |
| `dsp_reset` | Track change, seek glitch recovery |
| `dsp_set_sample_rate` / `dsp_set_channels` | Format change |
| `dsp_process_pcm16` | Media3 `AudioProcessor` queue |
| `dsp_set_processing_enabled` | User master bypass |

**Create defaults (recommended for music)**

```c
DspConfig cfg = {0};
cfg.sample_rate = 48000.f;
cfg.channels = 2;
cfg.max_block = 2048;
cfg.enable_eq = 1;
cfg.enable_dvc = 1;
cfg.enable_limiter = 1;
cfg.enable_dither = 1;
cfg.dither_mode = DSP_DITHER_TPDF;
cfg.limiter_mode = DSP_LIMITER_TRUEPEAK; /* or LOOKAHEAD */
cfg.limiter_threshold_db = -1.f;
cfg.limiter_ceiling_db = -0.1f;   /* local files */
cfg.limiter_release_ms = 50.f;
cfg.limiter_attack_ms = 0.1f;
cfg.limiter_lookahead_ms = 2.f;
```

Streaming delivery: `limiter_ceiling_db = -1.0f` (or profile-driven).

### 2.2 Offline Path A (per track)

| API | Purpose |
|-----|---------|
| `dsp_analyze_buffer` | peak, true-peak, RMS, crest, bass energy |
| `dsp_probe_max_bass_gain_db` | max safe low-shelf under ceiling−margin |

Run on a **background** thread after decode (full file or representative window).  
Does **not** need a live `DspEngine*` (pure functions).

### 2.3 Online Path B — auto-bass

| API | Purpose |
|-----|---------|
| `dsp_auto_bass_enable` | on/off |
| `dsp_auto_bass_set_target_db` | user intent (capped by probe) |
| `dsp_auto_bass_set_margin_db` | safety (default 1.0) |
| `dsp_auto_bass_set_freq_hz` | shelf corner (60–100) |
| `dsp_auto_bass_get_applied_db` | UI: what is actually applied |

### 2.4 Auto-DVC (item 5)

| API | Purpose |
|-----|---------|
| `dsp_auto_gain_enable` | on/off (drives DVC) |
| `dsp_auto_gain_set_target_rms_db` | e.g. −18 dBFS short-term |
| `dsp_auto_gain_set_bias_db` | user “volume preference” ± |
| `dsp_auto_gain_set_max_boost_db` / `max_cut_db` | clamps |
| `dsp_auto_gain_set_window_ms` | 200–1000 typical |
| `dsp_auto_gain_get_applied_db` | UI |
| `dsp_get_short_term_rms_db` | UI |

While auto-gain is **on**, prefer **bias** over manual `dsp_dvc_set_gain_db` (engine overwrites DVC each block).

### 2.5 Meters (poll ~10–30 Hz from UI)

| API / field | UI use |
|-------------|--------|
| `DspLevelMeter.in_peak_db` | Input peak |
| `in_true_peak_db` | Inter-sample aware input |
| `post_eq_peak_db` | After tone shaping |
| `bass_band_peak_db` | Sub energy |
| `headroom_db` | Ceiling − post peak |
| `short_term_rms_db` | Loudness match |
| `dsp_limiter_get_meter` | GR + peak-hold GR |
| `dsp_auto_bass_get_applied_db` | Applied bass |
| `dsp_auto_gain_get_applied_db` | Applied gain |

---

## 3. Required Resonate implements

### 3.1 JNI / FFI surface

Expose (names illustrative):

```text
nativeCreate / nativeDestroy / nativeProcessPcm16
nativeEqSetBands / nativeEqSetBand
nativeLimiter* / nativePreamp* / nativeSpeaker*
nativeAnalyzeBuffer / nativeProbeMaxBassGain
nativeAutoBass* / nativeAutoGain*
nativeGetLevelMeter / nativeGetLimiterMeter
nativeSetProcessingEnabled
```

Map `int16` Media3 buffers → `dsp_process_pcm16` in-place.

**Thread rule:** process only from the audio/Media3 thread; everything else from UI/background is fine.

### 3.2 Per-track analysis cache

Store (SQLite / Hive / file JSON):

```json
{
  "track_id": "hash-or-path",
  "file_mtime": 1234567890,
  "sample_peak_db": -1.2,
  "true_peak_db": -0.7,
  "rms_db": -14.5,
  "crest_db": 13.3,
  "bass_energy_db": -18.0,
  "max_safe_bass_db": 4.5,
  "scanned_at": 1732,
  "scan_quality": "full|window|none"
}
```

**Policy**

| Source | Scan |
|--------|------|
| Local file | Full or long window once; reuse until mtime changes |
| Stream / progressive | Skip offline; online auto-bass + auto-gain only |
| User skips scan | Online only |

On track start:

```text
max_safe = cache.max_safe_bass_db ?? 6.0
user_bass = settings.user_bass_target_db
target = min(user_bass, max_safe)
dsp_auto_bass_set_target_db(eng, target)
dsp_auto_bass_enable(eng, settings.auto_bass_on)
```

### 3.3 Offline scan worker

1. Decode PCM float (or convert from existing decoder output).  
2. Optional: take 30–90 s from mid-track **or** full file.  
3. Call `dsp_analyze_buffer` + `dsp_probe_max_bass_gain_db(…, shelf=80, ceiling, margin)`.  
4. Write cache.  
5. If this track is currently playing, update auto-bass target without glitch (mailbox is smooth).

Cancel on user navigate away; don’t block UI.

### 3.4 Session wiring (playback start)

```text
dsp_reset(eng)
dsp_set_sample_rate / channels if changed
dsp_limiter_set_ceiling from delivery profile
dsp_auto_bass_set_margin_db(settings.margin)
dsp_auto_bass_set_freq_hz(settings.bass_freq)
dsp_auto_bass_set_target_db(min(user, cached_max))
dsp_auto_bass_enable(settings.auto_bass)

dsp_auto_gain_set_target_rms_db(settings.loudness_target)  // e.g. -18
dsp_auto_gain_set_bias_db(settings.loudness_bias)
dsp_auto_gain_set_max_boost/cut from settings
dsp_auto_gain_enable(settings.auto_gain)

dsp_eq_set_bands(user_eq)
dsp_speaker_* if phone speaker route
```

### 3.5 Interaction rules (avoid fighting the user)

| Setting | Behavior |
|---------|----------|
| Auto-bass ON + user EQ low-shelf | Prefer: reduce auto target by sum of user low-shelf gains, **or** document that auto-bass is additive and lower user shelf |
| Auto-gain ON | Use bias for “volume”; don’t also crank manual DVC |
| Processing bypass | Disable meters animation; show “bypass” |
| Track change | `dsp_reset`; clear applied readouts until new blocks |

### 3.6 Delivery profiles (host presets)

| Profile | ceiling_db | margin | auto-gain target | notes |
|---------|------------|--------|------------------|-------|
| Local / archive | −0.1 | 1.0 | −18 | max fidelity |
| Streaming | −1.0 | 1.0 | −18 | platform safe |
| Bluetooth speaker | −1.5 | 1.5 | −16 | more headroom |
| Phone speaker | −1.0 | 1.5 | −16 | enable speaker+VB |

---

## 4. UI requirements

### 4.1 Now-playing / DSP sheet (minimum)

1. **Master processing** toggle → `dsp_set_processing_enabled`  
2. **Headroom** meter (dB) — color: green > 3 dB, yellow 1–3, red < 1  
3. **GR** meter from `DspLimiterMeter` (instant + peak hold)  
4. **Bass**  
   - Slider: *Wanted* bass (target)  
   - Readout: *Applied* (`dsp_auto_bass_get_applied_db`)  
   - Optional: *Safe max* from cache  
5. **Loudness**  
   - Toggle auto-gain  
   - Bias slider (−6…+6)  
   - Readout: applied gain + short-term RMS  
6. **EQ** — existing 31-band UI; call `dsp_eq_set_bands`  
7. **Limiter mode** — Fast / Lookahead / True-peak / Two-band (advanced)

### 4.2 Visual layout (suggested)

```
┌──────────────────────────────────────────┐
│ DSP                          [Bypass]    │
│ Headroom  ████████░░  +4.2 dB            │
│ GR        ██░░░░░░░░   1.1 dB            │
│ RMS       −17.4 dBFS   target −18        │
├──────────────────────────────────────────┤
│ Auto bass          [ON]                  │
│ Wanted   ●────○──  +6.0 dB               │
│ Applied            +3.4 dB  (safe ≤+4.5) │
│ Margin   ○──●────  1.0 dB                │
├──────────────────────────────────────────┤
│ Auto loudness      [ON]                  │
│ Bias     ──○─────  0.0 dB                │
│ Applied            +2.1 dB               │
├──────────────────────────────────────────┤
│ EQ  [edit]     Speaker mode [ ]  VB ─○─  │
└──────────────────────────────────────────┘
```

### 4.3 Settings screens

- Default auto-bass on/off, default target, margin, shelf Hz  
- Default auto-gain on/off, target RMS, max boost/cut, window  
- Delivery profile  
- “Scan library for safe bass” batch job  
- Advanced: limiter mode, ceiling, knee, two-band xover  

### 4.4 Accessibility / honesty

Always show **wanted vs applied** when they differ (headroom limited).  
Tooltip: *“Boost reduced to avoid digital clipping on this track.”*

### 4.5 Polling

- UI timer 15–30 Hz → `dsp_get_level_meter` + limiter meter + applied getters  
- Do not call process from UI thread  

---

## 5. Media3 `AudioProcessor` checklist

1. `queueInput` → convert if needed → `dsp_process_pcm16` in-place on 16-bit PCM.  
2. Match channel count / sample rate on format change (`dsp_set_*` + `dsp_reset`).  
3. `flush` / seek → `dsp_reset` (clears limiter lookahead + meters).  
4. Keep engine instance for the player lifetime (or sticky dual-engine if you hot-swap).  
5. Parameter changes from Flutter via MethodChannel/JNI → mailbox setters (already thread-safe).  

---

## 6. Recommended defaults

| Parameter | Default |
|-----------|---------|
| Auto-bass | ON |
| Bass target | +4 … +6 dB (user) |
| Bass margin | 1.0 dB |
| Bass freq | 75–80 Hz |
| Auto-gain | ON for playlists / OFF for critical listening (user choice) |
| RMS target | −18 dBFS short-term |
| Max boost / cut | 6 / 12 dB |
| Window | 400 ms |
| Limiter | True-peak, ceiling −0.1 local / −1.0 stream |

---

## 7. Testing on Resonate side

- [ ] Quiet track: applied bass approaches target; auto-gain boosts  
- [ ] Loud / already-limited track: applied bass ≈ 0; auto-gain cuts or flat  
- [ ] Probe matches offline: `max_safe_bass` ≤ what online allows without GR spikes  
- [ ] Seek / next track: no zipper, no stuck GR  
- [ ] Bypass: output matches input (bit-exact not required; level sane)  
- [ ] UI: wanted ≠ applied when headroom tight  
- [ ] PCM16 path: no clicks at block boundaries  

---

## 8. Future host hooks (not required for 0.5.1)

- Content-aware VB from `bass_energy_db`  
- Crest-based limiter personality  
- Device profiles (phone / BT / USB DAC)  
- Library-wide “bass match” normalization  
- Full LUFS (engine may add later; RMS is enough for v1)  

---

## 9. Version coupling

| Resonate feature | Min engine |
|------------------|------------|
| PCM16 + mailbox + 31-band EQ | 0.4.0 |
| Analyze / probe / auto-bass / level meters | 0.5.0 |
| Auto-gain + short-term RMS in meters | **0.5.1** |

Check `dsp_version()` at init; disable intelligent toggles if older.

---

## 10. v0.6.0 extended intelligence (engine complete)

### Headroom budget
```c
dsp_headroom_budget_set(eng, 0.50f, 0.20f, 0.30f); // bass, preamp, gain
```
Bass, auto-preamp, and auto-gain **share** one headroom pool so they cannot each spend the full margin.

### Auto-preamp
```c
dsp_auto_preamp_set_target_db(eng, 2.f);
dsp_auto_preamp_enable(eng, 1);
// UI: dsp_auto_preamp_get_applied_db(eng)
```

### Content-aware virtual bass
```c
dsp_speaker_set_enabled(eng, 1);
dsp_auto_vb_set_target(eng, 0.6f);  // max when track is bass-light
dsp_auto_vb_enable(eng, 1);
// UI: dsp_auto_vb_get_applied(eng)
```
Requires speaker mode on. Uses live bass-band meter + optional analysis hint.

### Crest personality + analysis hint (on track load)
```c
DspAnalysisResult a;
float max_bass = 0.f;
dsp_analyze_buffer(...);
dsp_probe_max_bass_gain_db(..., &max_bass);
dsp_apply_analysis_hint(eng, &a, max_bass);
// sets crest-based ceiling/release, bass-energy hint, max-safe cap for auto-bass
```

### Silence hygiene (default ON)
```c
dsp_silence_hygiene_enable(eng, 1);
dsp_silence_hygiene_set_threshold_db(eng, -60.f);
dsp_silence_hygiene_set_hold_ms(eng, 300.f);
```
Decays applied auto-bass/preamp/gain and GR peak-hold after sustained near-silence.

### Updated session wiring (track start)
```
dsp_reset(eng)
dsp_apply_analysis_hint(eng, &cached_analysis, cached_max_safe_bass)
dsp_auto_bass_set_target_db(eng, min(user_bass, cached_max_safe_bass))
dsp_auto_bass_enable(...)
dsp_auto_gain_enable(...)
dsp_auto_preamp_* / dsp_auto_vb_* as per settings
dsp_headroom_budget_set(...) // once at init is enough
dsp_silence_hygiene_enable(1)
```

### UI additions for v0.6
| Control | Readout |
|---------|---------|
| Budget (advanced) | three weights |
| Auto-preamp toggle + target | applied preamp dB |
| Auto-VB toggle + target | applied VB 0..1 |
| — | crest hint active indicator |

### Version coupling
| Feature | Min engine |
|---------|------------|
| Auto-gain / short-term RMS | 0.5.1 |
| Budget, auto-preamp, auto-VB, crest, silence, analysis hint | **0.6.0** |
