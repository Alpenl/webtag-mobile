package com.alpenl.webtag.share.network

import com.alpenl.webtag.share.contract.OriginNormalizer
import com.alpenl.webtag.share.contract.SessionIdentity
import com.alpenl.webtag.share.contract.SubmitResponse
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException
import java.util.UUID
import java.util.concurrent.TimeUnit

sealed interface ApiResult<out T> {
    data class Success<T>(val value: T, val namespace: String?) : ApiResult<T>
    data class Failure(val failure: ClassifiedFailure, val namespace: String?) : ApiResult<Nothing>
}

private class IdentityMismatchException : RuntimeException()

interface WebTagApi {
    fun validateSession(rawOrigin: String, apiKey: String): ApiResult<SessionIdentity>

    fun submit(
        identity: SessionIdentity,
        apiKey: String,
        url: String,
        idempotencyKey: String,
    ): ApiResult<SubmitResponse>

    fun refresh(
        identity: SessionIdentity,
        apiKey: String,
        linkId: String,
    ): ApiResult<SubmitResponse>
}

class WebTagApiClient(
    private val httpClient: OkHttpClient = defaultHttpClient(),
) : WebTagApi {
    override fun validateSession(rawOrigin: String, apiKey: String): ApiResult<SessionIdentity> {
        if (apiKey.isBlank()) {
            return ApiResult.Failure(
                ClassifiedFailure(com.alpenl.webtag.share.contract.ErrorKind.INVALID_CLIENT_RESPONSE),
                null,
            )
        }
        val origin = runCatching { OriginNormalizer.normalize(rawOrigin) }.getOrElse {
            return ApiResult.Failure(
                ClassifiedFailure(com.alpenl.webtag.share.contract.ErrorKind.INVALID_CLIENT_RESPONSE),
                null,
            )
        }
        return execute(origin, apiKey, "GET", "/api/session", null, acceptedStatusCodes = setOf(200)) { body, namespace ->
            val json = JSONObject(body)
            val bodyNamespace = json.getString("client_data_namespace")
            val representation = json.getString("representation_contract")
            val scopes = buildSet {
                val values = json.getJSONArray("scopes")
                for (index in 0 until values.length()) add(values.getString(index))
            }
            if (namespace != bodyNamespace) throw IdentityMismatchException()
            require(isNamespace(bodyNamespace) && representation == "v2" && scopes.all(String::isNotBlank)) {
                "unsupported session contract"
            }
            SessionIdentity(origin, bodyNamespace, scopes, representation)
        }
    }

    override fun submit(
        identity: SessionIdentity,
        apiKey: String,
        url: String,
        idempotencyKey: String,
    ): ApiResult<SubmitResponse> {
        if (!identity.canWrite() || !isNamespace(identity.clientDataNamespace) || apiKey.isBlank() || idempotencyKey.isBlank() ||
            runCatching { OriginNormalizer.normalize(identity.origin) }.getOrNull() != identity.origin
        ) {
            return ApiResult.Failure(
                ClassifiedFailure(com.alpenl.webtag.share.contract.ErrorKind.INVALID_CLIENT_RESPONSE),
                null,
            )
        }
        val body = JSONObject().put("url", url).toString()
            .toRequestBody("application/json".toMediaType())
        return execute(
            identity.origin,
            apiKey,
            "POST",
            "/api/links",
            body,
            idempotencyKey,
            acceptedStatusCodes = setOf(202),
        ) { responseBody, namespace ->
            if (namespace != identity.clientDataNamespace) throw IdentityMismatchException()
            val json = JSONObject(responseBody)
            val linkId = json.getString("link_id")
            val status = json.getString("status")
            require(status in setOf("pending", "processing", "done", "failed")) {
                "unknown submit status"
            }
            require(isUuid(linkId)) { "invalid link ID" }
            val jobId = json.optString("job_id").takeIf { it.isNotEmpty() }
            require(jobId == null || isUuid(jobId)) { "invalid job ID" }
            SubmitResponse(linkId, status, jobId)
        }
    }

    override fun refresh(
        identity: SessionIdentity,
        apiKey: String,
        linkId: String,
    ): ApiResult<SubmitResponse> {
        if (!identity.canWrite() || !isNamespace(identity.clientDataNamespace) || apiKey.isBlank() ||
            runCatching { OriginNormalizer.normalize(identity.origin) }.getOrNull() != identity.origin ||
            !isUuid(linkId)
        ) {
            return ApiResult.Failure(
                ClassifiedFailure(com.alpenl.webtag.share.contract.ErrorKind.INVALID_CLIENT_RESPONSE),
                null,
            )
        }
        return execute(
            identity.origin,
            apiKey,
            "POST",
            "/api/links/$linkId/refresh",
            null,
            acceptedStatusCodes = setOf(202),
        ) { responseBody, namespace ->
            if (namespace != identity.clientDataNamespace) throw IdentityMismatchException()
            val json = JSONObject(responseBody)
            val responseLinkId = json.getString("link_id")
            val status = json.getString("status")
            require(status in setOf("pending", "processing", "done", "failed")) { "unknown refresh status" }
            require(isUuid(responseLinkId)) { "invalid link ID" }
            require(UUID.fromString(responseLinkId) == UUID.fromString(linkId)) {
                "refresh response link ID does not match request"
            }
            val jobId = json.optString("job_id").takeIf { it.isNotEmpty() }
            require(jobId == null || isUuid(jobId)) { "invalid job ID" }
            SubmitResponse(responseLinkId, status, jobId)
        }
    }

    private fun <T> execute(
        origin: String,
        apiKey: String,
        method: String,
        path: String,
        body: okhttp3.RequestBody?,
        idempotencyKey: String? = null,
        acceptedStatusCodes: Set<Int>,
        decode: (String, String?) -> T,
    ): ApiResult<T> {
        val requestBuilder = Request.Builder()
            .url(origin + path)
            .header("Authorization", "Bearer $apiKey")
            .header("Accept", "application/json")
            .method(
                method,
                body ?: if (method in setOf("POST", "PUT", "PATCH")) {
                    ByteArray(0).toRequestBody()
                } else {
                    null
                },
            )
        idempotencyKey?.let { requestBuilder.header("Idempotency-Key", it) }
        return try {
            httpClient.newCall(requestBuilder.build()).execute().use { response ->
                val namespace = response.header("X-WebTag-Data-Namespace")
                val responseBody = response.body?.string().orEmpty()
                if (response.code !in acceptedStatusCodes && response.isSuccessful) {
                    return ApiResult.Failure(
                        ClassifiedFailure(
                            com.alpenl.webtag.share.contract.ErrorKind.INVALID_SUCCESS_PAYLOAD,
                            statusCode = response.code,
                        ),
                        namespace,
                    )
                }
                if (!response.isSuccessful) {
                    val errorCode = runCatching {
                        JSONObject(responseBody).optJSONObject("error")?.optString("error_code")
                            ?.takeIf { it.isNotEmpty() }
                    }.getOrNull()
                    return ApiResult.Failure(
                        ErrorClassifier.http(response.code, errorCode, response.header("Retry-After")),
                        namespace,
                    )
                }
                runCatching { ApiResult.Success(decode(responseBody, namespace), namespace) }
                    .getOrElse {
                        if (it is IdentityMismatchException) {
                            return ApiResult.Failure(
                                ClassifiedFailure(com.alpenl.webtag.share.contract.ErrorKind.IDENTITY_MISMATCH),
                                namespace,
                            )
                        }
                        ApiResult.Failure(
                            ClassifiedFailure(com.alpenl.webtag.share.contract.ErrorKind.INVALID_SUCCESS_PAYLOAD),
                            namespace,
                        )
                    }
            }
        } catch (error: IOException) {
            ApiResult.Failure(ErrorClassifier.transport(error), null)
        } catch (_: RuntimeException) {
            ApiResult.Failure(
                ClassifiedFailure(com.alpenl.webtag.share.contract.ErrorKind.INVALID_CLIENT_RESPONSE),
                null,
            )
        }
    }

    companion object {
        private fun isUuid(value: String): Boolean =
            runCatching { UUID.fromString(value) }.getOrNull()?.toString()?.equals(value, ignoreCase = true) == true

        private fun isNamespace(value: String): Boolean =
            value.length == 43 && value.all {
                it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '_' || it == '-'
            }

        fun defaultHttpClient(): OkHttpClient = OkHttpClient.Builder()
            .followRedirects(false)
            .followSslRedirects(false)
            .connectTimeout(2, TimeUnit.SECONDS)
            .readTimeout(2, TimeUnit.SECONDS)
            .writeTimeout(2, TimeUnit.SECONDS)
            .callTimeout(2, TimeUnit.SECONDS)
            .build()
    }
}
