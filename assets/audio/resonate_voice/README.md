# Resonate Voice Assets

This directory is a staging location for Resonate's recorded voice assets.

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

## Asset intake

- Preserve original filenames during initial intake.
- Do not overwrite source recordings with normalized or edited versions.
- Keep recordings in their assigned category folders.
- Do not add guessed event mappings. Populate `voice_manifest.json` only after the recordings have been audited.
- Voice assets are not wired to playback by this staging structure. DJ/DSP work remains the current implementation priority.
