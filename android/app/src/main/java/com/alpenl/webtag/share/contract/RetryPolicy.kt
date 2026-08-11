package com.alpenl.webtag.share.contract

import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.min
import kotlin.random.Random

object RetryPolicy {
    const val SEVEN_DAYS_MILLIS = 7L * 24 * 60 * 60 * 1000
    const val SIX_HOURS_MILLIS = 6L * 60 * 60 * 1000
    const val MIN_RETRY_AFTER_MILLIS = 60L * 1000
    const val REFRESH_COOLDOWN_REASON = "cooldown_active"
    const val REFRESH_QUOTA_REASON = "quota_exceeded"

    data class RefreshBlockPlan(
        val reason: String,
        val refreshNotBefore: Long?,
    )

    fun exponentialDelayMillis(attempt: Int, random: Random = Random.Default): Long {
        val normalizedAttempt = attempt.coerceAtLeast(1)
        val exponent = min(normalizedAttempt - 1, 10)
        val cap = min(SIX_HOURS_MILLIS, 30_000L * (1L shl exponent))
        val half = cap / 2
        return half + random.nextLong(half + 1)
    }

    fun retryAfterMillis(value: String?, nowMillis: Long): Long? {
        if (value.isNullOrBlank()) return null
        val trimmed = value.trim()
        trimmed.toLongOrNull()?.let { seconds ->
            if (seconds >= 0) return maxOf(MIN_RETRY_AFTER_MILLIS, seconds * 1000)
            return null
        }
        return runCatching {
            val target = ZonedDateTime.parse(trimmed, DateTimeFormatter.RFC_1123_DATE_TIME)
                .toInstant()
                .toEpochMilli()
            maxOf(MIN_RETRY_AFTER_MILLIS, target - nowMillis)
        }.getOrNull()
    }

    fun planRefreshBlock(
        error: ErrorKind,
        retryAfter: String?,
        nowMillis: Long,
    ): RefreshBlockPlan? = when (error) {
        ErrorKind.HTTP_429_RATE_LIMIT,
        ErrorKind.HTTP_429_COOLDOWN,
        -> {
            val delay = min(
                retryAfterMillis(retryAfter, nowMillis) ?: MIN_RETRY_AFTER_MILLIS,
                SIX_HOURS_MILLIS,
            )
            val notBefore = runCatching { Math.addExact(nowMillis, delay) }
                .getOrDefault(Long.MAX_VALUE)
            RefreshBlockPlan(REFRESH_COOLDOWN_REASON, notBefore)
        }
        ErrorKind.HTTP_429_QUOTA -> RefreshBlockPlan(REFRESH_QUOTA_REASON, null)
        else -> null
    }

    fun refreshCooldownRemainingMillis(
        reason: String?,
        refreshNotBefore: Long?,
        nowMillis: Long,
    ): Long {
        if (reason != REFRESH_COOLDOWN_REASON || refreshNotBefore == null || refreshNotBefore <= nowMillis) {
            return 0
        }
        return runCatching { Math.subtractExact(refreshNotBefore, nowMillis) }
            .getOrDefault(Long.MAX_VALUE)
    }

    fun planRetry(
        error: ErrorKind,
        attemptCount: Int,
        nowMillis: Long,
        retryAfter: String? = null,
        errorCode: String? = null,
        random: Random = Random.Default,
    ): RetryPlan {
        return when {
            error == ErrorKind.HTTP_429_QUOTA -> RetryPlan(
                QueueState.BLOCKED_QUOTA,
                null,
                nowMillis,
                QueueError(error, errorCode, 429, null),
            )
            error == ErrorKind.HTTP_401 -> RetryPlan(
                QueueState.BLOCKED_AUTH,
                null,
                nowMillis,
                QueueError(error, errorCode, 401, null),
            )
            error == ErrorKind.HTTP_403_SCOPE -> RetryPlan(
                QueueState.BLOCKED_SCOPE,
                null,
                nowMillis,
                QueueError(error, errorCode, 403, null),
            )
            error == ErrorKind.IDENTITY_MISMATCH -> RetryPlan(
                QueueState.BLOCKED_IDENTITY,
                null,
                nowMillis,
                QueueError(error, errorCode, null, null),
            )
            error == ErrorKind.TLS_TRUST_FAILURE ||
                error == ErrorKind.HTTP_409 ||
                error == ErrorKind.INVALID_SUCCESS_PAYLOAD ||
                error == ErrorKind.INVALID_CLIENT_RESPONSE ||
                error == ErrorKind.LOCAL_DATA_UNREADABLE -> RetryPlan(
                QueueState.FAILED_PERMANENT,
                null,
                nowMillis,
                QueueError(error, errorCode, null, null),
            )
            else -> {
                val delay = if (error == ErrorKind.HTTP_429_RATE_LIMIT || error == ErrorKind.HTTP_429_COOLDOWN) {
                    retryAfterMillis(retryAfter, nowMillis) ?: MIN_RETRY_AFTER_MILLIS
                } else {
                    val retryAfterDelay = retryAfterMillis(retryAfter, nowMillis)
                    maxOf(exponentialDelayMillis(attemptCount, random), retryAfterDelay ?: 0)
                }
                RetryPlan(
                    QueueState.RETRY_WAIT,
                    nowMillis + min(delay, SIX_HOURS_MILLIS),
                    nowMillis,
                    QueueError(error, errorCode, null, nowMillis + min(delay, SIX_HOURS_MILLIS)),
                )
            }
        }
    }

    fun shouldExpire(firstFailedAt: Long?, nowMillis: Long): Boolean =
        firstFailedAt != null && nowMillis - firstFailedAt >= SEVEN_DAYS_MILLIS
}
