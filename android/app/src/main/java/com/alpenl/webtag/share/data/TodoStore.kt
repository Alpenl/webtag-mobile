package com.alpenl.webtag.share.data

import androidx.room.Dao
import androidx.room.Entity
import androidx.room.Index
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import com.alpenl.webtag.share.contract.QueueIdentity
import com.alpenl.webtag.share.contract.newUuid
import com.alpenl.webtag.share.security.AndroidKeystoreCipher
import com.alpenl.webtag.share.security.EncryptedValue
import com.alpenl.webtag.share.todo.TodoCreate
import com.alpenl.webtag.share.todo.TodoItem
import com.alpenl.webtag.share.todo.TodoItemCodec
import com.alpenl.webtag.share.todo.TodoOriginKind
import com.alpenl.webtag.share.todo.TodoPatch
import org.json.JSONObject

@Entity(
    tableName = "todo_cache",
    primaryKeys = ["apiOrigin", "clientDataNamespace", "todoId"],
    indices = [Index(value = ["apiOrigin", "clientDataNamespace", "serverUpdatedAt"])],
)
data class TodoCacheEntity(
    val apiOrigin: String,
    val clientDataNamespace: String,
    val todoId: String,
    val payloadCiphertext: ByteArray,
    val payloadNonce: ByteArray,
    val cryptoVersion: Int,
    val serverUpdatedAt: Long,
    val fetchedAt: Long,
)

@Entity(
    tableName = "todo_outbox",
    indices = [
        Index(value = ["apiOrigin", "clientDataNamespace", "state", "nextAttemptAt"]),
        Index(value = ["apiOrigin", "clientDataNamespace", "targetTodoId"]),
    ],
)
data class TodoOutboxEntity(
    @androidx.room.PrimaryKey val operationId: String,
    val apiOrigin: String,
    val clientDataNamespace: String,
    val targetTodoId: String,
    val kind: String,
    val payloadCiphertext: ByteArray,
    val payloadNonce: ByteArray,
    val cryptoVersion: Int,
    val state: String,
    val attemptCount: Int,
    val nextAttemptAt: Long?,
    val lastErrorKind: String?,
    val leaseOwner: String?,
    val leaseExpiresAt: Long?,
    val createdAt: Long,
    val updatedAt: Long,
)

@Entity(
    tableName = "todo_sync_state",
    primaryKeys = ["apiOrigin", "clientDataNamespace"],
)
data class TodoSyncStateEntity(
    val apiOrigin: String,
    val clientDataNamespace: String,
    val todosEnabled: Boolean,
    val homeEnabled: Boolean,
    val inboxEnabled: Boolean,
    val lastSyncedAt: Long?,
)

enum class TodoOutboxKind(val wireValue: String) {
    CREATE("create"),
    PATCH("patch"),
    DELETE("delete"),
    ;

    companion object {
        fun fromWire(value: String): TodoOutboxKind = entries.firstOrNull { it.wireValue == value }
            ?: error("unknown TODO outbox kind: $value")
    }
}

enum class TodoOutboxState(val wireValue: String) {
    PENDING("pending"),
    RETRY_WAIT("retry_wait"),
    BLOCKED_AUTH("blocked_auth"),
    BLOCKED_SCOPE("blocked_scope"),
    BLOCKED_IDENTITY("blocked_identity"),
    CONFLICT("conflict"),
    FAILED_PERMANENT("failed_permanent"),
    ;

    companion object {
        fun fromWire(value: String): TodoOutboxState = entries.firstOrNull { it.wireValue == value }
            ?: error("unknown TODO outbox state: $value")
    }
}

@Dao
interface TodoDao {
    @Query(
        "SELECT * FROM todo_cache WHERE apiOrigin = :origin AND clientDataNamespace = :namespace " +
            "ORDER BY serverUpdatedAt DESC, todoId",
    )
    fun listCache(origin: String, namespace: String): List<TodoCacheEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsertCache(items: List<TodoCacheEntity>)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsertCache(item: TodoCacheEntity)

    @Query("DELETE FROM todo_cache WHERE apiOrigin = :origin AND clientDataNamespace = :namespace")
    fun deleteCacheForIdentity(origin: String, namespace: String)

    @Query(
        "DELETE FROM todo_cache WHERE apiOrigin = :origin AND clientDataNamespace = :namespace " +
            "AND todoId = :todoId",
    )
    fun deleteCachedTodo(origin: String, namespace: String, todoId: String)

    @Query(
        "SELECT * FROM todo_outbox WHERE apiOrigin = :origin AND clientDataNamespace = :namespace " +
            "ORDER BY createdAt, operationId",
    )
    fun listOutbox(origin: String, namespace: String): List<TodoOutboxEntity>

    @Query("SELECT * FROM todo_outbox WHERE operationId = :operationId")
    fun findOperation(operationId: String): TodoOutboxEntity?

    @Insert(onConflict = OnConflictStrategy.ABORT)
    fun insertOutbox(item: TodoOutboxEntity)

    @Query(
        "DELETE FROM todo_outbox WHERE operationId = :operationId AND leaseOwner = :owner",
    )
    fun deleteClaimedOutbox(operationId: String, owner: String): Int

    @Query(
        "SELECT COUNT(*) FROM todo_outbox WHERE operationId = :operationId AND leaseOwner = :owner",
    )
    fun ownsClaim(operationId: String, owner: String): Int

    @Query(
        "UPDATE todo_outbox SET targetTodoId = :serverTodoId, updatedAt = :updatedAt " +
            "WHERE apiOrigin = :origin AND clientDataNamespace = :namespace " +
            "AND targetTodoId = :localTodoId AND operationId <> :createOperationId",
    )
    fun rebindPendingOperations(
        origin: String,
        namespace: String,
        localTodoId: String,
        serverTodoId: String,
        createOperationId: String,
        updatedAt: Long,
    ): Int

    @Query(
        "SELECT * FROM todo_outbox WHERE apiOrigin = :origin AND clientDataNamespace = :namespace " +
            "AND state IN ('pending', 'retry_wait') " +
            "AND (nextAttemptAt IS NULL OR nextAttemptAt <= :now) " +
            "AND (leaseOwner IS NULL OR leaseExpiresAt IS NULL OR leaseExpiresAt <= :now) " +
            "ORDER BY createdAt, operationId LIMIT 1",
    )
    fun findDueOutbox(origin: String, namespace: String, now: Long): TodoOutboxEntity?

    @Query(
        "SELECT MIN(CASE " +
            "WHEN leaseOwner IS NOT NULL AND leaseExpiresAt > :now THEN leaseExpiresAt " +
            "WHEN nextAttemptAt IS NULL OR nextAttemptAt < :now THEN :now ELSE nextAttemptAt END) " +
            "FROM todo_outbox WHERE apiOrigin = :origin AND clientDataNamespace = :namespace " +
            "AND state IN ('pending', 'retry_wait')",
    )
    fun earliestOutboxAt(origin: String, namespace: String, now: Long): Long?

    @Query(
        "UPDATE todo_outbox SET state = :state, attemptCount = :attemptCount, " +
            "nextAttemptAt = :nextAttemptAt, lastErrorKind = :lastErrorKind, " +
            "leaseOwner = NULL, leaseExpiresAt = NULL, updatedAt = :updatedAt " +
            "WHERE operationId = :operationId AND leaseOwner = :owner",
    )
    fun updateOutboxState(
        operationId: String,
        owner: String,
        state: String,
        attemptCount: Int,
        nextAttemptAt: Long?,
        lastErrorKind: String?,
        updatedAt: Long,
    ): Int

    @Query(
        "UPDATE todo_outbox SET leaseOwner = :owner, leaseExpiresAt = :leaseExpiresAt, updatedAt = :now " +
            "WHERE operationId = :operationId AND apiOrigin = :origin AND clientDataNamespace = :namespace " +
            "AND state IN ('pending', 'retry_wait') " +
            "AND (nextAttemptAt IS NULL OR nextAttemptAt <= :now) " +
            "AND (leaseOwner IS NULL OR leaseExpiresAt IS NULL OR leaseExpiresAt <= :now)",
    )
    fun claim(
        operationId: String,
        origin: String,
        namespace: String,
        owner: String,
        leaseExpiresAt: Long,
        now: Long,
    ): Int

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsertSyncState(state: TodoSyncStateEntity)

    @Query(
        "SELECT * FROM todo_sync_state WHERE apiOrigin = :origin AND clientDataNamespace = :namespace",
    )
    fun syncState(origin: String, namespace: String): TodoSyncStateEntity?
}

data class TodoOutboxOperation(
    val entity: TodoOutboxEntity,
    val create: TodoCreate? = null,
    val patch: TodoPatch? = null,
)

data class ClaimedTodoOperation(
    val operation: TodoOutboxOperation,
    val owner: String,
)

data class TodoLocalSnapshot(
    val items: List<TodoItem>,
    val pendingOperations: Int,
    val blockedOperations: Int,
    val lastSyncedAt: Long?,
    val todosEnabled: Boolean?,
) {
    companion object {
        val EMPTY = TodoLocalSnapshot(
            items = emptyList(),
            pendingOperations = 0,
            blockedOperations = 0,
            lastSyncedAt = null,
            todosEnabled = null,
        )
    }
}

class TodoRepository(
    private val database: QueueDatabase,
    private val cipher: AndroidKeystoreCipher,
) {
    private val dao = database.todoDao()

    fun snapshot(identity: QueueIdentity): TodoLocalSnapshot {
        val cached = dao.listCache(identity.origin, identity.namespace)
            .mapNotNull { runCatching { decodeCache(it) }.getOrNull() }
        val operations = dao.listOutbox(identity.origin, identity.namespace)
            .mapNotNull { runCatching { decodeOperation(it) }.getOrNull() }
        val visible = applyOperations(cached, operations)
        val state = dao.syncState(identity.origin, identity.namespace)
        return TodoLocalSnapshot(
            items = visible,
            pendingOperations = operations.count {
                it.entity.state in setOf(TodoOutboxState.PENDING.wireValue, TodoOutboxState.RETRY_WAIT.wireValue)
            },
            blockedOperations = operations.count {
                it.entity.state !in setOf(TodoOutboxState.PENDING.wireValue, TodoOutboxState.RETRY_WAIT.wireValue)
            },
            lastSyncedAt = state?.lastSyncedAt,
            todosEnabled = state?.todosEnabled,
        )
    }

    fun replaceServerSnapshot(
        identity: QueueIdentity,
        items: List<TodoItem>,
        now: Long,
    ) = database.runInTransaction {
        dao.deleteCacheForIdentity(identity.origin, identity.namespace)
        if (items.isNotEmpty()) dao.upsertCache(items.map { encodeCache(identity, it, now) })
        val previous = dao.syncState(identity.origin, identity.namespace)
        dao.upsertSyncState(
            TodoSyncStateEntity(
                apiOrigin = identity.origin,
                clientDataNamespace = identity.namespace,
                todosEnabled = previous?.todosEnabled ?: true,
                homeEnabled = previous?.homeEnabled ?: false,
                inboxEnabled = previous?.inboxEnabled ?: false,
                lastSyncedAt = now,
            ),
        )
    }

    fun recordCapabilities(
        identity: QueueIdentity,
        todos: Boolean,
        home: Boolean,
        inbox: Boolean,
    ) {
        val previous = dao.syncState(identity.origin, identity.namespace)
        dao.upsertSyncState(
            TodoSyncStateEntity(
                apiOrigin = identity.origin,
                clientDataNamespace = identity.namespace,
                todosEnabled = todos,
                homeEnabled = home,
                inboxEnabled = inbox,
                lastSyncedAt = previous?.lastSyncedAt,
            ),
        )
    }

    fun stageCreate(
        identity: QueueIdentity,
        request: TodoCreate,
        now: Long = System.currentTimeMillis(),
    ): String {
        require(request.text.isNotBlank() && request.text.length <= 4096)
        val localTodoId = newUuid()
        val operationId = newUuid()
        insertOperation(
            identity = identity,
            operationId = operationId,
            targetTodoId = localTodoId,
            kind = TodoOutboxKind.CREATE,
            payload = JSONObject()
                .put("text", request.text)
                .put("due_at", request.dueAt ?: JSONObject.NULL)
                .toString(),
            now = now,
        )
        return localTodoId
    }

    fun stagePatch(
        identity: QueueIdentity,
        todoId: String,
        patch: TodoPatch,
        now: Long = System.currentTimeMillis(),
    ): String {
        val operationId = newUuid()
        val payload = JSONObject()
        patch.text?.let { payload.put("text", it) }
        payload.put("due_at_set", patch.dueAtSet)
        if (patch.dueAtSet) payload.put("due_at", patch.dueAt ?: JSONObject.NULL)
        patch.done?.let { payload.put("done", it) }
        patch.expectedHostRevision?.let { payload.put("expected_host_revision", it) }
        require(payload.length() > 1 || !payload.has("due_at_set")) { "empty TODO patch" }
        insertOperation(identity, operationId, todoId, TodoOutboxKind.PATCH, payload.toString(), now)
        return operationId
    }

    fun stageDelete(
        identity: QueueIdentity,
        todoId: String,
        now: Long = System.currentTimeMillis(),
    ): String {
        val operationId = newUuid()
        insertOperation(identity, operationId, todoId, TodoOutboxKind.DELETE, "{}", now)
        return operationId
    }

    fun claimDue(
        identity: QueueIdentity,
        now: Long,
        leaseMillis: Long,
    ): ClaimedTodoOperation? = database.runInTransaction(java.util.concurrent.Callable {
        val entity = dao.findDueOutbox(identity.origin, identity.namespace, now) ?: return@Callable null
        val owner = newUuid()
        if (dao.claim(
                entity.operationId,
                identity.origin,
                identity.namespace,
                owner,
                now + leaseMillis,
                now,
            ) != 1
        ) return@Callable null
        ClaimedTodoOperation(
            operation = decodeOperation(
                entity.copy(leaseOwner = owner, leaseExpiresAt = now + leaseMillis, updatedAt = now),
            ),
            owner = owner,
        )
    })

    fun nextScheduleAt(identity: QueueIdentity, now: Long): Long? =
        dao.earliestOutboxAt(identity.origin, identity.namespace, now)

    fun completeCreate(operation: TodoOutboxOperation, owner: String, created: TodoItem, now: Long): Boolean =
        database.runInTransaction(java.util.concurrent.Callable {
            if (dao.ownsClaim(operation.entity.operationId, owner) != 1) return@Callable false
            val identity = operation.entity.identity()
            dao.upsertCache(encodeCache(identity, created, now))
            dao.rebindPendingOperations(
                origin = identity.origin,
                namespace = identity.namespace,
                localTodoId = operation.entity.targetTodoId,
                serverTodoId = created.id,
                createOperationId = operation.entity.operationId,
                updatedAt = now,
            )
            dao.deleteClaimedOutbox(operation.entity.operationId, owner) == 1
        })

    fun completePatch(operation: TodoOutboxOperation, owner: String, updated: TodoItem, now: Long): Boolean =
        database.runInTransaction(java.util.concurrent.Callable {
            if (dao.ownsClaim(operation.entity.operationId, owner) != 1) return@Callable false
            dao.upsertCache(encodeCache(operation.entity.identity(), updated, now))
            dao.deleteClaimedOutbox(operation.entity.operationId, owner) == 1
        })

    fun completeDelete(operation: TodoOutboxOperation, owner: String): Boolean =
        database.runInTransaction(java.util.concurrent.Callable {
        if (dao.ownsClaim(operation.entity.operationId, owner) != 1) return@Callable false
        val entity = operation.entity
        dao.deleteCachedTodo(entity.apiOrigin, entity.clientDataNamespace, entity.targetTodoId)
        dao.deleteClaimedOutbox(entity.operationId, owner) == 1
    })

    fun discardOperation(operationId: String, owner: String): Boolean =
        dao.deleteClaimedOutbox(operationId, owner) == 1

    fun updateOperation(
        entity: TodoOutboxEntity,
        owner: String,
        state: TodoOutboxState,
        nextAttemptAt: Long?,
        errorKind: String?,
        now: Long,
    ): Boolean {
        return dao.updateOutboxState(
            operationId = entity.operationId,
            owner = owner,
            state = state.wireValue,
            attemptCount = entity.attemptCount + 1,
            nextAttemptAt = nextAttemptAt,
            lastErrorKind = errorKind,
            updatedAt = now,
        ) == 1
    }

    private fun insertOperation(
        identity: QueueIdentity,
        operationId: String,
        targetTodoId: String,
        kind: TodoOutboxKind,
        payload: String,
        now: Long,
    ) {
        val aad = outboxAad(operationId, identity)
        val encrypted = cipher.encrypt(payload, aad)
        dao.insertOutbox(
            TodoOutboxEntity(
                operationId = operationId,
                apiOrigin = identity.origin,
                clientDataNamespace = identity.namespace,
                targetTodoId = targetTodoId,
                kind = kind.wireValue,
                payloadCiphertext = encrypted.ciphertext,
                payloadNonce = encrypted.nonce,
                cryptoVersion = encrypted.version,
                state = TodoOutboxState.PENDING.wireValue,
                attemptCount = 0,
                nextAttemptAt = null,
                lastErrorKind = null,
                leaseOwner = null,
                leaseExpiresAt = null,
                createdAt = now,
                updatedAt = now,
            ),
        )
    }

    private fun encodeCache(identity: QueueIdentity, item: TodoItem, fetchedAt: Long): TodoCacheEntity {
        val encrypted = cipher.encrypt(TodoItemCodec.encode(item), cacheAad(item.id, identity))
        return TodoCacheEntity(
            apiOrigin = identity.origin,
            clientDataNamespace = identity.namespace,
            todoId = item.id,
            payloadCiphertext = encrypted.ciphertext,
            payloadNonce = encrypted.nonce,
            cryptoVersion = encrypted.version,
            serverUpdatedAt = item.updatedAt,
            fetchedAt = fetchedAt,
        )
    }

    private fun decodeCache(entity: TodoCacheEntity): TodoItem {
        val identity = entity.identity()
        val raw = cipher.decrypt(
            EncryptedValue(entity.payloadCiphertext, entity.payloadNonce, entity.cryptoVersion),
            cacheAad(entity.todoId, identity),
        )
        val item = TodoItemCodec.decode(raw)
        require(item.id == entity.todoId) { "TODO cache identity mismatch" }
        return item
    }

    private fun decodeOperation(entity: TodoOutboxEntity): TodoOutboxOperation {
        val raw = cipher.decrypt(
            EncryptedValue(entity.payloadCiphertext, entity.payloadNonce, entity.cryptoVersion),
            outboxAad(entity.operationId, entity.identity()),
        )
        val json = JSONObject(raw)
        return when (TodoOutboxKind.fromWire(entity.kind)) {
            TodoOutboxKind.CREATE -> TodoOutboxOperation(
                entity = entity,
                create = TodoCreate(
                    text = json.getString("text"),
                    dueAt = if (json.isNull("due_at")) null else json.getLong("due_at"),
                ),
            )
            TodoOutboxKind.PATCH -> TodoOutboxOperation(
                entity = entity,
                patch = TodoPatch(
                    text = json.optString("text").takeIf { json.has("text") },
                    dueAt = if (!json.optBoolean("due_at_set") || json.isNull("due_at")) null else json.getLong("due_at"),
                    dueAtSet = json.optBoolean("due_at_set"),
                    done = json.optBoolean("done").takeIf { json.has("done") },
                    expectedHostRevision = json.optLong("expected_host_revision").takeIf {
                        json.has("expected_host_revision")
                    },
                ),
            )
            TodoOutboxKind.DELETE -> TodoOutboxOperation(entity = entity)
        }
    }

    private fun applyOperations(
        cached: List<TodoItem>,
        operations: List<TodoOutboxOperation>,
    ): List<TodoItem> {
        val items = cached.associateByTo(linkedMapOf(), TodoItem::id)
        for (operation in operations) {
            val entity = operation.entity
            val active = entity.state in setOf(
                TodoOutboxState.PENDING.wireValue,
                TodoOutboxState.RETRY_WAIT.wireValue,
                TodoOutboxState.BLOCKED_AUTH.wireValue,
                TodoOutboxState.BLOCKED_SCOPE.wireValue,
            )
            if (!active) continue
            when (TodoOutboxKind.fromWire(entity.kind)) {
                TodoOutboxKind.CREATE -> {
                    val request = requireNotNull(operation.create)
                    items[entity.targetTodoId] = TodoItem(
                        id = entity.targetTodoId,
                        text = request.text,
                        dueAt = request.dueAt,
                        done = false,
                        originKind = TodoOriginKind.STANDALONE,
                        originHostKind = null,
                        originHostId = null,
                        originRefJson = null,
                        hostRevision = 0,
                        completedAt = null,
                        createdAt = entity.createdAt,
                        updatedAt = entity.updatedAt,
                        expired = false,
                        localOnly = true,
                        pending = true,
                    )
                }
                TodoOutboxKind.PATCH -> items[entity.targetTodoId]?.let { current ->
                    val patch = requireNotNull(operation.patch)
                    items[entity.targetTodoId] = current.copy(
                        text = patch.text ?: current.text,
                        dueAt = if (patch.dueAtSet) patch.dueAt else current.dueAt,
                        done = patch.done ?: current.done,
                        completedAt = when (patch.done) {
                            true -> entity.createdAt
                            false -> null
                            null -> current.completedAt
                        },
                        pending = true,
                    )
                }
                TodoOutboxKind.DELETE -> items.remove(entity.targetTodoId)
            }
        }
        return items.values.toList()
    }

    private fun TodoCacheEntity.identity() = QueueIdentity(apiOrigin, clientDataNamespace)
    private fun TodoOutboxEntity.identity() = QueueIdentity(apiOrigin, clientDataNamespace)
    private fun cacheAad(todoId: String, identity: QueueIdentity): String =
        "todo-cache-v1|$todoId|${identity.origin}|${identity.namespace}"
    private fun outboxAad(operationId: String, identity: QueueIdentity): String =
        "todo-outbox-v1|$operationId|${identity.origin}|${identity.namespace}"
}
