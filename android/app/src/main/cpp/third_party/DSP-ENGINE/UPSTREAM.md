# DSP-ENGINE vendored source

Upstream: https://github.com/innotrepid/DSP-ENGINE
Pinned upstream commit: 0d07d0c71c9a23a5d3c65802d477288a4733db91
Upstream version: 0.4.0
License: MIT (LICENSE)

The source is built as a native Android library and consumed only by Resonate's
Media3 PCM16 AudioProcessor through JNI. The upstream standalone audio backend
is not selected; Media3 owns Android playback and routing.

Local integration patches, if any, must be documented here and kept isolated
from upstream source changes so future upstream updates can be reconciled.
