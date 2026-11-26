package com.aetherion.resonate.dsp

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import java.nio.ByteBuffer

/**
 * First processor in the DJ sink chain. It binds each PCM block to the PTS
 * recorded by TimestampedDjAudioSink, then passes the PCM through unchanged.
 *
 * This is the timestamp foundation for the bounded scratch ring buffer; it
 * deliberately does not alter playback until cursor/buffer semantics are
 * implemented and verified.
 */
internal class DjScratchTimestampProcessor(
    private val deckId: String,
    private val ledger: DjScratchTimestampLedger,
) : BaseAudioProcessor() {
    @Volatile
    private var lastConsumedTimestamp: DjScratchPcmTimestamp? = null

    internal fun lastConsumedTimestampForTest(): DjScratchPcmTimestamp? =
        lastConsumedTimestamp

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        // Timestamp mapping is valid only for the PCM16 path used by the native
        // DSP processor. Other formats are passed through without metadata.
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) {
            lastConsumedTimestamp = null
        }
        return inputAudioFormat
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        if (!inputBuffer.hasRemaining()) return
        val timestamp = ledger.consume(
            inputBuffer,
            inputAudioFormat.sampleRate,
            inputAudioFormat.channelCount,
        )
        if (timestamp != null) lastConsumedTimestamp = timestamp
        val output = replaceOutputBuffer(inputBuffer.remaining())
        output.put(inputBuffer)
        output.flip()
    }

    override fun onFlush() {
        lastConsumedTimestamp = null
    }

    override fun onReset() {
        lastConsumedTimestamp = null
        ledger.clear()
    }
}
