# Resonate Voice Assets

This directory stages Resonate's recorded voice assets and their filename-level audit.

## Categories

Place each recording in the category that best matches its intended communication role:

- `dj_transition_performance/` — DJ transitions and performance cues
- `risk_safety_intelligence/` — risk, safety, and intelligence feedback
- `ask_resonate_companion/` — companion and conversational responses
- `mode_policy/` — mode and policy feedback
- `system_consent_status/` — system, consent, and status messages
- `deck_console_workspace/` — deck, console, and workspace feedback
- `hype_flavor_personality/` — personality, hype, and flavor
- `utility_micro/` — short utility and micro responses

## Audit status

- The eight source category ZIPs contain 84 MP3 entries.
- `VOICE_FILENAME_AUDIT.md` records the exact filenames and filename-derived phrase labels.
- `VOICE_WORKSPACE_ROUTING.md` proposes routing between automatic Player playback and manual DJ Workspace/Console events.
- `voice_manifest.json` now has 84 stable filename-level records, with proposed routes/origins and semantic-group proposals.

The manifest is **not runtime-ready**: all `assetPath` values are null and `runtimeEnabled` is false. Routes and semantic groups are proposals based on filenames and the routing document, not a completed listening/transcription audit. Do not trigger cues from this manifest until clips are extracted to verified Flutter asset paths, individually reviewed, and event mappings are confirmed.

## Asset intake and audio safety

- Preserve original filenames during initial intake.
- Do not overwrite source recordings with normalized or edited versions.
- Keep recordings in their assigned category folders.
- Do not add guessed event-to-file mappings.
- Voice assets are not wired to playback by this staging structure. The router is an eligibility policy only; it does not own an audio player.
- Preserve intentionally quiet/whispered dynamics. Do not blanket-normalize the clips.
- Before production wiring, test cue suppression and playback with music active, screen off, Bluetooth, interruptions, and crossfade.
