package com.alpenl.webtag.share.data

import android.content.Context
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import com.alpenl.webtag.share.contract.ErrorKind
import com.alpenl.webtag.share.contract.ActivationCommitOutcome
import com.alpenl.webtag.share.contract.ActiveSessionSnapshot
import com.alpenl.webtag.share.contract.LEGACY_ACTIVATION_REVISION
import com.alpenl.webtag.share.contract.OriginNormalizer
import com.alpenl.webtag.share.contract.QueueState
import com.alpenl.webtag.share.contract.QueueView
import com.alpenl.webtag.share.contract.RecentResult
import com.alpenl.webtag.share.contract.QueueIdentity
import com.alpenl.webtag.share.contract.RefreshCommitOutcome
import com.alpenl.webtag.share.contract.SessionIdentity
import com.alpenl.webtag.share.contract.SubmitCommitOutcome
import com.alpenl.webtag.share.contract.newUuid
import com.alpenl.webtag.share.security.AndroidKeystoreCipher
import org.json.JSONArray
import java.security.MessageDigest

@Entity(
    tableName = "queue_entries",
    indices = [
        androidx.room.Index(value = ["state", "nextAttemptAt"]),
        androidx.room.Index(value = ["leaseOwner"]),
    ],
)
data class QueueEntity(
    @androidx.room.PrimaryKey val id: String,
    val schemaVersion: Int,
    val urlCiphertext: ByteArray,
    val urlNonce: ByteArray,
    val cryptoVersion: Int,
    val idempotencyKey: String,
    val requestFingerprint: String,
    val apiOrigin: String,
    val clientDataNamespace: String,
    val state: String,
    val createdAt: Long,
    val firstFailedAt: Long?,
    val attemptCount: Int,
    val nextAttemptAt: Long?,
    val lastErrorKind: String?,
    val lastErrorCode: String?,
    val lastHttpStatus: Int?,
    val linkId: String?,
    val jobId: String?,
    val leaseOwner: String?,
    val leaseExpiresAt: Long?,
    val updatedAt: Long,
)

data class QueueEnqueueResult(
    val entry: QueueEntity,
    val reused: Boolean,
)

@Entity(tableName = "recent_results")
data class RecentResultEntity(
    @androidx.room.PrimaryKey val id: Int = 1,
    val urlCiphertext: ByteArray,
    val urlNonce: ByteArray,
    val cryptoVersion: Int,
    val linkId: String,
    val jobId: String?,
    val status: String,
    val createdAt: Long,
    val apiOrigin: String,
    val clientDataNamespace: String,
    val refreshNotBefore: Long?,
    val refreshBlockReason: String?,
)

@Entity(tableName = "active_session")
data class ActiveSessionEntity(
    @androidx.room.PrimaryKey val id: Int = 1,
    val apiOrigin: String,
    val clientDataNamespace: String,
    val scopesJson: String,
    val representationContract: String,
    val activationRevision: Long,
)

@Entity(tableName = "activation_state")
data class ActivationStateEntity(
    @androidx.room.PrimaryKey val id: Int = 1,
    val latestAttemptGeneration: Long,
)

@Dao
interface QueueDao {
    @Insert(onConflict = OnConflictStrategy.ABORT)
    fun insert(entry: QueueEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsertRecent(result: RecentResultEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsertActiveSession(session: ActiveSessionEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsertActivationState(state: ActivationStateEntity)

    @Query("SELECT * FROM active_session WHERE id = 1")
    fun activeSession(): ActiveSessionEntity?

    @Query("SELECT * FROM activation_state WHERE id = 1")
    fun activationState(): ActivationStateEntity?

    @Query(
        "SELECT * FROM queue_entries " +
            "WHERE state IN ('pending_submit', 'retry_wait', 'PENDING_SUBMIT', 'RETRY_WAIT') " +
            "AND (nextAttemptAt IS NULL OR nextAttemptAt <= :now) " +
            "AND apiOrigin = :apiOrigin AND clientDataNamespace = :namespace " +
            "AND (leaseOwner IS NULL OR leaseExpiresAt <= :now) " +
            "ORDER BY CASE WHEN nextAttemptAt IS NULL THEN 0 ELSE 1 END, nextAttemptAt, createdAt LIMIT 1",
    )
    fun findDue(apiOrigin: String, namespace: String, now: Long): QueueEntity?

    @Query(
        "UPDATE queue_entries SET leaseOwner = :owner, leaseExpiresAt = :expiresAt, " +
            "updatedAt = :now WHERE id = :id " +
            "AND apiOrigin = :apiOrigin AND clientDataNamespace = :namespace " +
            "AND state IN ('pending_submit', 'retry_wait', 'PENDING_SUBMIT', 'RETRY_WAIT') " +
            "AND (nextAttemptAt IS NULL OR nextAttemptAt <= :now) " +
            "AND (leaseOwner IS NULL OR leaseExpiresAt <= :now)",
    )
    fun claim(
        id: String,
        apiOrigin: String,
        namespace: String,
        owner: String,
        expiresAt: Long,
        now: Long,
    ): Int

    @Query(
        "UPDATE queue_entries SET state = :state, firstFailedAt = :firstFailedAt, " +
            "attemptCount = :attemptCount, nextAttemptAt = :nextAttemptAt, " +
            "lastErrorKind = :lastErrorKind, lastErrorCode = :lastErrorCode, " +
            "lastHttpStatus = :lastHttpStatus, linkId = :linkId, jobId = :jobId, " +
            "leaseOwner = NULL, leaseExpiresAt = NULL, updatedAt = :updatedAt " +
            "WHERE id = :id AND apiOrigin = :queueOrigin AND clientDataNamespace = :queueNamespace " +
            "AND leaseOwner = :owner AND leaseExpiresAt > :updatedAt " +
            "AND EXISTS (SELECT 1 FROM active_session WHERE id = 1 " +
            "AND apiOrigin = :activeOrigin AND clientDataNamespace = :activeNamespace " +
            "AND activationRevision = :activationRevision)",
    )
    fun updateClaimed(
        id: String,
        queueOrigin: String,
        queueNamespace: String,
        owner: String,
        state: String,
        firstFailedAt: Long?,
        attemptCount: Int,
        nextAttemptAt: Long?,
        lastErrorKind: String?,
        lastErrorCode: String?,
        lastHttpStatus: Int?,
        linkId: String?,
        jobId: String?,
        activeOrigin: String,
        activeNamespace: String,
        activationRevision: Long,
        updatedAt: Long,
    ): Int

    @Query(
        "DELETE FROM queue_entries WHERE id = :id " +
            "AND apiOrigin = :queueOrigin AND clientDataNamespace = :queueNamespace " +
            "AND leaseOwner = :owner AND leaseExpiresAt > :commitNow " +
            "AND EXISTS (SELECT 1 FROM active_session WHERE id = 1 " +
            "AND apiOrigin = :activeOrigin AND clientDataNamespace = :activeNamespace " +
            "AND activationRevision = :activationRevision)",
    )
    fun deleteClaimed(
        id: String,
        queueOrigin: String,
        queueNamespace: String,
        owner: String,
        commitNow: Long,
        activeOrigin: String,
        activeNamespace: String,
        activationRevision: Long,
    ): Int

    @Query("DELETE FROM queue_entries WHERE id = :id")
    fun deleteById(id: String)

    @Query("SELECT * FROM queue_entries WHERE id = :id")
    fun findById(id: String): QueueEntity?

    @Query("DELETE FROM queue_entries")
    fun deleteAll()

    @Query(
        "UPDATE queue_entries SET state = 'pending_submit', firstFailedAt = :firstFailedAt, " +
            "attemptCount = CASE WHEN state IN ('expired', 'EXPIRED') THEN 0 ELSE attemptCount END, " +
            "nextAttemptAt = NULL, lastErrorKind = NULL, lastErrorCode = NULL, " +
            "lastHttpStatus = NULL, leaseOwner = NULL, leaseExpiresAt = NULL, updatedAt = :now " +
            "WHERE id = :id " +
            "AND state IN (" +
            "'retry_wait', 'blocked_auth', 'blocked_scope', 'blocked_quota', 'failed_permanent', 'expired', " +
            "'RETRY_WAIT', 'BLOCKED_AUTH', 'BLOCKED_SCOPE', 'BLOCKED_QUOTA', 'FAILED_PERMANENT', 'EXPIRED'" +
            ") " +
            "AND (leaseOwner IS NULL OR leaseExpiresAt <= :now)",
    )
    fun resetForRetry(id: String, firstFailedAt: Long?, now: Long): Int

    @Query(
        "UPDATE queue_entries SET urlCiphertext = :urlCiphertext, urlNonce = :urlNonce, " +
            "cryptoVersion = :cryptoVersion, idempotencyKey = :idempotencyKey, " +
            "apiOrigin = :newOrigin, clientDataNamespace = :newNamespace, " +
            "state = 'pending_submit', firstFailedAt = NULL, attemptCount = 0, " +
            "nextAttemptAt = NULL, lastErrorKind = NULL, lastErrorCode = NULL, " +
            "lastHttpStatus = NULL, linkId = NULL, jobId = NULL, " +
            "leaseOwner = NULL, leaseExpiresAt = NULL, updatedAt = :now " +
            "WHERE id = :id AND apiOrigin = :oldOrigin AND clientDataNamespace = :oldNamespace " +
            "AND (leaseOwner IS NULL OR leaseExpiresAt <= :now)",
    )
    fun migrateIdentity(
        id: String,
        oldOrigin: String,
        oldNamespace: String,
        newOrigin: String,
        newNamespace: String,
        urlCiphertext: ByteArray,
        urlNonce: ByteArray,
        cryptoVersion: Int,
        idempotencyKey: String,
        now: Long,
    ): Int

    @Query("SELECT * FROM queue_entries ORDER BY createdAt")
    fun listAll(): List<QueueEntity>

    @Query("SELECT * FROM recent_results WHERE id = 1")
    fun recent(): RecentResultEntity?

    @Query(
        "UPDATE recent_results SET linkId = :linkId, jobId = :jobId, status = :status, " +
            "createdAt = :createdAt, refreshNotBefore = NULL, refreshBlockReason = NULL " +
            "WHERE id = 1 AND apiOrigin = :apiOrigin AND clientDataNamespace = :namespace " +
            "AND linkId = :expectedLinkId " +
            "AND EXISTS (SELECT 1 FROM active_session WHERE id = 1 " +
            "AND apiOrigin = :apiOrigin AND clientDataNamespace = :namespace " +
            "AND activationRevision = :activationRevision)",
    )
    fun recordRefreshSuccess(
        apiOrigin: String,
        namespace: String,
        expectedLinkId: String,
        linkId: String,
        jobId: String?,
        status: String,
        createdAt: Long,
        activationRevision: Long,
    ): Int

    @Query(
        "UPDATE recent_results SET refreshNotBefore = :refreshNotBefore, " +
            "refreshBlockReason = :refreshBlockReason " +
            "WHERE id = 1 AND apiOrigin = :apiOrigin AND clientDataNamespace = :namespace " +
            "AND linkId = :expectedLinkId " +
            "AND EXISTS (SELECT 1 FROM active_session WHERE id = 1 " +
            "AND apiOrigin = :apiOrigin AND clientDataNamespace = :namespace " +
            "AND activationRevision = :activationRevision)",
    )
    fun recordRefreshBlocked(
        apiOrigin: String,
        namespace: String,
        expectedLinkId: String,
        refreshNotBefore: Long?,
        refreshBlockReason: String,
        activationRevision: Long,
    ): Int

    @Query("DELETE FROM recent_results WHERE id = 1")
    fun clearRecent()

    @Query(
        "SELECT MIN(" +
            "CASE " +
            "WHEN leaseOwner IS NOT NULL AND leaseExpiresAt > :now THEN " +
            "CASE WHEN nextAttemptAt IS NOT NULL AND nextAttemptAt > leaseExpiresAt " +
            "THEN nextAttemptAt ELSE leaseExpiresAt END " +
            "WHEN nextAttemptAt IS NOT NULL AND nextAttemptAt > :now THEN nextAttemptAt " +
            "ELSE :now END" +
            ") FROM queue_entries " +
            "WHERE state IN ('pending_submit', 'retry_wait', 'PENDING_SUBMIT', 'RETRY_WAIT') " +
            "AND apiOrigin = :apiOrigin AND clientDataNamespace = :namespace",
    )
    fun earliestScheduleAt(apiOrigin: String, namespace: String, now: Long): Long?
}

@Database(
    entities = [
        QueueEntity::class,
        RecentResultEntity::class,
        ActiveSessionEntity::class,
        ActivationStateEntity::class,
        TodoCacheEntity::class,
        TodoOutboxEntity::class,
        TodoSyncStateEntity::class,
    ],
    version = 5,
    exportSchema = true,
)
abstract class QueueDatabase : RoomDatabase() {
    abstract fun queueDao(): QueueDao
    abstract fun todoDao(): TodoDao

    companion object {
        @Volatile
        private var instance: QueueDatabase? = null

        fun get(context: Context): QueueDatabase = instance ?: synchronized(this) {
            instance ?: Room.databaseBuilder(
                context.applicationContext,
                QueueDatabase::class.java,
                "webtag-share-queue.db",
            )
                .setJournalMode(JournalMode.WRITE_AHEAD_LOGGING)
                .addMigrations(MIGRATION_1_2, MIGRATION_2_3, MIGRATION_3_4, MIGRATION_4_5)
                .build()
                .also { instance = it }
        }

        val MIGRATION_1_2: Migration = object : Migration(1, 2) {
            override fun migrate(database: SupportSQLiteDatabase) {
                database.execSQL(
                    "CREATE TABLE IF NOT EXISTS active_session (" +
                        "id INTEGER NOT NULL, " +
                        "apiOrigin TEXT NOT NULL, " +
                        "clientDataNamespace TEXT NOT NULL, " +
                        "scopesJson TEXT NOT NULL, " +
                        "representationContract TEXT NOT NULL, " +
                        "PRIMARY KEY(id))",
                )
            }
        }

        val MIGRATION_2_3: Migration = object : Migration(2, 3) {
            override fun migrate(database: SupportSQLiteDatabase) {
                database.execSQL(
                    "ALTER TABLE active_session ADD COLUMN activationRevision INTEGER NOT NULL " +
                        "DEFAULT $LEGACY_ACTIVATION_REVISION",
                )
                database.execSQL(
                    "CREATE TABLE IF NOT EXISTS activation_state (" +
                        "id INTEGER NOT NULL, " +
                        "latestAttemptGeneration INTEGER NOT NULL, " +
                        "PRIMARY KEY(id))",
                )
                database.execSQL(
                    "INSERT OR IGNORE INTO activation_state (id, latestAttemptGeneration) " +
                        "SELECT 1, CASE WHEN EXISTS (SELECT 1 FROM active_session WHERE id = 1) " +
                        "THEN $LEGACY_ACTIVATION_REVISION ELSE 0 END",
                )
            }
        }

        val MIGRATION_3_4: Migration = object : Migration(3, 4) {
            override fun migrate(database: SupportSQLiteDatabase) {
                database.execSQL(
                    "CREATE TABLE IF NOT EXISTS todo_cache (" +
                        "apiOrigin TEXT NOT NULL, clientDataNamespace TEXT NOT NULL, todoId TEXT NOT NULL, " +
                        "payloadCiphertext BLOB NOT NULL, payloadNonce BLOB NOT NULL, cryptoVersion INTEGER NOT NULL, " +
                        "serverUpdatedAt INTEGER NOT NULL, fetchedAt INTEGER NOT NULL, " +
                        "PRIMARY KEY(apiOrigin, clientDataNamespace, todoId))",
                )
                database.execSQL(
                    "CREATE INDEX IF NOT EXISTS index_todo_cache_apiOrigin_clientDataNamespace_serverUpdatedAt " +
                        "ON todo_cache (apiOrigin, clientDataNamespace, serverUpdatedAt)",
                )
                database.execSQL(
                    "CREATE TABLE IF NOT EXISTS todo_outbox (" +
                        "operationId TEXT NOT NULL, apiOrigin TEXT NOT NULL, clientDataNamespace TEXT NOT NULL, " +
                        "targetTodoId TEXT NOT NULL, kind TEXT NOT NULL, payloadCiphertext BLOB NOT NULL, " +
                        "payloadNonce BLOB NOT NULL, cryptoVersion INTEGER NOT NULL, state TEXT NOT NULL, " +
                        "attemptCount INTEGER NOT NULL, nextAttemptAt INTEGER, lastErrorKind TEXT, " +
                        "createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL, PRIMARY KEY(operationId))",
                )
                database.execSQL(
                    "CREATE INDEX IF NOT EXISTS index_todo_outbox_apiOrigin_clientDataNamespace_state_nextAttemptAt " +
                        "ON todo_outbox (apiOrigin, clientDataNamespace, state, nextAttemptAt)",
                )
                database.execSQL(
                    "CREATE INDEX IF NOT EXISTS index_todo_outbox_apiOrigin_clientDataNamespace_targetTodoId " +
                        "ON todo_outbox (apiOrigin, clientDataNamespace, targetTodoId)",
                )
                database.execSQL(
                    "CREATE TABLE IF NOT EXISTS todo_sync_state (" +
                        "apiOrigin TEXT NOT NULL, clientDataNamespace TEXT NOT NULL, todosEnabled INTEGER NOT NULL, " +
                        "homeEnabled INTEGER NOT NULL, inboxEnabled INTEGER NOT NULL, lastSyncedAt INTEGER, " +
                        "PRIMARY KEY(apiOrigin, clientDataNamespace))",
                )
            }
        }

        val MIGRATION_4_5: Migration = object : Migration(4, 5) {
            override fun migrate(database: SupportSQLiteDatabase) {
                database.execSQL("ALTER TABLE todo_outbox ADD COLUMN leaseOwner TEXT")
                database.execSQL("ALTER TABLE todo_outbox ADD COLUMN leaseExpiresAt INTEGER")
            }
        }
    }
}

class QueueRepository(
    private val database: QueueDatabase,
    private val cipher: AndroidKeystoreCipher,
) {
    private val dao = database.queueDao()

    fun enqueue(url: String, identity: QueueIdentity, now: Long = System.currentTimeMillis()): QueueEntity {
        validateIdentity(identity)
        val entity = newEntry(url, identity, now)
        dao.insert(entity)
        return entity
    }

    fun enqueueOrReuse(
        url: String,
        identity: QueueIdentity,
        now: Long = System.currentTimeMillis(),
    ): QueueEnqueueResult = database.runInTransaction(java.util.concurrent.Callable {
        validateIdentity(identity)
        findReusableInternal(url, identity)?.let { return@Callable QueueEnqueueResult(it, true) }
        val entity = newEntry(url, identity, now)
        dao.insert(entity)
        QueueEnqueueResult(entity, false)
    })

    private fun newEntry(url: String, identity: QueueIdentity, now: Long): QueueEntity {
        val id = newUuid()
        val aad = aad(id, 1, identity)
        val encrypted = cipher.encrypt(url, aad)
        return QueueEntity(
            id = id,
            schemaVersion = 1,
            urlCiphertext = encrypted.ciphertext,
            urlNonce = encrypted.nonce,
            cryptoVersion = encrypted.version,
            idempotencyKey = newUuid(),
            requestFingerprint = sha256(url),
            apiOrigin = identity.origin,
            clientDataNamespace = identity.namespace,
            state = QueueState.PENDING_SUBMIT.wireValue,
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
    }

    fun decode(entry: QueueEntity): String {
        val url = cipher.decrypt(
            com.alpenl.webtag.share.security.EncryptedValue(
                entry.urlCiphertext,
                entry.urlNonce,
                entry.cryptoVersion,
            ),
            aad(entry.id, entry.schemaVersion, QueueIdentity(entry.apiOrigin, entry.clientDataNamespace)),
        )
        check(sha256(url) == entry.requestFingerprint) { "queue fingerprint mismatch" }
        return url
    }

    fun claimDue(
        activation: ActiveSessionSnapshot,
        now: Long = System.currentTimeMillis(),
        leaseMillis: Long = 30_000,
    ): Pair<QueueEntity, String>? {
        val identity = activation.identity
        val entry = dao.findDue(identity.origin, identity.clientDataNamespace, now) ?: return null
        val owner = newUuid()
        if (dao.claim(entry.id, entry.apiOrigin, entry.clientDataNamespace, owner, now + leaseMillis, now) != 1) return null
        return entry.copy(leaseOwner = owner, leaseExpiresAt = now + leaseMillis) to owner
    }

    fun claimForEntry(
        entry: QueueEntity,
        owner: String,
        now: Long = System.currentTimeMillis(),
        leaseMillis: Long = 30_000,
    ): Boolean = dao.claim(
        entry.id,
        entry.apiOrigin,
        entry.clientDataNamespace,
        owner,
        now + leaseMillis,
        now,
    ) == 1

    fun applyClaimed(
        entry: QueueEntity,
        owner: String,
        state: QueueState,
        firstFailedAt: Long?,
        attemptCount: Int,
        nextAttemptAt: Long?,
        errorKind: ErrorKind?,
        errorCode: String?,
        statusCode: Int?,
        linkId: String?,
        jobId: String?,
        activation: ActiveSessionSnapshot,
        now: Long = System.currentTimeMillis(),
    ): SubmitCommitOutcome = database.runInTransaction(java.util.concurrent.Callable {
        classifyClaim(entry, owner, activation, now)?.let { return@Callable it }
        val identity = activation.identity
        val updated = dao.updateClaimed(
            id = entry.id,
            queueOrigin = entry.apiOrigin,
            queueNamespace = entry.clientDataNamespace,
            owner = owner,
            state = state.wireValue,
            firstFailedAt = firstFailedAt,
            attemptCount = attemptCount,
            nextAttemptAt = nextAttemptAt,
            lastErrorKind = errorKind?.name,
            lastErrorCode = errorCode?.take(80),
            lastHttpStatus = statusCode,
            linkId = linkId,
            jobId = jobId,
            activeOrigin = identity.origin,
            activeNamespace = identity.clientDataNamespace,
            activationRevision = activation.activationRevision,
            updatedAt = now,
        )
        if (updated == 1) SubmitCommitOutcome.APPLIED else
            classifyClaim(entry, owner, activation, now) ?: SubmitCommitOutcome.STALE_CLAIM
    })

    fun commitSuccess(
        entry: QueueEntity,
        owner: String,
        result: RecentResult,
        activation: ActiveSessionSnapshot,
        url: String? = null,
        now: Long = System.currentTimeMillis(),
    ): SubmitCommitOutcome {
        val submittedUrl = url ?: decode(entry)
        check(sha256(submittedUrl) == entry.requestFingerprint) { "queue fingerprint mismatch" }
        check(result.identity == QueueIdentity(entry.apiOrigin, entry.clientDataNamespace)) {
            "submit result identity does not match queue identity"
        }
        val encrypted = cipher.encrypt(
            submittedUrl,
            aad("recent", 1, result.identity),
        )
        return database.runInTransaction(java.util.concurrent.Callable {
            classifyClaim(entry, owner, activation, now)?.let { return@Callable it }
            val identity = activation.identity
            val deleted = dao.deleteClaimed(
                id = entry.id,
                queueOrigin = entry.apiOrigin,
                queueNamespace = entry.clientDataNamespace,
                owner = owner,
                commitNow = now,
                activeOrigin = identity.origin,
                activeNamespace = identity.clientDataNamespace,
                activationRevision = activation.activationRevision,
            )
            if (deleted != 1) {
                return@Callable classifyClaim(entry, owner, activation, now)
                    ?: SubmitCommitOutcome.STALE_CLAIM
            }
            dao.upsertRecent(
                RecentResultEntity(
                    urlCiphertext = encrypted.ciphertext,
                    urlNonce = encrypted.nonce,
                    cryptoVersion = encrypted.version,
                    linkId = result.linkId,
                    jobId = result.jobId,
                    status = result.status,
                    createdAt = result.createdAt,
                    apiOrigin = result.identity.origin,
                    clientDataNamespace = result.identity.namespace,
                    refreshNotBefore = result.refreshNotBefore,
                    refreshBlockReason = result.refreshBlockReason,
                ),
            )
            SubmitCommitOutcome.APPLIED
        })
    }

    fun listViews(identity: QueueIdentity? = null): List<QueueView> = dao.listAll().mapNotNull { entry ->
        val entryIdentity = QueueIdentity(entry.apiOrigin, entry.clientDataNamespace)
        if (identity != null && entryIdentity != identity) {
            QueueView(
                entry.id,
                "",
                QueueState.BLOCKED_IDENTITY,
                entry.firstFailedAt,
                entry.nextAttemptAt,
                ErrorKind.IDENTITY_MISMATCH,
                entryIdentity,
            )
        } else {
            runCatching {
                QueueView(
                    entry.id,
                    decode(entry),
                    QueueState.fromWire(entry.state),
                    entry.firstFailedAt,
                    entry.nextAttemptAt,
                    entry.lastErrorKind?.let(ErrorKind::valueOf),
                    entryIdentity,
                )
            }.getOrElse {
                QueueView(
                    entry.id,
                    "",
                    QueueState.FAILED_PERMANENT,
                    entry.firstFailedAt,
                    entry.nextAttemptAt,
                    ErrorKind.LOCAL_DATA_UNREADABLE,
                    entryIdentity,
                )
            }
        }
    }

    fun listAll(): List<QueueEntity> = dao.listAll()

    fun beginActivationAttempt(): Long = database.runInTransaction(java.util.concurrent.Callable {
        val latest = maxOf(
            dao.activationState()?.latestAttemptGeneration ?: 0L,
            dao.activeSession()?.activationRevision ?: 0L,
        )
        val next = Math.addExact(latest, 1L)
        dao.upsertActivationState(ActivationStateEntity(latestAttemptGeneration = next))
        next
    })

    fun isLatestActivationAttempt(generation: Long): Boolean =
        generation > 0 && dao.activationState()?.latestAttemptGeneration == generation

    fun activateSessionIfLatest(
        identity: SessionIdentity,
        generation: Long,
    ): ActivationCommitOutcome {
        validateSessionIdentity(identity)
        require(generation > 0) { "activation generation must be positive" }
        return database.runInTransaction(java.util.concurrent.Callable {
            if (dao.activationState()?.latestAttemptGeneration != generation) {
                return@Callable ActivationCommitOutcome.IDENTITY_CHANGED
            }
            dao.upsertActiveSession(
                activeSessionEntity(identity, generation),
            )
            ActivationCommitOutcome.APPLIED
        })
    }

    /** Test/setup compatibility; production activation must use [activateSessionIfLatest]. */
    fun activateSession(identity: SessionIdentity, revision: Long = LEGACY_ACTIVATION_REVISION) {
        validateSessionIdentity(identity)
        require(revision > 0) { "activation revision must be positive" }
        database.runInTransaction {
            val latest = maxOf(dao.activationState()?.latestAttemptGeneration ?: 0L, revision)
            dao.upsertActivationState(ActivationStateEntity(latestAttemptGeneration = latest))
            dao.upsertActiveSession(activeSessionEntity(identity, revision))
        }
    }

    fun activeSessionSnapshot(): ActiveSessionSnapshot? {
        val session = dao.activeSession() ?: return null
        val origin = runCatching { OriginNormalizer.normalize(session.apiOrigin) }.getOrNull()
            ?: throw IllegalStateException("active session origin is invalid")
        check(origin == session.apiOrigin) { "active session origin is not canonical" }
        check(isNamespace(session.clientDataNamespace)) { "active session namespace is invalid" }
        check(session.representationContract == "v2") { "active session contract is unsupported" }
        check(session.activationRevision > 0) { "active session revision is invalid" }
        val scopes = JSONArray(session.scopesJson).let { values ->
            buildSet {
                for (index in 0 until values.length()) {
                    val scope = values.getString(index)
                    check(scope.isNotBlank()) { "active session scope is empty" }
                    add(scope)
                }
            }
        }
        return ActiveSessionSnapshot(
            identity = SessionIdentity(
                origin = session.apiOrigin,
                clientDataNamespace = session.clientDataNamespace,
                scopes = scopes,
                representationContract = session.representationContract,
            ),
            activationRevision = session.activationRevision,
        )
    }

    fun activeSessionIdentity(): SessionIdentity? = activeSessionSnapshot()?.identity

    /** Reuses a durable in-flight row after Activity/process recreation. */
    fun findReusable(url: String, identity: QueueIdentity): QueueEntity? = findReusableInternal(url, identity)

    /** Finds a durable row for process-recreation recovery, including terminal states. */
    fun findByUrl(url: String, identity: QueueIdentity): QueueEntity? = dao.listAll().firstOrNull { entry ->
        entry.apiOrigin == identity.origin &&
            entry.clientDataNamespace == identity.namespace &&
            runCatching { decode(entry) == url }.getOrDefault(false)
    }

    private fun findReusableInternal(url: String, identity: QueueIdentity): QueueEntity? =
        dao.listAll().firstOrNull { entry ->
            entry.apiOrigin == identity.origin &&
                entry.clientDataNamespace == identity.namespace &&
                entry.state in setOf(
                    QueueState.PENDING_SUBMIT.wireValue,
                    QueueState.RETRY_WAIT.wireValue,
                    QueueState.PENDING_SUBMIT.name,
                    QueueState.RETRY_WAIT.name,
                ) &&
                runCatching { decode(entry) == url }.getOrDefault(false)
        }

    fun delete(id: String) = dao.deleteById(id)

    fun clear() = database.runInTransaction { dao.deleteAll() }

    fun retry(id: String, now: Long = System.currentTimeMillis()): Boolean =
        dao.resetForRetry(id, null, now) == 1

    fun retryRecoverable(identity: QueueIdentity, now: Long = System.currentTimeMillis()): Int {
        validateIdentity(identity)
        return listAll()
            .filter {
                it.apiOrigin == identity.origin &&
                    it.clientDataNamespace == identity.namespace &&
                    it.state in setOf(
                        QueueState.RETRY_WAIT.wireValue,
                        QueueState.BLOCKED_AUTH.wireValue,
                        QueueState.BLOCKED_SCOPE.wireValue,
                        QueueState.BLOCKED_QUOTA.wireValue,
                        QueueState.EXPIRED.wireValue,
                        QueueState.RETRY_WAIT.name,
                        QueueState.BLOCKED_AUTH.name,
                        QueueState.BLOCKED_SCOPE.name,
                        QueueState.BLOCKED_QUOTA.name,
                        QueueState.EXPIRED.name,
                    )
            }
            .count { retry(it.id, now) }
    }

    fun retryIdentityBlocked(identity: QueueIdentity, now: Long = System.currentTimeMillis()): Int {
        validateIdentity(identity)
        return listAll()
            .filter {
                it.apiOrigin == identity.origin &&
                    it.clientDataNamespace == identity.namespace &&
                    it.state in setOf(
                        QueueState.BLOCKED_AUTH.wireValue,
                        QueueState.BLOCKED_SCOPE.wireValue,
                        QueueState.BLOCKED_AUTH.name,
                        QueueState.BLOCKED_SCOPE.name,
                    )
            }
            .count { retry(it.id, now) }
    }

    fun migrateIdentity(
        id: String,
        target: QueueIdentity,
        now: Long = System.currentTimeMillis(),
    ): Boolean {
        validateIdentity(target)
        var migrated = false
        database.runInTransaction {
            val entry = dao.findById(id) ?: return@runInTransaction
            val oldIdentity = QueueIdentity(entry.apiOrigin, entry.clientDataNamespace)
            validateIdentity(oldIdentity)
            if (oldIdentity == target || (entry.leaseOwner != null && (entry.leaseExpiresAt ?: Long.MAX_VALUE) > now)) {
                return@runInTransaction
            }
            val url = runCatching { decode(entry) }.getOrElse { return@runInTransaction }
            val encrypted = cipher.encrypt(url, aad(entry.id, entry.schemaVersion, target))
            migrated = dao.migrateIdentity(
                id = entry.id,
                oldOrigin = oldIdentity.origin,
                oldNamespace = oldIdentity.namespace,
                newOrigin = target.origin,
                newNamespace = target.namespace,
                urlCiphertext = encrypted.ciphertext,
                urlNonce = encrypted.nonce,
                cryptoVersion = encrypted.version,
                idempotencyKey = newUuid(),
                now = now,
            ) == 1
        }
        return migrated
    }

    fun nextScheduleAt(now: Long = System.currentTimeMillis()): Long? {
        val identity = activeSessionSnapshot()?.identity ?: return null
        return dao.earliestScheduleAt(identity.origin, identity.clientDataNamespace, now)
    }

    fun recordRefreshSuccess(
        activation: ActiveSessionSnapshot,
        expectedLinkId: String,
        response: com.alpenl.webtag.share.contract.SubmitResponse,
        now: Long = System.currentTimeMillis(),
    ): RefreshCommitOutcome = database.runInTransaction(java.util.concurrent.Callable {
        classifyRefreshInternal(activation, expectedLinkId)?.let { return@Callable it }
        val identity = activation.identity
        val updated = dao.recordRefreshSuccess(
            apiOrigin = identity.origin,
            namespace = identity.clientDataNamespace,
            expectedLinkId = expectedLinkId,
            linkId = response.linkId,
            jobId = response.jobId,
            status = response.status,
            createdAt = now,
            activationRevision = activation.activationRevision,
        )
        if (updated == 1) RefreshCommitOutcome.APPLIED else
            classifyRefreshInternal(activation, expectedLinkId) ?: RefreshCommitOutcome.RECENT_REPLACED
    })

    fun recordRefreshBlocked(
        activation: ActiveSessionSnapshot,
        expectedLinkId: String,
        refreshNotBefore: Long?,
        reason: String,
    ): RefreshCommitOutcome = database.runInTransaction(java.util.concurrent.Callable {
        classifyRefreshInternal(activation, expectedLinkId)?.let { return@Callable it }
        val identity = activation.identity
        val updated = dao.recordRefreshBlocked(
            apiOrigin = identity.origin,
            namespace = identity.clientDataNamespace,
            expectedLinkId = expectedLinkId,
            refreshNotBefore = refreshNotBefore,
            refreshBlockReason = reason,
            activationRevision = activation.activationRevision,
        )
        if (updated == 1) RefreshCommitOutcome.APPLIED else
            classifyRefreshInternal(activation, expectedLinkId) ?: RefreshCommitOutcome.RECENT_REPLACED
    })

    fun classifyRefresh(
        activation: ActiveSessionSnapshot,
        expectedLinkId: String,
    ): RefreshCommitOutcome = database.runInTransaction(java.util.concurrent.Callable {
        classifyRefreshInternal(activation, expectedLinkId) ?: RefreshCommitOutcome.APPLIED
    })

    fun readRecent(identity: QueueIdentity? = null): RecentResult? {
        val result = dao.recent() ?: return null
        val resultIdentity = QueueIdentity(result.apiOrigin, result.clientDataNamespace)
        if (identity != null && resultIdentity != identity) {
            return RecentResult(
                url = "",
                linkId = "",
                jobId = null,
                status = "identity_mismatch",
                createdAt = result.createdAt,
                identity = resultIdentity,
                refreshNotBefore = result.refreshNotBefore,
                refreshBlockReason = result.refreshBlockReason,
                isIdentityMismatch = true,
            )
        }
        val url = runCatching {
            cipher.decrypt(
                com.alpenl.webtag.share.security.EncryptedValue(result.urlCiphertext, result.urlNonce, result.cryptoVersion),
                aad("recent", 1, resultIdentity),
            )
        }.getOrNull() ?: return null
        return RecentResult(
            url,
            result.linkId,
            result.jobId,
            result.status,
            result.createdAt,
            resultIdentity,
            result.refreshNotBefore,
            result.refreshBlockReason,
            false,
        )
    }

    fun clearRecent() = dao.clearRecent()

    private fun aad(id: String, schemaVersion: Int, identity: QueueIdentity): String =
        "$id|$schemaVersion|${identity.origin}|${identity.namespace}"

    private fun validateIdentity(identity: QueueIdentity) {
        check(runCatching { OriginNormalizer.normalize(identity.origin) }.getOrNull() == identity.origin) {
            "queue origin is not canonical"
        }
        check(isNamespace(identity.namespace)) { "queue namespace is invalid" }
    }

    private fun validateSessionIdentity(identity: com.alpenl.webtag.share.contract.SessionIdentity) {
        validateIdentity(QueueIdentity(identity.origin, identity.clientDataNamespace))
        check(identity.representationContract == "v2") { "unsupported session contract" }
    }

    private fun isNamespace(value: String): Boolean =
        value.length == 43 && value.all {
            it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '_' || it == '-'
        }

    private fun activeSessionEntity(identity: SessionIdentity, revision: Long): ActiveSessionEntity =
        ActiveSessionEntity(
            apiOrigin = identity.origin,
            clientDataNamespace = identity.clientDataNamespace,
            scopesJson = JSONArray().apply {
                identity.scopes.toList().sorted().forEach(::put)
            }.toString(),
            representationContract = identity.representationContract,
            activationRevision = revision,
        )

    private fun classifyClaim(
        entry: QueueEntity,
        owner: String,
        activation: ActiveSessionSnapshot,
        commitNow: Long,
    ): SubmitCommitOutcome? {
        val current = dao.findById(entry.id) ?: return SubmitCommitOutcome.STALE_CLAIM
        if (current.apiOrigin != entry.apiOrigin ||
            current.clientDataNamespace != entry.clientDataNamespace ||
            current.leaseOwner != owner ||
            current.leaseExpiresAt == null ||
            current.leaseExpiresAt <= commitNow
        ) {
            return SubmitCommitOutcome.STALE_CLAIM
        }
        return if (activeSessionMatches(activation)) null else SubmitCommitOutcome.IDENTITY_CHANGED
    }

    private fun classifyRefreshInternal(
        activation: ActiveSessionSnapshot,
        expectedLinkId: String,
    ): RefreshCommitOutcome? {
        if (!activeSessionMatches(activation)) return RefreshCommitOutcome.IDENTITY_CHANGED
        val recent = dao.recent() ?: return RefreshCommitOutcome.RECENT_REPLACED
        val identity = activation.identity
        return if (recent.apiOrigin == identity.origin &&
            recent.clientDataNamespace == identity.clientDataNamespace &&
            recent.linkId == expectedLinkId
        ) {
            null
        } else {
            RefreshCommitOutcome.RECENT_REPLACED
        }
    }

    private fun activeSessionMatches(activation: ActiveSessionSnapshot): Boolean {
        val current = dao.activeSession() ?: return false
        val identity = activation.identity
        return current.apiOrigin == identity.origin &&
            current.clientDataNamespace == identity.clientDataNamespace &&
            current.activationRevision == activation.activationRevision
    }

    private fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }
}
