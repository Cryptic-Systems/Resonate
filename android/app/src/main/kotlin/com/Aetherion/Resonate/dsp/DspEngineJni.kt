package com.aetherion.resonate.dsp

object DspEngineJni {
    init {
        try {
            System.loadLibrary("dsp_engine")
        } catch (_: Throwable) {
        }
        try {
            System.loadLibrary("dsp_jni")
        } catch (_: Throwable) {
        }
    }

    external fun nativeCreate(sampleRate: Double, channels: Int): Long
    external fun nativeDestroy(handle: Long)
    external fun nativeProcessPcm16Direct(
        handle: Long,
        buffer: java.nio.ByteBuffer,
        frames: Int,
        channels: Int,
        sampleRate: Double
    ): Int
    external fun nativeSetEnabled(handle: Long, enabled: Boolean)
    external fun nativeSetProcessingEnabled(handle: Long, enabled: Boolean)
    external fun nativeSetVolume(handle: Long, linearGain: Double)
    external fun nativeSetEqBands(
        handle: Long,
        centersHz: DoubleArray?,
        gainsDb: DoubleArray,
        enabled: Boolean
    )
    external fun nativeSetSpeakerMode(handle: Long, enabled: Boolean)
    external fun nativeSetVirtualBass(handle: Long, amount: Double)
    external fun nativeSetPreamp(handle: Long, linearGain: Double)
    external fun nativeSetLimiterCeiling(handle: Long, highDb: Float, lowDb: Float)
    external fun nativeSetCrossoverHz(handle: Long, freqHz: Float)
    external fun nativeSetParametricEqBands(
        handle: Long,
        frequenciesHz: FloatArray,
        gainsDb: FloatArray,
        qs: FloatArray,
        types: IntArray,
        enabled: Boolean
    )
    external fun nativeSetDvc(
        handle: Long,
        enabled: Boolean,
        gainDb: Float,
        smoothing: Boolean,
        smoothingMs: Float
    )
    external fun nativeSetLimiterConfig(
        handle: Long,
        enabled: Boolean,
        mode: Int,
        thresholdDb: Float,
        releaseMs: Float,
        attackMs: Float,
        lookaheadMs: Float,
        kneeDb: Float
    )
    external fun nativeSetDither(handle: Long, enabled: Boolean, mode: Int)

    /** [processCalls, avgUs, maxUs, overruns, lastFrames, sampleRate] */
    external fun nativeGetStats(handle: Long): DoubleArray?

    external fun nativeResetStats(handle: Long)

}
