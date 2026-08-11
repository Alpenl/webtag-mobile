package com.alpenl.webtag.share

import com.alpenl.webtag.share.contract.ErrorKind
import com.alpenl.webtag.share.network.ErrorClassifier
import java.io.IOException
import java.net.SocketTimeoutException
import javax.net.ssl.SSLHandshakeException
import org.junit.Assert.assertEquals
import org.junit.Test

class ErrorClassifierTest {
    @Test
    fun classifiesServerBranchesWithoutParsingHumanMessages() {
        assertEquals(ErrorKind.HTTP_429_RATE_LIMIT, ErrorClassifier.http(429, "rate_limit_exceeded", "60").kind)
        assertEquals(ErrorKind.HTTP_429_COOLDOWN, ErrorClassifier.http(429, "cooldown_active", "60").kind)
        assertEquals(ErrorKind.HTTP_429_QUOTA, ErrorClassifier.http(429, "quota_exceeded", null).kind)
        assertEquals(ErrorKind.HTTP_403_SCOPE, ErrorClassifier.http(403, "insufficient_scope", null).kind)
        assertEquals(ErrorKind.INVALID_CLIENT_RESPONSE, ErrorClassifier.http(403, "forbidden", null).kind)
        assertEquals(ErrorKind.HTTP_409, ErrorClassifier.http(409, "unknown", null).kind)
    }

    @Test
    fun keepsTlsFailurePermanentAndTimeoutRetryable() {
        assertEquals(ErrorKind.TLS_TRUST_FAILURE, ErrorClassifier.transport(SSLHandshakeException("test")).kind)
        assertEquals(ErrorKind.CLIENT_DEADLINE, ErrorClassifier.transport(SocketTimeoutException("test")).kind)
    }

    @Test
    fun scansTheWholeCauseChainForTlsFailures() {
        val wrapped = IOException("request failed", SSLHandshakeException("certificate rejected"))

        assertEquals(ErrorKind.TLS_TRUST_FAILURE, ErrorClassifier.transport(wrapped).kind)
    }
}
