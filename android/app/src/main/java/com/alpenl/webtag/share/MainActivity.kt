package com.alpenl.webtag.share

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import androidx.room.InvalidationTracker
import com.alpenl.webtag.share.contract.ErrorKind
import com.alpenl.webtag.share.contract.QueueIdentity
import com.alpenl.webtag.share.contract.QueueState
import com.alpenl.webtag.share.contract.RefreshCommitOutcome
import com.alpenl.webtag.share.contract.RetryPolicy
import com.alpenl.webtag.share.queue.ConnectionResult
import com.alpenl.webtag.share.queue.MobileRuntime
import com.alpenl.webtag.share.queue.RefreshAttempt
import com.alpenl.webtag.share.ui.theme.WebTagShareTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.DateFormat
import java.security.MessageDigest
import java.util.Date

class MainActivity : ComponentActivity() {
    private var foregroundDrainJob: Job? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            WebTagShareTheme {
                SettingsScreen(MobileRuntime.get(this@MainActivity))
            }
        }
    }

    override fun onStart() {
        super.onStart()
        if (foregroundDrainJob?.isActive == true) return
        val runtime = MobileRuntime.get(this)
        foregroundDrainJob = lifecycleScope.launch(Dispatchers.IO) {
            runtime.repairActiveIdentity()
            var processed = 0
            try {
                while (isActive && processed < 16) {
                    val drained = runCatching { runtime.coordinator.drainOne() }.getOrDefault(false)
                    if (!drained) break
                    processed += 1
                }
            } finally {
                runCatching { runtime.scheduler.schedule() }
            }
        }
    }
}

@Composable
private fun SettingsScreen(runtime: MobileRuntime) {
    val scope = rememberCoroutineScope()
    var origin by remember { mutableStateOf("") }
    var apiKey by remember { mutableStateOf("") }
    var keyVisible by remember { mutableStateOf(false) }
    var connectionMessage by remember { mutableStateOf("") }
    var lastCheckedAt by remember { mutableStateOf<Long?>(null) }
    var busy by remember { mutableStateOf(false) }
    var queue by remember { mutableStateOf(emptyList<com.alpenl.webtag.share.contract.QueueView>()) }
    var recent by remember { mutableStateOf<com.alpenl.webtag.share.contract.RecentResult?>(null) }
    var showClearDialog by remember { mutableStateOf(false) }
    var showPermanentRetryDialog by remember { mutableStateOf(false) }
    var pendingPermanentRetryID by remember { mutableStateOf<String?>(null) }
    var showIdentityMigrationDialog by remember { mutableStateOf(false) }
    var pendingIdentityMigration by remember {
        mutableStateOf<com.alpenl.webtag.share.contract.QueueView?>(null)
    }
    var activeNamespace by remember { mutableStateOf<String?>(null) }
    var refreshBusy by remember { mutableStateOf(false) }
    var connectionRequestGeneration by remember { mutableLongStateOf(0L) }

    suspend fun reloadLocal() {
        val snapshot = withContext(Dispatchers.IO) {
            val current = runtime.activeConfiguration()
            val identity = current?.let { QueueIdentity(it.origin, it.namespace) }
            // A missing or interrupted credential activation must never reveal
            // URLs from another identity in the settings surface.
            val displayIdentity = identity ?: QueueIdentity("", "")
            val localQueue = runCatching { runtime.repository.listViews(displayIdentity) }.getOrDefault(emptyList())
            val localRecent = runCatching { runtime.repository.readRecent(displayIdentity) }.getOrNull()
            localQueue to localRecent
        }
        queue = snapshot.first
        recent = snapshot.second
    }

    DisposableEffect(runtime) {
        val observer = object : InvalidationTracker.Observer(
            "queue_entries",
            "recent_results",
            "active_session",
        ) {
            override fun onInvalidated(tables: Set<String>) {
                scope.launch { reloadLocal() }
            }
        }
        runtime.database.invalidationTracker.addObserver(observer)
        onDispose { runtime.database.invalidationTracker.removeObserver(observer) }
    }

    fun retryQueue(id: String) {
        scope.launch {
            withContext(Dispatchers.IO) {
                runtime.repository.retry(id)
                runtime.scheduler.schedule()
            }
            reloadLocal()
        }
    }

    LaunchedEffect(Unit) {
        val stored = withContext(Dispatchers.IO) { runtime.activeConfiguration() }
        if (stored != null) {
            origin = stored.origin
            apiKey = stored.apiKey
            activeNamespace = stored.namespace
            connectionMessage = "连接正常"
        }
        reloadLocal()
    }

    Scaffold(modifier = Modifier.fillMaxSize()) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(horizontal = 20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                Spacer(Modifier.height(20.dp))
                Text("WebTag Share", style = MaterialTheme.typography.headlineMedium)
                Text(
                    text = stringResource(R.string.home_status),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
            item { HorizontalDivider() }
            item {
                OutlinedTextField(
                    value = origin,
                    onValueChange = { origin = it },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text(stringResource(R.string.server_url)) },
                    placeholder = { Text(stringResource(R.string.server_url_hint)) },
                    singleLine = true,
                    enabled = !busy,
                )
            }
            item {
                OutlinedTextField(
                    value = apiKey,
                    onValueChange = { apiKey = it },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text(stringResource(R.string.api_key)) },
                    singleLine = true,
                    enabled = !busy,
                    visualTransformation = if (keyVisible) VisualTransformation.None else PasswordVisualTransformation(),
                    trailingIcon = {
                        IconButton(onClick = { keyVisible = !keyVisible }) {
                            Icon(
                                imageVector = if (keyVisible) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                                contentDescription = stringResource(if (keyVisible) R.string.hide_api_key else R.string.show_api_key),
                            )
                        }
                    },
                )
            }
            item {
                Button(
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !busy && origin.isNotBlank() && apiKey.isNotBlank(),
                    onClick = {
                        val requestGeneration = ++connectionRequestGeneration
                        val requestedOrigin = origin
                        val requestedApiKey = apiKey
                        busy = true
                        connectionMessage = ""
                        scope.launch {
                            val previousConfiguration = withContext(Dispatchers.IO) {
                                runtime.activeConfiguration()
                            }
                            fun restorePreviousConfiguration() {
                                previousConfiguration?.let { previous ->
                                    origin = previous.origin
                                    apiKey = previous.apiKey
                                    activeNamespace = previous.namespace
                                } ?: run {
                                    origin = ""
                                    apiKey = ""
                                    activeNamespace = null
                                }
                            }
                            val result = withContext(Dispatchers.IO) {
                                runCatching {
                                    runtime.connectionCoordinator.saveAndTest(
                                        requestedOrigin,
                                        requestedApiKey,
                                    )
                                }.getOrElse { ConnectionResult.StorageFailure }
                            }
                            if (requestGeneration == connectionRequestGeneration) {
                                when (result) {
                                    is ConnectionResult.Activated -> {
                                        val configuration = result.configuration
                                        origin = configuration.origin
                                        apiKey = configuration.apiKey
                                        activeNamespace = configuration.namespace
                                        withContext(Dispatchers.IO) {
                                            runCatching {
                                                runtime.repository.retryIdentityBlocked(
                                                    QueueIdentity(configuration.origin, configuration.namespace),
                                                )
                                            }
                                            runCatching { runtime.scheduler.schedule() }
                                        }
                                        connectionMessage = "连接正常"
                                        lastCheckedAt = System.currentTimeMillis()
                                    }
                                    is ConnectionResult.Failed -> {
                                        restorePreviousConfiguration()
                                        connectionMessage = connectionMessageFor(result.failure.kind)
                                    }
                                    ConnectionResult.StorageFailure -> {
                                        restorePreviousConfiguration()
                                        connectionMessage = "无法保存本地凭证"
                                    }
                                    // Another durable attempt superseded this response. Its UI state
                                    // is authoritative, so the old response must not restore this form.
                                    ConnectionResult.IdentityChanged -> Unit
                                }
                                busy = false
                                reloadLocal()
                            }
                        }
                    },
                ) {
                    Text(stringResource(R.string.save_and_test))
                }
            }
            item {
                if (connectionMessage.isNotBlank()) {
                    Text(
                        text = connectionMessage + (lastCheckedAt?.let { " · ${formatTime(it)}" } ?: ""),
                        color = if (connectionMessage == "连接正常") MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            }
            if (queue.isNotEmpty()) {
                item {
                    Text(
                        text = stringResource(R.string.queue_title, queue.size),
                        style = MaterialTheme.typography.titleLarge,
                    )
                }
                items(queue, key = { it.id }) { item ->
                    QueueRow(
                        item = item,
                        onRetry = {
                            if (item.state == QueueState.FAILED_PERMANENT) {
                                pendingPermanentRetryID = item.id
                                showPermanentRetryDialog = true
                            } else if (item.state == QueueState.BLOCKED_IDENTITY) {
                                pendingIdentityMigration = item
                                showIdentityMigrationDialog = true
                            } else {
                                retryQueue(item.id)
                            }
                        },
                        onMigrate = {
                            pendingIdentityMigration = item
                            showIdentityMigrationDialog = true
                        },
                        onDelete = {
                            scope.launch {
                                withContext(Dispatchers.IO) { runtime.repository.delete(item.id) }
                                reloadLocal()
                            }
                        },
                    )
                }
                item {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(
                            modifier = Modifier.weight(1f),
                            onClick = {
                                scope.launch {
                                    withContext(Dispatchers.IO) {
                                        runtime.activeConfiguration()
                                            ?.let { credential ->
                                                runtime.repository.retryRecoverable(
                                                    QueueIdentity(credential.origin, credential.namespace),
                                                )
                                            }
                                        runCatching { runtime.scheduler.schedule() }
                                    }
                                    reloadLocal()
                                }
                            },
                        ) { Text(stringResource(R.string.retry_recoverable)) }
                        OutlinedButton(
                            modifier = Modifier.weight(1f),
                            onClick = { showClearDialog = true },
                        ) { Text(stringResource(R.string.clear_queue)) }
                    }
                }
            }
            if (recent != null) {
                item {
                    RecentResultCard(
                        recent = recent!!,
                        busy = refreshBusy,
                        onRefresh = {
                            val selected = recent ?: return@RecentResultCard
                            if (selected.isIdentityMismatch) {
                                connectionMessage = "身份已变更"
                                return@RecentResultCard
                            }
                            refreshBusy = true
                            scope.launch {
                                val result = withContext(Dispatchers.IO) {
                                    runCatching { runtime.refreshCoordinator.refresh(selected) }.getOrNull()
                                }
                                if (result == null) {
                                    connectionMessage = "凭证无效"
                                } else {
                                    connectionMessage = when (result.commitOutcome) {
                                        RefreshCommitOutcome.IDENTITY_CHANGED -> "身份已变更"
                                        RefreshCommitOutcome.RECENT_REPLACED -> "最近结果已更新"
                                        RefreshCommitOutcome.APPLIED -> when (val attempt = result.attempt) {
                                            is RefreshAttempt.Success -> "连接正常"
                                            is RefreshAttempt.Failure -> {
                                                connectionMessageFor(attempt.failure.kind)
                                            }
                                        }
                                    }
                                }
                                refreshBusy = false
                                reloadLocal()
                            }
                        },
                        onClear = {
                            scope.launch {
                                withContext(Dispatchers.IO) { runtime.repository.clearRecent() }
                                recent = null
                                reloadLocal()
                            }
                        },
                    )
                }
            }
            item {
                Text(
                    text = stringResource(R.string.app_instruction),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodySmall,
                )
                Text(
                    text = "v0.1.0",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.labelSmall,
                    modifier = Modifier.padding(bottom = 24.dp),
                )
            }
        }
    }

    if (showPermanentRetryDialog) {
        AlertDialog(
            onDismissRequest = {
                showPermanentRetryDialog = false
                pendingPermanentRetryID = null
            },
            title = { Text("再次提交失败条目？") },
            text = { Text("这会复用原 URL，但会重新进入提交流程；服务端失败链接不会被隐式解析。") },
            confirmButton = {
                TextButton(onClick = {
                    pendingPermanentRetryID?.let(::retryQueue)
                    showPermanentRetryDialog = false
                    pendingPermanentRetryID = null
                }) { Text("确认重试") }
            },
            dismissButton = {
                TextButton(onClick = {
                    showPermanentRetryDialog = false
                    pendingPermanentRetryID = null
                }) { Text(stringResource(R.string.cancel)) }
            },
        )
    }

    if (showClearDialog) {
        AlertDialog(
            onDismissRequest = { showClearDialog = false },
            title = { Text(stringResource(R.string.clear_queue_title)) },
            text = { Text(stringResource(R.string.clear_queue_message, queue.size)) },
                confirmButton = {
                    TextButton(onClick = {
                        scope.launch {
                            withContext(Dispatchers.IO) { runtime.repository.clear() }
                            queue = emptyList()
                            showClearDialog = false
                            reloadLocal()
                        }
                    }) { Text(stringResource(R.string.confirm)) }
                },
            dismissButton = {
                TextButton(onClick = { showClearDialog = false }) { Text(stringResource(R.string.cancel)) }
            },
        )
    }

    if (showIdentityMigrationDialog) {
        val pending = pendingIdentityMigration
        AlertDialog(
            onDismissRequest = {
                showIdentityMigrationDialog = false
                pendingIdentityMigration = null
            },
            title = { Text("迁移并重试？") },
            text = {
                Text(
                    "旧身份：${pending?.identity?.origin.orEmpty()} · " +
                        "${namespaceFingerprint(pending?.identity?.namespace)}\n" +
                        "新身份：$origin · ${namespaceFingerprint(activeNamespace)}\n" +
                        "URL 会用新身份重新加密，并生成新的幂等 key。",
                )
            },
            confirmButton = {
                TextButton(
                    enabled = pending != null,
                    onClick = {
                        val selected = pending ?: return@TextButton
                        scope.launch {
                            val migrated = withContext(Dispatchers.IO) {
                                val config = runCatching { runtime.credentials.load() }.getOrNull()
                                if (config == null) {
                                    false
                                } else {
                                    val target = QueueIdentity(config.origin, config.namespace)
                                    val didMigrate = runCatching {
                                        runtime.repository.migrateIdentity(selected.id, target)
                                    }.getOrDefault(false)
                                    if (didMigrate) runCatching { runtime.scheduler.schedule() }
                                    didMigrate
                                }
                            }
                            connectionMessage = if (migrated) "已迁移，等待提交" else "无法迁移本地条目"
                            showIdentityMigrationDialog = false
                            pendingIdentityMigration = null
                            reloadLocal()
                        }
                    },
                ) { Text("迁移并重试") }
            },
            dismissButton = {
                TextButton(onClick = {
                    showIdentityMigrationDialog = false
                    pendingIdentityMigration = null
                }) { Text(stringResource(R.string.cancel)) }
            },
        )
    }
}

@Composable
private fun QueueRow(
    item: com.alpenl.webtag.share.contract.QueueView,
    onRetry: () -> Unit,
    onDelete: () -> Unit,
    onMigrate: () -> Unit,
) {
    Card(shape = RoundedCornerShape(8.dp), modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier.padding(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = item.url.ifBlank { stringResource(R.string.status_identity) },
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    style = MaterialTheme.typography.bodyMedium,
                )
                Text(
                    text = stateLabel(item.state),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodySmall,
                )
                item.firstFailedAt?.let { firstFailedAt ->
                    Text(
                        text = "首次失败：${formatTime(firstFailedAt)}",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                item.nextAttemptAt?.let { nextAttemptAt ->
                    Text(
                        text = "下次重试：${formatTime(nextAttemptAt)}",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
            if (item.state == QueueState.BLOCKED_IDENTITY) {
                TextButton(onClick = onMigrate) { Text("迁移并重试") }
            } else {
                IconButton(
                    onClick = onRetry,
                    enabled = item.state != QueueState.PENDING_SUBMIT,
                ) {
                    Icon(Icons.Default.Refresh, contentDescription = stringResource(R.string.retry))
                }
            }
            IconButton(onClick = onDelete) {
                Icon(Icons.Default.Delete, contentDescription = stringResource(R.string.delete))
            }
        }
    }
}

@Composable
private fun RecentResultCard(
    recent: com.alpenl.webtag.share.contract.RecentResult,
    busy: Boolean,
    onRefresh: () -> Unit,
    onClear: () -> Unit,
) {
    var cooldownNow by remember(recent.refreshBlockReason, recent.refreshNotBefore) {
        mutableStateOf(System.currentTimeMillis())
    }
    LaunchedEffect(recent.refreshBlockReason, recent.refreshNotBefore) {
        while (true) {
            val now = System.currentTimeMillis()
            cooldownNow = now
            val remaining = RetryPolicy.refreshCooldownRemainingMillis(
                recent.refreshBlockReason,
                recent.refreshNotBefore,
                now,
            )
            if (remaining == 0L) break
            delay(remaining)
        }
    }
    val cooldownActive = RetryPolicy.refreshCooldownRemainingMillis(
        recent.refreshBlockReason,
        recent.refreshNotBefore,
        cooldownNow,
    ) > 0

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.recent_result), style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
            IconButton(onClick = onClear) { Icon(Icons.Default.Delete, contentDescription = stringResource(R.string.delete)) }
        }
        Card(shape = RoundedCornerShape(8.dp), modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (recent.isIdentityMismatch) {
                    Text("身份已变更", color = MaterialTheme.colorScheme.error)
                } else {
                    Text(
                        recent.url,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    Text(statusLabel(recent.status), color = MaterialTheme.colorScheme.primary)
                    Text(
                        text = "Link ID：${recent.linkId}",
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall,
                    )
                    Text(
                        text = "结果时间：${formatTime(recent.createdAt)}",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                recent.refreshBlockReason?.let { reason ->
                    val notBefore = recent.refreshNotBefore
                    if (reason != RetryPolicy.REFRESH_COOLDOWN_REASON || cooldownActive) {
                        Text(
                            text = when (reason) {
                                RetryPolicy.REFRESH_COOLDOWN_REASON -> "重新解析冷却中" +
                                    (notBefore?.let { " · ${formatTime(it)} 后可重试" } ?: "")
                                RetryPolicy.REFRESH_QUOTA_REASON -> "配额已用完，处理额度后可手动重试"
                                else -> reason
                            },
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
                if (recent.status == "failed" && !recent.isIdentityMismatch) {
                    OutlinedButton(onClick = onRefresh, enabled = !busy && !cooldownActive) {
                        Text(stringResource(R.string.refresh))
                    }
                }
            }
        }
    }
}

private fun connectionMessageFor(kind: ErrorKind): String = when (kind) {
    ErrorKind.HTTP_401 -> "凭证无效"
    ErrorKind.HTTP_403_SCOPE -> "缺少 write 权限"
    ErrorKind.HTTP_429_RATE_LIMIT -> "请求过于频繁，请稍后重试"
    ErrorKind.HTTP_429_COOLDOWN -> "请稍后重新解析"
    ErrorKind.HTTP_429_QUOTA -> "配额已用完"
    ErrorKind.IDENTITY_MISMATCH -> "身份已变更"
    ErrorKind.TLS_TRUST_FAILURE -> "无法连接服务器"
    else -> "无法连接服务器"
}

private fun stateLabel(state: QueueState): String = when (state) {
    QueueState.PENDING_SUBMIT -> "待提交"
    QueueState.RETRY_WAIT -> "等待重试"
    QueueState.BLOCKED_AUTH -> "凭证无效"
    QueueState.BLOCKED_SCOPE -> "缺少 write 权限"
    QueueState.BLOCKED_QUOTA -> "配额已用完"
    QueueState.BLOCKED_IDENTITY -> "身份已变更"
    QueueState.FAILED_PERMANENT -> "提交失败"
    QueueState.EXPIRED -> "已过期"
}

private fun statusLabel(status: String): String = when (status) {
    "pending", "processing" -> "已收藏"
    "done" -> "已在库中"
    "failed" -> "已在库中，解析失败"
    else -> "提交失败"
}

private fun formatTime(epochMillis: Long): String = DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(epochMillis))

private fun namespaceFingerprint(namespace: String?): String {
    if (namespace.isNullOrEmpty()) return "未知"
    val digest = MessageDigest.getInstance("SHA-256")
        .digest(namespace.toByteArray(Charsets.UTF_8))
    return digest
        .take(4)
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }
}
