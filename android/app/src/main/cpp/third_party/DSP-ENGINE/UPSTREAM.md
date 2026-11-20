# DSP-ENGINE vendored source

Upstream: https://github.com/innotrepid/DSP-ENGINE
Pinned upstream commit: da6539a89f3d8d2e9899365f7582c0f30c1f0a5b
Upstream version: 0.6.0
License: MIT (LICENSE)

The source is built as a native Android library and consumed by Resonate's
Media3 PCM16 AudioProcessor through JNI. Media3 owns Android playback, routing,
format negotiation and the output device; the upstream standalone backend and
SRC entry point are not used in this live path.

## Resonate integration adaptations

- The JNI bridge stages UI/control updates in an atomic snapshot and applies
  upstream setters immediately before the next PCM16 processing block. This
  keeps direct EQ/limiter/speaker mutations on the audio thread even where the
  upstream implementation does not route every setter through its internal
  mailbox.
- JNI reports PCM16 callback timing/overrun metrics itself. The upstream PCM16
  entry point exposes audio meters and frame/call counters, but not Resonate's
  Media3 callback timing contract.
- The vendored `src/core/processor.cpp` retains Resonate-local real-time fixes:
  - shaped-dither feedback is converted from integer LSB units back to normalized
    sample units before feeding the quantizer, preventing large silence noise;
  - `DSP_LIMITER_TWOBAND` is accepted by `dsp_limiter_set_mode`;
  - the two-band limiter is refreshed after attack and release changes. Native
    regression tests and the PCM16 smoke test protect these behaviours.
- The upstream v0.6.0 analysis, headroom, auto-preamp, auto-virtual-bass,
  crest-hint and silence-hygiene APIs are now present in the vendored C ABI.
  Their JNI and Flutter host controls are being wired in staged follow-up work;
  do not assume every new API is exposed in the app until that wiring lands.

Keep future upstream updates pinned and reconcile these local adaptations
explicitly rather than pulling a moving branch at Android build time.
