import SwiftUI
import UIKit

enum CompanionDestination: String, Hashable {
    case today
    case todos
    case transfers
}

@MainActor
final class CompanionAppModel: ObservableObject {
    @Published private(set) var todos: CompanionTodoSnapshot = .empty
    @Published private(set) var activeIdentity: QueueIdentity?
    @Published private(set) var isSyncing = false
    @Published private(set) var syncStatus = ""

    private let queueRepository: AppGroupQueueRepository?
    private let todoRepository: CompanionTodoRepository?
    private let syncCoordinator: CompanionTodoSyncCoordinator?

    init(
        queueRepository injectedQueue: AppGroupQueueRepository? = nil,
        todoRepository injectedTodos: CompanionTodoRepository? = nil,
        credentials: KeychainCredentialStore = KeychainCredentialStore(),
        api: CompanionTodoAPI = CompanionTodoAPIClient()
    ) {
        let queue = injectedQueue ?? (try? AppGroupQueueRepository())
        let todos = injectedTodos ?? (try? CompanionTodoRepository())
        queueRepository = queue
        todoRepository = todos
        if let queue, let todos {
            syncCoordinator = CompanionTodoSyncCoordinator(
                repository: todos,
                queueRepository: queue,
                credentials: credentials,
                api: api
            )
        } else {
            syncCoordinator = nil
        }
        reload()
    }

    func reload() {
        do {
            let identity = try queueRepository?.activeIdentity()
            activeIdentity = identity
            todos = try identity.flatMap { try todoRepository?.snapshot(identity: $0) } ?? .empty
        } catch {
            activeIdentity = nil
            todos = .empty
            syncStatus = "无法读取本地待办"
        }
    }

    func onForegroundActive() {
        reload()
        synchronize()
    }

    func synchronize() {
        guard !isSyncing, let syncCoordinator, activeIdentity != nil else { return }
        isSyncing = true
        Task {
            let result = await syncCoordinator.synchronize()
            reload()
            isSyncing = false
            if let error = result.error {
                syncStatus = Self.status(for: error)
            } else if result.pulled {
                syncStatus = result.pushed > 0 ? "已同步 \(result.pushed) 项变更" : "已同步"
            } else {
                syncStatus = ""
            }
        }
    }

    func create(text: String, dueAt: Date?) {
        stage { identity, repository in
            try repository.stageCreate(
                identity: identity,
                request: CompanionTodoCreate(text: text, dueAt: dueAt)
            )
        }
    }

    func update(_ item: CompanionTodoItem, text: String, dueAt: Date?) {
        guard item.isStandalone else { return }
        stage { identity, repository in
            try repository.stagePatch(
                identity: identity,
                todoID: item.id,
                patch: CompanionTodoPatch(
                    text: text,
                    dueAt: dueAt,
                    dueAtSet: true,
                    done: nil,
                    expectedHostRevision: nil
                )
            )
        }
    }

    func toggle(_ item: CompanionTodoItem) {
        stage { identity, repository in
            try repository.stagePatch(
                identity: identity,
                todoID: item.id,
                patch: CompanionTodoPatch(
                    text: nil,
                    dueAt: nil,
                    dueAtSet: false,
                    done: !item.done,
                    expectedHostRevision: item.isStandalone ? nil : item.hostRevision
                )
            )
        }
    }

    func delete(_ item: CompanionTodoItem) {
        guard item.isStandalone else { return }
        stage { identity, repository in
            try repository.stageDelete(identity: identity, todoID: item.id)
        }
    }

    func sourceURL(for item: CompanionTodoItem) -> URL? {
        guard let identity = activeIdentity,
              let href = item.sourceHref,
              CompanionTodoItem.isSafeSourceHref(href),
              let base = URL(string: identity.origin),
              let url = URL(string: href, relativeTo: base)?.absoluteURL,
              url.scheme == base.scheme,
              url.host == base.host,
              url.port == base.port else {
            return nil
        }
        return url
    }

    private func stage(_ body: (QueueIdentity, CompanionTodoRepository) throws -> Void) {
        guard let identity = activeIdentity, let todoRepository else {
            syncStatus = "请先配置服务器连接"
            return
        }
        do {
            try body(identity, todoRepository)
            syncStatus = "已保存，等待同步"
            reload()
            synchronize()
        } catch {
            syncStatus = "无法保存待办"
        }
    }

    private static func status(for error: ErrorCategory) -> String {
        switch error {
        case .auth: return "凭证无效"
        case .scope: return "缺少 write 权限"
        case .identityMismatch: return "身份已变更"
        case .noNetwork, .dnsTimeout, .connectionReset, .clientDeadline: return "离线变更已保留"
        case .http409: return "待办发生冲突"
        case .localDataUnreadable: return "无法读取本地待办"
        default: return "同步暂时不可用"
        }
    }
}

struct ContentView: View {
    @StateObject private var settings = WebTagSettingsModel()
    @StateObject private var model = CompanionAppModel()
    @State private var selection: CompanionDestination = .today
    @State private var showingSettings = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $selection) {
            CompanionTodayScreen(
                model: model,
                settings: settings,
                openTodos: { selection = .todos },
                openTransfers: { selection = .transfers },
                openSettings: { showingSettings = true }
            )
            .tabItem { Label("今日", systemImage: "sun.max") }
            .tag(CompanionDestination.today)

            CompanionTodoScreen(model: model, openSettings: { showingSettings = true })
                .tabItem { Label("待办", systemImage: "checklist") }
                .tag(CompanionDestination.todos)

            CompanionTransferScreen(settings: settings, openSettings: { showingSettings = true })
                .tabItem { Label("传输", systemImage: "arrow.up.arrow.down") }
                .tag(CompanionDestination.transfers)
        }
        .sheet(isPresented: $showingSettings, onDismiss: {
            settings.reload()
            model.onForegroundActive()
        }) {
            SettingsScreen(model: settings)
        }
        .onAppear {
            settings.reload()
            model.onForegroundActive()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                settings.reload()
                model.onForegroundActive()
            }
        }
        .onOpenURL(perform: openDeepLink)
    }

    private func openDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "webtag" else { return }
        switch url.host?.lowercased() {
        case "today": selection = .today
        case "todos": selection = .todos
        case "transfers": selection = .transfers
        case "settings": showingSettings = true
        default: break
        }
    }
}

private struct CompanionTodayScreen: View {
    @ObservedObject var model: CompanionAppModel
    @ObservedObject var settings: WebTagSettingsModel
    let openTodos: () -> Void
    let openTransfers: () -> Void
    let openSettings: () -> Void
    @State private var showingCreate = false

    private var projection: CompanionTodoProjection {
        CompanionTodoPresenter.project(model.todos.items)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(Date.now.formatted(.dateTime.month().day().weekday(.wide)))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(summary)
                            .font(.title2.weight(.semibold))
                            .accessibilityIdentifier("today.summary")
                    }
                    .padding(.vertical, 4)
                }

                if model.activeIdentity == nil {
                    Section {
                        CompanionStatusView(title: "尚未连接 WebTag", detail: "完成连接后可使用离线待办和可靠传输。")
                        Button("设置连接", action: openSettings)
                    }
                } else {
                    Section {
                        let items = CompanionTodoPresenter.todayItems(model.todos.items)
                        if items.isEmpty {
                            CompanionStatusView(title: "待办已处理完", detail: "可以创建下一项，离线时也会保留。")
                        } else {
                            ForEach(items) { item in
                                CompanionTodoRow(item: item, model: model)
                            }
                        }
                        Button(action: openTodos) {
                            Label("查看全部待办", systemImage: "chevron.right")
                        }
                    } header: {
                        Text("需要处理")
                    }

                    Section("收藏传输") {
                        Button(action: openTransfers) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(transferSummary)
                                        .foregroundStyle(.primary)
                                    Text("系统分享产生的本地投递队列")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !model.syncStatus.isEmpty {
                    Section { Text(model.syncStatus).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("今日")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { model.synchronize() } label: {
                        if model.isSyncing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .accessibilityLabel("同步")
                    .disabled(model.isSyncing || model.activeIdentity == nil)
                }
                ToolbarItem(placement: .navigationBarTrailing) { SettingsButton(action: openSettings) }
            }
            .safeAreaInset(edge: .bottom) {
                if model.activeIdentity != nil {
                    Button { showingCreate = true } label: {
                        Label("新建待办", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
            }
            .sheet(isPresented: $showingCreate) {
                CompanionTodoEditor(item: nil) { text, dueAt in
                    model.create(text: text, dueAt: dueAt)
                    showingCreate = false
                }
            }
        }
    }

    private var summary: String {
        if projection.overdueCount > 0 {
            return "\(projection.overdueCount) 项已逾期 · \(projection.todayCount) 项今天截止"
        }
        if projection.todayCount > 0 { return "\(projection.todayCount) 项今天截止" }
        if projection.openCount > 0 { return "\(projection.openCount) 项待完成" }
        return "今天没有待处理事项"
    }

    private var transferSummary: String {
        let total = settings.projection.queue.total
        let needsAction = settings.projection.queue.groups
            .filter { $0.group != .pendingAndRetry }
            .reduce(0) { $0 + $1.count }
        if needsAction > 0 { return "\(needsAction) 条需要处理 · \(max(0, total - needsAction)) 条等待发送" }
        if total > 0 { return "\(total) 条正在等待发送或重试" }
        return "所有收藏均已送达"
    }
}

private struct CompanionTodoScreen: View {
    @ObservedObject var model: CompanionAppModel
    let openSettings: () -> Void
    @State private var filter: CompanionTodoFilter = .all
    @State private var showingCreate = false
    @State private var editing: CompanionTodoItem?
    @State private var deleting: CompanionTodoItem?

    private var projection: CompanionTodoProjection {
        CompanionTodoPresenter.project(model.todos.items, filter: filter)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("范围", selection: $filter) {
                        Text("全部").tag(CompanionTodoFilter.all)
                        Text("我的").tag(CompanionTodoFilter.standalone)
                        Text("来自内容").tag(CompanionTodoFilter.projected)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("todos.filter")

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(projection.days) { day in
                                VStack(spacing: 3) {
                                    Text(Calendar.current.isDateInToday(day.date) ? "今天" : day.date.formatted(.dateTime.weekday(.narrow)))
                                    Text("\(Calendar.current.component(.day, from: day.date)) · \(day.count)")
                                        .fontWeight(.semibold)
                                }
                                .font(.caption)
                                .frame(width: 54, height: 48)
                                .background(Calendar.current.isDateInToday(day.date) ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }

                    if model.todos.pendingOperations > 0 || model.todos.blockedOperations > 0 {
                        Text(operationSummary)
                            .font(.footnote)
                            .foregroundStyle(model.todos.blockedOperations > 0 ? .red : .secondary)
                    }
                }

                if model.activeIdentity == nil {
                    Section {
                        CompanionStatusView(title: "尚未连接", detail: "请先设置服务器地址和 API Key。")
                        Button("设置连接", action: openSettings)
                    }
                } else if model.todos.todosEnabled == false {
                    Section { CompanionStatusView(title: "待办不可用", detail: "当前服务器没有启用待办能力。") }
                } else if projection.isEmpty {
                    Section { CompanionStatusView(title: "还没有待办", detail: "点击右上角添加第一项。") }
                } else {
                    ForEach(projection.sections.filter { !$0.items.isEmpty }) { section in
                        Section(sectionTitle(section.section)) {
                            ForEach(section.items) { item in
                                CompanionTodoRow(
                                    item: item,
                                    model: model,
                                    onEdit: item.isStandalone ? { editing = item } : nil,
                                    onDelete: item.isStandalone ? { deleting = item } : nil
                                )
                            }
                        }
                    }
                }

                if !model.syncStatus.isEmpty {
                    Section { Text(model.syncStatus).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("待办")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { showingCreate = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("新建待办")
                        .disabled(model.activeIdentity == nil || model.todos.todosEnabled == false)
                    SettingsButton(action: openSettings)
                }
            }
            .refreshable { model.synchronize() }
            .sheet(isPresented: $showingCreate) {
                CompanionTodoEditor(item: nil) { text, dueAt in
                    model.create(text: text, dueAt: dueAt)
                    showingCreate = false
                }
            }
            .sheet(item: $editing) { item in
                CompanionTodoEditor(item: item) { text, dueAt in
                    model.update(item, text: text, dueAt: dueAt)
                    editing = nil
                }
            }
            .confirmationDialog("删除待办？", isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let deleting { model.delete(deleting) }
                    deleting = nil
                }
                Button("取消", role: .cancel) { deleting = nil }
            } message: {
                Text(deleting?.text ?? "")
            }
        }
    }

    private var operationSummary: String {
        var parts: [String] = []
        if model.todos.pendingOperations > 0 { parts.append("\(model.todos.pendingOperations) 项待同步") }
        if model.todos.blockedOperations > 0 { parts.append("\(model.todos.blockedOperations) 项需要处理") }
        return parts.joined(separator: " · ")
    }

    private func sectionTitle(_ section: CompanionTodoSection) -> String {
        switch section {
        case .overdue: return "已逾期"
        case .today: return "今天"
        case .upcoming: return "接下来"
        case .unscheduled: return "无日期"
        case .completed: return "已完成"
        }
    }
}

private struct CompanionTodoRow: View {
    let item: CompanionTodoItem
    @ObservedObject var model: CompanionAppModel
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { model.toggle(item) } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.done ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.done ? "恢复" : "完成")

            VStack(alignment: .leading, spacing: 5) {
                Text(item.text)
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    if let dueAt = item.dueAt {
                        Text(dueLabel(dueAt))
                            .foregroundStyle(!item.done && dueAt < Calendar.current.startOfDay(for: Date.now) ? Color.red : Color.secondary)
                    }
                    if !item.isStandalone { Label(originLabel, systemImage: "link") }
                    if item.pending { Label("待同步", systemImage: "clock") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let source = model.sourceURL(for: item) {
                Button { openURL(source) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("打开来源")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onEdit?() }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let onDelete { Button("删除", role: .destructive, action: onDelete) }
            if let onEdit { Button("编辑", action: onEdit).tint(.blue) }
        }
    }

    private var originLabel: String {
        switch item.originKind {
        case .thought: return "想法"
        case .note: return "笔记"
        case .inbox: return "Inbox"
        case .standalone: return "我的"
        }
    }

    private func dueLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "今天" }
        if Calendar.current.isDateInTomorrow(date) { return "明天" }
        return date.formatted(.dateTime.month().day())
    }
}

private struct CompanionTodoEditor: View {
    let item: CompanionTodoItem?
    let save: (String, Date?) -> Void
    @State private var text: String
    @State private var dueAt: Date?
    @Environment(\.dismiss) private var dismiss

    init(item: CompanionTodoItem?, save: @escaping (String, Date?) -> Void) {
        self.item = item
        self.save = save
        _text = State(initialValue: item?.text ?? "")
        _dueAt = State(initialValue: item?.dueAt)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("待办内容") {
                    TextEditor(text: $text)
                        .frame(minHeight: 90)
                        .onChange(of: text) { value in
                            if value.count > 4096 { text = String(value.prefix(4096)) }
                        }
                        .accessibilityIdentifier("todos.editor.text")
                }
                Section("截止时间") {
                    Picker("快捷选择", selection: Binding(
                        get: { dueChoice },
                        set: { dueAt = date(for: $0) }
                    )) {
                        Text("无日期").tag(0)
                        Text("今天").tag(1)
                        Text("明天").tag(2)
                        Text("下周").tag(3)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle(item == nil ? "新建待办" : "编辑待办")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save(text.trimmingCharacters(in: .whitespacesAndNewlines), dueAt) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("todos.editor.save")
                }
            }
        }
    }

    private var dueChoice: Int {
        guard let dueAt else { return 0 }
        let calendar = Calendar.current
        if calendar.isDateInToday(dueAt) { return 1 }
        if calendar.isDateInTomorrow(dueAt) { return 2 }
        let nextWeek = date(for: 3)
        if nextWeek.map({ calendar.isDate($0, inSameDayAs: dueAt) }) == true { return 3 }
        return 0
    }

    private func date(for choice: Int) -> Date? {
        guard choice != 0 else { return nil }
        let days = choice == 1 ? 0 : choice == 2 ? 1 : 7
        let calendar = Calendar.current
        guard let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: Date.now)) else { return nil }
        return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day)
    }
}

private struct CompanionTransferScreen: View {
    @ObservedObject var settings: WebTagSettingsModel
    let openSettings: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("此设备 · \(settings.projection.queue.total) 条")
                            .font(.headline)
                        Text("系统分享产生的本地收藏投递")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if settings.activeIdentity == nil {
                    Section {
                        CompanionStatusView(title: "尚未连接", detail: "完成连接后，系统分享会自动进入可靠传输队列。")
                        Button("设置连接", action: openSettings)
                    }
                } else if settings.projection.queue.total == 0 {
                    Section { CompanionStatusView(title: "所有收藏均已送达", detail: "新的分享会在这里显示发送与重试状态。") }
                } else {
                    ForEach(settings.projection.queue.groups, id: \.group) { group in
                        Section("\(group.group.title) · \(group.count) 条") {
                            ForEach(group.rows, id: \.id) { entry in
                                QueueEntryRow(
                                    entry: entry,
                                    retry: { settings.retry(entry) },
                                    migrate: { settings.requestIdentityMigration(entry); openSettings() },
                                    delete: { settings.delete(entry) }
                                )
                            }
                        }
                    }
                    Section {
                        Button("重试可恢复条目") { settings.retryRecoverable() }
                        Button("清空传输队列", role: .destructive) { settings.showClearConfirmation = true }
                    }
                }

                if let recent = settings.recent, !recent.isIdentityMismatch {
                    Section("最近结果") {
                        Text(recent.url).lineLimit(3)
                        Text(recent.status == "failed" ? "已在库中，解析失败" : "已送达")
                            .foregroundStyle(recent.status == "failed" ? .red : .green)
                    }
                }
            }
            .navigationTitle("传输")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { settings.onForegroundActive() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("同步传输")
                }
                ToolbarItem(placement: .navigationBarTrailing) { SettingsButton(action: openSettings) }
            }
            .onAppear { settings.onForegroundActive() }
            .confirmationDialog("清空待处理条目？", isPresented: $settings.showClearConfirmation) {
                Button("确认", role: .destructive) { settings.clearQueue() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这会删除本地队列中的 \(settings.projection.queue.total) 条记录。")
            }
            .confirmationDialog("再次提交失败条目？", isPresented: $settings.showPermanentRetryConfirmation) {
                Button("确认重试") { settings.confirmPermanentRetry() }
                Button("取消", role: .cancel) {}
            }
        }
    }
}

private struct SettingsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "gearshape") }
            .accessibilityLabel("设置")
            .accessibilityIdentifier("app.settings")
    }
}

private struct CompanionStatusView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

#Preview { ContentView() }
