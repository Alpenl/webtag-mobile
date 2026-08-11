package com.alpenl.webtag.share.settings

import com.alpenl.webtag.share.contract.RetryPolicy
import com.alpenl.webtag.share.queue.MobileClock

/** One identity-fenced read of the durable settings state. */
internal fun interface SettingsSnapshotSource {
    suspend fun read(): SettingsSnapshot
}

/**
 * Serialises snapshot commits so a slow read can never repaint the screen with what it found.
 *
 * Loads overlap constantly here: a foreground reload, the reload that follows a drain, and the
 * reload that follows "save and test" can all be in flight at once, and they finish in whatever
 * order the database and the credential store decide. Without a fence, the reader ends up looking
 * at a URL, link ID and cooldown deadline that belong to the identity they just switched away
 * from — which is exactly the state the repository redaction exists to prevent.
 *
 * Two facts decide a commit, and both are needed:
 *  - the issue sequence, which drops any load that finished after a later one started *and*
 *    committed, covering reordering within a single identity;
 *  - the activation revision the snapshot was stamped with, which drops a load whose identity has
 *    since been superseded even when no newer load has been issued through this loader.
 *
 * This class is confined to one thread — Compose commits on the main dispatcher — so the counters
 * need no synchronisation.
 */
internal class SettingsSnapshotLoader(private val source: SettingsSnapshotSource) {
    private var issuedSequence = 0L
    private var committedSequence = 0L
    private var committedRevision = SettingsSnapshot.NO_ACTIVE_SESSION

    /**
     * Reads one snapshot and commits it through [commit] unless a newer one already won.
     *
     * @return whether [commit] ran, which is what the tests assert on rather than the side effect.
     */
    suspend fun load(commit: (SettingsSnapshot) -> Unit): Boolean {
        val sequence = ++issuedSequence
        val snapshot = source.read()
        if (!supersedesCommitted(sequence, snapshot.activationRevision)) return false
        committedSequence = sequence
        committedRevision = snapshot.activationRevision
        commit(snapshot)
        return true
    }

    private fun supersedesCommitted(sequence: Long, revision: Long): Boolean {
        if (sequence <= committedSequence) return false
        // Clearing the credentials drops the revision back to "no session", and that snapshot is
        // newer than the activated one it replaces, so it is admitted on sequence alone.
        if (revision == SettingsSnapshot.NO_ACTIVE_SESSION) return true
        return revision >= committedRevision
    }
}

/**
 * The reload contract for coming back to the foreground: read once on arrival, and read again once
 * the drain and identity repair that arrival kicks off have finished.
 *
 * One read is not enough. The first read is what fixes a snapshot that went stale while the host
 * was backgrounded — another repository instance or a background completion can have moved the
 * durable state with no in-process invalidation to notice it. The second read is what shows the
 * result of the drain this foreground just ran.
 *
 * Neither read is a poll and there is no retry: a failing reconcile still gets its second read,
 * because the point of that read is to show whatever the durable state now is.
 */
internal suspend fun runForegroundConvergence(
    reload: suspend () -> Unit,
    reconcile: suspend () -> Unit,
) {
    reload()
    try {
        reconcile()
    } finally {
        reload()
    }
}

/**
 * Suspends until a refresh cooldown has elapsed, reporting the current instant every time it
 * changes, then returns.
 *
 * The clock and the sleep are both injected because the behaviour worth pinning is a timing one:
 * the button is disabled at one millisecond before the deadline and enabled at the deadline itself,
 * and it gets there without a single database or network call. A test drives this with a counter
 * and a sleep that advances it; production passes the system clock and `delay`.
 *
 * This never writes anything and never requests anything. Reaching the deadline unlocks the button
 * and removes the notice — it does not re-run the analysis on the reader's behalf.
 */
internal suspend fun awaitCooldownDeadline(
    reason: String?,
    refreshNotBefore: Long?,
    clock: MobileClock,
    sleep: suspend (Long) -> Unit,
    onNow: (Long) -> Unit,
) {
    while (true) {
        val now = clock.now()
        onNow(now)
        val remaining = RetryPolicy.refreshCooldownRemainingMillis(reason, refreshNotBefore, now)
        // `quota_exceeded` has no deadline, so it returns 0 here and parks nothing: the reader
        // clears a quota block by dealing with their quota, not by waiting.
        if (remaining == 0L) return
        sleep(remaining)
    }
}
