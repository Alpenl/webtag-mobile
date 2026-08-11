package com.alpenl.webtag.share.contract

import java.util.UUID

enum class QueueState(val wireValue: String) {
    PENDING_SUBMIT("pending_submit"),
    RETRY_WAIT("retry_wait"),
    BLOCKED_AUTH("blocked_auth"),
    BLOCKED_SCOPE("blocked_scope"),
    BLOCKED_QUOTA("blocked_quota"),
    BLOCKED_IDENTITY("blocked_identity"),
    FAILED_PERMANENT("failed_permanent"),
    EXPIRED("expired"),

    ;

    companion object {
        fun fromWire(value: String): QueueState = entries.firstOrNull {
            it.wireValue == value || it.name == value
        } ?: error("unknown queue state: $value")
    }
}

enum class ErrorKind {
    NONE,
    NO_NETWORK,
    DNS_TIMEOUT,
    CONNECTION_RESET,
    CLIENT_DEADLINE,
    TLS_TRUST_FAILURE,
    HTTP_408,
    HTTP_425,
    HTTP_409,
    HTTP_429_RATE_LIMIT,
    HTTP_429_COOLDOWN,
    HTTP_429_QUOTA,
    HTTP_401,
    HTTP_403_SCOPE,
    HTTP_5XX,
    INVALID_SUCCESS_PAYLOAD,
    INVALID_CLIENT_RESPONSE,
    IDENTITY_MISMATCH,
    LOCAL_DATA_UNREADABLE,
}

/**
 * Native share sources already flattened into the frozen extraction order.
 *
 * [texts] is a list rather than a single blob because a native share can carry several independent
 * text sources (Android EXTRA_TEXT plus every ClipData item text). Modelling them as one optional
 * string is what allowed the earlier "first non-empty text wins" behaviour to silently drop URLs.
 */
data class SharePayload(
    val structuredUrls: List<String>,
    val texts: List<String>,
)

/**
 * A share candidate keeps the two representations strictly apart: [submissionValue] is the verbatim
 * URL that every submit/restore path must use, [displayLabel] is a lossy host+path rendering that is
 * safe to show. A label can never be turned back into a URL, so nothing may reconstruct one from it.
 */
data class UrlCandidate(
    val submissionValue: String,
    val displayLabel: String,
)

data class SessionIdentity(
    val origin: String,
    val clientDataNamespace: String,
    val scopes: Set<String>,
    val representationContract: String,
) {
    fun canWrite(): Boolean = "write" in scopes && representationContract == "v2"
}

data class SubmitResponse(
    val linkId: String,
    val status: String,
    val jobId: String?,
)

data class CredentialConfig(
    val origin: String,
    val apiKey: String,
    val namespace: String,
    val scopes: Set<String>,
    val activationRevision: Long = LEGACY_ACTIVATION_REVISION,
) {
    fun sessionIdentity(): SessionIdentity = SessionIdentity(
        origin = origin,
        clientDataNamespace = namespace,
        scopes = scopes,
        representationContract = "v2",
    )
}

const val LEGACY_ACTIVATION_REVISION = 1L

data class ActiveSessionSnapshot(
    val identity: SessionIdentity,
    val activationRevision: Long,
)

enum class SubmitCommitOutcome {
    APPLIED,
    IDENTITY_CHANGED,
    STALE_CLAIM,
}

enum class RefreshCommitOutcome {
    APPLIED,
    IDENTITY_CHANGED,
    RECENT_REPLACED,
}

enum class ActivationCommitOutcome {
    APPLIED,
    IDENTITY_CHANGED,
}

data class QueueIdentity(
    val origin: String,
    val namespace: String,
)

data class QueueError(
    val kind: ErrorKind,
    val errorCode: String?,
    val httpStatus: Int?,
    val nextAttemptAt: Long?,
)

data class RetryPlan(
    val state: QueueState,
    val nextAttemptAt: Long?,
    val firstFailedAt: Long?,
    val error: QueueError?,
)

data class QueueView(
    val id: String,
    val url: String,
    val state: QueueState,
    val firstFailedAt: Long?,
    val nextAttemptAt: Long?,
    val errorKind: ErrorKind?,
    val identity: QueueIdentity? = null,
)

data class RecentResult(
    val url: String,
    val linkId: String,
    val jobId: String?,
    val status: String,
    val createdAt: Long,
    val identity: QueueIdentity,
    val refreshNotBefore: Long?,
    val refreshBlockReason: String?,
    val isIdentityMismatch: Boolean = false,
)

sealed interface SubmissionOutcome {
    data class Submitted(val response: SubmitResponse) : SubmissionOutcome
    data class Queued(val state: QueueState, val error: QueueError) : SubmissionOutcome
    data class Blocked(
        val state: QueueState,
        val error: QueueError,
        val durable: Boolean = true,
    ) : SubmissionOutcome
    data object ConfigurationRequired : SubmissionOutcome
    data object IdentityChanged : SubmissionOutcome
    data object StaleClaim : SubmissionOutcome
    data object NoCandidate : SubmissionOutcome
}

fun newUuid(): String = UUID.randomUUID().toString()
