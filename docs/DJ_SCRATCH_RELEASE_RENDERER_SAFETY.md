# DJ Scratch Release Renderer Safety

## Release-output barrier

The independent PCM release renderer is a candidate handoff endpoint, not an active
production output path. It must not be connected to the deck until the Media3
scratch cursor, audible clock, and release handoff are integrated.

Opening the renderer requires an explicit `media3OutputSilenced` confirmation.
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

## One-shot transfer coordinator

`DjScratchReleaseTransferCoordinator` owns the control-plane sequence for a
sealed tail: validate the exact capture and renderer contracts, require the
Media3-silence barrier, claim ownership once, open the renderer, drain the tail,
wait for the hardware playback head, and mark ownership drained. It rejects
mismatched media, generation, route, session, format, chain, timestamp state,
or non-direct scratch buffers before opening output.

Any open, render, accounting, or hardware-drain failure closes the renderer and
aborts the ownership generation. A successful transfer is terminal and cannot
be claimed a second time. Unit tests cover successful one-shot transfer,
Media3-silence rejection, route mismatch, and hardware-drain failure.

## Current implementation boundary

The coordinator and its tests are implemented, but the Media3 service does not
yet invoke the coordinator. The caller must still establish and verify actual
Media3 silence, connect the route/clock contract and capture lifecycle, and
coordinate the aligned return to Media3. The scratch feature gate remains
closed. Physical-device testing is required before enabling manual scratch.
