package com.alpenl.webtag.share.settings

import com.alpenl.webtag.share.contract.QueueIdentity
import com.alpenl.webtag.share.contract.QueueState
import com.alpenl.webtag.share.contract.QueueView
import com.alpenl.webtag.share.contract.RecentResult
import com.alpenl.webtag.share.contract.RetryPolicy

/**
 * The six sections the settings queue is rendered in, in the order they are rendered.
 *
 * Eight queue states in one flat list is the thing this replaces: `blocked_auth` and `expired` need
 * completely different actions from the reader, and a flat list gives no signal about which of the
 * two the row in front of them is. The order is frozen and encoded as declaration order, so a
 * section cannot be moved by editing a `when` branch somewhere else.
 *
 * The grouping is a *presentation* fact only. It says nothing about send priority, claiming, or the
 * state machine, all of which continue to work off [QueueState].
 */
internal enum class QueueGroup(val key: String) {
    PENDING_AND_RETRY("pending_and_retry"),
    BLOCKED_CREDENTIAL("blocked_credential"),
    BLOCKED_IDENTITY("blocked_identity"),
    BLOCKED_QUOTA("blocked_quota"),
    FAILED_PERMANENT("failed_permanent"),
    EXPIRED("expired"),
}

/** One rendered section: never empty, because empty sections are dropped from the projection. */
internal data class QueueGroupView(
    val group: QueueGroup,
    val rows: List<QueueView>,
) {
    val count: Int get() = rows.size
}

/**
 * [total] counts every durable row, including the rows in sections that are currently hidden, so
 * the header stays a count of what is stored rather than a count of what happens to be on screen.
 */
internal data class SettingsQueueProjection(
    val total: Int,
    val groups: List<QueueGroupView>,
) {
    val isEmpty: Boolean get() = total == 0

    companion object {
        val EMPTY = SettingsQueueProjection(total = 0, groups = emptyList())
    }
}

/**
 * Everything the settings queue and recent sections render, derived from one durable snapshot and
 * nothing else.
 *
 * There is deliberately no `origin` or `apiKey` here. A lifecycle reload replaces this whole object,
 * so anything reachable from it is something a reload is allowed to overwrite — and the credential
 * fields the user may be halfway through typing are therefore unrepresentable rather than merely
 * carefully avoided.
 */
internal data class SettingsProjection(
    val activationRevision: Long,
    val activeNamespace: String?,
    val queue: SettingsQueueProjection,
    val recent: RecentResult?,
) {
    companion object {
        val EMPTY = SettingsProjection(
            activationRevision = SettingsSnapshot.NO_ACTIVE_SESSION,
            activeNamespace = null,
            queue = SettingsQueueProjection.EMPTY,
            recent = null,
        )
    }
}

/**
 * One identity-fenced read of the durable state, stamped with the activation revision that was
 * current when it was taken.
 *
 * The revision is what makes a late snapshot recognisable: a read started under one identity and
 * released after another has been activated carries the old revision and must not be committed.
 */
internal data class SettingsSnapshot(
    val activationRevision: Long,
    val identity: QueueIdentity?,
    val activeNamespace: String?,
    val queue: List<QueueView>,
    val recent: RecentResult?,
) {
    fun toProjection(): SettingsProjection = SettingsProjection(
        activationRevision = activationRevision,
        activeNamespace = activeNamespace,
        queue = SettingsQueuePresenter.project(queue),
        recent = recent,
    )

    companion object {
        /** No credential is active, so nothing may be attributed to an identity. */
        const val NO_ACTIVE_SESSION = 0L
    }
}

/** Deterministic settings-queue grouping, free of Android and Compose so JVM tests can pin it. */
internal object SettingsQueuePresenter {
    /** The frozen state-to-section mapping. Exhaustive on purpose: a new state must choose a home. */
    fun groupOf(state: QueueState): QueueGroup = when (state) {
        QueueState.PENDING_SUBMIT, QueueState.RETRY_WAIT -> QueueGroup.PENDING_AND_RETRY
        QueueState.BLOCKED_AUTH, QueueState.BLOCKED_SCOPE -> QueueGroup.BLOCKED_CREDENTIAL
        QueueState.BLOCKED_IDENTITY -> QueueGroup.BLOCKED_IDENTITY
        QueueState.BLOCKED_QUOTA -> QueueGroup.BLOCKED_QUOTA
        QueueState.FAILED_PERMANENT -> QueueGroup.FAILED_PERMANENT
        QueueState.EXPIRED -> QueueGroup.EXPIRED
    }

    /**
     * Splits repository order into sections without reordering anything inside one.
     *
     * Rows arrive in the order the repository stores them, which is also the order they will be
     * sent in. Sorting within a section would make the list disagree with the send order for no
     * reader-visible gain, so only the partition is applied.
     */
    fun project(rows: List<QueueView>): SettingsQueueProjection {
        val buckets = LinkedHashMap<QueueGroup, MutableList<QueueView>>()
        for (row in rows) {
            buckets.getOrPut(groupOf(row.state)) { mutableListOf() }.add(row)
        }
        return SettingsQueueProjection(
            total = rows.size,
            // Iterating the enum rather than `buckets` is what fixes the section order: the order
            // rows happen to arrive in must not decide which section is rendered first.
            groups = QueueGroup.entries.mapNotNull { group ->
                buckets[group]?.let { QueueGroupView(group, it.toList()) }
            },
        )
    }
}

/**
 * The recent-result card, resolved down to what may be shown.
 *
 * Redaction is expressed by the absence of values rather than by a flag the card is trusted to
 * check: an identity-mismatched recent projects to blank fields and a disabled refresh, so a card
 * that forgot the mismatch branch still cannot print another identity's URL or link ID.
 */
internal data class RecentProjection(
    val redacted: Boolean,
    val url: String,
    val status: String,
    val linkId: String,
    val jobId: String?,
    val resultTimeMillis: Long?,
    val blockReason: String?,
    val blockNotBefore: Long?,
    val cooldownActive: Boolean,
    val refreshVisible: Boolean,
    val refreshEnabled: Boolean,
) {
    companion object {
        /**
         * @param busy a refresh this card started is still in flight.
         */
        fun of(recent: RecentResult, nowMillis: Long, busy: Boolean): RecentProjection {
            if (recent.isIdentityMismatch) {
                // The repository still surfaces the block reason and deadline on a mismatched row
                // because they belong to the record, not to the viewer. Neither may be rendered:
                // a cooldown deadline is a timestamp from the other identity's session.
                return RecentProjection(
                    redacted = true,
                    url = "",
                    status = "",
                    linkId = "",
                    jobId = null,
                    resultTimeMillis = null,
                    blockReason = null,
                    blockNotBefore = null,
                    cooldownActive = false,
                    refreshVisible = false,
                    refreshEnabled = false,
                )
            }
            val cooldownActive = RetryPolicy.refreshCooldownRemainingMillis(
                recent.refreshBlockReason,
                recent.refreshNotBefore,
                nowMillis,
            ) > 0
            // An elapsed cooldown leaves no trace: the notice disappears at the same instant the
            // button comes back, so the card can never say "cooling down" next to a live button.
            val blockReason = recent.refreshBlockReason
                ?.takeUnless { it == RetryPolicy.REFRESH_COOLDOWN_REASON && !cooldownActive }
            val refreshVisible = recent.status == FAILED_STATUS
            return RecentProjection(
                redacted = false,
                url = recent.url,
                status = recent.status,
                linkId = recent.linkId,
                jobId = recent.jobId,
                resultTimeMillis = recent.createdAt,
                blockReason = blockReason,
                blockNotBefore = recent.refreshNotBefore.takeIf { blockReason != null },
                cooldownActive = cooldownActive,
                refreshVisible = refreshVisible,
                refreshEnabled = refreshVisible && !busy && !cooldownActive,
            )
        }

        /** Only a failed analysis can be re-run; everything else is already a settled result. */
        private const val FAILED_STATUS = "failed"
    }
}
