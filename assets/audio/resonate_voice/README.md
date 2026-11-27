# Resonate Voice Assets

This directory contains Resonate's original recorded voice assets, filename-level audit, and runtime manifest.

## Categories

- `dj_transition_performance/` — DJ transitions and performance cues
- `risk_safety_intelligence/` — risk, safety, and intelligence feedback
- `ask_resonate_companion/` — companion and conversational responses
- `mode_policy/` — mode and policy feedback
- `system_consent_status/` — system, consent, and status messages
- `deck_console_workspace/` — deck, console, and workspace feedback
- `hype_flavor_personality/` — personality, hype, and flavor
- `utility_micro/` — short utility and micro responses
- `source_archives/` — preserved original category ZIPs; not registered as Flutter audio assets

## Current status

- All 84 original MP3s have been extracted into their category folders.
- The 8 original category ZIPs are retained under `source_archives/`.
- `voice_manifest.json` contains 84 stable IDs, verified asset paths, filename-derived route proposals, and runtime-enabled entries.
- The voice cue service now resolves by stable manifest ID and plays the original asset without transcoding or blanket normalization.
- Initial event wiring covers confirmed automatic Media3 crossfade commits, manual DJ Console opening, confirmed manual standby-deck preparation, and successful Ask Resonate commands.

Routes and semantic groups are still filename-derived and have not been confirmed by a full listening audit. The clips are enabled for playback as requested; report any phrase, pronunciation, or trigger mismatch during playback and we can correct the manifest/event mapping.

## Audio safety

- Preserve exact filenames and original MP3 bytes.
- Do not normalize, compress, or transcode the recordings as part of asset intake.
- Preserve intentionally quiet/whispered dynamics.
- Keep cue playback independent from the music transport and avoid taking audio focus away from the music.
- The router deduplicates event/group pairs and enforces Player vs manual DJ origin.
