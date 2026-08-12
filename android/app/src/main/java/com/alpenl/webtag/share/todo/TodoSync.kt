package com.alpenl.webtag.share.todo

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.alpenl.webtag.share.contract.ActiveSessionSnapshot
import com.alpenl.webtag.share.contract.CredentialConfig
import com.alpenl.webtag.share.contract.ErrorKind
import com.alpenl.webtag.share.contract.QueueIdentity
import com.alpenl.webtag.share.data.TodoOutboxKind
import com.alpenl.webtag.share.data.TodoOutboxOperation
import com.alpenl.webtag.share.data.ClaimedTodoOperation
import com.alpenl.webtag.share.data.TodoOutboxState
import com.alpenl.webtag.share.data.TodoRepository
import com.alpenl.webtag.share.network.ApiResult
import com.alpenl.webtag.share.network.ClassifiedFailure
import com.alpenl.webtag.share.network.WebTagCompanionApi
import com.alpenl.webtag.share.queue.MobileClock
import com.alpenl.webtag.share.queue.MobileRuntime
import java.util.concurrent.TimeUnit

class TodoSyncScheduler(
    private val context: Context,
    private val repository: TodoRepository,
    private val activeIdentity: () -> QueueIdentity?,
) {
    fun schedule(now: Long = System.currentTimeMillis()) {
        val identity = activeIdentity() ?: return
        val next = repository.nextScheduleAt(identity, now) ?: return
        val request = OneTimeWorkRequestBuilder<TodoSyncWorker>()
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setInitialDelay((next - now).coerceAtLeast(0), TimeUnit.MILLISECONDS)
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(
            UNIQUE_WORK_NAME,
            ExistingWorkPolicy.REPLACE,
            request,
        )
    }

    companion object {
        const val UNIQUE_WORK_NAME = "webtag-todo-sync"
    }
}

data class TodoSyncResult(
    val pushed: Int,
    val pulled: Boolean,
    val error: ErrorKind? = null,
)

class TodoSyncCoordinator(
    private val repository: TodoRepository,
    private val api: WebTagCompanionApi,
    private val activeConfiguration: () -> CredentialConfig?,
    private val activeSession: () -> ActiveSessionSnapshot?,
    private val clock: MobileClock,
) {
    fun synchronize(maxPushes: Int = 32): TodoSyncResult {
        val configuration = activeConfiguration() ?: return TodoSyncResult(0, false, ErrorKind.HTTP_401)
        val activation = activeSession() ?: return TodoSyncResult(0, false, ErrorKind.IDENTITY_MISMATCH)
        if (!configuration.matches(activation)) return TodoSyncResult(0, false, ErrorKind.IDENTITY_MISMATCH)
        val identity = QueueIdentity(configuration.origin, configuration.namespace)

        when (val capabilities = api.capabilities(activation.identity, configuration.apiKey)) {
            is ApiResult.Failure -> return TodoSyncResult(0, false, capabilities.failure.kind)
            is ApiResult.Success -> {
                if (!stillCurrent(activation)) return TodoSyncResult(0, false, ErrorKind.IDENTITY_MISMATCH)
                repository.recordCapabilities(
                    identity,
                    capabilities.value.todos,
                    capabilities.value.home,
                    capabilities.value.inbox,
                )
                if (!capabilities.value.todos) return TodoSyncResult(0, false)
            }
        }

        var pushed = 0
        while (pushed < maxPushes) {
            val claimed = repository.claimDue(identity, clock.now(), LEASE_MILLIS) ?: break
            val result = send(configuration, activation, claimed)
            if (!result) break
            pushed += 1
        }

        return when (val todos = api.listTodos(activation.identity, configuration.apiKey)) {
            is ApiResult.Failure -> TodoSyncResult(pushed, false, todos.failure.kind)
            is ApiResult.Success -> {
                if (!stillCurrent(activation)) return TodoSyncResult(pushed, false, ErrorKind.IDENTITY_MISMATCH)
                repository.replaceServerSnapshot(identity, todos.value, clock.now())
                TodoSyncResult(pushed, true)
            }
        }
    }

    private fun send(
        configuration: CredentialConfig,
        activation: ActiveSessionSnapshot,
        claimed: ClaimedTodoOperation,
    ): Boolean {
        val operation = claimed.operation
        val result = when (TodoOutboxKind.fromWire(operation.entity.kind)) {
            TodoOutboxKind.CREATE -> api.createTodo(
                activation.identity,
                configuration.apiKey,
                requireNotNull(operation.create),
                operation.entity.operationId,
            )
            TodoOutboxKind.PATCH -> api.patchTodo(
                activation.identity,
                configuration.apiKey,
                operation.entity.targetTodoId,
                requireNotNull(operation.patch),
                operation.entity.operationId,
            )
            TodoOutboxKind.DELETE -> api.deleteTodo(
                activation.identity,
                configuration.apiKey,
                operation.entity.targetTodoId,
                operation.entity.operationId,
            )
        }
        if (!stillCurrent(activation)) {
            repository.updateOperation(
                operation.entity,
                claimed.owner,
                TodoOutboxState.BLOCKED_IDENTITY,
                null,
                ErrorKind.IDENTITY_MISMATCH.name,
                clock.now(),
            )
            return false
        }
        return when (result) {
            is ApiResult.Success -> {
                val now = clock.now()
                when (TodoOutboxKind.fromWire(operation.entity.kind)) {
                    TodoOutboxKind.CREATE -> repository.completeCreate(operation, claimed.owner, result.value as TodoItem, now)
                    TodoOutboxKind.PATCH -> repository.completePatch(operation, claimed.owner, result.value as TodoItem, now)
                    TodoOutboxKind.DELETE -> repository.completeDelete(operation, claimed.owner)
                }
            }
            is ApiResult.Failure -> handleFailure(claimed, result.failure, activation, configuration)
        }
    }

    private fun handleFailure(
        claimed: ClaimedTodoOperation,
        failure: ClassifiedFailure,
        activation: ActiveSessionSnapshot,
        configuration: CredentialConfig,
    ): Boolean {
        val operation = claimed.operation
        if (failure.kind == ErrorKind.HTTP_409 && operation.patch?.done != null) {
            val list = api.listTodos(activation.identity, configuration.apiKey)
            if (list is ApiResult.Success && stillCurrent(activation)) {
                val current = list.value.firstOrNull { it.id == operation.entity.targetTodoId }
                if (TodoConflictPolicy.resolveDesiredDone(operation.patch.done, current) == TodoConflictResolution.CONVERGED) {
                    repository.discardOperation(operation.entity.operationId, claimed.owner)
                    repository.replaceServerSnapshot(
                        QueueIdentity(configuration.origin, configuration.namespace),
                        list.value,
                        clock.now(),
                    )
                    return true
                }
            }
            repository.updateOperation(
                operation.entity,
                claimed.owner,
                TodoOutboxState.CONFLICT,
                null,
                failure.kind.name,
                clock.now(),
            )
            return false
        }
        val state = stateFor(failure.kind)
        val next = if (state == TodoOutboxState.RETRY_WAIT) retryAt(operation.entity.attemptCount + 1, clock.now()) else null
        repository.updateOperation(operation.entity, claimed.owner, state, next, failure.kind.name, clock.now())
        return false
    }

    private fun stillCurrent(expected: ActiveSessionSnapshot): Boolean = activeSession() == expected

    private fun CredentialConfig.matches(snapshot: ActiveSessionSnapshot): Boolean =
        activationRevision == snapshot.activationRevision && sessionIdentity() == snapshot.identity

    companion object {
        const val LEASE_MILLIS = 30_000L
        fun stateFor(kind: ErrorKind): TodoOutboxState = when (kind) {
            ErrorKind.NO_NETWORK,
            ErrorKind.DNS_TIMEOUT,
            ErrorKind.CONNECTION_RESET,
            ErrorKind.CLIENT_DEADLINE,
            ErrorKind.HTTP_408,
            ErrorKind.HTTP_425,
            ErrorKind.HTTP_429_RATE_LIMIT,
            ErrorKind.HTTP_5XX,
            -> TodoOutboxState.RETRY_WAIT
            ErrorKind.HTTP_401 -> TodoOutboxState.BLOCKED_AUTH
            ErrorKind.HTTP_403_SCOPE -> TodoOutboxState.BLOCKED_SCOPE
            ErrorKind.IDENTITY_MISMATCH -> TodoOutboxState.BLOCKED_IDENTITY
            ErrorKind.HTTP_409 -> TodoOutboxState.CONFLICT
            else -> TodoOutboxState.FAILED_PERMANENT
        }

        fun retryAt(attempt: Int, now: Long): Long {
            val exponent = (attempt - 1).coerceIn(0, 10)
            val delay = (30_000L shl exponent).coerceAtMost(TimeUnit.HOURS.toMillis(6))
            return now + delay
        }
    }
}

class TodoSyncWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val runtime = MobileRuntime.get(applicationContext)
        val result = runtime.todoSyncCoordinator.synchronize()
        runtime.todoScheduler.schedule()
        return if (result.error in setOf(
                ErrorKind.NO_NETWORK,
                ErrorKind.DNS_TIMEOUT,
                ErrorKind.CONNECTION_RESET,
                ErrorKind.CLIENT_DEADLINE,
                ErrorKind.HTTP_5XX,
            )
        ) Result.retry() else Result.success()
    }
}
