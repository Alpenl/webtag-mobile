package com.alpenl.webtag.share.ui.companion

import com.alpenl.webtag.share.contract.QueueIdentity
import com.alpenl.webtag.share.data.TodoLocalSnapshot
import com.alpenl.webtag.share.queue.MobileRuntime
import com.alpenl.webtag.share.settings.SettingsQueuePresenter
import com.alpenl.webtag.share.settings.SettingsSnapshot
import com.alpenl.webtag.share.settings.SettingsProjection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal data class CompanionSnapshot(
    val settings: SettingsProjection,
    val todos: TodoLocalSnapshot,
) {
    companion object {
        val EMPTY = CompanionSnapshot(SettingsProjection.EMPTY, TodoLocalSnapshot.EMPTY)
    }
}

/** Reads every main-screen table behind one verified activation revision. */
internal class RuntimeCompanionSnapshotSource(
    private val runtime: MobileRuntime,
) {
    suspend fun read(): Pair<Long, CompanionSnapshot> = withContext(Dispatchers.IO) {
        val current = runCatching { runtime.activeConfiguration() }.getOrNull()
        val identity = current?.let { QueueIdentity(it.origin, it.namespace) }
        val displayIdentity = identity ?: QueueIdentity("", "")
        val queue = runCatching { runtime.repository.listViews(displayIdentity) }.getOrDefault(emptyList())
        val recent = runCatching { runtime.repository.readRecent(displayIdentity) }.getOrNull()
        val todos = identity?.let {
            runCatching { runtime.todoRepository.snapshot(it) }.getOrDefault(TodoLocalSnapshot.EMPTY)
        } ?: TodoLocalSnapshot.EMPTY
        val revision = current?.activationRevision ?: SettingsSnapshot.NO_ACTIVE_SESSION
        revision to CompanionSnapshot(
            settings = SettingsProjection(
                activationRevision = revision,
                activeNamespace = current?.namespace,
                queue = SettingsQueuePresenter.project(queue),
                recent = recent,
            ),
            todos = todos,
        )
    }
}

/** Drops reordered reads and snapshots from an activation superseded by a newer one. */
internal class CompanionSnapshotLoader(
    private val source: RuntimeCompanionSnapshotSource,
) {
    private var issuedSequence = 0L
    private var committedSequence = 0L
    private var committedRevision = SettingsSnapshot.NO_ACTIVE_SESSION

    suspend fun load(commit: (CompanionSnapshot) -> Unit): Boolean {
        val sequence = ++issuedSequence
        val (revision, snapshot) = source.read()
        if (sequence <= committedSequence) return false
        if (revision != SettingsSnapshot.NO_ACTIVE_SESSION && revision < committedRevision) return false
        committedSequence = sequence
        committedRevision = revision
        commit(snapshot)
        return true
    }
}
