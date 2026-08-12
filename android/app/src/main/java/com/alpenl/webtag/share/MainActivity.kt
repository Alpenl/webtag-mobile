package com.alpenl.webtag.share

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.annotation.StringRes
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
import com.alpenl.webtag.share.contract.ErrorKind
import com.alpenl.webtag.share.contract.QueueIdentity
import com.alpenl.webtag.share.contract.QueueState
import com.alpenl.webtag.share.contract.RecentResult
import com.alpenl.webtag.share.contract.RefreshCommitOutcome
import com.alpenl.webtag.share.contract.RetryPolicy
import com.alpenl.webtag.share.queue.ConnectionResult
import com.alpenl.webtag.share.queue.MobileClock
import com.alpenl.webtag.share.queue.MobileRuntime
import com.alpenl.webtag.share.queue.RefreshAttempt
import com.alpenl.webtag.share.settings.QueueGroup
import com.alpenl.webtag.share.settings.QueueGroupView
import com.alpenl.webtag.share.settings.RecentProjection
import com.alpenl.webtag.share.settings.SettingsProjection
import com.alpenl.webtag.share.settings.SettingsTimeFormatter
import com.alpenl.webtag.share.settings.awaitCooldownDeadline
import com.alpenl.webtag.share.data.TodoLocalSnapshot
import com.alpenl.webtag.share.ui.theme.WebTagShareTheme
import com.alpenl.webtag.share.ui.companion.CompanionApp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.security.MessageDigest

class MainActivity : ComponentActivity() {
    private var deepLinkRoute by mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        deepLinkRoute = intent.companionRoute()
        enableEdgeToEdge()
        setContent {
            WebTagShareTheme {
                CompanionApp(MobileRuntime.get(this@MainActivity), deepLinkRoute)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        deepLinkRoute = intent.companionRoute()
    }
}

private fun Intent.companionRoute(): String? = data?.takeIf { it.scheme == "webtag" }?.host

@Composable
internal fun SettingsScreen(
    runtime: MobileRuntime,
    projection: SettingsProjection,
    todoSnapshot: TodoLocalSnapshot,
    resumeTick: Long,
    reloadLocal: suspend () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var origin by remember { mutableStateOf("") }
    var apiKey by remember { mutableStateOf("") }
    var keyVisible by remember { mutableStateOf(false) }
    var connectionMessage by remember { mutableStateOf("") }
    var lastCheckedAt by remember { mutableStateOf<Long?>(null) }
    var busy by remember { mutableStateOf(false) }
    var showClearDialog by remember { mutableStateOf(false) }
    var showPermanentRetryDialog by remember { mutableStateOf(false) }
    var pendingPermanentRetryID by remember { mutableStateOf<String?>(null) }
    var showIdentityMigrationDialog by remember { mutableStateOf(false) }
    var pendingIdentityMigration by remember {
        mutableStateOf<com.alpenl.webtag.share.contract.QueueView?>(null)
    }
    var refreshBusy by remember { mutableStateOf(false) }
    var connectionRequestGeneration by remember { mutableLongStateOf(0L) }
    fun retryQueue(id: String) {
        scope.launch {
            withContext(Dispatchers.IO) {
                runtime.repository.retry(id)
                runtime.scheduler.schedule()
            }
            reloadLocal()
        }
    }

    // The one place the credential fields are ever written from storage: the first composition,
    // before there is a draft to lose. Every later reload goes through `reloadLocal`.
    LaunchedEffect(Unit) {
        val stored = withContext(Dispatchers.IO) { runtime.activeConfiguration() }
        if (stored != null) {
            origin = stored.origin
            apiKey = stored.apiKey
            connectionMessage = "连接正常"
        }
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
                            // A rejected credential is the one case where the draft is rolled back,
                            // because the user asked for it to be committed and it was not.
                            fun restorePreviousConfiguration() {
                                previousConfiguration?.let { previous ->
                                    origin = previous.origin
                                    apiKey = previous.apiKey
                                } ?: run {
                                    origin = ""
                                    apiKey = ""
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
            item {
                HorizontalDivider()
                Spacer(Modifier.height(8.dp))
                Text("待办同步", style = MaterialTheme.typography.titleLarge)
                Text(
                    text = when (todoSnapshot.todosEnabled) {
                        false -> "当前服务器未启用待办接口"
                        else -> buildString {
                            append("本地 ${todoSnapshot.items.size} 项")
                            if (todoSnapshot.pendingOperations > 0) {
                                append(" · ${todoSnapshot.pendingOperations} 项待同步")
                            }
                            if (todoSnapshot.blockedOperations > 0) {
                                append(" · ${todoSnapshot.blockedOperations} 项需要处理")
                            }
                        }
                    },
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodyMedium,
                )
                todoSnapshot.lastSyncedAt?.let {
                    Text(
                        text = "上次同步 ${formatTime(it)}",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                OutlinedButton(
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !busy && projection.activeNamespace != null,
                    onClick = {
                        scope.launch {
                            busy = true
                            withContext(Dispatchers.IO) {
                                runCatching { runtime.todoSyncCoordinator.synchronize() }
                                runCatching { runtime.todoScheduler.schedule() }
                            }
                            busy = false
                            reloadLocal()
                        }
                    },
                ) { Text("立即同步") }
            }
            if (!projection.queue.isEmpty) {
                item {
                    Text(
                        // The total counts every durable row, not the rows currently on screen.
                        text = stringResource(R.string.queue_title, projection.queue.total),
                        style = MaterialTheme.typography.titleLarge,
                    )
                }
                projection.queue.groups.forEach { group ->
                    item(key = "queue-group-${group.group.key}") { QueueGroupHeader(group) }
                    items(group.rows, key = { it.id }) { item ->
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
            projection.recent?.let { currentRecent ->
                item {
                    RecentResultCard(
                        recent = currentRecent,
                        busy = refreshBusy,
                        clock = runtime.clock,
                        resumeTick = resumeTick,
                        onRefresh = {
                            val selected = projection.recent ?: return@RecentResultCard
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
            text = { Text(stringResource(R.string.clear_queue_message, projection.queue.total)) },
                confirmButton = {
                    TextButton(onClick = {
                        scope.launch {
                            withContext(Dispatchers.IO) { runtime.repository.clear() }
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
                        "新身份：$origin · ${namespaceFingerprint(projection.activeNamespace)}\n" +
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

/**
 * A section heading and its own count.
 *
 * The per-section count is the point of the heading: "3 条待提交与重试, 1 条凭证阻断" is an
 * actionable summary, while one number over eight interleaved states is not.
 */
@Composable
internal fun QueueGroupHeader(group: QueueGroupView) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            text = stringResource(queueGroupTitle(group.group)),
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.weight(1f),
        )
        Text(
            text = stringResource(R.string.queue_group_count, group.count),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.labelMedium,
        )
    }
}

@StringRes
private fun queueGroupTitle(group: QueueGroup): Int = when (group) {
    QueueGroup.PENDING_AND_RETRY -> R.string.queue_group_pending_and_retry
    QueueGroup.BLOCKED_CREDENTIAL -> R.string.queue_group_blocked_credential
    QueueGroup.BLOCKED_IDENTITY -> R.string.queue_group_blocked_identity
    QueueGroup.BLOCKED_QUOTA -> R.string.queue_group_blocked_quota
    QueueGroup.FAILED_PERMANENT -> R.string.queue_group_failed_permanent
    QueueGroup.EXPIRED -> R.string.queue_group_expired
}

@Composable
internal fun QueueRow(
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
                SettingsTimeFormatter.absolute(item.firstFailedAt)?.let { firstFailedAt ->
                    Text(
                        text = "首次失败：$firstFailedAt",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                SettingsTimeFormatter.absolute(item.nextAttemptAt)?.let { nextAttemptAt ->
                    Text(
                        text = "下次重试：$nextAttemptAt",
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

/**
 * @param resumeTick changes every time the host returns to the foreground, which restarts the
 *   cooldown wait. `delay` runs off a clock that does not advance while the process is frozen, so a
 *   deadline crossed in the background is only noticed by recomputing on arrival.
 */
@Composable
internal fun RecentResultCard(
    recent: RecentResult,
    busy: Boolean,
    clock: MobileClock,
    resumeTick: Long,
    onRefresh: () -> Unit,
    onClear: () -> Unit,
) {
    // Keyed on the whole record: a replacement recent, an identity switch and a cleared cooldown
    // all have to retire the wait that belonged to the previous one.
    var cooldownNow by remember(recent, resumeTick) { mutableLongStateOf(clock.now()) }
    LaunchedEffect(recent, resumeTick) {
        awaitCooldownDeadline(
            reason = recent.refreshBlockReason,
            refreshNotBefore = recent.refreshNotBefore,
            clock = clock,
            sleep = { delay(it) },
            onNow = { cooldownNow = it },
        )
    }
    val view = RecentProjection.of(recent, cooldownNow, busy)

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.recent_result), style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
            IconButton(onClick = onClear) { Icon(Icons.Default.Delete, contentDescription = stringResource(R.string.delete)) }
        }
        Card(shape = RoundedCornerShape(8.dp), modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (view.redacted) {
                    Text("身份已变更", color = MaterialTheme.colorScheme.error)
                } else {
                    Text(
                        view.url,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    Text(statusLabel(view.status), color = MaterialTheme.colorScheme.primary)
                    Text(
                        text = "Link ID：${view.linkId}",
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall,
                    )
                    view.resultTimeMillis?.let { resultTime ->
                        Text(
                            text = "结果时间：${formatTime(resultTime)}",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
                view.blockReason?.let { reason ->
                    Text(
                        text = when (reason) {
                            RetryPolicy.REFRESH_COOLDOWN_REASON -> "重新解析冷却中" +
                                (view.blockNotBefore?.let { " · ${formatTime(it)} 后可重试" } ?: "")
                            RetryPolicy.REFRESH_QUOTA_REASON -> "配额已用完，处理额度后可手动重试"
                            else -> reason
                        },
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                if (view.refreshVisible) {
                    OutlinedButton(onClick = onRefresh, enabled = view.refreshEnabled) {
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

private fun formatTime(epochMillis: Long): String = SettingsTimeFormatter.absolute(epochMillis).orEmpty()

private fun namespaceFingerprint(namespace: String?): String {
    if (namespace.isNullOrEmpty()) return "未知"
    val digest = MessageDigest.getInstance("SHA-256")
        .digest(namespace.toByteArray(Charsets.UTF_8))
    return digest
        .take(4)
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }
}
