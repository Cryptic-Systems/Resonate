package com.Aetherion.Resonate

import com.aetherion.resonate.dsp.DspEngineRegistry
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Owns the Flutter-to-native boundary for live DSP controls.
 *
 * This handler only translates channel arguments into registry operations; native
 * processor ownership and sticky A/B state remain inside DspEngineRegistry.
 */
internal class LiveDspChannelHandler {
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setLiveDspEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                DspEngineRegistry.applyEnabledAll(enabled)
                result.success(mapOf(
                    "ok" to true,
                    "enabled" to enabled,
                    "active" to DspEngineRegistry.activeCount(),
                ))
            }
            "setLiveDspPreampDb" -> {
                val db = (call.argument<Number>("db") ?: 0.0).toDouble().coerceIn(-12.0, 12.0)
                val linear = Math.pow(10.0, db / 20.0)
                DspEngineRegistry.applyPreampAll(linear)
                result.success(mapOf("ok" to true, "db" to db, "linear" to linear, "active" to DspEngineRegistry.activeCount()))
            }
            "setLiveDspDvcDb" -> {
                // DVC is its own smoothed native gain stage, not EQ preamp or crossfade gain.
                val db = (call.argument<Number>("db") ?: 0.0).toDouble().coerceIn(-24.0, 6.0)
                val linear = Math.pow(10.0, db / 20.0).coerceIn(0.0, 4.0)
                DspEngineRegistry.applyVolumeAll(linear)
                result.success(mapOf("ok" to true, "db" to db, "linear" to linear, "active" to DspEngineRegistry.activeCount()))
            }
            "setLiveDspDvc" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                val db = (call.argument<Number>("db") ?: 0.0).toFloat().coerceIn(-120f, 24f)
                val smoothing = call.argument<Boolean>("smoothing") ?: true
                val smoothingMs = (call.argument<Number>("smoothingMs") ?: 15.0).toFloat().coerceIn(0f, 200f)
                DspEngineRegistry.applyDvcAll(enabled, db, smoothing, smoothingMs)
                result.success(mapOf("ok" to true, "enabled" to enabled, "db" to db, "active" to DspEngineRegistry.activeCount()))
            }
            "setLiveDspLimiterConfig" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                val mode = (call.argument<Number>("mode") ?: 0).toInt().coerceIn(0, 3)
                val threshold = (call.argument<Number>("thresholdDb") ?: -1.0).toFloat()
                val release = (call.argument<Number>("releaseMs") ?: 50.0).toFloat()
                val attack = (call.argument<Number>("attackMs") ?: 0.1).toFloat()
                val lookahead = (call.argument<Number>("lookaheadMs") ?: 2.0).toFloat()
                val knee = (call.argument<Number>("kneeDb") ?: 0.0).toFloat()
                DspEngineRegistry.applyLimiterConfigAll(enabled, mode, threshold, release, attack, lookahead, knee)
                result.success(mapOf("ok" to true, "enabled" to enabled, "mode" to mode, "active" to DspEngineRegistry.activeCount()))
            }
            "setLiveDspDither" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                val mode = (call.argument<Number>("mode") ?: 1).toInt().coerceIn(0, 2)
                DspEngineRegistry.applyDitherAll(enabled, mode)
                result.success(mapOf("ok" to true, "enabled" to enabled, "mode" to mode, "active" to DspEngineRegistry.activeCount()))
            }
            "setLiveDspParametricEqBands" -> {
                val frequencies = (call.argument<List<Number>>("frequenciesHz") ?: emptyList()).map { it.toFloat() }.toFloatArray()
                val gains = (call.argument<List<Number>>("gainsDb") ?: emptyList()).map { it.toFloat() }.toFloatArray()
                val qs = (call.argument<List<Number>>("qs") ?: emptyList()).map { it.toFloat() }.toFloatArray()
                val types = (call.argument<List<Number>>("types") ?: emptyList()).map { it.toInt() }.toIntArray()
                val ok = DspEngineRegistry.applyParametricEqBandsAll(frequencies, gains, qs, types)
                result.success(mapOf("ok" to ok, "bands" to frequencies.size, "active" to DspEngineRegistry.activeCount()))
            }
            "setLiveDspLimiterCeiling" -> {
                val high = ((call.argument<Number>("highDb") ?: -0.5).toFloat())
                    .coerceIn(-12.0f, -0.05f)
                val low = ((call.argument<Number>("lowDb") ?: -0.2).toFloat())
                    .coerceIn(-12.0f, -0.05f)
                DspEngineRegistry.applyLimiterCeilingAll(high, low)
                result.success(mapOf(
                    "ok" to true,
                    "highDb" to high,
                    "lowDb" to low,
                    "active" to DspEngineRegistry.activeCount(),
                ))
            }
            "setLiveDspCrossoverHz" -> {
                val hz = ((call.argument<Number>("hz") ?: 120.0).toFloat())
                    .coerceIn(80.0f, 200.0f)
                DspEngineRegistry.applyCrossoverHzAll(hz)
                result.success(mapOf(
                    "ok" to true,
                    "hz" to hz,
                    "active" to DspEngineRegistry.activeCount(),
                ))
            }
            "setLiveDspEqBands" -> {
                val centers = (call.argument<List<Double>>("centersHz") ?: emptyList()).toDoubleArray()
                val gains = (call.argument<List<Double>>("gainsDb") ?: emptyList()).toDoubleArray()
                val enabled = call.argument<Boolean>("enabled") ?: true
                DspEngineRegistry.applyEqBandsAll(
                    if (centers.isEmpty()) null else centers,
                    gains,
                    enabled,
                )
                result.success(mapOf("ok" to true, "bands" to gains.size, "active" to DspEngineRegistry.activeCount()))
            }
            "setLiveDspSpeakerMode" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                DspEngineRegistry.applySpeakerModeAll(enabled)
                result.success(mapOf(
                    "ok" to true,
                    "enabled" to enabled,
                    "active" to DspEngineRegistry.activeCount(),
                ))
            }
            "setLiveDspVirtualBass" -> {
                val amount = (call.argument<Number>("amount") ?: 0.55).toDouble().coerceIn(0.0, 1.0)
                DspEngineRegistry.applyVirtualBassAll(amount)
                result.success(mapOf("ok" to true, "amount" to amount))
            }
            "setLiveDspIntelligenceConfig" -> {
                val bassWeight = (call.argument<Number>("bassWeight") ?: 0.50).toFloat()
                val preampWeight = (call.argument<Number>("preampWeight") ?: 0.20).toFloat()
                val gainWeight = (call.argument<Number>("gainWeight") ?: 0.30).toFloat()
                val autoPreamp = call.argument<Boolean>("autoPreampEnabled") ?: false
                val autoPreampTarget = (call.argument<Number>("autoPreampTargetDb") ?: 0.0).toFloat()
                val autoVirtualBass = call.argument<Boolean>("autoVirtualBassEnabled") ?: false
                val autoVirtualBassTarget = (call.argument<Number>("autoVirtualBassTarget") ?: 0.55).toFloat()
                val silenceHygiene = call.argument<Boolean>("silenceHygieneEnabled") ?: false
                val silenceThreshold = (call.argument<Number>("silenceThresholdDb") ?: -70.0).toFloat()
                val silenceHold = (call.argument<Number>("silenceHoldMs") ?: 500.0).toFloat()
                DspEngineRegistry.applyIntelligenceConfigAll(
                    bassWeight, preampWeight, gainWeight,
                    autoPreamp, autoPreampTarget,
                    autoVirtualBass, autoVirtualBassTarget,
                    silenceHygiene, silenceThreshold, silenceHold,
                )
                result.success(DspEngineRegistry.statusMap())
            }
            "setLiveDspAutoDynamicsConfig" -> {
                val autoBassEnabled = call.argument<Boolean>("autoBassEnabled") ?: false
                val autoBassTargetDb = (call.argument<Number>("autoBassTargetDb") ?: 4.0).toFloat()
                val autoBassMarginDb = (call.argument<Number>("autoBassMarginDb") ?: 1.0).toFloat()
                val autoBassFreqHz = (call.argument<Number>("autoBassFreqHz") ?: 80.0).toFloat()
                val autoGainEnabled = call.argument<Boolean>("autoGainEnabled") ?: false
                val autoGainTargetRmsDb = (call.argument<Number>("autoGainTargetRmsDb") ?: -18.0).toFloat()
                val autoGainBiasDb = (call.argument<Number>("autoGainBiasDb") ?: 0.0).toFloat()
                val autoGainMaxBoostDb = (call.argument<Number>("autoGainMaxBoostDb") ?: 6.0).toFloat()
                val autoGainMaxCutDb = (call.argument<Number>("autoGainMaxCutDb") ?: 12.0).toFloat()
                val autoGainWindowMs = (call.argument<Number>("autoGainWindowMs") ?: 400.0).toFloat()
                val ok = DspEngineRegistry.applyAutoDynamicsConfigAll(
                    autoBassEnabled, autoBassTargetDb, autoBassMarginDb, autoBassFreqHz,
                    autoGainEnabled, autoGainTargetRmsDb, autoGainBiasDb,
                    autoGainMaxBoostDb, autoGainMaxCutDb, autoGainWindowMs,
                )
                result.success(mapOf("ok" to ok) + DspEngineRegistry.statusMap())
            }
            "setLiveDspDeckAnalysisHint" -> {
                val deckId = call.argument<String>("deckId") ?: ""
                val songId = call.argument<String>("songId") ?: ""
                val samplePeak = (call.argument<Number>("samplePeakDb") ?: Double.NaN).toFloat()
                val truePeak = (call.argument<Number>("truePeakDb") ?: Double.NaN).toFloat()
                val rms = (call.argument<Number>("rmsDb") ?: Double.NaN).toFloat()
                val crest = (call.argument<Number>("crestDb") ?: Double.NaN).toFloat()
                val bass = (call.argument<Number>("bassEnergyDb") ?: Double.NaN).toFloat()
                val ok = DspEngineRegistry.applyDeckAnalysisHint(
                    deckId, songId, samplePeak, truePeak, rms, crest, bass,
                )
                result.success(mapOf("ok" to ok, "deckId" to deckId, "songId" to songId))
            }
            "getLiveDspStatus" -> result.success(DspEngineRegistry.statusMap())
            else -> result.notImplemented()
        }
    }
}
