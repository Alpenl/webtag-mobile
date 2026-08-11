package com.alpenl.webtag.share.settings

import com.alpenl.webtag.share.contract.QueueIdentity
import com.alpenl.webtag.share.queue.MobileRuntime
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Reads the durable settings state off the process runtime, stamped with the activation revision
 * that was current for the read.
 *
 * The whole read runs under one `activeConfiguration()`. That call already refuses to return
 * anything unless the credential store and the `active_session` row agree on both the identity and
 * its revision, so the queue and the recent result below it are fenced by the same decision rather
 * than by two independent ones that could straddle an activation.
 */
internal class RuntimeSettingsSnapshotSource(
    private val runtime: MobileRuntime,
) : SettingsSnapshotSource {
    override suspend fun read(): SettingsSnapshot = withContext(Dispatchers.IO) {
        val current = runCatching { runtime.activeConfiguration() }.getOrNull()
        val identity = current?.let { QueueIdentity(it.origin, it.namespace) }
        // A missing or interrupted credential activation must never reveal URLs from another
        // identity in the settings surface, so it reads as an identity that matches nothing.
        val displayIdentity = identity ?: QueueIdentity("", "")
        SettingsSnapshot(
            activationRevision = current?.activationRevision ?: SettingsSnapshot.NO_ACTIVE_SESSION,
            identity = identity,
            activeNamespace = current?.namespace,
            queue = runCatching { runtime.repository.listViews(displayIdentity) }
                .getOrDefault(emptyList()),
            recent = runCatching { runtime.repository.readRecent(displayIdentity) }.getOrNull(),
        )
    }
}
