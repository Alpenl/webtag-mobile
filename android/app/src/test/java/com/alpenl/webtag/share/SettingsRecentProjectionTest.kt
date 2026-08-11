package com.alpenl.webtag.share

import com.alpenl.webtag.share.contract.QueueIdentity
import com.alpenl.webtag.share.contract.RecentResult
import com.alpenl.webtag.share.contract.RetryPolicy
import com.alpenl.webtag.share.settings.RecentProjection
import com.alpenl.webtag.share.settings.SettingsTimeFormatter
import java.util.Locale
import java.util.TimeZone
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Pins what the recent-result card is allowed to show.
 *
 * The two halves are asymmetric on purpose. A matching recent has to show *everything* — a
 * truncated link ID cannot be pasted into a support conversation, and a missing result time makes
 * "已在库中，解析失败" undatable. A mismatched one has to show *nothing*: it belongs to a session
 * the current credential has no claim on, and that includes its cooldown deadline.
 */
class SettingsRecentProjectionTest {
    private val previousLocale: Locale = Locale.getDefault()
    private val previousZone: TimeZone = TimeZone.getDefault()

    @Before
    fun pinPlatformFormatting() {
        // The card renders in whatever locale and zone the device is set to, so both are pinned
        // here to make the time assertions deterministic. They compare renderings against each
        // other rather than against a literal: the short pattern comes from the platform's CLDR
        // data, which differs between JDK builds, and a literal would pin the test to whichever
        // JDK happened to run it.
        Locale.setDefault(Locale.SIMPLIFIED_CHINESE)
        TimeZone.setDefault(TimeZone.getTimeZone("Asia/Shanghai"))
    }

    @After
    fun restorePlatformFormatting() {
        Locale.setDefault(previousLocale)
        TimeZone.setDefault(previousZone)
    }

    @Test
    fun anIdentityMatchingRecentShowsUrlStatusFullLinkIdAndResultTime() {
        val recent = recent(
            url = "https://example.com/article?ref=share",
            linkId = "0199a1d2-7c41-7b3e-9f60-2b8c4d5e6f70",
            status = "failed",
        )

        val view = RecentProjection.of(recent, nowMillis = RESULT_TIME + 1, busy = false)

        assertFalse(view.redacted)
        assertEquals("https://example.com/article?ref=share", view.url)
        assertEquals("failed", view.status)
        // The whole canonical link ID, not a prefix: a shortened one is not addressable.
        assertEquals("0199a1d2-7c41-7b3e-9f60-2b8c4d5e6f70", view.linkId)
        assertEquals("job-42", view.jobId)
        assertEquals(RESULT_TIME, view.resultTimeMillis)
        assertTrue(view.refreshVisible)
        assertTrue(view.refreshEnabled)
    }

    @Test
    fun anIdentityMismatchedRecentRedactsEveryFieldAndCannotBeRefreshed() {
        val recent = recent(
            url = "https://example.com/leaked",
            linkId = "0199a1d2-7c41-7b3e-9f60-2b8c4d5e6f70",
            status = "failed",
        ).copy(
            isIdentityMismatch = true,
            // The repository surfaces these on a mismatched row because they belong to the record.
            // Neither may reach the screen: a deadline is an observation of the other session.
            refreshBlockReason = RetryPolicy.REFRESH_COOLDOWN_REASON,
            refreshNotBefore = RESULT_TIME + 60_000,
        )

        val view = RecentProjection.of(recent, nowMillis = RESULT_TIME, busy = false)

        assertTrue(view.redacted)
        assertEquals("", view.url)
        assertEquals("", view.linkId)
        assertEquals("", view.status)
        assertNull(view.jobId)
        assertNull(view.resultTimeMillis)
        assertNull(view.blockReason)
        assertNull(view.blockNotBefore)
        assertFalse(view.cooldownActive)
        assertFalse(view.refreshVisible)
        assertFalse(view.refreshEnabled)
    }

    @Test
    fun onlyAFailedAnalysisOffersRefresh() {
        for (status in listOf("pending", "processing", "done")) {
            val view = RecentProjection.of(
                recent(status = status),
                nowMillis = RESULT_TIME,
                busy = false,
            )
            assertFalse(status, view.refreshVisible)
            assertFalse(status, view.refreshEnabled)
        }
    }

    @Test
    fun anInFlightRefreshDisablesTheButtonWithoutHidingIt() {
        val view = RecentProjection.of(recent(status = "failed"), RESULT_TIME, busy = true)

        assertTrue(view.refreshVisible)
        assertFalse(view.refreshEnabled)
    }

    @Test
    fun anElapsedCooldownRemovesTheNoticeAtTheSameInstantItEnablesTheButton() {
        val deadline = RESULT_TIME + 60_000
        val cooling = recent(status = "failed").copy(
            refreshBlockReason = RetryPolicy.REFRESH_COOLDOWN_REASON,
            refreshNotBefore = deadline,
        )

        val justBefore = RecentProjection.of(cooling, deadline - 1, busy = false)
        assertTrue(justBefore.cooldownActive)
        assertEquals(RetryPolicy.REFRESH_COOLDOWN_REASON, justBefore.blockReason)
        assertEquals(deadline, justBefore.blockNotBefore)
        assertFalse(justBefore.refreshEnabled)

        val atDeadline = RecentProjection.of(cooling, deadline, busy = false)
        assertFalse(atDeadline.cooldownActive)
        // A stale "冷却中" line next to a live button is the contradiction this rules out.
        assertNull(atDeadline.blockReason)
        assertNull(atDeadline.blockNotBefore)
        assertTrue(atDeadline.refreshEnabled)
    }

    @Test
    fun aQuotaBlockHasNoDeadlineAndNeverExpiresOnItsOwn() {
        val blocked = recent(status = "failed").copy(
            refreshBlockReason = RetryPolicy.REFRESH_QUOTA_REASON,
            refreshNotBefore = null,
        )

        val view = RecentProjection.of(blocked, RESULT_TIME + 10 * 365 * 24 * 3_600_000L, false)

        // Quota is not a timed cooldown: the notice stays, and waiting is not what clears it, so
        // the button stays available for the reader to try again once they have dealt with it.
        assertEquals(RetryPolicy.REFRESH_QUOTA_REASON, view.blockReason)
        assertNull(view.blockNotBefore)
        assertFalse(view.cooldownActive)
        assertTrue(view.refreshEnabled)
    }

    @Test
    fun aMissingTimeRendersNothingRatherThanAPlaceholder() {
        assertNull(SettingsTimeFormatter.absolute(null))
    }

    @Test
    fun aPresentTimeCarriesTheExactInstantIntoTheRendering() {
        // A minute apart has to render differently. "Not blank" would also pass for an
        // implementation that dropped the time of day and printed only the date.
        assertNotEquals(
            SettingsTimeFormatter.absolute(RESULT_TIME),
            SettingsTimeFormatter.absolute(RESULT_TIME + 60_000),
        )
    }

    @Test
    fun theInstantIsRenderedInThePlatformZoneRatherThanUtc() {
        // Nothing here asserts what the short format looks like: that is CLDR data and it
        // moves between JDK builds. What has to hold is that the *wall clock* is the
        // device's own. 01:20Z is 09:20 in the pinned zone, so rendering that instant in
        // Shanghai must produce exactly what rendering 09:20Z produces in UTC.
        val shanghai = SettingsTimeFormatter.absolute(RESULT_TIME)
        TimeZone.setDefault(TimeZone.getTimeZone("UTC"))

        assertEquals(shanghai, SettingsTimeFormatter.absolute(RESULT_TIME + 8 * 3_600_000))
        // The failure this rules out is the plausible-looking one: a timestamp eight hours
        // off that still reads as a valid date and time.
        assertNotEquals(shanghai, SettingsTimeFormatter.absolute(RESULT_TIME))
    }

    @Test
    fun theRenderingFollowsThePlatformLocale() {
        val chinese = SettingsTimeFormatter.absolute(RESULT_TIME)
        Locale.setDefault(Locale.US)

        // `2026/8/11 …` versus `8/11/26, …`: the field order itself differs, so this holds
        // whatever CLDR revision the platform ships.
        assertNotEquals(chinese, SettingsTimeFormatter.absolute(RESULT_TIME))
    }

    private fun recent(
        url: String = "https://example.com/article",
        linkId: String = "0199a1d2-7c41-7b3e-9f60-2b8c4d5e6f70",
        status: String = "done",
    ) = RecentResult(
        url = url,
        linkId = linkId,
        jobId = "job-42",
        status = status,
        createdAt = RESULT_TIME,
        identity = QueueIdentity("https://webtag.example", "namespace"),
        refreshNotBefore = null,
        refreshBlockReason = null,
    )

    private companion object {
        /** 2026-08-11T01:20:00Z, i.e. 09:20 in the pinned zone. */
        const val RESULT_TIME = 1_786_411_200_000L
    }
}
