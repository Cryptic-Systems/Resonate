# DJ Scratch Release Renderer Safety

## Release-output barrier

The independent PCM release renderer is a candidate handoff endpoint, not an active
production output path. It must not be connected to the deck until the Media3
scratch cursor, audible clock, and release handoff are integrated.

Opening the renderer now requires an explicit `media3OutputSilenced` confirmation.
A false value rejects the open before an AudioTrack is created. The caller must
establish that the canonical Media3 output for the same deck has been silenced
as part of the release protocol; merely reaching a cursor timestamp or observing
post-seek PCM is not sufficient.

After the barrier is satisfied, the renderer still requires:
- the exact Media3 AudioSession ID;
- the exact current routed output device and unchanged route generation;
- matching PCM16 sample rate and channel count;
- the expected post-DSP processing-chain identity;
- route revalidation before and during every output write;
- the effective deck gain, applied only after route validation.

The sealed tail remains one-shot and generation-owned. Route changes, deck
promotion, pause/interruption, media replacement, or transport preemption must
abort the ownership generation and close the renderer. A renderer failure must
not fall back to unverified concurrent output.

## Current implementation boundary

The renderer API and JVM tests enforce the explicit Media3-silence barrier.
The service does not yet invoke this renderer, and the scratch feature gate
remains closed. Production integration still requires a single control-plane
owner that proves Media3 silence, validates the exact route/clock contract,
transfers the sealed tail once, and coordinates the aligned return to Media3.
Physical-device testing is required before enabling manual scratch.
