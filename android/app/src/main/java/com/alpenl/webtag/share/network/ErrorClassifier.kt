package com.alpenl.webtag.share.network

import com.alpenl.webtag.share.contract.ErrorKind
import java.io.IOException
import java.net.UnknownHostException
import java.net.SocketTimeoutException
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLPeerUnverifiedException

data class ClassifiedFailure(
    val kind: ErrorKind,
    val errorCode: String? = null,
    val statusCode: Int? = null,
    val retryAfter: String? = null,
)

object ErrorClassifier {
    fun http(statusCode: Int, errorCode: String?, retryAfter: String?): ClassifiedFailure {
        val kind = when {
            statusCode == 401 -> ErrorKind.HTTP_401
            statusCode == 403 && errorCode == "insufficient_scope" -> ErrorKind.HTTP_403_SCOPE
            statusCode == 408 -> ErrorKind.HTTP_408
            statusCode == 409 -> ErrorKind.HTTP_409
            statusCode == 425 -> ErrorKind.HTTP_425
            statusCode == 429 && errorCode == "cooldown_active" -> ErrorKind.HTTP_429_COOLDOWN
            statusCode == 429 && errorCode == "quota_exceeded" -> ErrorKind.HTTP_429_QUOTA
            statusCode == 429 -> ErrorKind.HTTP_429_RATE_LIMIT
            statusCode in 500..599 -> ErrorKind.HTTP_5XX
            else -> ErrorKind.INVALID_CLIENT_RESPONSE
        }
        return ClassifiedFailure(kind, errorCode, statusCode, retryAfter)
    }

    fun transport(error: Throwable): ClassifiedFailure {
        val causes = generateSequence(error) { it.cause }.toList()
        return when {
            causes.any { it is SSLHandshakeException || it is SSLPeerUnverifiedException } ->
                ClassifiedFailure(ErrorKind.TLS_TRUST_FAILURE)
            causes.any { it is UnknownHostException } -> ClassifiedFailure(ErrorKind.DNS_TIMEOUT)
            causes.any { it is SocketTimeoutException } -> ClassifiedFailure(ErrorKind.CLIENT_DEADLINE)
            causes.any { it is IOException } -> ClassifiedFailure(ErrorKind.CONNECTION_RESET)
            else -> ClassifiedFailure(ErrorKind.INVALID_CLIENT_RESPONSE)
        }
    }
}
