package com.alpenl.webtag.share

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.alpenl.webtag.share.contract.CredentialConfig
import com.alpenl.webtag.share.contract.ErrorKind
import com.alpenl.webtag.share.contract.QueueIdentity
import com.alpenl.webtag.share.contract.QueueState
import com.alpenl.webtag.share.contract.SessionIdentity
import com.alpenl.webtag.share.contract.SubmitCommitOutcome
import com.alpenl.webtag.share.contract.SubmissionOutcome
import com.alpenl.webtag.share.data.QueueDatabase
import com.alpenl.webtag.share.data.QueueRepository
import com.alpenl.webtag.share.network.WebTagApiClient
import com.alpenl.webtag.share.queue.QueueScheduler
import com.alpenl.webtag.share.queue.MobileClock
import com.alpenl.webtag.share.queue.ShareSubmissionCoordinator
import com.alpenl.webtag.share.security.AndroidKeystoreCipher
import com.alpenl.webtag.share.security.EncryptedCredentialStore
import java.util.UUID
import java.util.concurrent.TimeUnit
import javax.net.ssl.HostnameVerifier
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ShareSubmissionCoordinatorInstrumentedTest {
    private lateinit var database: QueueDatabase
    private lateinit var repository: QueueRepository
    private lateinit var credentials: EncryptedCredentialStore
    private lateinit var server: MockWebServer
    private lateinit var identity: SessionIdentity
    private lateinit var coordinator: ShareSubmissionCoordinator
    private var commitNow = 0L

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        database = Room.inMemoryDatabaseBuilder(context, QueueDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        repository = QueueRepository(
            database,
            AndroidKeystoreCipher("coordinator-data-${UUID.randomUUID()}"),
        )
        credentials = EncryptedCredentialStore(
            context,
            AndroidKeystoreCipher("coordinator-credentials-${UUID.randomUUID()}"),
        )

        val certificate = HeldCertificate.Builder()
            .addSubjectAlternativeName("localhost")
            .build()
        val certificates = HandshakeCertificates.Builder()
            .heldCertificate(certificate)
            .addTrustedCertificate(certificate.certificate)
            .build()
        server = MockWebServer()
        server.useHttps(certificates.sslSocketFactory(), false)
        server.start()

        val origin = server.url("/").toString().removeSuffix("/")
        val namespace = "n".repeat(43)
        identity = SessionIdentity(origin, namespace, setOf("write"), "v2")
        credentials.save(CredentialConfig(origin, "test-key", namespace, setOf("write")))
        repository.activateSession(identity)

        val hostnameVerifier = HostnameVerifier { hostname, _ -> hostname == "localhost" }
        val client = OkHttpClient.Builder()
            .sslSocketFactory(certificates.sslSocketFactory(), certificates.trustManager)
            .hostnameVerifier(hostnameVerifier)
            .followRedirects(false)
            .followSslRedirects(false)
            .connectTimeout(2, TimeUnit.SECONDS)
            .readTimeout(2, TimeUnit.SECONDS)
            .writeTimeout(2, TimeUnit.SECONDS)
            .callTimeout(2, TimeUnit.SECONDS)
            .build()
        coordinator = ShareSubmissionCoordinator(
            repository,
            credentials,
            WebTagApiClient(client),
            QueueScheduler(context, repository),
            MobileClock { commitNow },
        )
    }

    @After
    fun tearDown() {
        credentials.clear()
        database.close()
        server.shutdown()
    }

    @Test
    fun successCommitsRecentResultAndRemovesQueueEntry() {
        val url = "https://example.org/article"
        server.enqueue(
            MockResponse()
                .setResponseCode(202)
                .setHeader("X-WebTag-Data-Namespace", identity.clientDataNamespace)
                .setBody("{\"link_id\":\"11111111-1111-1111-1111-111111111111\",\"status\":\"done\"}"),
        )

        val outcome = coordinator.submit(url, identity, now = 1_000L)

        assertTrue(outcome is SubmissionOutcome.Submitted)
        assertTrue(repository.listAll().isEmpty())
        assertEquals(url, repository.readRecent(QueueIdentity(identity.origin, identity.clientDataNamespace))?.url)
        val request = server.takeRequest(1, TimeUnit.SECONDS)!!
        assertEquals("POST", request.method)
        assertEquals(url, JSONObject(request.body.readUtf8()).getString("url"))
        assertTrue(request.getHeader("Idempotency-Key")!!.isNotBlank())
    }

    @Test
    fun failedSubmitIsACompletedResultAndDoesNotTriggerRefresh() {
        val url = "https://example.org/failed"
        server.enqueue(
            MockResponse()
                .setResponseCode(202)
                .setHeader("X-WebTag-Data-Namespace", identity.clientDataNamespace)
                .setBody("{\"link_id\":\"33333333-3333-3333-3333-333333333333\",\"status\":\"failed\"}"),
        )

        val outcome = coordinator.submit(url, identity, now = 1_500L)

        assertTrue(outcome is SubmissionOutcome.Submitted)
        assertEquals("failed", repository.readRecent(QueueIdentity(identity.origin, identity.clientDataNamespace))?.status)
        assertTrue(repository.listAll().isEmpty())
        val request = server.takeRequest(1, TimeUnit.SECONDS)!!
        assertEquals("/api/links", request.path)
        assertEquals(1, server.requestCount)
    }

    @Test
    fun responseLossReplaysWithTheSameIdempotencyKeyAndCommitsOnce() {
        val now = 10_000L
        val url = "https://example.org/response-loss"
        server.enqueue(
            MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST),
        )

        val first = coordinator.submit(url, identity, now = now)

        assertTrue(first is SubmissionOutcome.Queued)
        val firstRequest = server.takeRequest(1, TimeUnit.SECONDS)!!
        val firstKey = firstRequest.getHeader("Idempotency-Key")
        assertTrue(!firstKey.isNullOrBlank())
        assertEquals("/api/links", firstRequest.path)

        server.enqueue(
            MockResponse()
                .setResponseCode(202)
                .setHeader("X-WebTag-Data-Namespace", identity.clientDataNamespace)
                .setBody("{\"link_id\":\"44444444-4444-4444-4444-444444444444\",\"status\":\"pending\"}"),
        )

        assertTrue(coordinator.drainOne(now = now + 120_000L))
        val replayRequest = server.takeRequest(1, TimeUnit.SECONDS)!!
        assertEquals(firstKey, replayRequest.getHeader("Idempotency-Key"))
        assertTrue(repository.listAll().isEmpty())
        assertEquals(
            "44444444-4444-4444-4444-444444444444",
            repository.readRecent(QueueIdentity(identity.origin, identity.clientDataNamespace))?.linkId,
        )
    }

    @Test
    fun authFailureIsRetainedAsBlockedAuthWithNoRetrySchedule() {
        server.enqueue(
            MockResponse()
                .setResponseCode(401)
                .setBody("{\"error\":{\"error_code\":\"invalid_api_key\"}}"),
        )

        val outcome = coordinator.submit("https://example.org/auth", identity, now = 2_000L)

        assertTrue(outcome is SubmissionOutcome.Blocked)
        assertEquals("blocked_auth", repository.listAll().single().state)
        assertEquals(1, repository.listAll().single().attemptCount)
    }

    @Test
    fun missingCredentialDoesNotCreateOrSendQueueEntry() {
        credentials.clear()

        val outcome = coordinator.submit("https://example.org/missing", identity, now = 3_000L)

        assertEquals(SubmissionOutcome.ConfigurationRequired, outcome)
        assertTrue(repository.listAll().isEmpty())
        assertEquals(0, server.requestCount)
    }

    @Test
    fun credentialIdentityMismatchDoesNotCreateOrSendQueueEntry() {
        credentials.save(
            CredentialConfig(
                identity.origin,
                "different-key",
                "x".repeat(43),
                setOf("write"),
            ),
        )

        val outcome = coordinator.submit("https://example.org/mismatched", identity, now = 3_500L)

        assertEquals(SubmissionOutcome.ConfigurationRequired, outcome)
        assertTrue(repository.listAll().isEmpty())
        assertEquals(0, server.requestCount)
    }

    @Test
    fun reusingPendingRowKeepsItsOriginalIdempotencyKey() {
        val url = "https://example.org/reuse-key"
        val entry = repository.enqueue(
            url,
            QueueIdentity(identity.origin, identity.clientDataNamespace),
            now = System.currentTimeMillis(),
        )
        server.enqueue(
            MockResponse()
                .setResponseCode(202)
                .setHeader("X-WebTag-Data-Namespace", identity.clientDataNamespace)
                .setBody("{\"link_id\":\"22222222-2222-2222-2222-222222222222\",\"status\":\"pending\"}"),
        )

        val outcome = coordinator.submit(url, identity, now = System.currentTimeMillis())

        assertTrue(outcome is SubmissionOutcome.Submitted)
        assertEquals(entry.idempotencyKey, server.takeRequest(1, TimeUnit.SECONDS)!!.getHeader("Idempotency-Key"))
    }

    @Test
    fun activeLeaseIsReusedWithoutCreatingOrSendingAnotherRow() {
        val now = System.currentTimeMillis()
        val url = "https://example.org/active-lease"
        val entry = repository.enqueue(
            url,
            QueueIdentity(identity.origin, identity.clientDataNamespace),
            now,
        )
        assertEquals(1, database.queueDao().claim(
            entry.id,
            entry.apiOrigin,
            entry.clientDataNamespace,
            "active-owner",
            now + 30_000,
            now,
        ))

        val outcome = coordinator.submit(url, identity, now = now + 1)

        assertTrue(outcome is SubmissionOutcome.Queued)
        assertEquals(1, repository.listAll().size)
        assertEquals(entry.idempotencyKey, repository.listAll().single().idempotencyKey)
        assertEquals(0, server.requestCount)
    }

    @Test
    fun futureRetryRowIsNotSentBeforeItsNextAttemptAt() {
        val now = System.currentTimeMillis()
        val url = "https://example.org/future-retry"
        val entry = repository.enqueue(
            url,
            QueueIdentity(identity.origin, identity.clientDataNamespace),
            now,
        )
        val owner = "retry-owner"
        assertEquals(1, database.queueDao().claim(
            entry.id,
            entry.apiOrigin,
            entry.clientDataNamespace,
            owner,
            now + 30_000,
            now,
        ))
        assertEquals(SubmitCommitOutcome.APPLIED,
            repository.applyClaimed(
                entry = entry,
                owner = owner,
                state = QueueState.RETRY_WAIT,
                firstFailedAt = now,
                attemptCount = 1,
                nextAttemptAt = now + 60_000,
                errorKind = ErrorKind.NO_NETWORK,
                errorCode = null,
                statusCode = null,
                linkId = null,
                jobId = null,
                activation = repository.activeSessionSnapshot()!!,
                now = now + 1,
            ),
        )

        val outcome = coordinator.submit(url, identity, now = now + 2)

        assertTrue(outcome is SubmissionOutcome.Queued)
        assertEquals(QueueState.RETRY_WAIT, (outcome as SubmissionOutcome.Queued).state)
        assertEquals(1, repository.listAll().size)
        assertEquals("retry_wait", repository.listAll().single().state)
        assertEquals(0, server.requestCount)
    }
}
