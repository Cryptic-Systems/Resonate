package com.Aetherion.Resonate

import com.aetherion.resonate.dsp.DspEngineRegistry
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class LiveDspChannelHandlerTest {
    private class CapturingResult : MethodChannel.Result {
        var value: Any? = null
        var errorCode: String? = null
        override fun success(result: Any?) { value = result }
        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            this.errorCode = errorCode
        }
        override fun notImplemented() { errorCode = "NOT_IMPLEMENTED" }
    }

    @Before
    fun setUp() {
        DspEngineRegistry.resetForTests()
        DspEngineRegistry.setDeckTrack("A", "song-1")
    }

    @After
    fun tearDown() {
        DspEngineRegistry.resetForTests()
    }

    @Test
    fun deckAnalysisHintIsHandledAndCachedForTheMatchingDeck() {
        val result = CapturingResult()
        val call = MethodCall(
            "setLiveDspDeckAnalysisHint",
            mapOf(
                "deckId" to "A",
                "songId" to "song-1",
                "samplePeakDb" to -1.0,
                "truePeakDb" to -0.8,
                "rmsDb" to -18.0,
                "crestDb" to 10.0,
                "bassEnergyDb" to -12.0,
                "maxSafeBassDb" to 6.0,
            ),
        )

        LiveDspChannelHandler().handle(call, result)

        @Suppress("UNCHECKED_CAST")
        val response = result.value as Map<String, Any?>
        assertEquals(null, result.errorCode)
        assertTrue(response["ok"] == true)
        assertEquals("cached_for_future_engine", response["reason"])
        assertEquals("A", response["deckId"])
        assertEquals("song-1", response["songId"])
    }

    @Test
    fun deckAnalysisHintRejectsAStaleSongIdentity() {
        val result = CapturingResult()
        val call = MethodCall(
            "setLiveDspDeckAnalysisHint",
            mapOf(
                "deckId" to "A",
                "songId" to "old-song",
                "samplePeakDb" to -1.0,
                "truePeakDb" to -0.8,
                "rmsDb" to -18.0,
                "crestDb" to 10.0,
                "bassEnergyDb" to -12.0,
                "maxSafeBassDb" to 6.0,
            ),
        )

        LiveDspChannelHandler().handle(call, result)

        @Suppress("UNCHECKED_CAST")
        val response = result.value as Map<String, Any?>
        assertTrue(response["ok"] == false)
        assertEquals("deck_song_mismatch", response["reason"])
    }
}
