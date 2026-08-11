package com.alpenl.webtag.share.queue

import android.content.Context
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import com.alpenl.webtag.share.contract.ErrorKind
import com.alpenl.webtag.share.contract.ActivationCommitOutcome
import com.alpenl.webtag.share.contract.ActiveSessionSnapshot
import com.alpenl.webtag.share.contract.CredentialConfig
import com.alpenl.webtag.share.contract.OriginNormalizer
import com.alpenl.webtag.share.contract.QueueError
import com.alpenl.webtag.share.contract.QueueIdentity
import com.alpenl.webtag.share.contract.QueueState
import com.alpenl.webtag.share.contract.RecentResult
import com.alpenl.webtag.share.contract.RefreshCommitOutcome
import com.alpenl.webtag.share.contract.RetryPolicy
import com.alpenl.webtag.share.contract.SessionIdentity
import com.alpenl.webtag.share.contract.SubmissionOutcome
import com.alpenl.webtag.share.contract.SubmitCommitOutcome
import com.alpenl.webtag.share.contract.SubmitResponse
import com.alpenl.webtag.share.data.QueueDatabase
import com.alpenl.webtag.share.data.QueueEntity
import com.alpenl.webtag.share.data.QueueRepository
import com.alpenl.webtag.share.network.ApiResult
import com.alpenl.webtag.share.network.ClassifiedFailure
import com.alpenl.webtag.share.network.WebTagApiClient
import com.alpenl.webtag.share.network.WebTagApi
import com.alpenl.webtag.share.security.AndroidKeystoreCipher
import com.alpenl.webtag.share.security.EncryptedCredentialStore
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext

class QueueScheduler(
    private val context: Context,
    private val repository: QueueRepository,
) {
    fun schedule(now: Long = System.currentTimeMillis()) {
        val nextAttemptAt = repository.nextScheduleAt(now) ?: return
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()
        val request = OneTimeWorkRequestBuilder<QueueDrainWorker>()
            .setConstraints(constraints)
            .setInitialDelay(delayMillis(nextAttemptAt, now), TimeUnit.MILLISECONDS)
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(
            UNIQUE_WORK_NAME,
            ExistingWorkPolicy.REPLACE,
            request,
        )
    }

    fun scheduleForegroundRecovery() {
        val now = System.currentTimeMillis()
        val nextAttemptAt = repository.nextScheduleAt(now) ?: return
        val recoveryAt = now + FOREGROUND_LEASE_MILLIS
        val request = OneTimeWorkRequestBuilder<QueueDrainWorker>()
            .setConstraints(
                Constraints.Builder()
                    .setRequiredNetworkType(NetworkType.CONNECTED)
                    .build(),
            )
            .setInitialDelay(
                delayMillis(minOf(nextAttemptAt, recoveryAt), now),
                TimeUnit.MILLISECONDS,
            )
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(
            UNIQUE_WORK_NAME,
            // A delayed unique request may already exist. REPLACE is required to
            // shorten it to the claimed row's lease deadline; the lease prevents
            // a cancelled worker from committing after another worker reclaims it.
            ExistingWorkPolicy.REPLACE,
            request,
        )
    }

    companion object {
        const val UNIQUE_WORK_NAME = "webtag-share-queue-drain"
        const val FOREGROUND_LEASE_MILLIS = 30_000L

        fun delayMillis(nextAttemptAt: Long?, now: Long): Long =
            ((nextAttemptAt ?: now) - now).coerceAtLeast(0)
    }
}

fun interface MobileClock {
    fun now(): Long
}

private val systemClock = MobileClock(System::currentTimeMillis)

sealed interface ConnectionResult {
    data class Activated(val configuration: CredentialConfig) : ConnectionResult
    data class Failed(val failure: ClassifiedFailure) : ConnectionResult
    data object IdentityChanged : ConnectionResult
    data object StorageFailure : ConnectionResult
}

sealed interface RefreshAttempt {
    data class Success(val response: SubmitResponse) : RefreshAttempt
    data class Failure(val failure: ClassifiedFailure) : RefreshAttempt
}

data class RefreshResult(
    val attempt: RefreshAttempt,
    val commitOutcome: RefreshCommitOutcome,
)

class ConnectionCoordinator(
    private val repository: QueueRepository,
    private val credentials: EncryptedCredentialStore,
    private val api: WebTagApi,
) {
    fun saveAndTest(rawOrigin: String, apiKey: String): ConnectionResult {
        val generation = repository.beginActivationAttempt()
        val normalized = runCatching { OriginNormalizer.normalize(rawOrigin) }.getOrElse {
            return latestFailure(generation, ErrorKind.INVALID_CLIENT_RESPONSE)
        }
        val response = runCatching { api.validateSession(normalized, apiKey) }
            .getOrElse { ApiResult.Failure(ClassifiedFailure(ErrorKind.INVALID_CLIENT_RESPONSE), null) }
        return when (response) {
            is ApiResult.Failure -> latestFailure(generation, response.failure)
            is ApiResult.Success -> activate(generation, normalized, apiKey, response.value)
        }
    }

    private fun activate(
        generation: Long,
        origin: String,
        apiKey: String,
        identity: SessionIdentity,
    ): ConnectionResult {
        if (!identity.canWrite()) return latestFailure(generation, ErrorKind.HTTP_403_SCOPE)
        if (identity.origin != origin) return latestFailure(generation, ErrorKind.IDENTITY_MISMATCH)
        if (!repository.isLatestActivationAttempt(generation)) return ConnectionResult.IdentityChanged
        val configuration = CredentialConfig(
            origin = origin,
            apiKey = apiKey,
            namespace = identity.clientDataNamespace,
            scopes = identity.scopes,
            activationRevision = generation,
        )
        if (runCatching { credentials.stage(configuration) }.isFailure) {
            return if (repository.isLatestActivationAttempt(generation)) {
                ConnectionResult.StorageFailure
            } else {
                ConnectionResult.IdentityChanged
            }
        }
        return when (repository.activateSessionIfLatest(identity, generation)) {
            ActivationCommitOutcome.IDENTITY_CHANGED -> {
                credentials.discardStaged(generation)
                ConnectionResult.IdentityChanged
            }
            ActivationCommitOutcome.APPLIED -> {
                val promoted = runCatching { credentials.promoteStaged(generation) }.getOrNull()
                    ?: runCatching {
                        repository.activeSessionSnapshot()?.let(credentials::recover)
                    }.getOrNull()
                if (promoted == configuration) ConnectionResult.Activated(configuration)
                else ConnectionResult.StorageFailure
            }
        }
    }

    private fun latestFailure(generation: Long, kind: ErrorKind): ConnectionResult =
        latestFailure(generation, ClassifiedFailure(kind))

    private fun latestFailure(generation: Long, failure: ClassifiedFailure): ConnectionResult =
        if (repository.isLatestActivationAttempt(generation)) ConnectionResult.Failed(failure)
        else ConnectionResult.IdentityChanged
}

class RefreshCoordinator(
    private val repository: QueueRepository,
    private val credentials: EncryptedCredentialStore,
    private val api: WebTagApi,
    private val clock: MobileClock = systemClock,
) {
    fun refresh(selected: RecentResult): RefreshResult {
        val activation = runCatching { repository.activeSessionSnapshot() }.getOrNull()
            ?: return identityChanged()
        val initial = repository.classifyRefresh(activation, selected.linkId)
        if (initial != RefreshCommitOutcome.APPLIED) {
            return RefreshResult(
                RefreshAttempt.Failure(ClassifiedFailure(ErrorKind.IDENTITY_MISMATCH)),
                initial,
            )
        }
        val config = runCatching { credentials.recover(activation) }.getOrNull()
            ?: return identityChanged()
        if (selected.identity != QueueIdentity(
                activation.identity.origin,
                activation.identity.clientDataNamespace,
            ) || config.activationRevision != activation.activationRevision
        ) {
            return identityChanged()
        }
        val attempt = when (val session = api.validateSession(config.origin, config.apiKey)) {
            is ApiResult.Failure -> RefreshAttempt.Failure(session.failure)
            is ApiResult.Success -> {
                val verified = session.value
                if (!verified.canWrite() || verified != activation.identity) {
                    RefreshAttempt.Failure(ClassifiedFailure(ErrorKind.IDENTITY_MISMATCH))
                } else {
                    when (val response = api.refresh(verified, config.apiKey, selected.linkId)) {
                        is ApiResult.Success -> RefreshAttempt.Success(response.value)
                        is ApiResult.Failure -> RefreshAttempt.Failure(response.failure)
                    }
                }
            }
        }
        val commitNow = clock.now()
        val commit = when (attempt) {
            is RefreshAttempt.Success -> repository.recordRefreshSuccess(
                activation,
                selected.linkId,
                attempt.response,
                commitNow,
            )
            is RefreshAttempt.Failure -> {
                val block = RetryPolicy.planRefreshBlock(
                    attempt.failure.kind,
                    attempt.failure.retryAfter,
                    commitNow,
                )
                if (block == null) {
                    repository.classifyRefresh(activation, selected.linkId)
                } else {
                    repository.recordRefreshBlocked(
                        activation,
                        selected.linkId,
                        block.refreshNotBefore,
                        block.reason,
                    )
                }
            }
        }
        return RefreshResult(attempt, commit)
    }

    private fun identityChanged(): RefreshResult = RefreshResult(
        RefreshAttempt.Failure(ClassifiedFailure(ErrorKind.IDENTITY_MISMATCH)),
        RefreshCommitOutcome.IDENTITY_CHANGED,
    )
}

class ShareSubmissionCoordinator(
    private val repository: QueueRepository,
    private val credentials: EncryptedCredentialStore,
    private val api: WebTagApi,
    private val scheduler: QueueScheduler,
    private val clock: MobileClock = systemClock,
) {
    fun submit(
        url: String,
        identity: SessionIdentity?,
        now: Long = System.currentTimeMillis(),
    ): SubmissionOutcome {
        if (identity == null || !identity.canWrite()) return SubmissionOutcome.ConfigurationRequired
        val activation = runCatching { repository.activeSessionSnapshot() }.getOrNull()
            ?: return SubmissionOutcome.ConfigurationRequired
        val config = runCatching { credentials.recover(activation) }.getOrNull()
            ?: return SubmissionOutcome.ConfigurationRequired
        if (config.sessionIdentity() != identity ||
            activation.identity != identity ||
            config.activationRevision != activation.activationRevision ||
            !identity.canWrite()
        ) {
            return SubmissionOutcome.ConfigurationRequired
        }
        val apiKey = config.apiKey
        val queueIdentity = QueueIdentity(identity.origin, identity.clientDataNamespace)
        val enqueueResult = runCatching {
            repository.enqueueOrReuse(url, queueIdentity, now)
        }.getOrElse {
            return localDataFailure()
        }
        runCatching { scheduler.schedule(now) }
        val entry = enqueueResult.entry
        if (enqueueResult.reused) {
            val state = QueueState.fromWire(entry.state)
            val leaseActive = entry.leaseOwner != null &&
                (entry.leaseExpiresAt ?: Long.MAX_VALUE) > now
            val retryNotDue = state == QueueState.RETRY_WAIT &&
                (entry.nextAttemptAt ?: now) > now
            if (leaseActive || retryNotDue) {
                runCatching { scheduler.schedule(now) }
                return SubmissionOutcome.Queued(
                    state,
                    QueueError(ErrorKind.NONE, null, null, entry.nextAttemptAt),
                )
            }
        }
        val owner = com.alpenl.webtag.share.contract.newUuid()
        if (!runCatching { repository.claimForEntry(entry, owner, now) }.getOrDefault(false)) {
            runCatching { scheduler.schedule(now) }
            return SubmissionOutcome.Queued(
                QueueState.PENDING_SUBMIT,
                QueueError(ErrorKind.LOCAL_DATA_UNREADABLE, null, null, now),
            )
        }
        runCatching { scheduler.scheduleForegroundRecovery() }
        val result = runCatching { api.submit(identity, apiKey, url, entry.idempotencyKey) }
            .getOrElse { ApiResult.Failure(ClassifiedFailure(ErrorKind.LOCAL_DATA_UNREADABLE), null) }
        return applyApiResult(entry, owner, activation, url, result)
    }

    fun drainOne(now: Long = System.currentTimeMillis()): Boolean {
        val activation = runCatching { repository.activeSessionSnapshot() }.getOrNull() ?: return false
        val config = runCatching { credentials.recover(activation) }.getOrNull() ?: return false
        val identity = activation.identity
        if (!identity.canWrite() || config.sessionIdentity() != identity ||
            config.activationRevision != activation.activationRevision
        ) {
            return false
        }
        val claimed = runCatching { repository.claimDue(activation, now) }.getOrNull() ?: return false
        val (entry, owner) = claimed
        val url = runCatching { repository.decode(entry) }.getOrElse {
            val plan = RetryPolicy.planRetry(ErrorKind.LOCAL_DATA_UNREADABLE, entry.attemptCount + 1, now)
            return repository.applyClaimed(
                entry,
                owner,
                plan.state,
                plan.firstFailedAt,
                entry.attemptCount + 1,
                null,
                plan.error?.kind,
                plan.error?.errorCode,
                plan.error?.httpStatus,
                null,
                null,
                activation,
                now,
            ) == SubmitCommitOutcome.APPLIED
        }
        val result = runCatching { api.submit(identity, config.apiKey, url, entry.idempotencyKey) }
            .getOrElse { ApiResult.Failure(ClassifiedFailure(ErrorKind.LOCAL_DATA_UNREADABLE), null) }
        return when (applyApiResult(entry, owner, activation, url, result)) {
            SubmissionOutcome.IdentityChanged, SubmissionOutcome.StaleClaim -> false
            else -> true
        }
    }

    private fun applyApiResult(
        entry: QueueEntity,
        owner: String,
        activation: ActiveSessionSnapshot,
        url: String,
        result: ApiResult<com.alpenl.webtag.share.contract.SubmitResponse>,
    ): SubmissionOutcome {
        val identity = activation.identity
        val now = clock.now()
        return when (result) {
            is ApiResult.Success -> {
                if (result.namespace != identity.clientDataNamespace) {
                    val plan = RetryPolicy.planRetry(ErrorKind.IDENTITY_MISMATCH, entry.attemptCount + 1, now)
                    val committed = runCatching {
                        repository.applyClaimed(
                            entry,
                            owner,
                            plan.state,
                            entry.firstFailedAt ?: now,
                            entry.attemptCount + 1,
                            null,
                            plan.error?.kind,
                            plan.error?.errorCode,
                            plan.error?.httpStatus,
                            null,
                            null,
                            activation,
                            now,
                        )
                    }.getOrElse { return localDataFailure() }
                    commitOutcome(committed) {
                        SubmissionOutcome.Blocked(plan.state, plan.error ?: localDataError())
                    }
                } else {
                    val response = result.value
                    val recent = RecentResult(
                        url = url,
                        linkId = response.linkId,
                        jobId = response.jobId,
                        status = response.status,
                        createdAt = now,
                        identity = QueueIdentity(identity.origin, identity.clientDataNamespace),
                        refreshNotBefore = null,
                        refreshBlockReason = null,
                    )
                    try {
                        val committed = repository.commitSuccess(entry, owner, recent, activation, url, now)
                        commitOutcome(committed) { SubmissionOutcome.Submitted(response) }
                    } catch (_: Exception) {
                        val markedPermanent = runCatching {
                            repository.applyClaimed(
                                entry,
                                owner,
                                QueueState.FAILED_PERMANENT,
                                entry.firstFailedAt ?: now,
                                entry.attemptCount + 1,
                                null,
                                ErrorKind.LOCAL_DATA_UNREADABLE,
                                null,
                                null,
                                null,
                                null,
                                activation,
                                now,
                            )
                        }.getOrElse { return localDataFailure() }
                        commitOutcome(markedPermanent) {
                            SubmissionOutcome.Blocked(QueueState.FAILED_PERMANENT, localDataError())
                        }
                    }
                }
            }
            is ApiResult.Failure -> {
                val failure = result.failure
                val plan = RetryPolicy.planRetry(
                    failure.kind,
                    entry.attemptCount + 1,
                    now,
                    failure.retryAfter,
                    failure.errorCode,
                )
                val firstFailedAt = entry.firstFailedAt ?: now
                val expiring = RetryPolicy.shouldExpire(firstFailedAt, now)
                val state = if (expiring && plan.state == QueueState.RETRY_WAIT) QueueState.EXPIRED else plan.state
                val nextAttempt = if (state == QueueState.RETRY_WAIT) plan.nextAttemptAt else null
                val committed = runCatching {
                    repository.applyClaimed(
                        entry,
                        owner,
                        state,
                        firstFailedAt,
                        entry.attemptCount + 1,
                        nextAttempt,
                        failure.kind,
                        failure.errorCode,
                        failure.statusCode,
                        null,
                        null,
                        activation,
                        now,
                    )
                }.getOrElse { return localDataFailure() }
                if (committed != SubmitCommitOutcome.APPLIED) return commitOutcome(committed) { localDataFailure() }
                if (state == QueueState.RETRY_WAIT) runCatching { scheduler.schedule(now) }
                val error = plan.error?.copy(nextAttemptAt = nextAttempt)
                    ?: com.alpenl.webtag.share.contract.QueueError(failure.kind, failure.errorCode, failure.statusCode, nextAttempt)
                if (state == QueueState.RETRY_WAIT) SubmissionOutcome.Queued(state, error)
                else SubmissionOutcome.Blocked(state, error)
            }
        }
    }

    private fun localDataError(): QueueError =
        QueueError(ErrorKind.LOCAL_DATA_UNREADABLE, null, null, null)

    private fun localDataFailure(): SubmissionOutcome =
        SubmissionOutcome.Blocked(QueueState.FAILED_PERMANENT, localDataError(), durable = false)

    private inline fun commitOutcome(
        outcome: SubmitCommitOutcome,
        applied: () -> SubmissionOutcome,
    ): SubmissionOutcome = when (outcome) {
        SubmitCommitOutcome.APPLIED -> applied()
        SubmitCommitOutcome.IDENTITY_CHANGED -> SubmissionOutcome.IdentityChanged
        SubmitCommitOutcome.STALE_CLAIM -> SubmissionOutcome.StaleClaim
    }
}

class QueueDrainWorker(
    context: Context,
    params: androidx.work.WorkerParameters,
) : androidx.work.CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val runtime = MobileRuntime.get(applicationContext)
        var processed = 0
        while (processed < 16 && runtime.coordinator.drainOne()) {
            processed += 1
        }
        val canSchedule = runtime.activeConfiguration() != null
        if (canSchedule) {
            runtime.scheduler.schedule()
        }
        return Result.success()
    }
}

class MobileRuntime private constructor(context: Context) {
    private val appContext = context.applicationContext
    private val cipher = AndroidKeystoreCipher("webtag-share-data-v1")
    val database = QueueDatabase.get(appContext)
    val repository = QueueRepository(database, cipher)
    val credentials = EncryptedCredentialStore(appContext)
    val api = WebTagApiClient()
    val scheduler = QueueScheduler(appContext, repository)
    val coordinator = ShareSubmissionCoordinator(repository, credentials, api, scheduler)
    val connectionCoordinator = ConnectionCoordinator(repository, credentials, api)
    val refreshCoordinator = RefreshCoordinator(repository, credentials, api)

    /** The same clock the coordinators commit against, so the UI never disagrees with a deadline. */
    val clock: MobileClock = systemClock

    fun activeConfiguration(): CredentialConfig? = runCatching {
        val snapshot = repository.activeSessionSnapshot() ?: return@runCatching null
        credentials.recover(snapshot)?.takeIf { configuration ->
            configuration.activationRevision == snapshot.activationRevision &&
                configuration.sessionIdentity() == snapshot.identity &&
                snapshot.identity.canWrite()
        }
    }.getOrNull()

    /** Completes an interrupted credential promotion, but never recreates Room authority from a file. */
    fun repairActiveIdentity(): Boolean = activeConfiguration() != null

    /**
     * Repairs the active identity and drains whatever the host was unable to send while it was
     * backgrounded, then hands the remainder back to the scheduler.
     *
     * This lives here rather than in `onStart` so the settings screen can await it and read the
     * durable state once it has finished, which is the only way the screen shows the result of a
     * drain it triggered itself.
     */
    suspend fun reconcileForeground(maxDrains: Int = FOREGROUND_DRAIN_BUDGET) {
        withContext(Dispatchers.IO) {
            repairActiveIdentity()
            var processed = 0
            try {
                while (isActive && processed < maxDrains) {
                    val drained = runCatching { coordinator.drainOne() }.getOrDefault(false)
                    if (!drained) break
                    processed += 1
                }
            } finally {
                runCatching { scheduler.schedule() }
            }
        }
    }

    companion object {
        /** Matches the background worker's budget: a foreground burst must not starve the UI. */
        const val FOREGROUND_DRAIN_BUDGET = 16

        @Volatile
        private var instance: MobileRuntime? = null

        fun get(context: Context): MobileRuntime = instance ?: synchronized(this) {
            instance ?: MobileRuntime(context).also { instance = it }
        }
    }
}
