# DSP-ENGINE vendored source

Upstream: https://github.com/innotrepid/DSP-ENGINE
Pinned upstream commit: 0d07d0c71c9a23a5d3c65802d477288a4733db91
Upstream version: 0.4.0
License: MIT (LICENSE)

The source is built as a native Android library and consumed by Resonate's
Media3 PCM16 AudioProcessor through JNI. Media3 owns Android playback, routing,
format negotiation and the output device; the upstream standalone backend and
SRC entry point are not used in this live path.

## Resonate integration adaptations

- The JNI bridge stages UI/control updates in an atomic snapshot and applies
  upstream setters immediately before the next PCM16 processing block. This
  keeps direct EQ/limiter/speaker mutations on the audio thread even where the
  upstream v0.4.0 implementation does not route every setter through its
  internal mailbox.
- JNI reports PCM16 callback timing/overrun metrics itself because upstream
  v0.4.0's PCM16 entry point updates call/frame counters but not timing data.
- The vendored src/core/processor.cpp accepts DSP_LIMITER_TWOBAND in
  dsp_limiter_set_mode and refreshes the two-band limiter when attack/release
  settings change. These fixes are app-local; the upstream repository is not
  modified.

Keep future upstream updates pinned and reconcile these local adaptations
explicitly rather than pulling a moving branch at Android build time.
