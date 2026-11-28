package com.aetherion.resonate.dsp

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DjScratchSpeedMappingTest {
    @Test
    fun unityPlaybackSpeedPreservesPlatterRate() {
        assertEquals(1.5, DjScratchSpeedMapping.cursorVelocity(1.5, 1f)!!, 0.0)
        assertEquals(-2.0, DjScratchSpeedMapping.cursorVelocity(-2.0, 1f)!!, 0.0)
    }

    @Test
    fun compensatesForDownstreamMedia3SpeedStage() {
        // Sonic/AudioTrack multiplies the processor output's media rate.
        // Dividing the cursor rate by that speed preserves requested audible rate.
        assertEquals(0.5, DjScratchSpeedMapping.cursorVelocity(1.0, 2f)!!, 0.0)
        assertEquals(2.0, DjScratchSpeedMapping.cursorVelocity(1.0, 0.5f)!!, 0.0)
        assertEquals(-0.75, DjScratchSpeedMapping.cursorVelocity(-1.5, 2f)!!, 0.0)
    }

    @Test
    fun rejectsInvalidOrUnrepresentableSpeedMappings() {
        assertNull(DjScratchSpeedMapping.cursorVelocity(1.0, 0f))
        assertNull(DjScratchSpeedMapping.cursorVelocity(1.0, Float.NaN))
        assertNull(DjScratchSpeedMapping.cursorVelocity(Double.NaN, 1f))
        assertNull(DjScratchSpeedMapping.cursorVelocity(4.0, 0.5f))
        assertNull(DjScratchSpeedMapping.cursorVelocity(5.0, 1f))
    }
}
