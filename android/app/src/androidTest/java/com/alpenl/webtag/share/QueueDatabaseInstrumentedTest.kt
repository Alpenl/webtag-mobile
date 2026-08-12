package com.alpenl.webtag.share

import android.content.Context
import androidx.room.Room
import androidx.room.testing.MigrationTestHelper
import androidx.test.InstrumentationRegistry
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.alpenl.webtag.share.data.QueueDatabase
import com.alpenl.webtag.share.data.QueueEntity
import com.alpenl.webtag.share.data.QueueRepository
import com.alpenl.webtag.share.data.RecentResultEntity
import com.alpenl.webtag.share.data.TodoRepository
import com.alpenl.webtag.share.contract.QueueIdentity
import com.alpenl.webtag.share.contract.QueueState
import com.alpenl.webtag.share.contract.ErrorKind
import com.alpenl.webtag.share.contract.ActiveSessionSnapshot
import com.alpenl.webtag.share.contract.CredentialConfig
import com.alpenl.webtag.share.contract.RecentResult
import com.alpenl.webtag.share.contract.RefreshCommitOutcome
import com.alpenl.webtag.share.contract.SessionIdentity
import com.alpenl.webtag.share.contract.SubmitCommitOutcome
import com.alpenl.webtag.share.contract.SubmitResponse
import com.alpenl.webtag.share.network.ApiResult
import com.alpenl.webtag.share.network.ClassifiedFailure
import com.alpenl.webtag.share.network.WebTagApi
import com.alpenl.webtag.share.queue.ConnectionCoordinator
import com.alpenl.webtag.share.queue.ConnectionResult
import com.alpenl.webtag.share.security.AndroidKeystoreCipher
import com.alpenl.webtag.share.security.EncryptedCredentialStore
import com.alpenl.webtag.share.todo.TodoCreate
import com.alpenl.webtag.share.todo.TodoItem
import com.alpenl.webtag.share.todo.TodoOriginKind
import com.alpenl.webtag.share.todo.TodoPatch
import java.security.GeneralSecurityException
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class QueueDatabaseInstrumentedTest {
    @get:Rule
    val migrationHelper = MigrationTestHelper(
        InstrumentationRegistry.getInstrumentation(),
        QueueDatabase::class.java,
    )

    private lateinit var database: QueueDatabase

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        database = Room.inMemoryDatabaseBuilder(context, QueueDatabase::class.java)
            .allowMainThreadQueries()
            .build()
    }

    @After
    fun tearDown() {
        database.close()
    }

    @Test
    fun leaseClaimIsAtomicAndExpiredRowsBecomeDue() {
        val now = 1_000L
        val entry = queueEntity("entry-a", now)
        val dao = database.queueDao()
        dao.insert(entry)

        assertEquals(1, dao.claim(entry.id, entry.apiOrigin, entry.clientDataNamespace, "owner-a", now + 10, now))
        assertEquals(0, dao.claim(entry.id, entry.apiOrigin, entry.clientDataNamespace, "owner-b", now + 20, now + 1))
        assertNotNull(dao.findDue(entry.apiOrigin, entry.clientDataNamespace, now + 10))
    }

    @Test
    fun expiredLeaseCanBeReclaimedAtTheExactBoundaryButOldOwnerCannotWrite() {
        val now = 2_000L
        val entry = queueEntity("boundary", now)
        val dao = database.queueDao()
        dao.insert(entry)

        assertEquals(1, dao.claim(entry.id, entry.apiOrigin, entry.clientDataNamespace, "owner-a", now + 10, now))
        assertEquals(1, dao.claim(entry.id, entry.apiOrigin, entry.clientDataNamespace, "owner-b", now + 20, now + 10))
        assertEquals(
            0,
            dao.updateClaimed(
                id = entry.id,
                queueOrigin = entry.apiOrigin,
                queueNamespace = entry.clientDataNamespace,
                owner = "owner-a",
                state = "failed_permanent",
                firstFailedAt = now + 10,
                attemptCount = 1,
                nextAttemptAt = null,
                lastErrorKind = "HTTP_5XX",
                lastErrorCode = null,
                lastHttpStatus = 500,
                linkId = null,
                jobId = null,
                activeOrigin = entry.apiOrigin,
                activeNamespace = entry.clientDataNamespace,
                activationRevision = 1,
                updatedAt = now + 10,
            ),
        )
        assertEquals("pending_submit", dao.listAll().single().state)
        assertEquals("owner-b", dao.listAll().single().leaseOwner)
    }

    @Test
    fun resetForRetryOnlyChangesRetryableStatesWithoutAnActiveLease() {
        val now = 1_000L
        val dao = database.queueDao()
        val retryableStates = listOf(
            "retry_wait",
            "blocked_auth",
            "blocked_scope",
            "blocked_quota",
            "failed_permanent",
            "expired",
        )
        retryableStates.forEachIndexed { index, state ->
            dao.insert(queueEntity("retryable-$index", now, state = state))
        }
        dao.insert(queueEntity("pending", now, state = "pending_submit"))
        dao.insert(queueEntity("identity", now, state = "blocked_identity"))
        dao.insert(
            queueEntity("leased", now, state = "retry_wait").copy(
                leaseOwner = "active-owner",
                leaseExpiresAt = now + 10_000,
            ),
        )

        retryableStates.forEachIndexed { index, _ ->
            assertEquals(1, dao.resetForRetry("retryable-$index", null, now))
        }
        assertEquals(0, dao.resetForRetry("pending", null, now))
        assertEquals(0, dao.resetForRetry("identity", null, now))
        assertEquals(0, dao.resetForRetry("leased", null, now))
        assertEquals(
            "pending_submit",
            dao.listAll().single { it.id == "pending" }.state,
        )
        assertEquals(
            "blocked_identity",
            dao.listAll().single { it.id == "identity" }.state,
        )
    }

    @Test
    fun schedulerWaitsForRetryAtAndActiveLeaseBeforeWaking() {
        val now = 4_000L
        val dao = database.queueDao()
        dao.insert(
            queueEntity("future-retry", now, state = "retry_wait").copy(
                nextAttemptAt = now + 60_000,
            ),
        )
        assertEquals(now + 60_000, dao.earliestScheduleAt("https://example.org", "n".repeat(43), now))

        dao.insert(
            queueEntity("leased", now, state = "pending_submit").copy(
                leaseOwner = "active-owner",
                leaseExpiresAt = now + 30_000,
            ),
        )
        assertEquals(now + 30_000, dao.earliestScheduleAt("https://example.org", "n".repeat(43), now))
        assertEquals(now + 30_000, dao.earliestScheduleAt("https://example.org", "n".repeat(43), now + 30_000))
    }

    @Test
    fun claimDoesNotSendAFutureRetryRowBeforeItsDueTime() {
        val now = 4_500L
        val dao = database.queueDao()
        dao.insert(
            queueEntity("future-claim", now, state = "retry_wait").copy(
                nextAttemptAt = now + 60_000,
            ),
        )

        assertEquals(0, dao.claim("future-claim", "https://example.org", "n".repeat(43), "early-owner", now + 30_000, now))
        assertEquals(1, dao.claim("future-claim", "https://example.org", "n".repeat(43), "due-owner", now + 90_000, now + 60_000))
    }

    @Test
    fun keystoreCipherUsesNonceAndAuthenticatedAad() {
        val cipher = AndroidKeystoreCipher("instrumented-${UUID.randomUUID()}")
        val encrypted = cipher.encrypt("https://example.org/article", "entry|1|identity")
        assertEquals(12, encrypted.nonce.size)
        assertEquals("https://example.org/article", cipher.decrypt(encrypted, "entry|1|identity"))

        val tampered = encrypted.ciphertext.clone().also { it[it.lastIndex] = (it[it.lastIndex].toInt() xor 1).toByte() }
        assertThrows(GeneralSecurityException::class.java) {
            cipher.decrypt(encrypted.copy(ciphertext = tampered), "entry|1|identity")
        }
        assertArrayEquals(encrypted.nonce, encrypted.nonce)
        assertThrows(GeneralSecurityException::class.java) {
            cipher.decrypt(encrypted, "entry|1|other-identity")
        }
    }

    @Test
    fun repositoryRejectsADecryptedUrlWithAStaleFingerprint() {
        val repository = QueueRepository(
            database,
            AndroidKeystoreCipher("fingerprint-${UUID.randomUUID()}"),
        )
        val identity = QueueIdentity("https://example.org", "n".repeat(43))
        val entry = repository.enqueue("https://example.org/article", identity, now = 5_000L)

        assertEquals("https://example.org/article", repository.decode(entry))
        assertThrows(IllegalStateException::class.java) {
            repository.decode(entry.copy(requestFingerprint = "stale"))
        }
    }

    @Test
    fun findReusableReturnsTheExistingPendingRowForTheSameUrlAndIdentity() {
        val repository = QueueRepository(
            database,
            AndroidKeystoreCipher("reuse-${UUID.randomUUID()}"),
        )
        val identity = QueueIdentity("https://example.org", "r".repeat(43))
        val url = "https://example.org/reuse"
        val entry = repository.enqueue(url, identity, now = 5_500L)

        val reusable = repository.findReusable(url, identity)

        assertNotNull(reusable)
        assertEquals(entry.id, reusable!!.id)
        assertEquals(entry.idempotencyKey, reusable.idempotencyKey)
        assertEquals(1, repository.listAll().size)
        assertNull(repository.findReusable("https://example.org/other", identity))
        assertNull(repository.findReusable(url, QueueIdentity(identity.origin, "s".repeat(43))))
    }

    @Test
    fun enqueueOrReuseAtomicallyKeepsTheExistingIdempotencyKey() {
        val repository = QueueRepository(
            database,
            AndroidKeystoreCipher("atomic-reuse-${UUID.randomUUID()}"),
        )
        val identity = QueueIdentity("https://example.org", "a".repeat(43))
        val url = "https://example.org/atomic-reuse"

        val first = repository.enqueueOrReuse(url, identity, now = 5_600L)
        val second = repository.enqueueOrReuse(url, identity, now = 5_601L)

        assertFalse(first.reused)
        assertTrue(second.reused)
        assertEquals(first.entry.id, second.entry.id)
        assertEquals(first.entry.idempotencyKey, second.entry.idempotencyKey)
        assertEquals(1, repository.listAll().size)
    }

    @Test
    fun identityMigrationReencryptsAndResetsTransientQueueState() {
        val now = 6_000L
        val oldIdentity = QueueIdentity("https://old.example", "o".repeat(43))
        val newIdentity = QueueIdentity("https://new.example", "n".repeat(43))
        val repository = QueueRepository(
            database,
            AndroidKeystoreCipher("migration-${UUID.randomUUID()}"),
        )
        val entry = repository.enqueue("https://example.org/migrate", oldIdentity, now)
        val dao = database.queueDao()
        activate(repository, oldIdentity)

        assertEquals(1, dao.claim(entry.id, entry.apiOrigin, entry.clientDataNamespace, "migration-owner", now + 10_000, now))
        assertEquals(
            1,
            dao.updateClaimed(
                id = entry.id,
                queueOrigin = entry.apiOrigin,
                queueNamespace = entry.clientDataNamespace,
                owner = "migration-owner",
                state = "blocked_identity",
                firstFailedAt = now - 1_000,
                attemptCount = 4,
                nextAttemptAt = now + 60_000,
                lastErrorKind = "IDENTITY_MISMATCH",
                lastErrorCode = "namespace_changed",
                lastHttpStatus = 409,
                linkId = "old-link",
                jobId = "old-job",
                activeOrigin = entry.apiOrigin,
                activeNamespace = entry.clientDataNamespace,
                activationRevision = 1,
                updatedAt = now + 1,
            ),
        )
        val before = dao.findById(entry.id)!!

        assertTrue(repository.migrateIdentity(entry.id, newIdentity, now + 2))

        val migrated = dao.findById(entry.id)!!
        assertEquals(before.id, migrated.id)
        assertEquals(before.createdAt, migrated.createdAt)
        assertEquals(before.requestFingerprint, migrated.requestFingerprint)
        assertNotEquals(before.idempotencyKey, migrated.idempotencyKey)
        assertEquals(newIdentity.origin, migrated.apiOrigin)
        assertEquals(newIdentity.namespace, migrated.clientDataNamespace)
        assertEquals("pending_submit", migrated.state)
        assertEquals("https://example.org/migrate", repository.decode(migrated))
        assertNull(migrated.firstFailedAt)
        assertEquals(0, migrated.attemptCount)
        assertNull(migrated.nextAttemptAt)
        assertNull(migrated.lastErrorKind)
        assertNull(migrated.lastErrorCode)
        assertNull(migrated.lastHttpStatus)
        assertNull(migrated.linkId)
        assertNull(migrated.jobId)
        assertNull(migrated.leaseOwner)
        assertNull(migrated.leaseExpiresAt)
    }

    @Test
    fun identityMigrationRejectsAnActiveLeaseAndSameIdentity() {
        val now = 7_000L
        val oldIdentity = QueueIdentity("https://old.example", "o".repeat(43))
        val newIdentity = QueueIdentity("https://new.example", "n".repeat(43))
        val repository = QueueRepository(
            database,
            AndroidKeystoreCipher("migration-lease-${UUID.randomUUID()}"),
        )
        val entry = repository.enqueue("https://example.org/leased", oldIdentity, now)
        val dao = database.queueDao()

        assertEquals(1, dao.claim(entry.id, entry.apiOrigin, entry.clientDataNamespace, "active-owner", now + 10_000, now))
        assertFalse(repository.migrateIdentity(entry.id, newIdentity, now + 1))
        assertFalse(repository.migrateIdentity(entry.id, oldIdentity, now + 1))

        val unchanged = dao.findById(entry.id)!!
        assertEquals(oldIdentity.origin, unchanged.apiOrigin)
        assertEquals(oldIdentity.namespace, unchanged.clientDataNamespace)
        assertEquals("active-owner", unchanged.leaseOwner)
        assertEquals("https://example.org/leased", repository.decode(unchanged))
    }

    @Test
    fun identityMigrationRejectsNonCanonicalTargetBeforeChangingTheRow() {
        val now = 7_500L
        val oldIdentity = QueueIdentity("https://old.example", "o".repeat(43))
        val invalidTarget = QueueIdentity("http://new.example", "n".repeat(43))
        val repository = QueueRepository(
            database,
            AndroidKeystoreCipher("migration-invalid-${UUID.randomUUID()}"),
        )
        val entry = repository.enqueue("https://example.org/invalid-target", oldIdentity, now)

        assertThrows(IllegalStateException::class.java) {
            repository.migrateIdentity(entry.id, invalidTarget, now + 1)
        }

        val unchanged = database.queueDao().findById(entry.id)!!
        assertEquals(oldIdentity.origin, unchanged.apiOrigin)
        assertEquals(oldIdentity.namespace, unchanged.clientDataNamespace)
        assertEquals("https://example.org/invalid-target", repository.decode(unchanged))
    }

    @Test
    fun identityMatchedAuthAndScopeBlocksAutomaticallyReturnToPending() {
        val now = 8_000L
        val identity = QueueIdentity("https://example.org", "i".repeat(43))
        val repository = QueueRepository(
            database,
            AndroidKeystoreCipher("identity-recovery-${UUID.randomUUID()}"),
        )
        val dao = database.queueDao()
        listOf("blocked_auth", "blocked_scope").forEachIndexed { index, state ->
            dao.insert(queueEntity("identity-recovery-$index", now, state = state).copy(
                apiOrigin = identity.origin,
                clientDataNamespace = identity.namespace,
            ))
        }

        assertEquals(2, repository.retryIdentityBlocked(identity, now))
        assertTrue(dao.listAll().all { it.state == "pending_submit" })
        assertTrue(dao.listAll().all { it.lastErrorKind == null && it.nextAttemptAt == null })
    }

    @Test
    fun retryRecoverableOnlyResetsRowsForTheRequestedIdentity() {
        val now = 8_500L
        val activeIdentity = QueueIdentity("https://active.example", "a".repeat(43))
        val otherIdentity = QueueIdentity("https://other.example", "b".repeat(43))
        val repository = QueueRepository(
            database,
            AndroidKeystoreCipher("retry-identity-${UUID.randomUUID()}"),
        )
        val dao = database.queueDao()
        dao.insert(
            queueEntity("active-retry", now, state = "retry_wait").copy(
                apiOrigin = activeIdentity.origin,
                clientDataNamespace = activeIdentity.namespace,
            ),
        )
        dao.insert(
            queueEntity("other-retry", now + 1, state = "retry_wait").copy(
                apiOrigin = otherIdentity.origin,
                clientDataNamespace = otherIdentity.namespace,
            ),
        )

        assertEquals(1, repository.retryRecoverable(activeIdentity, now))
        assertEquals("pending_submit", dao.findById("active-retry")!!.state)
        assertEquals("retry_wait", dao.findById("other-retry")!!.state)
    }

    @Test
    fun activeSessionMetadataRoundTripsWithoutStoringAnApiKey() {
        val repository = QueueRepository(
            database,
            AndroidKeystoreCipher("active-session-${UUID.randomUUID()}"),
        )
        val identity = SessionIdentity(
            origin = "https://example.org",
            clientDataNamespace = "s".repeat(43),
            scopes = setOf("write", "read"),
            representationContract = "v2",
        )

        repository.activateSession(identity)

        assertEquals(identity, repository.activeSessionIdentity())
        assertEquals(1, database.queueDao().activeSession()?.id)
    }

    @Test
    fun onlyTheLatestConnectionGenerationCanActivateAndAbaGetsNewRevisions() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val repository = QueueRepository(database, AndroidKeystoreCipher("connection-race-${UUID.randomUUID()}"))
        val credentials = EncryptedCredentialStore(
            context,
            AndroidKeystoreCipher("connection-race-credentials-${UUID.randomUUID()}"),
        )
        val namespaceA = "e".repeat(43)
        val namespaceB = "f".repeat(43)
        val delayedStarted = CountDownLatch(1)
        val releaseDelayed = CountDownLatch(1)
        val api = object : WebTagApi {
            override fun validateSession(rawOrigin: String, apiKey: String): ApiResult<SessionIdentity> = when (apiKey) {
                "old" -> {
                    delayedStarted.countDown()
                    check(releaseDelayed.await(5, TimeUnit.SECONDS))
                    ApiResult.Success(SessionIdentity("https://a.example", namespaceA, setOf("write"), "v2"), namespaceA)
                }
                "new" -> ApiResult.Success(
                    SessionIdentity("https://b.example", namespaceB, setOf("write"), "v2"),
                    namespaceB,
                )
                "again" -> ApiResult.Success(
                    SessionIdentity("https://a.example", namespaceA, setOf("write"), "v2"),
                    namespaceA,
                )
                else -> ApiResult.Failure(ClassifiedFailure(ErrorKind.INVALID_CLIENT_RESPONSE), null)
            }

            override fun submit(identity: SessionIdentity, apiKey: String, url: String, idempotencyKey: String): ApiResult<SubmitResponse> = error("not used")

            override fun refresh(identity: SessionIdentity, apiKey: String, linkId: String): ApiResult<SubmitResponse> = error("not used")
        }
        val coordinator = ConnectionCoordinator(repository, credentials, api)
        var delayedResult: ConnectionResult? = null
        val thread = Thread { delayedResult = coordinator.saveAndTest("https://a.example", "old") }
        try {
            thread.start()
            assertTrue(delayedStarted.await(5, TimeUnit.SECONDS))
            assertTrue(coordinator.saveAndTest("https://b.example", "new") is ConnectionResult.Activated)
            releaseDelayed.countDown()
            thread.join(5_000)
            assertEquals(ConnectionResult.IdentityChanged, delayedResult)
            val bSnapshot = repository.activeSessionSnapshot()!!
            assertEquals("https://b.example", bSnapshot.identity.origin)
            assertEquals(2L, bSnapshot.activationRevision)
            assertEquals(2L, credentials.recover(bSnapshot)!!.activationRevision)

            assertTrue(coordinator.saveAndTest("https://a.example", "again") is ConnectionResult.Activated)
            val aAgain = repository.activeSessionSnapshot()!!
            assertEquals("https://a.example", aAgain.identity.origin)
            assertEquals(3L, aAgain.activationRevision)
            assertEquals(3L, credentials.recover(aAgain)!!.activationRevision)
        } finally {
            releaseDelayed.countDown()
            thread.join(5_000)
            credentials.clear()
        }
    }

    @Test
    fun credentialRecoveryOnlyAcceptsTheMatchingPersistentSessionPair() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val credentialAlias = "recovery-credentials-${UUID.randomUUID()}"
        val repository = QueueRepository(database, AndroidKeystoreCipher("recovery-data-${UUID.randomUUID()}"))
        val store = EncryptedCredentialStore(context, AndroidKeystoreCipher(credentialAlias))
        val identityA = QueueIdentity("https://a.example", "g".repeat(43))
        val identityB = QueueIdentity("https://b.example", "h".repeat(43))
        try {
            val sessionA = activate(repository, identityA)
            store.save(CredentialConfig(identityA.origin, "key-a", identityA.namespace, setOf("write"), 1))

            // A restarted store sees the durable matching pair, not an in-memory cache.
            val restarted = EncryptedCredentialStore(context, AndroidKeystoreCipher(credentialAlias))
            assertEquals("key-a", restarted.recover(sessionA)!!.apiKey)

            val sessionB = activateNext(repository, identityB)
            assertNull(restarted.recover(sessionB))
            restarted.stage(CredentialConfig(identityB.origin, "key-b", identityB.namespace, setOf("write"), sessionB.activationRevision))
            assertEquals("key-b", restarted.recover(sessionB)!!.apiKey)
            assertEquals(sessionB.activationRevision, restarted.load()!!.activationRevision)
        } finally {
            store.clear()
        }
    }

    @Test
    fun submitCommitUsesTheCommitClockAndRejectsTheLeaseDeadline() {
        val now = 50_000L
        val identity = QueueIdentity("https://example.org", "t".repeat(43))
        val repository = QueueRepository(
            database,
            AndroidKeystoreCipher("commit-clock-${UUID.randomUUID()}"),
        )
        val activation = activate(repository, identity)

        val beforeDeadline = repository.enqueue("https://example.org/before", identity, now)
        assertTrue(repository.claimForEntry(beforeDeadline, "before-owner", now, leaseMillis = 10))
        assertEquals(
            SubmitCommitOutcome.APPLIED,
            repository.applyClaimed(
                beforeDeadline,
                "before-owner",
                QueueState.RETRY_WAIT,
                now,
                1,
                now + 100,
                ErrorKind.NO_NETWORK,
                null,
                null,
                null,
                null,
                activation,
                now + 9,
            ),
        )

        val exactDeadline = repository.enqueue("https://example.org/exact", identity, now)
        assertTrue(repository.claimForEntry(exactDeadline, "exact-owner", now, leaseMillis = 10))
        assertEquals(
            SubmitCommitOutcome.STALE_CLAIM,
            repository.applyClaimed(
                exactDeadline,
                "exact-owner",
                QueueState.FAILED_PERMANENT,
                now,
                1,
                null,
                ErrorKind.HTTP_5XX,
                null,
                500,
                null,
                null,
                activation,
                now + 10,
            ),
        )
        val unchanged = database.queueDao().findById(exactDeadline.id)!!
        assertEquals("exact-owner", unchanged.leaseOwner)
        assertEquals(now + 10, unchanged.leaseExpiresAt)
        assertEquals("pending_submit", unchanged.state)
    }

    @Test
    fun reclaimedOwnerCannotMutateTheNewClaimOrWriteRecentResult() {
        val now = 60_000L
        val identity = QueueIdentity("https://example.org", "u".repeat(43))
        val repository = QueueRepository(
            database,
            AndroidKeystoreCipher("reclaim-cas-${UUID.randomUUID()}"),
        )
        val activation = activate(repository, identity)
        val entry = repository.enqueue("https://example.org/reclaim", identity, now)
        assertTrue(repository.claimForEntry(entry, "owner-1", now, leaseMillis = 10))
        assertTrue(repository.claimForEntry(entry, "owner-2", now + 10, leaseMillis = 10))

        assertEquals(
            SubmitCommitOutcome.STALE_CLAIM,
            repository.applyClaimed(
                entry,
                "owner-1",
                QueueState.FAILED_PERMANENT,
                now,
                1,
                null,
                ErrorKind.HTTP_5XX,
                null,
                500,
                null,
                null,
                activation,
                now + 11,
            ),
        )
        assertEquals(
            SubmitCommitOutcome.STALE_CLAIM,
            repository.commitSuccess(
                entry,
                "owner-1",
                RecentResult(
                    "https://example.org/reclaim",
                    "11111111-1111-1111-1111-111111111111",
                    null,
                    "done",
                    now + 11,
                    identity,
                    null,
                    null,
                ),
                activation,
                now = now + 11,
            ),
        )
        val ownerTwo = database.queueDao().findById(entry.id)!!
        assertEquals("owner-2", ownerTwo.leaseOwner)
        assertEquals(now + 20, ownerTwo.leaseExpiresAt)
        assertEquals("pending_submit", ownerTwo.state)
        assertNull(database.queueDao().recent())
    }

    @Test
    fun identityChangeRejectsClaimedSuccessAndFailureWithoutTouchingEitherIdentity() {
        val now = 70_000L
        val identityA = QueueIdentity("https://a.example", "a".repeat(43))
        val identityB = QueueIdentity("https://b.example", "b".repeat(43))
        val repository = QueueRepository(
            database,
            AndroidKeystoreCipher("identity-cas-${UUID.randomUUID()}"),
        )
        val activationA = activate(repository, identityA)
        val entry = repository.enqueue("https://example.org/a", identityA, now)
        assertTrue(repository.claimForEntry(entry, "a-owner", now, leaseMillis = 100))
        val activationB = activateNext(repository, identityB)
        database.queueDao().upsertRecent(recentEntity("b-link", "done", now, identityB))

        assertEquals(
            SubmitCommitOutcome.IDENTITY_CHANGED,
            repository.applyClaimed(
                entry,
                "a-owner",
                QueueState.FAILED_PERMANENT,
                now,
                1,
                null,
                ErrorKind.HTTP_5XX,
                null,
                500,
                null,
                null,
                activationA,
                now + 1,
            ),
        )
        assertEquals(
            SubmitCommitOutcome.IDENTITY_CHANGED,
            repository.commitSuccess(
                entry,
                "a-owner",
                RecentResult(
                    "https://example.org/a",
                    "22222222-2222-2222-2222-222222222222",
                    null,
                    "done",
                    now + 1,
                    identityA,
                    null,
                    null,
                ),
                activationA,
                now = now + 1,
            ),
        )
        assertEquals(identityB, QueueIdentity(activationB.identity.origin, activationB.identity.clientDataNamespace))
        assertEquals("a-owner", database.queueDao().findById(entry.id)!!.leaseOwner)
        assertEquals("b-link", database.queueDao().recent()!!.linkId)
    }

    @Test
    fun refreshClassifiesIdentityChangesBeforeLinkReplacementAndDoesNotMutate() {
        val now = 80_000L
        val identityA = QueueIdentity("https://a.example", "c".repeat(43))
        val identityB = QueueIdentity("https://b.example", "d".repeat(43))
        val repository = QueueRepository(
            database,
            AndroidKeystoreCipher("refresh-revision-${UUID.randomUUID()}"),
        )
        val activationA = activate(repository, identityA)
        database.queueDao().upsertRecent(recentEntity("a-link", "done", now, identityA))
        activateNext(repository, identityB)
        database.queueDao().upsertRecent(recentEntity("b-link", "done", now + 1, identityB))

        assertEquals(
            RefreshCommitOutcome.IDENTITY_CHANGED,
            repository.recordRefreshSuccess(
                activationA,
                "a-link",
                SubmitResponse("a-link", "processing", "late-job"),
                now + 2,
            ),
        )
        assertEquals("b-link", database.queueDao().recent()!!.linkId)

        val currentA = activateNext(repository, identityA)
        database.queueDao().upsertRecent(recentEntity("replacement", "done", now + 3, identityA))
        assertEquals(
            RefreshCommitOutcome.RECENT_REPLACED,
            repository.recordRefreshBlocked(currentA, "a-link", now + 60_000, "cooldown_active"),
        )
        assertEquals(
            RefreshCommitOutcome.RECENT_REPLACED,
            repository.recordRefreshBlocked(currentA, "a-link", null, "quota_exceeded"),
        )
        val replacement = database.queueDao().recent()!!
        assertEquals("replacement", replacement.linkId)
        assertNull(replacement.refreshNotBefore)
        assertNull(replacement.refreshBlockReason)
    }

    @Test
    fun staleRefreshCannotOverwriteANewerRecentResultForTheSameIdentity() {
        val identity = QueueIdentity("https://example.org", "r".repeat(43))
        val repository = QueueRepository(
            database,
            AndroidKeystoreCipher("recent-cas-stale-${UUID.randomUUID()}"),
        )
        val dao = database.queueDao()
        val activation = activate(repository, identity)
        val oldResult = recentEntity("old-link", "failed", 1_000L, identity)
        val newResult = recentEntity("new-link", "done", 2_000L, identity)
        dao.upsertRecent(oldResult)
        dao.upsertRecent(newResult)

        assertEquals(RefreshCommitOutcome.RECENT_REPLACED,
            repository.recordRefreshSuccess(
                activation,
                expectedLinkId = oldResult.linkId,
                response = SubmitResponse(oldResult.linkId, "processing", "old-refresh-job"),
                now = 3_000L,
            ),
        )
        assertEquals(RefreshCommitOutcome.RECENT_REPLACED,
            repository.recordRefreshBlocked(
                activation,
                expectedLinkId = oldResult.linkId,
                refreshNotBefore = 63_000L,
                reason = "cooldown_active",
            ),
        )

        val stored = dao.recent()!!
        assertEquals(newResult.linkId, stored.linkId)
        assertEquals(newResult.jobId, stored.jobId)
        assertEquals(newResult.status, stored.status)
        assertEquals(newResult.createdAt, stored.createdAt)
        assertNull(stored.refreshNotBefore)
        assertNull(stored.refreshBlockReason)
        assertArrayEquals(newResult.urlCiphertext, stored.urlCiphertext)
        assertArrayEquals(newResult.urlNonce, stored.urlNonce)
    }

    @Test
    fun matchingRefreshCompareAndSetUpdatesTheCurrentRecentResult() {
        val identity = QueueIdentity("https://example.org", "c".repeat(43))
        val repository = QueueRepository(
            database,
            AndroidKeystoreCipher("recent-cas-current-${UUID.randomUUID()}"),
        )
        val current = recentEntity("current-link", "failed", 4_000L, identity).copy(
            refreshNotBefore = 64_000L,
            refreshBlockReason = "cooldown_active",
        )
        database.queueDao().upsertRecent(current)
        val activation = activate(repository, identity)

        assertEquals(RefreshCommitOutcome.APPLIED,
            repository.recordRefreshSuccess(
                activation,
                expectedLinkId = current.linkId,
                response = SubmitResponse(current.linkId, "processing", "current-refresh-job"),
                now = 5_000L,
            ),
        )
        assertEquals(RefreshCommitOutcome.APPLIED,
            repository.recordRefreshBlocked(
                activation,
                expectedLinkId = current.linkId,
                refreshNotBefore = 65_000L,
                reason = "cooldown_active",
            ),
        )

        val stored = database.queueDao().recent()!!
        assertEquals(current.linkId, stored.linkId)
        assertEquals("current-refresh-job", stored.jobId)
        assertEquals("processing", stored.status)
        assertEquals(5_000L, stored.createdAt)
        assertEquals(65_000L, stored.refreshNotBefore)
        assertEquals("cooldown_active", stored.refreshBlockReason)
    }

    @Test
    fun roomV1MigrationAddsActiveSessionWithoutDroppingQueueRows() {
        val name = "queue-migration-${UUID.randomUUID()}"
        val oldDatabase = migrationHelper.createDatabase(name, 1)
        oldDatabase.execSQL(
            "INSERT INTO queue_entries (" +
                "id, schemaVersion, urlCiphertext, urlNonce, cryptoVersion, idempotencyKey, " +
                "requestFingerprint, apiOrigin, clientDataNamespace, state, createdAt, " +
                "firstFailedAt, attemptCount, nextAttemptAt, lastErrorKind, lastErrorCode, " +
                "lastHttpStatus, linkId, jobId, leaseOwner, leaseExpiresAt, updatedAt" +
                ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            arrayOf(
                "migration-entry",
                1,
                byteArrayOf(1),
                byteArrayOf(2),
                1,
                "migration-key",
                "migration-fingerprint",
                "https://example.org",
                "m".repeat(43),
                "pending_submit",
                1_000L,
                null,
                0,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                1_000L,
            ),
        )
        oldDatabase.close()

        val migrated = migrationHelper.runMigrationsAndValidate(
            name,
            2,
            true,
            QueueDatabase.MIGRATION_1_2,
        )
        val queue = migrated.query("SELECT id FROM queue_entries WHERE id = 'migration-entry'")
        val sessionTable = migrated.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'active_session'",
        )
        try {
            assertTrue(queue.moveToFirst())
            assertTrue(sessionTable.moveToFirst())
        } finally {
            queue.close()
            sessionTable.close()
            migrated.close()
        }
    }

    @Test
    fun roomV2MigrationAssignsTheLegacyRevisionAndPersistsTheGenerationFloor() {
        val name = "queue-activation-migration-${UUID.randomUUID()}"
        val oldDatabase = migrationHelper.createDatabase(name, 2)
        oldDatabase.execSQL(
            "INSERT INTO active_session (id, apiOrigin, clientDataNamespace, scopesJson, representationContract) " +
                "VALUES (1, 'https://example.org', '${"z".repeat(43)}', '[\"write\"]', 'v2')",
        )
        oldDatabase.close()

        val migrated = migrationHelper.runMigrationsAndValidate(
            name,
            3,
            true,
            QueueDatabase.MIGRATION_2_3,
        )
        val revision = migrated.query("SELECT activationRevision FROM active_session WHERE id = 1")
        val generation = migrated.query("SELECT latestAttemptGeneration FROM activation_state WHERE id = 1")
        try {
            assertTrue(revision.moveToFirst())
            assertEquals(1L, revision.getLong(0))
            assertTrue(generation.moveToFirst())
            assertEquals(1L, generation.getLong(0))
        } finally {
            revision.close()
            generation.close()
            migrated.close()
        }
    }

    @Test
    fun roomV3MigrationAddsTodoStorageWithoutDroppingCaptureRows() {
        val name = "queue-todo-migration-${UUID.randomUUID()}"
        val oldDatabase = migrationHelper.createDatabase(name, 3)
        oldDatabase.execSQL(
            "INSERT INTO queue_entries (" +
                "id, schemaVersion, urlCiphertext, urlNonce, cryptoVersion, idempotencyKey, " +
                "requestFingerprint, apiOrigin, clientDataNamespace, state, createdAt, " +
                "firstFailedAt, attemptCount, nextAttemptAt, lastErrorKind, lastErrorCode, " +
                "lastHttpStatus, linkId, jobId, leaseOwner, leaseExpiresAt, updatedAt" +
                ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            arrayOf(
                "todo-migration-entry",
                1,
                byteArrayOf(1),
                byteArrayOf(2),
                1,
                "todo-migration-key",
                "todo-migration-fingerprint",
                "https://example.org",
                "m".repeat(43),
                "pending_submit",
                1_000L,
                null,
                0,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                1_000L,
            ),
        )
        oldDatabase.close()

        val migrated = migrationHelper.runMigrationsAndValidate(
            name,
            4,
            true,
            QueueDatabase.MIGRATION_3_4,
        )
        val queue = migrated.query("SELECT id FROM queue_entries WHERE id = 'todo-migration-entry'")
        val todoTables = migrated.query(
            "SELECT count(*) FROM sqlite_master WHERE type = 'table' " +
                "AND name IN ('todo_cache', 'todo_outbox', 'todo_sync_state')",
        )
        try {
            assertTrue(queue.moveToFirst())
            assertTrue(todoTables.moveToFirst())
            assertEquals(3, todoTables.getInt(0))
        } finally {
            queue.close()
            todoTables.close()
            migrated.close()
        }
    }

    @Test
    fun roomV4MigrationAddsTodoLeasesWithoutDroppingPendingOperations() {
        val name = "todo-lease-migration-${UUID.randomUUID()}"
        val oldDatabase = migrationHelper.createDatabase(name, 4)
        oldDatabase.execSQL(
            "INSERT INTO todo_outbox (operationId, apiOrigin, clientDataNamespace, targetTodoId, " +
                "kind, payloadCiphertext, payloadNonce, cryptoVersion, state, attemptCount, " +
                "nextAttemptAt, lastErrorKind, createdAt, updatedAt) " +
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            arrayOf(
                "pending-operation",
                "https://example.org",
                "p".repeat(43),
                UUID.randomUUID().toString(),
                "create",
                byteArrayOf(1),
                byteArrayOf(2),
                1,
                "pending",
                0,
                null,
                null,
                1_000L,
                1_000L,
            ),
        )
        oldDatabase.close()

        val migrated = migrationHelper.runMigrationsAndValidate(
            name,
            5,
            true,
            QueueDatabase.MIGRATION_4_5,
        )
        val row = migrated.query(
            "SELECT operationId, leaseOwner, leaseExpiresAt FROM todo_outbox " +
                "WHERE operationId = 'pending-operation'",
        )
        try {
            assertTrue(row.moveToFirst())
            assertEquals("pending-operation", row.getString(0))
            assertTrue(row.isNull(1))
            assertTrue(row.isNull(2))
        } finally {
            row.close()
            migrated.close()
        }
    }

    @Test
    fun todoRepositoryKeepsEncryptedSnapshotsIdentityBoundAndOptimistic() {
        val repository = TodoRepository(
            database,
            AndroidKeystoreCipher("todo-store-${UUID.randomUUID()}"),
        )
        val identityA = QueueIdentity("https://example.org", "a".repeat(43))
        val identityB = QueueIdentity("https://example.org", "b".repeat(43))
        repository.replaceServerSnapshot(identityA, listOf(todoItem("server-a", "server text", 2_000)), 3_000)

        assertEquals(listOf("server text"), repository.snapshot(identityA).items.map { it.text })
        assertTrue(repository.snapshot(identityB).items.isEmpty())

        val localID = repository.stageCreate(identityA, TodoCreate("offline create", null), now = 4_000)
        val operationID = repository.stagePatch(
            identityA,
            localID,
            TodoPatch(done = true),
            now = 4_001,
        )
        val optimistic = repository.snapshot(identityA)
        assertEquals(2, optimistic.pendingOperations)
        assertTrue(optimistic.items.single { it.id == localID }.done)
        assertTrue(optimistic.items.single { it.id == localID }.localOnly)

        val createClaim = repository.claimDue(identityA, 5_000, 30_000)!!
        val serverCreated = todoItem("server-created", "offline create", 5_000)
        assertTrue(repository.completeCreate(createClaim.operation, createClaim.owner, serverCreated, 5_000))

        val rebound = database.todoDao().findOperation(operationID)!!
        assertEquals(serverCreated.id, rebound.targetTodoId)
        assertTrue(repository.snapshot(identityA).items.single { it.id == serverCreated.id }.done)
        assertFalse(repository.snapshot(identityA).items.any { it.id == localID })
    }

    @Test
    fun todoOutboxClaimIsAtomicAndRejectsAStaleOwner() {
        val repository = TodoRepository(
            database,
            AndroidKeystoreCipher("todo-lease-${UUID.randomUUID()}"),
        )
        val identity = QueueIdentity("https://example.org", "l".repeat(43))
        repository.stageCreate(identity, TodoCreate("leased create", null), now = 10_000)

        val first = repository.claimDue(identity, 11_000, 30_000)!!
        assertNull(repository.claimDue(identity, 11_001, 30_000))
        val second = repository.claimDue(identity, 41_000, 30_000)!!
        val created = todoItem("leased-server", "leased create", 42_000)

        assertFalse(repository.completeCreate(first.operation, first.owner, created, 42_000))
        assertTrue(repository.completeCreate(second.operation, second.owner, created, 42_000))
        assertNull(database.todoDao().findOperation(first.operation.entity.operationId))
    }

    @Test
    fun replacingTodoServerSnapshotPreservesPendingDesiredState() {
        val repository = TodoRepository(
            database,
            AndroidKeystoreCipher("todo-replace-${UUID.randomUUID()}"),
        )
        val identity = QueueIdentity("https://example.org", "c".repeat(43))
        val original = todoItem("replace", "old", 1_000)
        repository.replaceServerSnapshot(identity, listOf(original), 1_500)
        repository.stagePatch(identity, original.id, TodoPatch(text = "edited"), now = 1_600)
        repository.replaceServerSnapshot(identity, listOf(original.copy(updatedAt = 2_000)), 2_100)

        val snapshot = repository.snapshot(identity)
        assertEquals("edited", snapshot.items.single().text)
        assertTrue(snapshot.items.single().pending)
    }

    private fun queueEntity(id: String, now: Long, state: String = "pending_submit") = QueueEntity(
        id = id,
        schemaVersion = 1,
        urlCiphertext = byteArrayOf(1, 2, 3),
        urlNonce = byteArrayOf(4, 5, 6),
        cryptoVersion = 1,
        idempotencyKey = "idempotency-$id",
        requestFingerprint = "fingerprint-$id",
        apiOrigin = "https://example.org",
        clientDataNamespace = "n".repeat(43),
        state = state,
        createdAt = now,
        firstFailedAt = null,
        attemptCount = 0,
        nextAttemptAt = null,
        lastErrorKind = null,
        lastErrorCode = null,
        lastHttpStatus = null,
        linkId = null,
        jobId = null,
        leaseOwner = null,
        leaseExpiresAt = null,
        updatedAt = now,
    )

    private fun todoItem(seed: String, text: String, updatedAt: Long): TodoItem = TodoItem(
        id = UUID.nameUUIDFromBytes(seed.toByteArray()).toString(),
        text = text,
        dueAt = null,
        done = false,
        originKind = TodoOriginKind.STANDALONE,
        originHostKind = null,
        originHostId = null,
        originRefJson = null,
        hostRevision = 0,
        completedAt = null,
        createdAt = 1_000,
        updatedAt = updatedAt,
        expired = false,
    )

    private fun recentEntity(
        linkId: String,
        status: String,
        createdAt: Long,
        identity: QueueIdentity,
    ) = RecentResultEntity(
        urlCiphertext = byteArrayOf(linkId.length.toByte(), 2, 3),
        urlNonce = byteArrayOf(4, 5, 6),
        cryptoVersion = 1,
        linkId = linkId,
        jobId = "job-$linkId",
        status = status,
        createdAt = createdAt,
        apiOrigin = identity.origin,
        clientDataNamespace = identity.namespace,
        refreshNotBefore = null,
        refreshBlockReason = null,
    )

    private fun activate(repository: QueueRepository, identity: QueueIdentity): ActiveSessionSnapshot {
        val session = SessionIdentity(identity.origin, identity.namespace, setOf("write"), "v2")
        repository.activateSession(session)
        return repository.activeSessionSnapshot()!!
    }

    private fun activateNext(repository: QueueRepository, identity: QueueIdentity): ActiveSessionSnapshot {
        val session = SessionIdentity(identity.origin, identity.namespace, setOf("write"), "v2")
        val generation = repository.beginActivationAttempt()
        assertEquals(com.alpenl.webtag.share.contract.ActivationCommitOutcome.APPLIED, repository.activateSessionIfLatest(session, generation))
        return repository.activeSessionSnapshot()!!
    }
}
