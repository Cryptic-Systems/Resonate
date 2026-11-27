# Resonate Voice Recording Filename Audit

Branch: `resonate-voice-audit`  
Base: `dj-workspace-development`

## Scope and confidence

This is a **filename-derived audit**, not a completed listening/transcription audit. The source archive names are treated as the exact recorded words, as directed. The filename is preserved verbatim in the inventory; the display phrase below removes the category prefix and file extension and converts filename separators to spaces where possible.

No audio has been re-recorded, renamed, normalized, or edited. Quiet/whispered delivery is intentional where the creator has specified it; loudness alone is not a defect. Actual vocal style per individual clip remains unverified.

The repository currently stores the eight category ZIP archives, not extracted MP3 files. This document therefore does not claim that individual MP3s are already Flutter-loadable assets, and the existing placeholder manifest is intentionally not populated with unusable paths.

## Archive verification update (2026-11-27)

I inspected the supplied `Resonate Feedback.zip` and its eight nested category archives. The archives contain **84 MP3 entries** with category counts matching this inventory: 15 companion, 8 deck/console, 19 DJ transition, 8 hype, 9 mode, 8 risk, 8 utility, and 9 system. The exact filenames were checked against the nested archive listings, including capitalization, apostrophes, the embedded space in `voice_ask_queue _updated.mp3`, and the two double-period filenames. This confirms the filename inventory only; it does not confirm spoken delivery, audio quality, or routing suitability by listening.

## Integration principles

- Use one spoken cue for one meaningful state/event; don't stack several near-synonyms.
- Voice feedback must never compete with essential music, navigation, or safety behavior.
- Apply category-aware cooldowns and a global voice-busy guard; suppress stale cues if the state changes before playback.
- Low-priority companion, hype, and micro acknowledgements should be suppressible and should not announce routine UI taps.
- Risk/safety cues must be tied to a real detection and have higher priority than flavor cues. They must not claim a condition was detected unless the engine confirms it.
- Consent is always an explicit user action. A consent-related recording may explain or confirm a consent state but never grants consent.
- Preserve whisper/performance dynamics. Do not blanket-normalize all clips to one level.
- Keep source archive names and original clip filenames intact; use stable manifest IDs for code references.
- Before runtime integration, extract the archives into their intended folders, verify each file against the inventory, and run a listening review.

## Filename-derived inventory

Phrase text is based on the filename and is not an independent transcript verification.

### Ask Resonate / Companion (15)

| Filename | Filename-derived phrase | Suggested use |
|---|---|---|
| `voice_ask_built_you_a_120-minute_mix.mp3` | Built you a 120-minute mix | Only after a 120-minute mix is successfully created |
| `voice_ask_built_you_a_30-minute_mix.mp3` | Built you a 30-minute mix | Only after a 30-minute mix is successfully created |
| `voice_ask_built_you_a_45-minute_mix.mp3` | Built you a 45-minute mix | Only after a 45-minute mix is successfully created |
| `voice_ask_built_you_a_60-minute_mix.mp3` | Built you a 60-minute mix | Only after a 60-minute mix is successfully created |
| `voice_ask_built_you_a_90-minute_mix.mp3` | Built you a 90-minute mix | Only after a 90-minute mix is successfully created |
| `voice_ask_found_some_tracks_that_match_the_mood.mp3` | Found some tracks that match the mood | After a mood-based discovery result exists |
| `voice_ask_got_it.mp3` | Got it | Conversational acknowledgement; avoid duplicate confirmation |
| `voice_ask_here’s_what_I_found.mp3` | Here's what I found | Before presenting a completed search/result |
| `voice_ask_keeping_it_local.mp3` | Keeping it local | Only when local-only scope is active |
| `voice_ask_looking_through_your_library.mp3` | Looking through your library | During a real library search, if it takes long enough |
| `voice_ask_on_it.mp3` | On it | Acknowledgement for an accepted non-instant request |
| `voice_ask_queue _updated.mp3` | Queue updated | After a successful queue mutation; filename contains an extra space |
| `voice_ask_ready_when_you_are.mp3` | Ready when you are | Non-urgent companion/standby response |
| `voice_ask_warmup_set.mp3` | Warmup set | Only when a warmup set is prepared |
| `voice_ask_you_might_like_these.mp3` | You might like these | Before showing a recommendation set |

### Deck / Console / Workspace (8)

| Filename | Filename-derived phrase | Suggested use |
|---|---|---|
| `console_active_deck_switched.mp3` | Active deck switched | After the active deck actually changes |
| `console_both_decks_loaded.mp3` | Both decks loaded | When both deck sources are ready |
| `Console_console_open.mp3` | Console open | On explicit console opening, if spoken feedback is enabled |
| `console_deck_A_active.mp3` | Deck A active | On explicit deck selection; don't repeat with active-deck-switched |
| `console_deck_B_active.mp3` | Deck B active | On explicit deck selection; don't repeat with active-deck-switched |
| `Console_incoming_prepared.mp3` | Incoming prepared | When incoming deck preparation completes |
| `console_monitoring.mp3` | Monitoring | Only when monitoring is actually enabled |
| `console_standby_ready.mp3` | Standby ready | When workspace is ready for performance |

### DJ Transition / Performance (19)

| Filename | Filename-derived phrase | Suggested use |
|---|---|---|
| `voice_dj_aligning_the_phrase.mp3` | Aligning the phrase | Optional, only during actual phrase alignment |
| `voice_dj_building_into_the_next_one.mp3` | Building into the next one | Pre-transition performance cue; low frequency |
| `voice_dj_coming_up_next.mp3` | Coming up next | Announce incoming track once, not alongside another incoming cue |
| `voice_dj_Drop_Incoming.mp3` | Drop incoming | Only for a planned drop with confirmed timing |
| `voice_dj_energy_rising.mp3` | Energy rising | When energy analysis confirms a rise |
| `voice_dj_here_we_go.mp3` | Here we go | Rare transition/performance accent |
| `voice_dj_keeping_the_flow_tight..mp3` | Keeping the flow tight | Optional flavor; source filename has double period |
| `voice_dj_key_match_looking_solid.mp3` | Key match looking solid | Only after key compatibility is assessed |
| `voice_dj_letting_it_breathe.mp3` | Letting it breathe | When intentionally leaving space/avoiding a transition |
| `voice_dj_let’s_go.mp3` | Let's go | High-energy accent; use sparingly |
| `voice_dj_next_track_locked.mp3` | Next track locked | When the next track is actually selected/locked |
| `voice_dj_nice_transition.mp3` | Nice transition | After a successful transition; don't combine with smooth handoff/that was clean |
| `voice_dj_reading_the_room.mp3` | Reading the room | Only if Resonate has an active room/context analysis |
| `voice_dj_ride_this_one_out..mp3` | Ride this one out | When the policy intentionally holds the current track; source filename has double period |
| `voice_dj_smooth_handoff.mp3` | Smooth handoff | After a clean handoff; choose instead of other success praise |
| `voice_dj_soft_landing.mp3` | Soft landing | After a gentle transition/ending |
| `voice_dj_standby_ready.mp3` | Standby ready | When the next transition is prepared |
| `voice_dj_that_was_clean.mp3` | That was clean | Post-transition praise; mutually exclusive with similar praise |
| `voice_dj_this_one’s_got_heat.mp3` | This one's got heat | Only when energy/selection context supports the sentiment |

### Hype / Flavor / Personality (8)

| Filename | Filename-derived phrase | Suggested use |
|---|---|---|
| `hype_feeling_the_groove.mp3` | Feeling the groove | Rare positive listening moment |
| `hype_good_taste.mp3` | Good taste | Recommendation/listening praise; very sparingly |
| `hype_let’s_keep_this_moving.mp3` | Let's keep this moving | When momentum is deliberately maintained |
| `hype_locked_in.mp3` | Locked in | Confirmed focused/locked performance state |
| `hype_nice_selection.mp3` | Nice selection | After user selection; avoid overpraise |
| `hype_rising.mp3` | Rising | Only with a confirmed rising energy context |
| `hype_this_is_the_one.mp3` | This is the one | Strong recommendation; only with high confidence |
| `hype_you’re_on_a_roll.mp3` | You're on a roll | Rare repeated-success moment |

### Mode / Policy (9)

| Filename | Filename-derived phrase | Suggested use |
|---|---|---|
| `voice_mode_audiobook.mp3` | Audiobook | Only when audiobook mode is selected/confirmed |
| `voice_mode_driving.mp3` | Driving | Only when driving mode is selected/confirmed |
| `voice_mode_motivation.mp3` | Motivation | Only when motivation mode is selected/confirmed |
| `voice_mode_normal.mp3` | Normal | Only when normal mode is selected/confirmed |
| `voice_mode_podcast.mp3` | Podcast | Only when podcast mode is selected/confirmed |
| `voice_mode_running.mp3` | Running | Only when running mode is selected/confirmed |
| `voice_mode_sleep.mp3` | Sleep | Only when sleep mode is selected/confirmed; avoid wakeful interruptions |
| `voice_mode_work.mp3` | Work | Only when work mode is selected/confirmed |
| `voice_mode_workout.mp3` | Workout | Only when workout mode is selected/confirmed |

### Risk / Safety / Intelligence (8)

| Filename | Filename-derived phrase | Suggested use |
|---|---|---|
| `voice_risk_autopilot_standing_by.mp3` | Autopilot standing by | Only when autopilot is enabled and ready; must not imply it is active otherwise |
| `voice_risk_bass_collision.mp3` | Bass collision | Only after bass conflict detection; prioritize clear corrective feedback |
| `voice_risk_better_transition_available.mp3` | Better transition available | When a better candidate is calculated; non-urgent suggestion |
| `voice_risk_confidence_low.mp3` | Confidence low | When confidence threshold is genuinely below policy threshold |
| `voice_risk_energy_shock_detected.mp3` | Energy shock detected | Only when transition/energy analysis confirms a large discontinuity |
| `voice_risk_harmonic_conflict.mp3` | Harmonic conflict | Only after harmonic/key conflict detection |
| `voice_risk_playing_it_safe.mp3` | Playing it safe | When a conservative policy is intentionally selected |
| `voice_risk_structure_mismatch.mp3` | Structure mismatch | Only when phrase/section structure comparison detects mismatch |

### Short Utility / Micro (8)

| Filename | Filename-derived phrase | Suggested use |
|---|---|---|
| `short_utility_done.mp3` | Done | Brief completion confirmation; avoid if a specific result cue follows |
| `short_utility_got_it.mp3` | Got it | Short acknowledgement; don't duplicate companion got-it |
| `short_utility_locked.mp3` | Locked | After a successful lock action |
| `short_utility_nice.mp3` | Nice | Very sparse informal acknowledgement |
| `short_utility_noted.mp3` | Noted | After a preference/instruction is accepted |
| `short_utility_okay.mp3` | Okay | Generic acknowledgement; use only if no more specific cue |
| `short_utility_ready.mp3` | Ready | State confirmation after readiness check |
| `short_utility_yes.mp3` | Yes | Positive response; use only when a yes is contextually appropriate |

### System / Consent / Status (9)

| Filename | Filename-derived phrase | Suggested use |
|---|---|---|
| `voice_system_all_set.mp3` | All set | After setup/preparation is complete |
| `voice_system_analyzing.mp3` | Analyzing | During a real analysis task that lasts long enough |
| `voice_system_autopilot_consent.mp3` | Autopilot consent | Consent explanation/confirmation only; explicit user action remains required |
| `voice_system_intelligence_is_offline.mp3` | Intelligence is offline | When the intelligence subsystem is actually unavailable |
| `voice_system_preparation_complete.mp3` | Preparation complete | After preparation completes; avoid duplicating all-set |
| `voice_system_ready.mp3` | Ready | General ready state; choose over standby-ready when suitable |
| `voice_system_standing_by.mp3` | Standing by | Idle/standby state; not on every app launch |
| `voice_system_voice_feedback_enabled.mp3` | Voice feedback enabled | After the user explicitly enables voice feedback |
| `voice_system_voice_feedback_off.mp3` | Voice feedback off | After the user explicitly disables voice feedback |

## Filename hygiene observations

- `voice_ask_queue _updated.mp3` has an embedded extra space.
- `voice_dj_keeping_the_flow_tight..mp3` and `voice_dj_ride_this_one_out..mp3` have double periods before the extension.
- Case and apostrophe style are not fully uniform.

Do not rename the originals during audit. Once extracted, use manifest IDs and exact source paths so filename cleanup is not a runtime dependency.

## Next implementation steps

1. Extract the ZIPs into their category folders without modifying source clips.
2. Confirm the 84 filenames and category counts against this document.
3. Add stable IDs and explicit phrase/category/style fields to the manifest.
4. Review the actual codebase's DJ/voice event lifecycle before wiring triggers.
5. Add a small voice playback coordinator with priority, cooldown, stale-event cancellation, and user opt-out.
6. Run device tests with music playing, screen off, Bluetooth routing, interruptions, and crossfade enabled.


## Workspace routing

The category inventory above is not a playback permission list. Resonate has separate automatic playback and hands-on DJ Workspace/Console experiences, and cues may be valid in either, both, or only one depending on the actual event. See [VOICE_WORKSPACE_ROUTING.md](VOICE_WORKSPACE_ROUTING.md) for the filename-level routing proposal, duplicate-phrase rules, event contract, and safeguards. Route by event origin and confirmed state, not by category folder alone.
