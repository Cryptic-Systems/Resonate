package com.aetherion.resonate.dsp

import org.junit.Assert.assertEquals
import org.junit.Test

class DjScratchOutputRouteGenerationTest {
    @Test
    fun outputTopologyChangesAdvanceGenerationMonotonically() {
        val routes = DjScratchOutputRouteGeneration(initialGeneration = 12L)
        assertEquals(12L, routes.snapshot())
        assertEquals(13L, routes.onOutputDevicesChanged())
        assertEquals(14L, routes.onOutputDevicesChanged())
        assertEquals(14L, routes.snapshot())
    }

    @Test
    fun independentInstancesDoNotShareRouteState() {
        val first = DjScratchOutputRouteGeneration()
        val second = DjScratchOutputRouteGeneration()
        first.onOutputDevicesChanged()
        assertEquals(1L, first.snapshot())
        assertEquals(0L, second.snapshot())
    }
}
