package com.aetherion.resonate.dsp

import androidx.media3.common.audio.AudioProcessor
import android.util.Log

/**
 * Factory for native DSP AudioProcessors installed in Media3 DefaultAudioSink.
 *
 * Media3 calls [createProcessors] once per deck, so dual playback receives
 * independent DSP processors and native handles for decks A and B. The
 * no-argument overload remains as compatibility for the legacy just_audio
 * injection hook while that backend is being retired.
 *
 * Crash history (2026-09-28): old JNI called dsp_create(double, int) but the
 * real ABI is dsp_create(const DspConfig*). That treated the sample-rate bits
 * as a pointer → SIGSEGV in dsp_create+36. JNI was corrected to build a
 * DspConfig and pass &cfg; native can be ON again.
 */
object DspEngineSinkHook {
    private const val TAG = "DspEngineSinkHook"

    /**
     * Master switch for live native EQ/DVC.
     * Requires libdsp_engine.so in the APK and ABI-matched JNI.
     */
    private const val ENABLE_NATIVE_LIVE_DSP = true

    /** Compatibility overload used only by the legacy just_audio sink patch. */
    @JvmStatic
    fun createProcessors(): Array<AudioProcessor> = createProcessors("legacy")

    @JvmStatic
    fun createProcessors(deckId: String): Array<AudioProcessor> {
        return try {
            val allow = ENABLE_NATIVE_LIVE_DSP && DspSessionGate.isNativeAllowed()
            val proc = DspEngineAudioProcessor(deckId)
            proc.setNativeProcessEnabled(allow)
            val active = DspEngineRegistry.activeCount()
            if (allow) {
                Log.i(
                    TAG,
                    "Injected 1 host AudioProcessor(s) native=ON deck=$deckId " +
                        "(session ok; registry_active=$active — dual A/B uses 2 injects)"
                )
            } else {
                Log.i(
                    TAG,
                    "Injected 1 host AudioProcessor(s) pass-through deck=$deckId " +
                        "(ENABLE=$ENABLE_NATIVE_LIVE_DSP gate_tripped=${DspSessionGate.isTripped()})"
                )
            }
            arrayOf(proc)
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to create DspEngineAudioProcessor", t)
            emptyArray()
        }
    }
}
