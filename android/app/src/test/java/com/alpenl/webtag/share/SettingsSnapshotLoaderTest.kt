package com.alpenl.webtag.share

import com.alpenl.webtag.share.contract.QueueIdentity
import com.alpenl.webtag.share.contract.QueueState
import com.alpenl.webtag.share.contract.QueueView
import com.alpenl.webtag.share.contract.RecentResult
import com.alpenl.webtag.share.settings.SettingsProjection
import com.alpenl.webtag.share.settings.SettingsSnapshot
import com.alpenl.webtag.share.settings.SettingsSnapshotLoader
import com.alpenl.webtag.share.settings.SettingsSnapshotSource
import com.alpenl.webtag.share.settings.runForegroundConvergence
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the two things that decide whether the settings screen is looking at the current state:
 * that returning to the foreground reads the durable state itself instead of waiting for an
 * in-process invalidation, and that a slow read can never repaint the screen with what it found.
 */
class SettingsSnapshotLoaderTest {
    @Test
    fun aChangeMadeWhileTheHostWasInactiveIsVisibleOnTheNextForeground() = runBlocking {
        // A second repository instance — a background completion, or the share activity in another
        // process — moves the durable state to B. Room's invalidation tracker only fires for writes
        // made through the instance the screen observes, so nothing tells the screen about it.
        val durable = FakeDurableState(snapshot(revision = 3, queueUrl = "https://example.com/a"))
        val loader = SettingsSnapshotLoader(durable)
        var projection = SettingsProjection.EMPTY
        loader.load { projection = it.toProjection() }
        assertEquals("https://example.com/a", projection.singleQueueUrl())

        durable.current = snapshot(revision = 3, queueUrl = "https://example.com/b")

        runForegroundConvergence(
            reload = { loader.load { projection = it.toProjection() } },
            reconcile = {},
        )

        assertEquals("https://example.com/b", projection.singleQueueUrl())
    }

    @Test
    fun theReadAfterTheDrainShowsWhatTheDrainProduced() = runBlocking {
        val durable = FakeDurableState(snapshot(revision = 3, queueUrl = "https://example.com/b"))
        val loader = SettingsSnapshotLoader(durable)
        val seen = mutableListOf<String?>()

        runForegroundConvergence(
            reload = { loader.load { seen += it.toProjection().singleQueueUrl() } },
            // Standing in for the drain the foreground kicks off: it commits C after the arrival
            // read has already happened, so only a second read can show it.
            reconcile = { durable.current = snapshot(revision = 3, queueUrl = "https://example.com/c") },
        )

        assertEquals(listOf("https://example.com/b", "https://example.com/c"), seen)
    }

    @Test
    fun aFailingReconcileStillGetsItsSecondRead() = runBlocking {
        val durable = FakeDurableState(snapshot(revision = 3, queueUrl = "https://example.com/b"))
        val loader = SettingsSnapshotLoader(durable)
        var reads = 0

        val thrown = runCatching {
            runForegroundConvergence(
                reload = { loader.load { reads += 1 } },
                reconcile = { throw IllegalStateException("drain exploded") },
            )
        }.exceptionOrNull()

        // The point of the second read is to show whatever the durable state now is, which matters
        // most when the drain died partway through it.
        assertEquals(2, reads)
        assertTrue(thrown is IllegalStateException)
    }

    @Test
    fun aLateSnapshotFromTheOldIdentityDoesNotOverwriteTheNewOne() = runBlocking {
        val old = snapshot(
            revision = 3,
            queueUrl = "https://old.example/article",
            recent = recent("https://old.example/article", "old-link-id", 5_000),
        )
        val new = snapshot(
            revision = 4,
            origin = "https://new.example",
            namespace = "new-namespace",
            queueUrl = "https://new.example/article",
            recent = recent("https://new.example/article", "new-link-id", 9_000),
        )
        val released = CompletableDeferred<Unit>()
        var pendingIsOld = true
        val source = SettingsSnapshotSource {
            if (pendingIsOld) {
                pendingIsOld = false
                released.await()
                old
            } else {
                new
            }
        }
        val loader = SettingsSnapshotLoader(source)
        var projection = SettingsProjection.EMPTY

        coroutineScope {
            val stale = async { loader.load { projection = it.toProjection() } }
            yield()
            // The new identity's load is issued second and finishes first, which is exactly the
            // ordering an activation during a slow read produces.
            val fresh = async { loader.load { projection = it.toProjection() } }
            assertTrue(fresh.await())
            released.complete(Unit)
            assertFalse(stale.await())
        }

        assertEquals(4L, projection.activationRevision)
        assertEquals("new-namespace", projection.activeNamespace)
        assertEquals("https://new.example/article", projection.singleQueueUrl())
        assertEquals("new-link-id", projection.recent?.linkId)
        assertEquals(9_000L, projection.recent?.refreshNotBefore)
        assertEquals(QueueState.PENDING_SUBMIT, projection.singleQueueState())
    }

    @Test
    fun twoReloadsOfTheSameIdentityCommitInIssueOrderNotCompletionOrder() = runBlocking {
        // Overlapping reloads within one identity are the ordinary case, not the exotic one: the
        // Room invalidation observer, the reload after a drain and the reload after a retry all
        // fire independently, and the database can serve them out of order. Their revisions are
        // identical, so only the issue sequence can tell which answer is the older one.
        val released = CompletableDeferred<Unit>()
        var first = true
        val source = SettingsSnapshotSource {
            if (first) {
                first = false
                released.await()
                snapshot(revision = 5, queueUrl = "https://example.com/older")
            } else {
                snapshot(revision = 5, queueUrl = "https://example.com/newer")
            }
        }
        val loader = SettingsSnapshotLoader(source)
        var projection = SettingsProjection.EMPTY

        coroutineScope {
            val older = async { loader.load { projection = it.toProjection() } }
            yield()
            val newer = async { loader.load { projection = it.toProjection() } }
            assertTrue(newer.await())
            released.complete(Unit)
            assertFalse(older.await())
        }

        assertEquals("https://example.com/newer", projection.singleQueueUrl())
    }

    @Test
    fun aReadThatObservedTheSupersededRevisionIsDroppedEvenWhenItIsTheLatestIssued() = runBlocking {
        // Nothing newer has been issued through the loader here, so the issue sequence has no
        // opinion. The revision the read was stamped with is the only evidence that the identity
        // it describes has already been replaced.
        val durable = FakeDurableState(snapshot(revision = 4, queueUrl = "https://new.example/a"))
        val loader = SettingsSnapshotLoader(durable)
        var projection = SettingsProjection.EMPTY
        assertTrue(loader.load { projection = it.toProjection() })

        durable.current = snapshot(
            revision = 3,
            origin = "https://old.example",
            namespace = "old-namespace",
            queueUrl = "https://old.example/a",
        )

        assertFalse(loader.load { projection = it.toProjection() })
        assertEquals(4L, projection.activationRevision)
        assertEquals("https://new.example/a", projection.singleQueueUrl())
    }

    @Test
    fun clearingTheCredentialCommitsEvenThoughItsRevisionIsLower() = runBlocking {
        val durable = FakeDurableState(snapshot(revision = 7, queueUrl = "https://example.com/a"))
        val loader = SettingsSnapshotLoader(durable)
        var projection = SettingsProjection.EMPTY
        loader.load { projection = it.toProjection() }

        durable.current = SettingsSnapshot(
            activationRevision = SettingsSnapshot.NO_ACTIVE_SESSION,
            identity = null,
            activeNamespace = null,
            queue = emptyList(),
            recent = null,
        )

        assertTrue(loader.load { projection = it.toProjection() })
        // Losing the credential is a newer state than having it, so the fence must not treat the
        // absent revision as a stale one and leave the previous identity's rows on screen.
        assertNull(projection.activeNamespace)
        assertTrue(projection.queue.isEmpty)
    }

    @Test
    fun theProjectionCannotCarryTheCredentialDraft() {
        // A reload replaces this whole value, so anything reachable from it is something a reload
        // is allowed to discard. Keeping `origin` and `apiKey` out of it is what makes "a
        // foreground reload wiped what I was typing" unrepresentable rather than merely untested.
        val fields = SettingsProjection::class.java.declaredFields
            .filterNot { java.lang.reflect.Modifier.isStatic(it.modifiers) }
            .map { it.name }

        assertEquals(
            listOf("activationRevision", "activeNamespace", "queue", "recent"),
            fields,
        )
    }

    private class FakeDurableState(var current: SettingsSnapshot) : SettingsSnapshotSource {
        override suspend fun read(): SettingsSnapshot = current
    }

    private fun SettingsProjection.singleQueueUrl(): String? =
        queue.groups.singleOrNull()?.rows?.singleOrNull()?.url

    private fun SettingsProjection.singleQueueState(): QueueState? =
        queue.groups.singleOrNull()?.rows?.singleOrNull()?.state

    private fun snapshot(
        revision: Long,
        origin: String = "https://old.example",
        namespace: String = "old-namespace",
        queueUrl: String,
        recent: RecentResult? = null,
    ) = SettingsSnapshot(
        activationRevision = revision,
        identity = QueueIdentity(origin, namespace),
        activeNamespace = namespace,
        queue = listOf(
            QueueView(
                id = "row-1",
                url = queueUrl,
                state = QueueState.PENDING_SUBMIT,
                firstFailedAt = null,
                nextAttemptAt = null,
                errorKind = null,
            ),
        ),
        recent = recent,
    )

    private fun recent(url: String, linkId: String, notBefore: Long) = RecentResult(
        url = url,
        linkId = linkId,
        jobId = null,
        status = "failed",
        createdAt = 1_000,
        identity = QueueIdentity("https://old.example", "old-namespace"),
        refreshNotBefore = notBefore,
        refreshBlockReason = "cooldown_active",
    )
}
