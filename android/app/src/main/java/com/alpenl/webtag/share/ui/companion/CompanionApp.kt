package com.alpenl.webtag.share.ui.companion

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.CloudUpload
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.Today
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import androidx.room.InvalidationTracker
import com.alpenl.webtag.share.QueueGroupHeader
import com.alpenl.webtag.share.QueueRow
import com.alpenl.webtag.share.RecentResultCard
import com.alpenl.webtag.share.SettingsScreen
import com.alpenl.webtag.share.contract.QueueIdentity
import com.alpenl.webtag.share.contract.QueueState
import com.alpenl.webtag.share.data.TodoLocalSnapshot
import com.alpenl.webtag.share.queue.MobileRuntime
import com.alpenl.webtag.share.settings.QueueGroup
import com.alpenl.webtag.share.settings.SettingsProjection
import com.alpenl.webtag.share.settings.runForegroundConvergence
import com.alpenl.webtag.share.todo.TodoCreate
import com.alpenl.webtag.share.todo.TodoFilter
import com.alpenl.webtag.share.todo.TodoItem
import com.alpenl.webtag.share.todo.TodoPatch
import com.alpenl.webtag.share.todo.TodoPresenter
import com.alpenl.webtag.share.todo.TodoSection
import com.alpenl.webtag.share.todo.TodoSectionView
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal enum class CompanionDestination(
    val title: String,
) {
    TODAY("今日"),
    TODOS("待办"),
    TRANSFERS("传输"),
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CompanionApp(runtime: MobileRuntime, deepLinkRoute: String? = null) {
    val scope = rememberCoroutineScope()
    val source = remember(runtime) { RuntimeCompanionSnapshotSource(runtime) }
    val loader = remember(source) { CompanionSnapshotLoader(source) }
    var snapshot by remember { mutableStateOf(CompanionSnapshot.EMPTY) }
    var destination by remember { mutableStateOf(CompanionDestination.TODAY) }
    var showingSettings by remember { mutableStateOf(false) }
    var resumeTick by remember { mutableLongStateOf(0L) }
    val snackbar = remember { SnackbarHostState() }

    LaunchedEffect(deepLinkRoute) {
        when (deepLinkRoute) {
            "today" -> {
                destination = CompanionDestination.TODAY
                showingSettings = false
            }
            "todos" -> {
                destination = CompanionDestination.TODOS
                showingSettings = false
            }
            "transfers" -> {
                destination = CompanionDestination.TRANSFERS
                showingSettings = false
            }
            "settings" -> showingSettings = true
        }
    }

    suspend fun reloadLocal() {
        loader.load { snapshot = it }
    }

    DisposableEffect(runtime) {
        val observer = object : InvalidationTracker.Observer(
            "queue_entries",
            "recent_results",
            "active_session",
            "todo_cache",
            "todo_outbox",
            "todo_sync_state",
        ) {
            override fun onInvalidated(tables: Set<String>) {
                scope.launch { reloadLocal() }
            }
        }
        runtime.database.invalidationTracker.addObserver(observer)
        onDispose { runtime.database.invalidationTracker.removeObserver(observer) }
    }

    val lifecycleOwner = LocalLifecycleOwner.current
    LaunchedEffect(lifecycleOwner, runtime) {
        lifecycleOwner.lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            resumeTick += 1
            runForegroundConvergence(
                reload = { reloadLocal() },
                reconcile = { runtime.reconcileForeground() },
            )
        }
    }

    BackHandler(enabled = showingSettings) { showingSettings = false }

    Scaffold(
        modifier = Modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                title = { Text(if (showingSettings) "设置" else destination.title) },
                navigationIcon = {
                    if (showingSettings) {
                        IconButton(onClick = { showingSettings = false }) {
                            Icon(Icons.Default.ArrowBack, contentDescription = "返回")
                        }
                    }
                },
                actions = {
                    if (!showingSettings) {
                        IconButton(onClick = { showingSettings = true }) {
                            Icon(Icons.Default.Settings, contentDescription = "设置")
                        }
                    }
                },
            )
        },
        bottomBar = {
            if (!showingSettings) {
                NavigationBar {
                    CompanionDestination.entries.forEach { item ->
                        NavigationBarItem(
                            selected = destination == item,
                            onClick = { destination = item },
                            icon = {
                                Icon(
                                    imageVector = when (item) {
                                        CompanionDestination.TODAY -> Icons.Default.Today
                                        CompanionDestination.TODOS -> Icons.Default.Checklist
                                        CompanionDestination.TRANSFERS -> Icons.Default.CloudUpload
                                    },
                                    contentDescription = null,
                                )
                            },
                            label = { Text(item.title, maxLines = 1) },
                        )
                    }
                }
            }
        },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        if (showingSettings) {
            Column(Modifier.padding(padding)) {
                SettingsScreen(
                    runtime = runtime,
                    projection = snapshot.settings,
                    todoSnapshot = snapshot.todos,
                    resumeTick = resumeTick,
                    reloadLocal = { reloadLocal() },
                )
            }
        } else {
            when (destination) {
                CompanionDestination.TODAY -> TodayScreen(
                    runtime = runtime,
                    snapshot = snapshot,
                    modifier = Modifier.padding(padding),
                    openTodos = { destination = CompanionDestination.TODOS },
                    openTransfers = { destination = CompanionDestination.TRANSFERS },
                    snackbar = snackbar,
                )
                CompanionDestination.TODOS -> TodoScreen(
                    runtime = runtime,
                    snapshot = snapshot.todos,
                    modifier = Modifier.padding(padding),
                    snackbar = snackbar,
                )
                CompanionDestination.TRANSFERS -> TransferScreen(
                    runtime = runtime,
                    projection = snapshot.settings,
                    resumeTick = resumeTick,
                    modifier = Modifier.padding(padding),
                    openSettings = { showingSettings = true },
                    reloadLocal = { scope.launch { reloadLocal() } },
                )
            }
        }
    }
}

@Composable
private fun TodayScreen(
    runtime: MobileRuntime,
    snapshot: CompanionSnapshot,
    modifier: Modifier,
    openTodos: () -> Unit,
    openTransfers: () -> Unit,
    snackbar: SnackbarHostState,
) {
    val scope = rememberCoroutineScope()
    val zone = remember { ZoneId.systemDefault() }
    val now = runtime.clock.now()
    val projection = remember(snapshot.todos.items, now, zone) {
        TodoPresenter.project(snapshot.todos.items, now, zone)
    }
    val items = remember(snapshot.todos.items, now, zone) {
        TodoPresenter.todayItems(snapshot.todos.items, now, zone)
    }
    var showCreate by remember { mutableStateOf(false) }

    LazyColumn(
        modifier = modifier.fillMaxSize().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Spacer(Modifier.height(4.dp))
            Text(
                text = LocalDate.now(zone).format(DateTimeFormatter.ofPattern("M 月 d 日 EEEE", Locale.CHINA)),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodyMedium,
            )
            Text(
                text = when {
                    projection.overdueCount > 0 -> "${projection.overdueCount} 项已逾期 · ${projection.todayCount} 项今天截止"
                    projection.todayCount > 0 -> "${projection.todayCount} 项今天截止"
                    projection.openCount > 0 -> "${projection.openCount} 项待完成"
                    else -> "今天没有待处理事项"
                },
                style = MaterialTheme.typography.headlineSmall,
            )
        }
        if (snapshot.settings.activeNamespace == null) {
            item {
                QuietStatusCard(
                    title = "尚未连接 WebTag",
                    detail = "请从右上角设置服务器地址和 API Key。",
                )
            }
        } else {
            item { SectionHeading("需要处理", items.size, openTodos) }
            if (items.isEmpty()) {
                item { QuietStatusCard("待办已处理完", "可以创建下一项，离线时也会安全保存。") }
            } else {
                items(items, key = TodoItem::id) { item ->
                    TodoRow(
                        item = item,
                        now = now,
                        zone = zone,
                        onToggle = { toggleTodo(scope, runtime, item, snackbar) },
                    )
                }
            }
            item {
                FilledTonalButton(
                    onClick = { showCreate = true },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Icon(Icons.Default.Add, contentDescription = null)
                    Text("新建待办", modifier = Modifier.padding(start = 8.dp))
                }
            }
            item {
                val total = snapshot.settings.queue.total
                val needsAction = snapshot.settings.queue.groups
                    .filterNot { it.group == QueueGroup.PENDING_AND_RETRY }
                    .sumOf { it.count }
                HorizontalDivider()
                SectionHeading("收藏传输", total, openTransfers)
                Text(
                    text = when {
                        needsAction > 0 -> "$needsAction 条需要处理 · ${total - needsAction} 条等待发送"
                        total > 0 -> "$total 条正在等待发送或重试"
                        else -> "所有收藏均已送达"
                    },
                    color = if (needsAction > 0) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        }
        item { Spacer(Modifier.height(12.dp)) }
    }

    if (showCreate) {
        TodoEditorSheet(
            initial = null,
            onDismiss = { showCreate = false },
            onSave = { text, dueAt ->
                stageTodo(scope, runtime, snackbar) { identity ->
                    runtime.todoRepository.stageCreate(identity, TodoCreate(text, dueAt))
                }
                showCreate = false
            },
        )
    }
}

@Composable
private fun TodoScreen(
    runtime: MobileRuntime,
    snapshot: TodoLocalSnapshot,
    modifier: Modifier,
    snackbar: SnackbarHostState,
) {
    val scope = rememberCoroutineScope()
    val zone = remember { ZoneId.systemDefault() }
    val now = runtime.clock.now()
    var filter by remember { mutableStateOf(TodoFilter.ALL) }
    var showCreate by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<TodoItem?>(null) }
    var deleting by remember { mutableStateOf<TodoItem?>(null) }
    val projection = remember(snapshot.items, filter, now, zone) {
        TodoPresenter.project(snapshot.items, now, zone, filter)
    }
    val listState = rememberLazyListState()

    Scaffold(
        modifier = modifier.fillMaxSize(),
        floatingActionButton = {
            if (snapshot.todosEnabled != false) {
                FloatingActionButton(onClick = { showCreate = true }) {
                    Icon(Icons.Default.Add, contentDescription = "新建待办")
                }
            }
        },
    ) { padding ->
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize().padding(padding),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            item {
                Column(
                    modifier = Modifier.padding(horizontal = 16.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TodoFilter.entries.forEach { item ->
                            FilterChip(
                                selected = filter == item,
                                onClick = { filter = item },
                                label = {
                                    Text(
                                        when (item) {
                                            TodoFilter.ALL -> "全部"
                                            TodoFilter.STANDALONE -> "我的"
                                            TodoFilter.PROJECTED -> "来自内容"
                                        },
                                    )
                                },
                            )
                        }
                    }
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        items(projection.days, key = { it.date.toString() }) { day ->
                            val today = day.date == LocalDate.now(zone)
                            AssistChip(
                                onClick = {
                                    scope.launch {
                                        listState.animateScrollToItem(
                                            sectionListIndex(
                                                if (today) TodoSection.TODAY else TodoSection.UPCOMING,
                                                projection.sections,
                                            ),
                                        )
                                    }
                                },
                                label = {
                                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                        Text(if (today) "今天" else day.date.dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.CHINA))
                                        Text("${day.date.dayOfMonth} · ${day.count}", fontWeight = FontWeight.SemiBold)
                                    }
                                },
                            )
                        }
                    }
                    if (snapshot.pendingOperations > 0 || snapshot.blockedOperations > 0) {
                        Text(
                            text = buildString {
                                if (snapshot.pendingOperations > 0) append("${snapshot.pendingOperations} 项待同步")
                                if (snapshot.blockedOperations > 0) {
                                    if (isNotEmpty()) append(" · ")
                                    append("${snapshot.blockedOperations} 项需要处理")
                                }
                            },
                            color = if (snapshot.blockedOperations > 0) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
            }
            if (snapshot.todosEnabled == false) {
                item { QuietStatusCard("待办不可用", "当前服务器没有启用待办能力。", Modifier.padding(horizontal = 16.dp)) }
            } else if (projection.isEmpty) {
                item { QuietStatusCard("还没有待办", "点击右下角添加第一项。", Modifier.padding(horizontal = 16.dp)) }
            } else {
                projection.sections.forEach { section ->
                    if (section.items.isNotEmpty()) {
                        item(key = "section-${section.section}") {
                            TodoSectionHeading(section)
                        }
                        items(section.items, key = TodoItem::id) { item ->
                            TodoRow(
                                item = item,
                                now = now,
                                zone = zone,
                                modifier = Modifier.padding(horizontal = 16.dp),
                                onToggle = { toggleTodo(scope, runtime, item, snackbar) },
                                onClick = { if (item.isStandalone) editing = item },
                                onDelete = if (item.isStandalone) ({ deleting = item }) else null,
                            )
                        }
                    }
                }
            }
            item { Spacer(Modifier.height(80.dp)) }
        }
    }

    if (showCreate || editing != null) {
        val target = editing
        TodoEditorSheet(
            initial = target,
            onDismiss = {
                showCreate = false
                editing = null
            },
            onSave = { text, dueAt ->
                stageTodo(scope, runtime, snackbar) { identity ->
                    if (target == null) {
                        runtime.todoRepository.stageCreate(identity, TodoCreate(text, dueAt))
                    } else {
                        runtime.todoRepository.stagePatch(
                            identity,
                            target.id,
                            TodoPatch(text = text, dueAt = dueAt, dueAtSet = true),
                        )
                    }
                }
                showCreate = false
                editing = null
            },
        )
    }

    deleting?.let { item ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text("删除待办？") },
            text = { Text(item.text) },
            confirmButton = {
                TextButton(onClick = {
                    stageTodo(scope, runtime, snackbar) { identity ->
                        runtime.todoRepository.stageDelete(identity, item.id)
                    }
                    deleting = null
                }) { Text("删除") }
            },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("取消") } },
        )
    }
}

@Composable
private fun TransferScreen(
    runtime: MobileRuntime,
    projection: SettingsProjection,
    resumeTick: Long,
    modifier: Modifier,
    openSettings: () -> Unit,
    reloadLocal: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var clearing by remember { mutableStateOf(false) }
    var refreshBusy by remember { mutableStateOf(false) }

    fun retry(id: String) {
        scope.launch {
            withContext(Dispatchers.IO) {
                runtime.repository.retry(id)
                runtime.scheduler.schedule()
            }
            reloadLocal()
        }
    }

    LazyColumn(
        modifier = modifier.fillMaxSize().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("此设备 · ${projection.queue.total} 条", style = MaterialTheme.typography.titleMedium)
                    Text("系统分享产生的本地收藏投递", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                IconButton(onClick = {
                    scope.launch {
                        runtime.reconcileForeground()
                        reloadLocal()
                    }
                }) { Icon(Icons.Default.Sync, contentDescription = "同步传输") }
            }
        }
        if (projection.activeNamespace == null) {
            item {
                QuietStatusCard("尚未连接", "完成连接后，系统分享会自动进入可靠传输队列。")
                Button(onClick = openSettings, modifier = Modifier.fillMaxWidth()) { Text("设置连接") }
            }
        } else if (projection.queue.isEmpty) {
            item { QuietStatusCard("所有收藏均已送达", "新的分享会在这里显示发送与重试状态。") }
        } else {
            projection.queue.groups.forEach { group ->
                item(key = "transfer-${group.group.key}") { QueueGroupHeader(group) }
                items(group.rows, key = { it.id }) { item ->
                    QueueRow(
                        item = item,
                        onRetry = {
                            if (item.state == QueueState.BLOCKED_IDENTITY || item.state == QueueState.FAILED_PERMANENT) {
                                openSettings()
                            } else {
                                retry(item.id)
                            }
                        },
                        onMigrate = openSettings,
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
                                    runtime.activeConfiguration()?.let {
                                        runtime.repository.retryRecoverable(QueueIdentity(it.origin, it.namespace))
                                    }
                                    runtime.scheduler.schedule()
                                }
                                reloadLocal()
                            }
                        },
                    ) { Text("重试可恢复条目") }
                    OutlinedButton(
                        modifier = Modifier.weight(1f),
                        onClick = { clearing = true },
                    ) { Text("清空") }
                }
            }
        }
        projection.recent?.let { recent ->
            item {
                RecentResultCard(
                    recent = recent,
                    busy = refreshBusy,
                    clock = runtime.clock,
                    resumeTick = resumeTick,
                    onRefresh = {
                        refreshBusy = true
                        scope.launch {
                            withContext(Dispatchers.IO) { runtime.refreshCoordinator.refresh(recent) }
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
        item { Spacer(Modifier.height(16.dp)) }
    }

    if (clearing) {
        AlertDialog(
            onDismissRequest = { clearing = false },
            title = { Text("清空待处理条目？") },
            text = { Text("这会删除本机传输队列中的 ${projection.queue.total} 条记录。") },
            confirmButton = {
                TextButton(onClick = {
                    scope.launch {
                        withContext(Dispatchers.IO) { runtime.repository.clear() }
                        clearing = false
                        reloadLocal()
                    }
                }) { Text("确认") }
            },
            dismissButton = { TextButton(onClick = { clearing = false }) { Text("取消") } },
        )
    }
}

@Composable
private fun TodoRow(
    item: TodoItem,
    now: Long,
    zone: ZoneId,
    modifier: Modifier = Modifier,
    onToggle: () -> Unit,
    onClick: (() -> Unit)? = null,
    onDelete: (() -> Unit)? = null,
) {
    Card(
        modifier = modifier.fillMaxWidth(),
        onClick = onClick ?: {},
        enabled = onClick != null,
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp, horizontal = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Checkbox(checked = item.done, onCheckedChange = { onToggle() })
            Column(Modifier.weight(1f)) {
                Text(
                    text = item.text,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                    style = MaterialTheme.typography.bodyLarge,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    item.dueAt?.let {
                        Text(
                            text = dueLabel(it, now, zone),
                            color = if (!item.done && it < now) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                    if (!item.isStandalone) {
                        Text("来自${item.originKind.wireValue}", color = MaterialTheme.colorScheme.tertiary, style = MaterialTheme.typography.bodySmall)
                    }
                    if (item.pending) {
                        Text("待同步", color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
            onDelete?.let {
                IconButton(onClick = it) { Icon(Icons.Default.Delete, contentDescription = "删除") }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TodoEditorSheet(
    initial: TodoItem?,
    onDismiss: () -> Unit,
    onSave: (String, Long?) -> Unit,
) {
    val zone = remember { ZoneId.systemDefault() }
    var text by remember(initial) { mutableStateOf(initial?.text.orEmpty()) }
    var dueAt by remember(initial) { mutableStateOf(initial?.dueAt) }
    val now = remember { System.currentTimeMillis() }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(if (initial == null) "新建待办" else "编辑待办", style = MaterialTheme.typography.titleLarge)
            OutlinedTextField(
                value = text,
                onValueChange = { if (it.length <= 4096) text = it },
                label = { Text("待办内容") },
                modifier = Modifier.fillMaxWidth(),
                minLines = 2,
                maxLines = 5,
            )
            Text("截止时间", style = MaterialTheme.typography.labelLarge)
            LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                item {
                    FilterChip(
                        selected = dueAt == null,
                        onClick = { dueAt = null },
                        label = { Text("无日期") },
                    )
                }
                items(listOf(0L to "今天", 1L to "明天", 7L to "下周")) { (days, label) ->
                    val target = LocalDate.now(zone).plusDays(days).atTime(18, 0).atZone(zone).toInstant().toEpochMilli()
                    FilterChip(
                        selected = dueAt?.let { Instant.ofEpochMilli(it).atZone(zone).toLocalDate() } == LocalDate.now(zone).plusDays(days),
                        onClick = { dueAt = target },
                        label = { Text(label) },
                    )
                }
            }
            dueAt?.let { Text("截止 ${dueLabel(it, now, zone)}", color = MaterialTheme.colorScheme.onSurfaceVariant) }
            Button(
                onClick = { onSave(text.trim(), dueAt) },
                enabled = text.isNotBlank(),
                modifier = Modifier.fillMaxWidth(),
            ) { Text("保存") }
            Spacer(Modifier.height(20.dp))
        }
    }
}

@Composable
private fun TodoSectionHeading(section: TodoSectionView) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = when (section.section) {
                TodoSection.OVERDUE -> "已逾期"
                TodoSection.TODAY -> "今天"
                TodoSection.UPCOMING -> "接下来"
                TodoSection.UNSCHEDULED -> "无日期"
                TodoSection.COMPLETED -> "已完成"
            },
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.weight(1f),
        )
        Text("${section.items.size} 项", color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun SectionHeading(title: String, count: Int, onClick: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("$title · $count", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
        TextButton(onClick = onClick) { Text("查看全部") }
    }
}

@Composable
private fun QuietStatusCard(title: String, detail: String, modifier: Modifier = Modifier) {
    Card(modifier = modifier.fillMaxWidth()) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            Text(detail, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
        }
    }
}

private fun toggleTodo(
    scope: CoroutineScope,
    runtime: MobileRuntime,
    item: TodoItem,
    snackbar: SnackbarHostState,
) {
    stageTodo(scope, runtime, snackbar, message = if (item.done) "待办已恢复" else "待办已完成") { identity ->
        runtime.todoRepository.stagePatch(
            identity,
            item.id,
            TodoPatch(
                done = !item.done,
                expectedHostRevision = item.hostRevision.takeUnless { item.isStandalone },
            ),
        )
    }
}

private fun stageTodo(
    scope: CoroutineScope,
    runtime: MobileRuntime,
    snackbar: SnackbarHostState,
    message: String = "已保存，等待同步",
    action: (QueueIdentity) -> Unit,
) {
    scope.launch {
        val staged = withContext(Dispatchers.IO) {
            val config = runtime.activeConfiguration() ?: return@withContext false
            runCatching {
                action(QueueIdentity(config.origin, config.namespace))
                runtime.todoScheduler.schedule()
            }.isSuccess
        }
        snackbar.showSnackbar(if (staged) message else "无法保存待办变更")
    }
}

private fun sectionListIndex(target: TodoSection, sections: List<TodoSectionView>): Int {
    var index = 1
    for (section in sections) {
        if (section.items.isEmpty()) continue
        if (section.section == target) return index
        index += 1 + section.items.size
    }
    return 0
}

private fun dueLabel(epochMillis: Long, now: Long, zone: ZoneId): String {
    val due = Instant.ofEpochMilli(epochMillis).atZone(zone)
    val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
    val date = due.toLocalDate()
    val day = when (date) {
        today -> "今天"
        today.plusDays(1) -> "明天"
        else -> date.format(DateTimeFormatter.ofPattern("M 月 d 日", Locale.CHINA))
    }
    return "$day ${due.format(DateTimeFormatter.ofPattern("HH:mm"))}"
}
