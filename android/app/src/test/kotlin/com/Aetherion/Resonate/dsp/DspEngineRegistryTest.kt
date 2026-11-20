package com.aetherion.resonate.dsp

import org.junit.After
import org.junit.Before
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class DspEngineRegistryTest {
    private open class FakeApi : DspEngineRegistry.NativeDspApi {
        val calls = mutableListOf<String>()

        override fun setEnabled(handle: Long, enabled: Boolean) {
            calls += "eq-enabled:" + handle + ":" + enabled
        }

        override fun setProcessingEnabled(handle: Long, enabled: Boolean) {
            calls += "enabled:" + handle + ":" + enabled
        }

        override fun setVolume(handle: Long, linearGain: Double) {
            calls += "volume:" + handle + ":" + linearGain
        }

        override fun setEqBands(handle: Long, centersHz: DoubleArray?, gainsDb: DoubleArray, enabled: Boolean) {
            calls += "eq:" + handle + ":" + gainsDb.joinToString(",") + ":" + enabled
        }

        override fun setSpeakerMode(handle: Long, enabled: Boolean) {
            calls += "speaker:" + handle + ":" + enabled
        }

        override fun setVirtualBass(handle: Long, amount: Double) {
            calls += "bass:" + handle + ":" + amount
        }

        override fun setPreamp(handle: Long, linearGain: Double) {
            calls += "preamp:" + handle + ":" + linearGain
        }

        override fun setLimiterCeiling(handle: Long, highDb: Float, lowDb: Float) {
            calls += "limiter:" + handle + ":" + highDb + ":" + lowDb
        }

        override fun setCrossoverHz(handle: Long, freqHz: Float) {
            calls += "crossover:" + handle + ":" + freqHz
        }

        override fun setParametricEqBands(
            handle: Long, frequenciesHz: FloatArray, gainsDb: FloatArray,
            qs: FloatArray, types: IntArray, enabled: Boolean
        ) {
            calls += "parametric:" + handle + ":" + frequenciesHz.size + ":" +
                qs.firstOrNull() + ":" + types.firstOrNull()
            setEqBands(handle, frequenciesHz.map { it.toDouble() }.toDoubleArray(),
                gainsDb.map { it.toDouble() }.toDoubleArray(), enabled)
        }

        override fun setDvc(handle: Long, enabled: Boolean, gainDb: Float, smoothing: Boolean, smoothingMs: Float) {
            calls += "dvc:" + handle + ":" + enabled + ":" + gainDb + ":" + smoothing + ":" + smoothingMs
        }

        override fun setLimiterConfig(
            handle: Long, enabled: Boolean, mode: Int, thresholdDb: Float,
            releaseMs: Float, attackMs: Float, lookaheadMs: Float, kneeDb: Float
        ) {
            calls += "limiter-config:" + handle + ":" + enabled + ":" + mode + ":" + thresholdDb
        }

        override fun setDither(handle: Long, enabled: Boolean, mode: Int) {
            calls += "dither:" + handle + ":" + enabled + ":" + mode
        }

        override fun setAnalysisHint(
            handle: Long, enabled: Boolean, samplePeakDb: Float, truePeakDb: Float,
            rmsDb: Float, crestDb: Float, bassEnergyDb: Float,
        ) {
            calls += "analysis:" + handle + ":" + enabled + ":" + samplePeakDb + ":" +
                truePeakDb + ":" + rmsDb + ":" + crestDb + ":" + bassEnergyDb
        }

        override fun setIntelligenceConfig(
            handle: Long, bassWeight: Float, preampWeight: Float, gainWeight: Float,
            autoPreampEnabled: Boolean, autoPreampTargetDb: Float,
            autoVirtualBassEnabled: Boolean, autoVirtualBassTarget: Float,
            silenceHygieneEnabled: Boolean, silenceThresholdDb: Float, silenceHoldMs: Float,
        ) {
            calls += "intelligence:" + handle + ":" + bassWeight + ":" + preampWeight + ":" +
                gainWeight + ":" + autoPreampEnabled + ":" + autoPreampTargetDb + ":" +
                autoVirtualBassEnabled + ":" + autoVirtualBassTarget + ":" +
                silenceHygieneEnabled + ":" + silenceThresholdDb + ":" + silenceHoldMs
        }
    }

    private lateinit var fake: FakeApi

    @Before
    fun setUp() {
        DspEngineRegistry.resetForTests()
        fake = FakeApi()
        DspEngineRegistry.nativeApi = fake
    }

    @After
    fun tearDown() {
        DspEngineRegistry.resetForTests()
    }

    @Test
    fun register_applies_one_coherent_sticky_generation_to_new_engine() {
        DspEngineRegistry.applyVolumeAll(0.72)
        DspEngineRegistry.applyEqBandsAll(
            doubleArrayOf(60.0, 1000.0, 8000.0),
            doubleArrayOf(2.0, -1.5, 3.0),
            true
        )
        DspEngineRegistry.applySpeakerModeAll(true)
        DspEngineRegistry.applyVirtualBassAll(0.81)
        DspEngineRegistry.applyPreampAll(1.35)
        DspEngineRegistry.applyLimiterCeilingAll(-0.8f, -0.3f)
        DspEngineRegistry.applyCrossoverHzAll(140f)

        fake.calls.clear()
        assertTrue(DspEngineRegistry.register(2, 2002L))

        assertEquals(1, DspEngineRegistry.activeCount())
        assertTrue(fake.calls.any { it == "volume:2002:0.72" })
        assertTrue(fake.calls.any { it == "eq:2002:2.0,-1.5,3.0:true" })
        assertTrue(fake.calls.any { it == "speaker:2002:true" })
        assertTrue(fake.calls.any { it == "bass:2002:0.81" })
        assertTrue(fake.calls.any { it == "preamp:2002:1.35" })
        assertTrue(fake.calls.any { it == "limiter:2002:-0.8:-0.3" })
        assertTrue(fake.calls.any { it == "crossover:2002:140.0" })
    }

    @Test
    fun advanced_dsp_profile_is_sticky_and_applied_to_new_engine() {
        DspEngineRegistry.applyDvcAll(false, -6f, false, 28f)
        DspEngineRegistry.applyLimiterConfigAll(true, 3, -2f, 120f, 1f, 5f, 2f)
        DspEngineRegistry.applyDitherAll(true, 2)
        assertTrue(DspEngineRegistry.applyParametricEqBandsAll(
            floatArrayOf(40f, 1000f, 12000f),
            floatArrayOf(4f, -1f, 2f),
            floatArrayOf(0.8f, 1.2f, 2f),
            intArrayOf(1, 0, 2),
        ))

        fake.calls.clear()
        assertTrue(DspEngineRegistry.register(11, 11011L))

        assertTrue(fake.calls.any { it == "dvc:11011:false:-6.0:false:28.0" })
        assertTrue(fake.calls.any { it == "limiter-config:11011:true:3:-2.0" })
        assertTrue(fake.calls.any { it == "dither:11011:true:2" })
        assertTrue(fake.calls.any { it == "parametric:11011:3:0.8:1" })
    }

    @Test
    fun v06_intelligence_profile_is_normalized_clamped_and_inherited_by_new_decks() {
        assertTrue(DspEngineRegistry.register(41, 41041L, "A"))
        DspEngineRegistry.applyIntelligenceConfigAll(
            2f, 1f, 1f,
            true, 18f,
            true, 1.4f,
            true, -140f, 9000f,
        )

        assertTrue(fake.calls.any {
            it == "intelligence:41041:0.5:0.25:0.25:true:12.0:true:1.0:true:-120.0:5000.0"
        })

        val status = DspEngineRegistry.statusMap()
        assertEquals(0.5f, status["headroomBassWeight"])
        assertEquals(0.25f, status["headroomPreampWeight"])
        assertEquals(0.25f, status["headroomGainWeight"])
        assertEquals(12f, status["autoPreampTargetDb"])
        assertEquals(1f, status["autoVirtualBassTarget"])
        assertEquals(-120f, status["silenceThresholdDb"])
        assertEquals(5000f, status["silenceHoldMs"])

        fake.calls.clear()
        assertTrue(DspEngineRegistry.register(42, 42042L, "B"))
        assertTrue(fake.calls.any {
            it == "intelligence:42042:0.5:0.25:0.25:true:12.0:true:1.0:true:-120.0:5000.0"
        })
    }

    @Test
    fun v06_intelligence_profile_rejects_non_finite_or_empty_headroom_weights() {
        DspEngineRegistry.applyIntelligenceConfigAll(
            0f, 0f, 0f,
            true, 4f, true, 0.8f, true, -70f, 500f,
        )
        val status = DspEngineRegistry.statusMap()
        assertEquals(0.50f, status["headroomBassWeight"])
        assertEquals(0.20f, status["headroomPreampWeight"])
        assertEquals(0.30f, status["headroomGainWeight"])

        DspEngineRegistry.applyIntelligenceConfigAll(
            Float.NaN, 0.2f, 0.3f,
            true, 4f, true, 0.8f, true, -70f, 500f,
        )
        assertEquals(0.50f, DspEngineRegistry.statusMap()["headroomBassWeight"])
    }

    @Test
    fun default_q_tracks_the_spacing_of_studio_and_legacy_eq_banks() {
        DspEngineRegistry.applyEqBandsAll(
            DoubleArray(31) { 20.0 + it },
            DoubleArray(31),
            true,
        )
        assertTrue(DspEngineRegistry.register(31, 31031L))
        assertTrue(fake.calls.any { it == "parametric:31031:31:4.3:0" })

        DspEngineRegistry.unregister(31)
        fake.calls.clear()
        DspEngineRegistry.applyEqBandsAll(
            DoubleArray(10) { 100.0 + it * 100.0 },
            DoubleArray(10),
            true,
        )
        assertTrue(DspEngineRegistry.register(10, 10010L))
        assertTrue(fake.calls.any { it == "parametric:10010:10:1.4:0" })
    }

    @Test
    fun master_volume_remains_effective_when_dvc_is_bypassed() {
        DspEngineRegistry.applyPreampAll(1.0)
        DspEngineRegistry.applyDvcAll(false, -6f, true, 15f)
        fake.calls.clear()
        assertTrue(DspEngineRegistry.register(12, 12012L))
        assertTrue(fake.calls.any { it.startsWith("preamp:12012:0.501") })

        fake.calls.clear()
        DspEngineRegistry.applyVolumeAll(0.25)
        assertTrue(fake.calls.any { it == "preamp:12012:0.25" })
    }

    @Test
    fun preview_decks_inherit_the_same_sticky_dsp_profile_as_music_decks() {
        DspEngineRegistry.applyDvcAll(true, -3f, true, 18f)
        DspEngineRegistry.applyDitherAll(true, 2)
        fake.calls.clear()
        assertTrue(DspEngineRegistry.register(81, 8101L, "preview_out"))
        assertTrue(DspEngineRegistry.register(82, 8202L, "preview_in"))
        assertEquals(2, DspEngineRegistry.activeCount())
        assertTrue(fake.calls.any { it == "dvc:8101:true:-3.0:true:18.0" })
        assertTrue(fake.calls.any { it == "dvc:8202:true:-3.0:true:18.0" })
        assertTrue(fake.calls.any { it == "dither:8101:true:2" })
        assertTrue(fake.calls.any { it == "dither:8202:true:2" })
    }

    @Test
    fun register_rejects_engine_when_sticky_application_fails() {
        val failing = object : FakeApi() {
            override fun setVolume(handle: Long, linearGain: Double) {
                throw IllegalStateException("synthetic JNI failure")
            }
        }
        DspEngineRegistry.nativeApi = failing

        assertFalse(DspEngineRegistry.register(3, 3003L))
        assertEquals(0, DspEngineRegistry.activeCount())
    }

    @Test
    fun live_updates_reach_all_registered_engines() {
        assertTrue(DspEngineRegistry.register(1, 1001L))
        assertTrue(DspEngineRegistry.register(2, 2002L))
        fake.calls.clear()

        DspEngineRegistry.applyPreampAll(1.5)

        assertEquals(
            setOf("preamp:1001:1.5", "preamp:2002:1.5"),
            fake.calls.filter { it.startsWith("preamp:") }.toSet()
        )
    }
    @Test
    fun dvc_gain_is_clamped_and_inherited_by_new_engines() {
        DspEngineRegistry.applyVolumeAll(99.0)
        assertTrue(fake.calls.none { it.startsWith("volume:") })

        fake.calls.clear()
        assertTrue(DspEngineRegistry.register(7, 7007L))
        assertTrue(fake.calls.contains("volume:7007:4.0"))

        fake.calls.clear()
        DspEngineRegistry.applyVolumeAll(-2.0)
        assertTrue(fake.calls.contains("volume:7007:0.0"))
    }

    @Test
    fun setting_update_cannot_miss_engine_being_registered() {
        val enteredRegister = CountDownLatch(1)
        val releaseRegister = CountDownLatch(1)
        val blocking = object : FakeApi() {
            override fun setVolume(handle: Long, linearGain: Double) {
                if (handle == 2002L && enteredRegister.count > 0) {
                    enteredRegister.countDown()
                    check(releaseRegister.await(2, TimeUnit.SECONDS)) {
                        "test timed out waiting to release registration"
                    }
                }
                super.setVolume(handle, linearGain)
            }
        }
        DspEngineRegistry.nativeApi = blocking

        val registerThread = Thread {
            check(DspEngineRegistry.register(2, 2002L))
        }
        registerThread.start()
        assertTrue(enteredRegister.await(2, TimeUnit.SECONDS))

        val updateDone = CountDownLatch(1)
        val updateThread = Thread {
            try {
                DspEngineRegistry.applyVolumeAll(0.42)
            } finally {
                updateDone.countDown()
            }
        }
        updateThread.start()

        // The update must block while registration is applying its sticky snapshot.
        // Without the shared lock, it can finish now and miss the unpublished handle.
        val updateWasBlocked = !updateDone.await(100, TimeUnit.MILLISECONDS)
        releaseRegister.countDown()
        registerThread.join(2000)
        updateThread.join(2000)
        assertFalse(registerThread.isAlive)
        assertFalse(updateThread.isAlive)
        assertTrue(updateWasBlocked)

        assertTrue(blocking.calls.any { it == "volume:2002:0.42" })
        blocking.calls.clear()
        assertTrue(DspEngineRegistry.register(3, 3003L))
        assertTrue(blocking.calls.any { it == "volume:3003:0.42" })
    }


    @Test
    fun processing_cannot_be_disabled_and_is_inherited_by_new_engines() {
        assertTrue(DspEngineRegistry.register(1, 1001L))
        DspEngineRegistry.applyEnabledAll(false)
        assertTrue(fake.calls.any { it == "enabled:1001:true" })

        fake.calls.clear()
        assertTrue(DspEngineRegistry.register(2, 2002L))
        assertTrue(fake.calls.any { it == "enabled:2002:true" })

        fake.calls.clear()
        DspEngineRegistry.applyEnabledAll(true)
        assertTrue(fake.calls.any { it == "enabled:1001:true" })
        assertTrue(fake.calls.any { it == "enabled:2002:true" })
    }

    @Test
    fun new_engine_without_eq_curve_keeps_processing_always_on() {
        DspEngineRegistry.applyEnabledAll(false)
        fake.calls.clear()

        assertTrue(DspEngineRegistry.register(9, 9009L))

        // Both the processing gate and EQ gate are always enabled.
        assertTrue(fake.calls.contains("enabled:9009:true"))
        assertTrue(fake.calls.contains("eq-enabled:9009:true"))
    }

    @Test
    fun eq_processing_remains_enabled_when_legacy_off_command_arrives() {
        assertTrue(DspEngineRegistry.register(1, 1001L))
        DspEngineRegistry.applyEnabledAll(false)
        DspEngineRegistry.applyEqBandsAll(
            doubleArrayOf(80.0, 1000.0, 8000.0),
            doubleArrayOf(3.0, 0.0, -2.0),
            true
        )
        assertTrue(fake.calls.contains("eq:1001:3.0,0.0,-2.0:true"))

        fake.calls.clear()
        DspEngineRegistry.applyEnabledAll(true)

        assertTrue(fake.calls.contains("enabled:1001:true"))
        assertTrue(fake.calls.contains("eq:1001:3.0,0.0,-2.0:true"))
    }

    @Test
    fun legacy_disabled_eq_request_cannot_bypass_resonate_eq() {
        assertTrue(DspEngineRegistry.register(1, 1001L))
        DspEngineRegistry.applyEqBandsAll(
            doubleArrayOf(80.0, 1000.0, 8000.0),
            doubleArrayOf(3.0, 0.0, -2.0),
            false
        )
        fake.calls.clear()

        DspEngineRegistry.applyEnabledAll(false)
        DspEngineRegistry.applyEnabledAll(true)

        assertTrue(fake.calls.any { it == "eq:1001:3.0,0.0,-2.0:true" })
        assertTrue(fake.calls.contains("enabled:1001:true"))
        assertTrue(fake.calls.none { it == "eq:1001:3.0,0.0,-2.0:false" })
    }

    @Test
    fun status_reports_last_requested_dvc_preamp_limiter_and_crossover_values() {
        DspEngineRegistry.applyVolumeAll(0.5011872336)
        DspEngineRegistry.applyPreampAll(1.2589254118)
        DspEngineRegistry.applyLimiterCeilingAll(-1.2f, -2.4f)
        DspEngineRegistry.applyCrossoverHzAll(135f)

        val status = DspEngineRegistry.statusMap()
        assertEquals(0.5011872336, status["linearGain"])
        assertEquals(1.2589254118, status["preampLinearGain"])
        assertEquals(-1.2f, status["limiterHighDb"])
        assertEquals(-2.4f, status["limiterLowDb"])
        assertEquals(135f, status["crossoverHz"])
        assertEquals(0, status["activeEngines"])
    }

    @Test
    fun limiter_and_crossover_updates_are_clamped_and_sticky_for_both_engines() {
        assertTrue(DspEngineRegistry.register(1, 1001L))
        assertTrue(DspEngineRegistry.register(2, 2002L))
        fake.calls.clear()

        DspEngineRegistry.applyLimiterCeilingAll(-99f, 1f)
        DspEngineRegistry.applyCrossoverHzAll(900f)

        assertTrue(fake.calls.contains("limiter:1001:-12.0:-0.05"))
        assertTrue(fake.calls.contains("limiter:2002:-12.0:-0.05"))
        assertTrue(fake.calls.contains("crossover:1001:200.0"))
        assertTrue(fake.calls.contains("crossover:2002:200.0"))

        fake.calls.clear()
        assertTrue(DspEngineRegistry.register(3, 3003L))
        assertTrue(fake.calls.contains("limiter:3003:-12.0:-0.05"))
        assertTrue(fake.calls.contains("crossover:3003:200.0"))
    }

    @Test
    fun analysis_hints_are_isolated_by_physical_deck_and_media_identity() {
        assertTrue(DspEngineRegistry.setDeckTrack("A", "track-a"))
        assertTrue(DspEngineRegistry.setDeckTrack("B", "track-b"))
        assertTrue(DspEngineRegistry.register(101, 10101L, "A"))
        assertTrue(DspEngineRegistry.register(102, 10202L, "B"))
        fake.calls.clear()

        assertTrue(DspEngineRegistry.applyDeckAnalysisHint(
            "A", "track-a", -1f, -0.5f, -14f, 13f, -8f,
        ))
        assertFalse(DspEngineRegistry.applyDeckAnalysisHint(
            "A", "track-b", -2f, -1f, -16f, 10f, -12f,
        ))
        assertTrue(fake.calls.any { it.startsWith("analysis:10101:true:-1.0:-0.5:-14.0:13.0:-8.0") })
        assertFalse(fake.calls.any { it.startsWith("analysis:10202:true:") })

        fake.calls.clear()
        assertTrue(DspEngineRegistry.setDeckTrack("A", "track-c"))
        assertTrue(fake.calls.any { it == "analysis:10101:false:-160.0:-160.0:-160.0:0.0:-160.0" })
        assertFalse(fake.calls.any { it.startsWith("analysis:10202:false:") })
        assertFalse(DspEngineRegistry.applyDeckAnalysisHint(
            "A", "track-a", -1f, -0.5f, -14f, 13f, -8f,
        ))
    }

    @Test
    fun deck_analysis_hint_is_inherited_only_by_engine_for_same_current_track() {
        assertTrue(DspEngineRegistry.setDeckTrack("B", "incoming"))
        assertTrue(DspEngineRegistry.applyDeckAnalysisHint(
            "B", "incoming", -3f, -2f, -18f, 15f, -10f,
        ))
        fake.calls.clear()

        assertTrue(DspEngineRegistry.register(111, 11111L, "A"))
        assertTrue(DspEngineRegistry.register(112, 11212L, "B"))

        assertFalse(fake.calls.any { it.startsWith("analysis:11111:true:") })
        assertTrue(fake.calls.any { it.startsWith("analysis:11212:true:-3.0:-2.0:-18.0:15.0:-10.0") })
    }

    @Test
    fun repeat_one_same_track_deck_inherits_existing_measured_hint() {
        assertTrue(DspEngineRegistry.setDeckTrack("A", "repeat-song"))
        assertTrue(DspEngineRegistry.register(121, 12121L, "A"))
        assertTrue(DspEngineRegistry.applyDeckAnalysisHint(
            "A", "repeat-song", -2f, -1f, -12f, 10f, -15f,
        ))
        fake.calls.clear()

        assertTrue(DspEngineRegistry.setDeckTrack("B", "repeat-song"))
        assertTrue(DspEngineRegistry.register(122, 12222L, "B"))

        assertTrue(fake.calls.any {
            it == "analysis:12222:true:-2.0:-1.0:-12.0:10.0:-15.0"
        })
    }

    @Test
    fun repeat_one_same_track_hint_update_reaches_already_assigned_standby_deck() {
        assertTrue(DspEngineRegistry.setDeckTrack("A", "repeat-song"))
        assertTrue(DspEngineRegistry.setDeckTrack("B", "repeat-song"))
        assertTrue(DspEngineRegistry.register(131, 13131L, "A"))
        assertTrue(DspEngineRegistry.register(132, 13232L, "B"))
        fake.calls.clear()

        assertTrue(DspEngineRegistry.applyDeckAnalysisHint(
            "A", "repeat-song", -3f, -2f, -18f, 15f, -10f,
        ))

        assertTrue(fake.calls.any {
            it == "analysis:13131:true:-3.0:-2.0:-18.0:15.0:-10.0"
        })
        assertTrue(fake.calls.any {
            it == "analysis:13232:true:-3.0:-2.0:-18.0:15.0:-10.0"
        })
    }

    @Test
    fun legacy_just_audio_reflection_hook_keeps_its_no_argument_entrypoint() {
        val hook = Class.forName("com.aetherion.resonate.dsp.DspEngineSinkHook")
        val method = hook.getMethod("createProcessors")
        assertEquals(0, method.parameterCount)
    }

    @Test
    fun temporary_eq_overlay_targets_only_the_requested_logical_deck() {
        assertTrue(DspEngineRegistry.register(1, 1001L, "A"))
        assertTrue(DspEngineRegistry.register(2, 2002L, "B"))
        DspEngineRegistry.setActiveDeck("A")
        fake.calls.clear()

        assertTrue(DspEngineRegistry.setTemporaryEqOverlay(
            "active",
            doubleArrayOf(100.0, 1000.0, 10000.0),
            doubleArrayOf(-6.0, 0.0, 6.0),
        ))

        assertTrue(fake.calls.any { it.startsWith("eq:1001:") })
        assertFalse(fake.calls.any { it.startsWith("eq:2002:") })
    }

    @Test
    fun media3_deck_overlay_does_not_touch_legacy_just_audio_processors() {
        assertTrue(DspEngineRegistry.register(1, 1001L, "A"))
        assertTrue(DspEngineRegistry.register(9, 9009L, "legacy"))
        DspEngineRegistry.setActiveDeck("A")
        fake.calls.clear()

        assertTrue(DspEngineRegistry.setTemporaryEqOverlay(
            "active",
            doubleArrayOf(100.0, 1000.0),
            doubleArrayOf(-3.0, 3.0),
        ))

        assertTrue(fake.calls.any { it.startsWith("eq:1001:") })
        assertFalse(fake.calls.any { it.startsWith("eq:9009:") })
    }

    @Test
    fun standby_overlay_targets_the_inactive_physical_deck_and_role_follows_promotion() {
        assertTrue(DspEngineRegistry.register(1, 1001L, "A"))
        assertTrue(DspEngineRegistry.register(2, 2002L, "B"))
        DspEngineRegistry.setActiveDeck("A")
        fake.calls.clear()

        assertTrue(DspEngineRegistry.setTemporaryEqOverlay(
            "standby",
            doubleArrayOf(80.0, 8000.0),
            doubleArrayOf(-4.0, 4.0),
        ))
        assertTrue(fake.calls.any { it.startsWith("eq:2002:") })
        assertFalse(fake.calls.any { it.startsWith("eq:1001:") })

        DspEngineRegistry.setActiveDeck("B")
        fake.calls.clear()
        assertTrue(DspEngineRegistry.setTemporaryEqOverlay(
            "active",
            doubleArrayOf(80.0, 8000.0),
            doubleArrayOf(3.0, -3.0),
        ))
        assertTrue(fake.calls.any { it.startsWith("eq:2002:") })
        assertFalse(fake.calls.any { it.startsWith("eq:1001:") })
    }

    @Test
    fun temporary_overlay_composes_with_persistent_eq_and_clear_restores_base_curve() {
        assertTrue(DspEngineRegistry.register(1, 1001L, "A"))
        DspEngineRegistry.setActiveDeck("A")
        DspEngineRegistry.applyEqBandsAll(
            doubleArrayOf(100.0, 1000.0, 10000.0),
            doubleArrayOf(1.0, 2.0, 3.0),
            true,
        )
        fake.calls.clear()

        assertTrue(DspEngineRegistry.setTemporaryEqOverlay(
            "active",
            doubleArrayOf(100.0, 1000.0, 10000.0),
            doubleArrayOf(-2.0, 0.0, 2.0),
        ))
        assertTrue(fake.calls.contains("eq:1001:-1.0,2.0,5.0:true"))

        fake.calls.clear()
        assertTrue(DspEngineRegistry.clearTemporaryEqOverlay("active"))
        assertTrue(fake.calls.contains("eq:1001:1.0,2.0,3.0:true"))
    }

    @Test
    fun persistent_eq_updates_retain_active_deck_overlay() {
        assertTrue(DspEngineRegistry.register(1, 1001L, "A"))
        DspEngineRegistry.setActiveDeck("A")
        assertTrue(DspEngineRegistry.setTemporaryEqOverlay(
            "active",
            doubleArrayOf(100.0, 1000.0, 10000.0),
            doubleArrayOf(1.0, 2.0, 3.0),
        ))
        fake.calls.clear()

        DspEngineRegistry.applyEqBandsAll(
            doubleArrayOf(100.0, 1000.0, 10000.0),
            doubleArrayOf(4.0, 5.0, 6.0),
            true,
        )
        assertTrue(fake.calls.contains("eq:1001:5.0,7.0,9.0:true"))
    }

    @Test
    fun overlay_rejects_malformed_or_out_of_range_curves() {
        assertFalse(DspEngineRegistry.setTemporaryEqOverlay(
            "unknown",
            doubleArrayOf(100.0),
            doubleArrayOf(1.0),
        ))
        assertFalse(DspEngineRegistry.setTemporaryEqOverlay(
            "active",
            doubleArrayOf(100.0, 200.0),
            doubleArrayOf(1.0),
        ))
        assertFalse(DspEngineRegistry.setTemporaryEqOverlay(
            "active",
            doubleArrayOf(10.0),
            doubleArrayOf(1.0),
        ))
        assertFalse(DspEngineRegistry.setTemporaryEqOverlay(
            "active",
            doubleArrayOf(100.0),
            doubleArrayOf(13.0),
        ))
    }

}
