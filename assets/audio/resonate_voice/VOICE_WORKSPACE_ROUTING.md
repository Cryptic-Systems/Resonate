# Resonate Voice Cue Routing: Automatic Playback vs DJ Workspace

Branch: `resonate-voice-audit`
Base: `dj-workspace-development`

## Why routing is separate from the asset category

Resonate has two user experiences:

- **Automatic playback / Player** — Resonate makes or executes playback decisions and the user listens.
- **Manual DJ Workspace** — the user is actively preparing, selecting, or driving deck/transition operations.

A recording's folder describes its communication style, not where it is allowed to play. The same spoken phrase may be valid in both experiences, but only when the underlying event is valid in that experience. Conversely, a phrase about a user-driven deck action must not be emitted by automatic playback merely because the file is in the DJ category.

Repository note: the current `DjWorkspaceScreen` describes itself as observational; hands-on deck operation is delegated to DJ Console. Route manual-performance cues from the actual action/event source (Workspace/Console), not simply from opening the overview screen.

## Routing labels

Use one of these labels per manifest asset:

- `player_auto` — automatic playback only.
- `dj_manual` — manual DJ operation only.
- `both_contextual` — valid in both, but only when the same semantic event occurs in that experience.
- `shared_system` — system/consent/voice-feedback state is shared; announce only after a real user setting or confirmed system-state change.
- `conditional` — only if a specific analysis or policy result exists; destination is selected by the event's originating experience.

These are routing permissions, not instructions to play a cue. Event code must still check voice feedback preference, stale state, priority, cooldown, playback/transition state, and whether a more specific phrase already covers the event.

## Phrase routing matrix

### 1. Automatic playback / Player only

These phrases describe Resonate doing a task on behalf of the listener, or automatic policy decisions. Do not play them for a manually initiated deck operation unless that operation genuinely invokes the same companion task.

| Filename | Route | Gate |
|---|---|---|
| `voice_ask_built_you_a_120-minute_mix.mp3` | player_auto | A 120-minute mix was successfully built |
| `voice_ask_built_you_a_30-minute_mix.mp3` | player_auto | A 30-minute mix was successfully built |
| `voice_ask_built_you_a_45-minute_mix.mp3` | player_auto | A 45-minute mix was successfully built |
| `voice_ask_built_you_a_60-minute_mix.mp3` | player_auto | A 60-minute mix was successfully built |
| `voice_ask_built_you_a_90-minute_mix.mp3` | player_auto | A 90-minute mix was successfully built |
| `voice_ask_found_some_tracks_that_match_the_mood.mp3` | player_auto | Mood discovery returned matching tracks |
| `voice_ask_found_some_tracks_that_match_the_mood.mp3` | player_auto | Mood discovery returned matching tracks |
| `voice_ask_keeping_it_local.mp3` | player_auto | Local-only search scope is active |
| `voice_ask_looking_through_your_library.mp3` | player_auto | A library search is underway and takes long enough to justify speech |
| `voice_ask_warmup_set.mp3` | player_auto | Automatic warmup set is prepared |
| `voice_ask_you_might_like_these.mp3` | player_auto | Automatic recommendations are ready |
| `voice_risk_autopilot_standing_by.mp3` | player_auto | Automatic mixing/autopilot is enabled and ready; never imply active playback control if it is only standing by |
| `voice_risk_playing_it_safe.mp3` | conditional | Automatic policy deliberately chose a conservative transition |
| `voice_mode_*.mp3` | player_auto / shared_system | Use only when the mode is confirmed; announce mode changes once, not every track |

### 2. Manual DJ operation only

These phrases refer to a user-driven deck, console, monitoring, or performance action. They must not be triggered by autonomous playback merely because similar deck mechanics exist underneath.

| Filename | Route | Gate |
|---|---|---|
| `console_active_deck_switched.mp3` | dj_manual | User successfully changes active deck |
| `console_deck_A_active.mp3` | dj_manual | User explicitly selects Deck A; don't also play active-deck-switched |
| `console_deck_B_active.mp3` | dj_manual | User explicitly selects Deck B; don't also play active-deck-switched |
| `Console_console_open.mp3` | dj_manual | User opens the hands-on console and spoken UI confirmation is enabled |
| `console_both_decks_loaded.mp3` | dj_manual | Both manual deck sources are loaded and ready |
| `Console_incoming_prepared.mp3` | dj_manual | Manual incoming deck preparation completes |
| `console_monitoring.mp3` | dj_manual | User enables monitoring |
| `console_standby_ready.mp3` | dj_manual | Manual console is ready for user-directed performance |
| `voice_dj_aligning_the_phrase.mp3` | dj_manual | Manual performance is actively aligning a phrase; avoid narrating every analysis tick |
| `voice_dj_drop_incoming.mp3` | dj_manual | User-triggered/planned drop is confirmed and timing is locked |
| `voice_dj_here_we_go.mp3` | dj_manual | User initiates a performance moment |
| `voice_dj_let’s_go.mp3` | dj_manual | User initiates a high-energy performance moment; very sparse |
| `voice_dj_reading_the_room.mp3` | dj_manual / conditional | Only if a real room/context analysis exists and the user is in the manual performance context |

### 3. Both experiences, event-contextual

These phrases can be shared, but they are not interchangeable sound effects. The caller must provide the origin and confirmed event. Do not announce both a generic and a specific phrase for one event.

| Filename or phrase family | Route | Context rule |
|---|---|---|
| `voice_ask_got_it.mp3` / `short_utility_got_it.mp3` | both_contextual | Acknowledge an accepted user request in either experience; select one recording only |
| `voice_ask_on_it.mp3` | both_contextual | A non-instant request is accepted; not for routine taps |
| `voice_ask_ready_when_you_are.mp3` | both_contextual | Resonate is waiting for the user's next action, not an automatic playback state |
| `voice_ask_queue _updated.mp3` | both_contextual | Queue mutation succeeded in either experience; use exact source filename including its embedded space |
| `short_utility_done.mp3` | both_contextual | Generic completion only when no specific result phrase follows |
| `short_utility_locked.mp3` | both_contextual | A lock action succeeded; avoid when a more specific cue already confirms it |
| `short_utility_noted.mp3` | both_contextual | A user preference/instruction was accepted |
| `short_utility_okay.mp3` / `short_utility_yes.mp3` | both_contextual | Only when conversationally appropriate and no stronger acknowledgement is queued |
| `short_utility_nice.mp3` | both_contextual | Sparse, optional acknowledgement; never a routine control response |
| `short_utility_ready.mp3` / `voice_system_ready.mp3` / `voice_system_all_set.mp3` | both_contextual / shared_system | Confirm the specific readiness/setup event once; choose one |
| `voice_system_preparation_complete.mp3` | both_contextual | A preparation task actually completed; do not pair with “All set” |
| `voice_system_analyzing.mp3` | both_contextual | A real analysis task is in progress and long enough to justify speech |
| `voice_system_standing_by.mp3` | both_contextual | Entering an intentional standby state, not every idle interval |
| `voice_dj_coming_up_next.mp3` | both_contextual | Announce a confirmed incoming track in automatic transitions or manual performance; only once per incoming track |
| `voice_dj_next_track_locked.mp3` | both_contextual | The next track is actually locked/selected, regardless of whether automatic policy or user action selected it |
| `voice_dj_standby_ready.mp3` | both_contextual | A transition is prepared in either mode; do not duplicate console-standby-ready |
| `voice_dj_building_into_the_next_one.mp3` | both_contextual | A real transition build is underway; use only when the transition plan supports it |
| `voice_dj_energy_rising.mp3` / `hype_rising.mp3` | conditional | Confirmed energy rise; choose one, route based on automatic vs manual event origin |
| `voice_dj_key_match_looking_solid.mp3` | conditional | Confirmed key compatibility; can describe an automatic plan or manual pair analysis |
| `voice_dj_let’s_keep_this_moving.mp3` | both_contextual | A deliberate keep-moving decision, not an ordinary track change |
| `voice_dj_letting_it_breathe.mp3` | both_contextual | A deliberate hold/space decision; automatic policy or user-directed performance |
| `voice_dj_ride_this_one_out..mp3` | conditional | Current track is intentionally held; source filename has double period |
| `voice_dj_keeping_the_flow_tight..mp3` | both_contextual | Optional flavor during a confirmed smooth sequence; source filename has double period |
| `voice_dj_nice_transition.mp3` / `voice_dj_smooth_handoff.mp3` / `voice_dj_that_was_clean.mp3` / `voice_dj_soft_landing.mp3` | conditional | Post-transition praise in either experience; choose exactly one that matches the result |
| `voice_dj_this_one’s_got_heat.mp3` / `hype_feeling_the_groove.mp3` | conditional | Optional energy/flavor cue only when analysis/context supports it; never claim subjective certainty |
| `hype_good_taste.mp3` / `hype_nice_selection.mp3` / `hype_this_is_the_one.mp3` / `hype_you’re_on_a_roll.mp3` / `hype_locked_in.mp3` | conditional | Sparse encouragement after a meaningful user selection or high-confidence result; avoid repetitive praise |

### 4. Shared system state and conditional risk feedback

| Filename or phrase family | Route | Gate |
|---|---|---|
| `voice_system_autopilot_consent.mp3` | shared_system | Explain consent only; consent itself must come from an explicit user action |
| `voice_system_voice_feedback_enabled.mp3` / `voice_system_voice_feedback_off.mp3` | shared_system | Only after the user explicitly changes voice feedback |
| `voice_system_intelligence_is_offline.mp3` | shared_system | Intelligence subsystem is actually unavailable |
| `voice_risk_bass_collision.mp3` | conditional | Actual bass-conflict detection; use the originating experience and prioritize actionable safety over flavor |
| `voice_risk_better_transition_available.mp3` | conditional | A better candidate was calculated; low-priority suggestion in either experience |
| `voice_risk_confidence_low.mp3` | conditional | Confidence fell below the active policy threshold |
| `voice_risk_energy_shock_detected.mp3` | conditional | Confirmed large energy discontinuity |
| `voice_risk_harmonic_conflict.mp3` | conditional | Confirmed harmonic/key conflict |
| `voice_risk_structure_mismatch.mp3` | conditional | Confirmed phrase/section structure mismatch |

## Runtime event contract

Every cue request should carry:

- `cueId` — stable manifest ID, never a filename-derived lookup at runtime.
- `origin` — `player_auto`, `dj_manual`, or `shared_system`.
- `eventId` — dedupe key for one semantic event (e.g. transition UUID or queue mutation ID).
- `priority` and `expiresAt` — stale cues must be discarded.
- `semanticGroup` — mutually exclusive variants (e.g. transition praise, acknowledgement, ready state).
- `requiresVoiceFeedback` — true for all optional spoken cues.
- `confirmedState` — caller must supply proof that the event completed or detection exists.

The coordinator should enforce:

1. Route permission: reject a `player_auto` cue in manual context and vice versa unless explicitly `both_contextual` or `conditional`.
2. One cue per event: dedupe by `eventId`; choose one member of a semantic group.
3. Workspace change: cancel queued low-priority cues from the previous experience. Do not interrupt a clip already playing unless it is a safety-critical cue and policy explicitly allows it.
4. No speech on every tap, track tick, beat tick, or analysis update.
5. Respect voice feedback opt-out and preserve source recording dynamics; no blanket normalization.
6. Risk/safety cues may outrank flavor, but must never be fabricated or used as generic DJ banter.

## Implementation order

1. Keep source filenames and archive content unchanged.
2. Extract and verify the 84 clips into their final asset directories.
3. Extend `voice_manifest.json` with stable IDs, exact paths, phrase text, category, routing label, semantic group, and confidence/source notes.
4. Implement routing/dedupe/cooldown in a small coordinator; do not wire cues directly from UI widgets.
5. Add tests for workspace switching, duplicate cue suppression, stale cue expiry, opt-out, and automatic/manual event routing.
6. Device-test with music active, screen off, Bluetooth, interruptions, and crossfade.

This routing is a filename-derived proposal. Confirm each clip's exact spoken delivery and timing during the listening audit before production wiring.
