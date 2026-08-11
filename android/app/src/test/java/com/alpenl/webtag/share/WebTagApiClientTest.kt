package com.alpenl.webtag.share

import com.alpenl.webtag.share.contract.ErrorKind
import com.alpenl.webtag.share.contract.SessionIdentity
import com.alpenl.webtag.share.contract.UrlCandidateExtractor
import com.alpenl.webtag.share.network.ApiResult
import com.alpenl.webtag.share.network.WebTagApiClient
import java.util.concurrent.TimeUnit
import javax.net.ssl.HostnameVerifier
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class WebTagApiClientTest {
    private lateinit var server: MockWebServer
    private lateinit var certificates: HandshakeCertificates

    @Before
    fun setUp() {
        val certificate = HeldCertificate.Builder()
            .addSubjectAlternativeName("localhost")
            .build()
        certificates = HandshakeCertificates.Builder()
            .heldCertificate(certificate)
            .addTrustedCertificate(certificate.certificate)
            .build()
        server = MockWebServer()
        server.useHttps(certificates.sslSocketFactory(), false)
        server.start()
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    @Test
    fun sessionRequiresMatchingNamespaceHeader() {
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setHeader("X-WebTag-Data-Namespace", namespace)
                .setBody(sessionBody(namespace)),
        )

        val result = client().validateSession(origin(), "key")

        assertTrue(result is ApiResult.Success)
        assertEquals(namespace, (result as ApiResult.Success).value.clientDataNamespace)
        val request = server.takeRequest(1, TimeUnit.SECONDS)
        assertNotNull(request)
        assertEquals("GET", request!!.method)
        assertEquals("Bearer key", request.getHeader("Authorization"))
    }

    @Test
    fun sessionRejectsNamespaceMismatchAndMissingHeader() {
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setHeader("X-WebTag-Data-Namespace", otherNamespace)
                .setBody(sessionBody(namespace)),
        )
        val mismatch = client().validateSession(origin(), "key")
        assertEquals(ErrorKind.IDENTITY_MISMATCH, (mismatch as ApiResult.Failure).failure.kind)

        server.enqueue(MockResponse().setResponseCode(200).setBody(sessionBody(namespace)))
        val missing = client().validateSession(origin(), "key")
        assertEquals(ErrorKind.IDENTITY_MISMATCH, (missing as ApiResult.Failure).failure.kind)
    }

    @Test
    fun sessionRejectsInvalidNamespaceCharacters() {
        val invalidNamespace = "n".repeat(42) + "!"
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setHeader("X-WebTag-Data-Namespace", invalidNamespace)
                .setBody(sessionBody(invalidNamespace)),
        )

        val result = client().validateSession(origin(), "key")

        assertEquals(ErrorKind.INVALID_SUCCESS_PAYLOAD, (result as ApiResult.Failure).failure.kind)
    }

    @Test
    fun sessionRejectsMissingScopesAsInvalidSuccessPayload() {
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setHeader("X-WebTag-Data-Namespace", namespace)
                .setBody(
                    "{\"client_data_namespace\":\"$namespace\",\"representation_contract\":\"v2\"}",
                ),
        )

        val result = client().validateSession(origin(), "key")

        assertEquals(ErrorKind.INVALID_SUCCESS_PAYLOAD, (result as ApiResult.Failure).failure.kind)
    }

    @Test
    fun sessionRejectsBlankApiKeyBeforeCreatingARequest() {
        val result = client().validateSession(origin(), "  \t")

        assertEquals(ErrorKind.INVALID_CLIENT_RESPONSE, (result as ApiResult.Failure).failure.kind)
        assertEquals(0, server.requestCount)
    }

    @Test
    fun submitUsesOnlyUrlBodyAndStableIdempotencyKey() {
        server.enqueue(
            MockResponse()
                .setResponseCode(202)
                .setHeader("X-WebTag-Data-Namespace", namespace)
                .setBody("{\"link_id\":\"11111111-1111-1111-1111-111111111111\",\"status\":\"pending\",\"job_id\":\"22222222-2222-2222-2222-222222222222\"}"),
        )
        val url = "https://example.com/a?x=1"

        val result = client().submit(identity(), "key", url, "idem-1")

        assertTrue(result is ApiResult.Success)
        assertEquals("11111111-1111-1111-1111-111111111111", (result as ApiResult.Success).value.linkId)
        val request = server.takeRequest(1, TimeUnit.SECONDS)!!
        assertEquals("POST", request.method)
        assertEquals("/api/links", request.path)
        assertEquals("idem-1", request.getHeader("Idempotency-Key"))
        assertEquals("{\"url\":\"https://example.com/a?x=1\"}", request.body.readUtf8())
    }

    @Test
    fun submitSendsTheExtractedCandidateVerbatimAndNeverItsDisplayLabel() {
        server.enqueue(
            MockResponse()
                .setResponseCode(202)
                .setHeader("X-WebTag-Data-Namespace", namespace)
                .setBody("{\"link_id\":\"11111111-1111-1111-1111-111111111111\",\"status\":\"pending\",\"job_id\":null}"),
        )
        val shared = "HTTPS://Example.COM:8443/Keep%2FCase?utm=Aa%2Bb&x=1#Sect%20ion"
        val candidate = UrlCandidateExtractor.extract(sharePayload(intentDataUrl = shared)).single()

        val result = client().submit(identity(), "key", candidate.submissionValue, "idem-candidate")

        assertTrue(result is ApiResult.Success)
        assertEquals("example.com:8443/Keep%2FCase", candidate.displayLabel)
        val request = server.takeRequest(1, TimeUnit.SECONDS)!!
        // The wire body must carry the shared URL byte for byte: casing, port, percent-encoding,
        // query and fragment all survive, and nothing was rebuilt from the label.
        assertEquals("{\"url\":\"$shared\"}", request.body.readUtf8())
    }

    @Test
    fun submitRejectsAClientIdentityWithoutWriteBeforeCreatingARequest() {
        val readOnlyIdentity = SessionIdentity(origin(), namespace, setOf("read"), "v2")

        val result = client().submit(readOnlyIdentity, "key", "https://example.com", "idem-read-only")

        assertEquals(ErrorKind.INVALID_CLIENT_RESPONSE, (result as ApiResult.Failure).failure.kind)
        assertEquals(0, server.requestCount)
    }

    @Test
    fun classifiesAuthScopeRateLimitQuotaServerAndInvalidSuccessPayload() {
        server.enqueue(error(401, "invalid_api_key"))
        server.enqueue(error(403, "insufficient_scope"))
        server.enqueue(error(429, "rate_limit_exceeded", "90"))
        server.enqueue(error(429, "quota_exceeded"))
        server.enqueue(error(500, "internal_error"))
        server.enqueue(MockResponse().setResponseCode(200).setHeader("X-WebTag-Data-Namespace", namespace).setBody("not-json"))

        assertEquals(ErrorKind.HTTP_401, submitFailure().kind)
        assertEquals(ErrorKind.HTTP_403_SCOPE, submitFailure().kind)
        assertEquals(ErrorKind.HTTP_429_RATE_LIMIT, submitFailure().kind)
        assertEquals(ErrorKind.HTTP_429_QUOTA, submitFailure().kind)
        assertEquals(ErrorKind.HTTP_5XX, submitFailure().kind)
        assertEquals(ErrorKind.INVALID_SUCCESS_PAYLOAD, submitFailure().kind)
    }

    @Test
    fun doesNotFollowRedirectsOrForwardTheAuthenticatedRequest() {
        server.enqueue(
            MockResponse()
                .setResponseCode(302)
                .setHeader("Location", "https://other.example/api/links"),
        )

        val result = client().submit(identity(), "key", "https://example.com", "idem-redirect")

        assertTrue(result is ApiResult.Failure)
        assertEquals(ErrorKind.INVALID_CLIENT_RESPONSE, (result as ApiResult.Failure).failure.kind)
        assertEquals(1, server.requestCount)
    }

    @Test
    fun rejectsUnexpectedSuccessfulStatusCode() {
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setHeader("X-WebTag-Data-Namespace", namespace)
                .setBody("{\"link_id\":\"11111111-1111-1111-1111-111111111111\",\"status\":\"pending\"}"),
        )

        val result = client().submit(identity(), "key", "https://example.com", "idem-status")

        assertEquals(ErrorKind.INVALID_SUCCESS_PAYLOAD, (result as ApiResult.Failure).failure.kind)
        assertEquals(200, result.failure.statusCode)
    }

    @Test
    fun refreshUsesExplicitEndpointWithoutSubmitIdempotencyHeader() {
        server.enqueue(
            MockResponse()
                .setResponseCode(202)
                .setHeader("X-WebTag-Data-Namespace", namespace)
                .setBody("{\"link_id\":\"11111111-1111-1111-1111-111111111111\",\"status\":\"processing\",\"job_id\":\"33333333-3333-3333-3333-333333333333\"}"),
        )

        val result = client().refresh(identity(), "key", "11111111-1111-1111-1111-111111111111")

        assertTrue(result is ApiResult.Success)
        val request = server.takeRequest(1, TimeUnit.SECONDS)!!
        assertEquals("POST", request.method)
        assertEquals("/api/links/11111111-1111-1111-1111-111111111111/refresh", request.path)
        assertNull(request.getHeader("Idempotency-Key"))
        assertEquals(0L, request.body.size)
    }

    @Test
    fun refreshRejectsAResponseForADifferentLink() {
        server.enqueue(
            MockResponse()
                .setResponseCode(202)
                .setHeader("X-WebTag-Data-Namespace", namespace)
                .setBody("{\"link_id\":\"22222222-2222-2222-2222-222222222222\",\"status\":\"processing\"}"),
        )

        val result = client().refresh(identity(), "key", "11111111-1111-1111-1111-111111111111")

        assertEquals(ErrorKind.INVALID_SUCCESS_PAYLOAD, (result as ApiResult.Failure).failure.kind)
    }

    @Test
    fun refreshRejectsNonUuidBeforeCreatingARequest() {
        val result = client().refresh(identity(), "key", "not-a-uuid")

        assertEquals(ErrorKind.INVALID_CLIENT_RESPONSE, (result as ApiResult.Failure).failure.kind)
        assertEquals(0, server.requestCount)
    }

    @Test
    fun rejectsNonUuidResponseIdentifiers() {
        server.enqueue(
            MockResponse()
                .setResponseCode(202)
                .setHeader("X-WebTag-Data-Namespace", namespace)
                .setBody("{\"link_id\":\"not-a-uuid\",\"status\":\"pending\"}"),
        )

        val result = client().submit(identity(), "key", "https://example.com", "idem-invalid-id")

        assertEquals(ErrorKind.INVALID_SUCCESS_PAYLOAD, (result as ApiResult.Failure).failure.kind)
    }

    @Test
    fun mapsReadTimeoutToRetryableTimeout() {
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setHeader("X-WebTag-Data-Namespace", namespace)
                .setBody(sessionBody(namespace))
                .setBodyDelay(250, TimeUnit.MILLISECONDS),
        )

        val result = client(readTimeoutMillis = 50).validateSession(origin(), "key")

        assertEquals(ErrorKind.CLIENT_DEADLINE, (result as ApiResult.Failure).failure.kind)
    }

    private fun submitFailure(): com.alpenl.webtag.share.network.ClassifiedFailure {
        val result = client().submit(identity(), "key", "https://example.com", "idem-${server.requestCount}")
        return (result as ApiResult.Failure).failure
    }

    private fun error(status: Int, code: String, retryAfter: String? = null): MockResponse =
        MockResponse().setResponseCode(status).apply {
            retryAfter?.let { setHeader("Retry-After", it) }
            setBody("{\"error\":{\"error_code\":\"$code\"}}")
        }

    private fun sessionBody(value: String): String =
        "{\"client_data_namespace\":\"$value\",\"representation_contract\":\"v2\",\"scopes\":[\"write\"]}"

    private fun identity() = SessionIdentity(origin(), namespace, setOf("write"), "v2")

    private fun origin(): String = server.url("/").toString().removeSuffix("/")

    private fun client(readTimeoutMillis: Long = 2_000): WebTagApiClient {
        val hostnameVerifier = HostnameVerifier { hostname, _ -> hostname == "localhost" }
        val okHttp = OkHttpClient.Builder()
            .sslSocketFactory(certificates.sslSocketFactory(), certificates.trustManager)
            .hostnameVerifier(hostnameVerifier)
            .followRedirects(false)
            .followSslRedirects(false)
            .connectTimeout(2, TimeUnit.SECONDS)
            .readTimeout(readTimeoutMillis, TimeUnit.MILLISECONDS)
            .writeTimeout(2, TimeUnit.SECONDS)
            .callTimeout(2, TimeUnit.SECONDS)
            .build()
        return WebTagApiClient(okHttp)
    }

    companion object {
        private val namespace = "n".repeat(43)
        private val otherNamespace = "o".repeat(43)
    }
}
