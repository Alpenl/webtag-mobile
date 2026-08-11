package com.alpenl.webtag.share

import com.alpenl.webtag.share.contract.ErrorKind
import com.alpenl.webtag.share.contract.QueueState
import com.alpenl.webtag.share.contract.RetryPolicy
import java.time.Instant
import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RetryPolicyTest {
    @Test
    fun retryDelayIsJitteredAndBounded() {
        val delay = RetryPolicy.exponentialDelayMillis(4, Random(7))
        assertTrue(delay in 120_000L..240_000L)
    }

    @Test
    fun retryAfterUsesAtLeastSixtySeconds() {
        assertEquals(60_000L, RetryPolicy.retryAfterMillis("1", 0))
        assertEquals(90_000L, RetryPolicy.retryAfterMillis("90", 0))
    }

    @Test
    fun refreshRateLimitAndCooldownShareThePersistedCooldownPlan() {
        val now = 1_000L

        listOf(ErrorKind.HTTP_429_RATE_LIMIT, ErrorKind.HTTP_429_COOLDOWN).forEach { error ->
            val plan = RetryPolicy.planRefreshBlock(error, "90", now)

            assertEquals(RetryPolicy.REFRESH_COOLDOWN_REASON, plan?.reason)
            assertEquals(now + 90_000L, plan?.refreshNotBefore)
        }
    }

    @Test
    fun refreshCooldownFallsBackToTheMinimumAndCapsLongServerDelays() {
        val now = 2_000L

        assertEquals(
            now + RetryPolicy.MIN_RETRY_AFTER_MILLIS,
            RetryPolicy.planRefreshBlock(ErrorKind.HTTP_429_COOLDOWN, "invalid", now)?.refreshNotBefore,
        )
        assertEquals(
            now + RetryPolicy.SIX_HOURS_MILLIS,
            RetryPolicy.planRefreshBlock(ErrorKind.HTTP_429_RATE_LIMIT, "999999999", now)?.refreshNotBefore,
        )
    }

    @Test
    fun refreshQuotaIsPersistentButNon429FailuresDoNotCreateABlock() {
        val quota = RetryPolicy.planRefreshBlock(ErrorKind.HTTP_429_QUOTA, null, 0)

        assertEquals(RetryPolicy.REFRESH_QUOTA_REASON, quota?.reason)
        assertEquals(null, quota?.refreshNotBefore)
        assertEquals(null, RetryPolicy.planRefreshBlock(ErrorKind.HTTP_5XX, null, 0))
    }

    @Test
    fun refreshCooldownUnlocksAtTheExactDeadline() {
        val deadline = 61_000L

        assertEquals(
            1L,
            RetryPolicy.refreshCooldownRemainingMillis(
                RetryPolicy.REFRESH_COOLDOWN_REASON,
                deadline,
                deadline - 1,
            ),
        )
        assertEquals(
            0L,
            RetryPolicy.refreshCooldownRemainingMillis(
                RetryPolicy.REFRESH_COOLDOWN_REASON,
                deadline,
                deadline,
            ),
        )
        assertEquals(0L, RetryPolicy.refreshCooldownRemainingMillis("quota_exceeded", deadline, 0))
        assertEquals(0L, RetryPolicy.refreshCooldownRemainingMillis("cooldown_active", null, 0))
    }

    @Test
    fun errorStatesFollowTheFrozenQueueContract() {
        assertEquals(QueueState.BLOCKED_AUTH, RetryPolicy.planRetry(ErrorKind.HTTP_401, 1, 0).state)
        assertEquals(QueueState.BLOCKED_SCOPE, RetryPolicy.planRetry(ErrorKind.HTTP_403_SCOPE, 1, 0).state)
        assertEquals(QueueState.BLOCKED_QUOTA, RetryPolicy.planRetry(ErrorKind.HTTP_429_QUOTA, 1, 0).state)
        assertEquals(QueueState.FAILED_PERMANENT, RetryPolicy.planRetry(ErrorKind.TLS_TRUST_FAILURE, 1, 0).state)
        assertEquals(QueueState.RETRY_WAIT, RetryPolicy.planRetry(ErrorKind.HTTP_5XX, 1, 0).state)
    }

    @Test
    fun everyRetryableTransportAndHttpBranchStaysRetryable() {
        listOf(
            ErrorKind.NO_NETWORK,
            ErrorKind.DNS_TIMEOUT,
            ErrorKind.CONNECTION_RESET,
            ErrorKind.CLIENT_DEADLINE,
            ErrorKind.HTTP_408,
            ErrorKind.HTTP_425,
            ErrorKind.HTTP_5XX,
            ErrorKind.HTTP_429_RATE_LIMIT,
            ErrorKind.HTTP_429_COOLDOWN,
        ).forEach { error ->
            assertEquals(error.name, QueueState.RETRY_WAIT, RetryPolicy.planRetry(error, 1, 0).state)
        }
        assertEquals(
            QueueState.BLOCKED_IDENTITY,
            RetryPolicy.planRetry(ErrorKind.IDENTITY_MISMATCH, 1, 0).state,
        )
        listOf(
            ErrorKind.TLS_TRUST_FAILURE,
            ErrorKind.HTTP_409,
            ErrorKind.INVALID_SUCCESS_PAYLOAD,
            ErrorKind.INVALID_CLIENT_RESPONSE,
            ErrorKind.LOCAL_DATA_UNREADABLE,
        ).forEach { error ->
            assertEquals(error.name, QueueState.FAILED_PERMANENT, RetryPolicy.planRetry(error, 1, 0).state)
        }
    }

    @Test
    fun retryAfterAcceptsRfc1123DatesAndRejectsInvalidValues() {
        val now = Instant.parse("2015-10-21T07:00:00Z").toEpochMilli()
        assertEquals(
            28 * 60 * 1_000L,
            RetryPolicy.retryAfterMillis("Wed, 21 Oct 2015 07:28:00 GMT", now),
        )
        assertEquals(60_000L, RetryPolicy.retryAfterMillis("Wed, 21 Oct 2015 06:59:00 GMT", now))
        assertEquals(null, RetryPolicy.retryAfterMillis("-1", now))
        assertEquals(null, RetryPolicy.retryAfterMillis("not-a-date", now))
    }

    @Test
    fun retryAfterAndExpiryRespectFrozenBoundaries() {
        assertEquals(
            90_000L,
            RetryPolicy.planRetry(ErrorKind.HTTP_429_RATE_LIMIT, 1, 0, retryAfter = "90").nextAttemptAt,
        )
        assertEquals(
            60_000L,
            RetryPolicy.planRetry(ErrorKind.HTTP_429_COOLDOWN, 1, 0, retryAfter = "invalid").nextAttemptAt,
        )
        assertTrue(
            RetryPolicy.planRetry(ErrorKind.HTTP_5XX, 50, 0, random = Random(7)).nextAttemptAt!! <=
                RetryPolicy.SIX_HOURS_MILLIS,
        )
        assertFalse(RetryPolicy.shouldExpire(0, RetryPolicy.SEVEN_DAYS_MILLIS - 1))
        assertTrue(RetryPolicy.shouldExpire(0, RetryPolicy.SEVEN_DAYS_MILLIS))
        assertFalse(RetryPolicy.shouldExpire(null, RetryPolicy.SEVEN_DAYS_MILLIS))
    }
}
