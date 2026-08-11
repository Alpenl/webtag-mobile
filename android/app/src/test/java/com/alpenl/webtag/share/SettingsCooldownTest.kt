package com.alpenl.webtag.share

import com.alpenl.webtag.share.contract.QueueIdentity
import com.alpenl.webtag.share.contract.RecentResult
import com.alpenl.webtag.share.contract.RetryPolicy
import com.alpenl.webtag.share.queue.MobileClock
import com.alpenl.webtag.share.settings.RecentProjection
import com.alpenl.webtag.share.settings.awaitCooldownDeadline
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Drives the refresh cooldown off a clock the test owns.
 *
 * A cooldown that only lifts when something else happens to redraw the screen is the bug this
 * exists for: the reader sits on a disabled button minutes past its deadline, and the only way out
 * is to leave and come back. So the assertions are about the boundary itself — disabled at one
 * millisecond before the deadline, enabled at the deadline — and about the cost of getting there,
 * which is one parked wait rather than a poll.
 */
class SettingsCooldownTest {
    @Test
    fun theButtonUnlocksExactlyAtTheDeadlineAfterParkingOnce() = runBlocking {
        val clock = MutableClock(START)
        val cooling = recent(deadline = START + 60_000)
        val observed = mutableListOf<Long>()
        val sleeps = mutableListOf<Long>()

        assertFalse(RecentProjection.of(cooling, clock.now(), busy = false).refreshEnabled)

        awaitCooldownDeadline(
            reason = cooling.refreshBlockReason,
            refreshNotBefore = cooling.refreshNotBefore,
            clock = clock,
            sleep = { millis ->
                sleeps += millis
                // One millisecond short of the deadline the button is still locked, and the wait
                // has to park again rather than declaring itself finished.
                clock.value += millis - 1
                assertFalse(RecentProjection.of(cooling, clock.now(), false).refreshEnabled)
                clock.value += 1
            },
            onNow = { observed += it },
        )

        // One park, for exactly the remaining interval. A polling implementation would show
        // hundreds of one-second entries here instead.
        assertEquals(listOf(60_000L), sleeps)
        assertEquals(listOf(START, START + 60_000), observed)
        assertTrue(RecentProjection.of(cooling, clock.now(), busy = false).refreshEnabled)
    }

    @Test
    fun theWaitHasNothingItCouldWriteOrRequestWith() {
        val source = java.io.File("src/main/java/com/alpenl/webtag/share/settings/SettingsSnapshotLoader.kt")
        assertTrue("source not found from ${java.io.File("").absolutePath}", source.isFile)
        val body = source.readText()
            .substringAfter("internal suspend fun awaitCooldownDeadline(")

        // Reaching a deadline updates view state and nothing else. Giving the wait a repository or
        // an API client is how "the cooldown expired" quietly turns into "the cooldown expired, so
        // we re-ran the analysis", which is a request the reader never asked for.
        for (forbidden in listOf("repository", "runtime", "api", "database", "Dao", "refresh(")) {
            assertFalse(forbidden, body.contains(forbidden))
        }
    }

    @Test
    fun anAlreadyElapsedDeadlineParksNothing() = runBlocking {
        val clock = MutableClock(START + 60_000)
        var sleeps = 0

        awaitCooldownDeadline(
            reason = RetryPolicy.REFRESH_COOLDOWN_REASON,
            refreshNotBefore = START + 60_000,
            clock = clock,
            sleep = { sleeps += 1 },
            onNow = {},
        )

        // `now == deadline` is unlocked, not "one more tick then unlocked".
        assertEquals(0, sleeps)
    }

    @Test
    fun aDeadlineCrossedInTheBackgroundIsResolvedOnTheFirstRecomputation() = runBlocking {
        val clock = MutableClock(START)
        val cooling = recent(deadline = START + 60_000)
        var now = clock.now()

        // The host is backgrounded here. `delay` runs off a clock that does not advance while the
        // process is frozen, so the wait that was parked never fires; wall time still passes.
        clock.value = START + 120_000

        // Returning to the foreground restarts the wait, and its very first observation is enough.
        awaitCooldownDeadline(
            reason = cooling.refreshBlockReason,
            refreshNotBefore = cooling.refreshNotBefore,
            clock = clock,
            sleep = { throw AssertionError("an elapsed cooldown must not park again") },
            onNow = { now = it },
        )

        assertEquals(START + 120_000, now)
        assertTrue(RecentProjection.of(cooling, now, busy = false).refreshEnabled)
    }

    @Test
    fun aQuotaBlockNeverParks() = runBlocking {
        val clock = MutableClock(START)
        var sleeps = 0

        awaitCooldownDeadline(
            reason = RetryPolicy.REFRESH_QUOTA_REASON,
            refreshNotBefore = null,
            clock = clock,
            sleep = { sleeps += 1 },
            onNow = {},
        )

        // Quota is not a timed cooldown. Parking on it would leave a wait that can never complete.
        assertEquals(0, sleeps)
    }

    @Test
    fun replacingTheRecentResultRetiresTheWaitThatBelongedToTheOldOne() = runBlocking {
        val clock = MutableClock(START)
        var lastObserved = 0L

        coroutineScope {
            val wait = async {
                awaitCooldownDeadline(
                    reason = RetryPolicy.REFRESH_COOLDOWN_REASON,
                    refreshNotBefore = START + 3_600_000,
                    clock = clock,
                    sleep = { kotlinx.coroutines.delay(it) },
                    onNow = { lastObserved = it },
                )
            }
            yield()
            assertEquals(START, lastObserved)
            // A replacement recent, an identity switch and disposal all reach the wait the same
            // way: the effect that owns it is cancelled, and nothing it observed is committed.
            wait.cancel()
            assertTrue(runCatching { wait.await() }.exceptionOrNull() is CancellationException)
        }

        clock.value = START + 3_600_000
        assertEquals(START, lastObserved)
    }

    @Test
    fun anIdentitySwitchLeavesTheReplacementRedactedAndLocked() {
        val mismatched = recent(deadline = START + 60_000).copy(isIdentityMismatch = true)

        val view = RecentProjection.of(mismatched, START + 3_600_000, busy = false)

        // Even well past the old session's deadline, a mismatched recent offers nothing to refresh.
        assertTrue(view.redacted)
        assertFalse(view.refreshVisible)
        assertFalse(view.refreshEnabled)
    }

    private class MutableClock(var value: Long) : MobileClock {
        override fun now(): Long = value
    }

    private fun recent(deadline: Long) = RecentResult(
        url = "https://example.com/article",
        linkId = "0199a1d2-7c41-7b3e-9f60-2b8c4d5e6f70",
        jobId = null,
        status = "failed",
        createdAt = START,
        identity = QueueIdentity("https://webtag.example", "namespace"),
        refreshNotBefore = deadline,
        refreshBlockReason = RetryPolicy.REFRESH_COOLDOWN_REASON,
    )

    private companion object {
        const val START = 1_786_411_200_000L
    }
}
