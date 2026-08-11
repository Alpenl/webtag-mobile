package com.alpenl.webtag.share

import com.alpenl.webtag.share.queue.QueueScheduler
import org.junit.Assert.assertEquals
import org.junit.Test

class QueueSchedulerTest {
    @Test
    fun schedulesImmediatelyForPendingEntries() {
        assertEquals(0L, QueueScheduler.delayMillis(1_000L, 1_000L))
        assertEquals(0L, QueueScheduler.delayMillis(500L, 1_000L))
        assertEquals(0L, QueueScheduler.delayMillis(null, 1_000L))
    }

    @Test
    fun preservesFutureRetryTimeAsInitialDelay() {
        assertEquals(90_000L, QueueScheduler.delayMillis(91_000L, 1_000L))
    }
}
