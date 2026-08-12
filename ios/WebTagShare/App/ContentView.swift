import SwiftUI
import CryptoKit
import Foundation

private func sameLinkID(_ left: String, _ right: String) -> Bool {
    guard let leftUUID = UUID(uuidString: left), let rightUUID = UUID(uuidString: right) else { return false }
    return leftUUID == rightUUID
}

@MainActor
final class WebTagSettingsModel: ObservableObject {
    @Published var origin = ""
    @Published var apiKey = ""
    @Published var keyVisible = false
    @Published var status = ""
    @Published var isBusy = false
    @Published var showClearConfirmation = false
    @Published var showPermanentRetryConfirmation = false
    @Published var showIdentityMigrationConfirmation = false
    @Published var refreshBusy = false

    /// Everything the queue and recent sections render, always from one durable
    /// read. `origin` and `apiKey` are deliberately outside it: a lifecycle reload
    /// replaces this value wholesale, and an unsaved credential draft must survive
    /// that, so it is unrepresentable here rather than merely carefully avoided.
    @Published private(set) var projection: SettingsProjection = .empty
    /// Recomputed from `projection.recent` and the clock, and re-evaluated by the
    /// cooldown timer at the exact deadline so the button unlocks on its own.
    @Published private(set) var refreshGate: SettingsRecentRefreshGate = .unavailable

    var queue: [QueueEntry] { projection.queue.groups.flatMap(\.rows) }
    var recent: RecentResult? { projection.recent }

    private let repository: AppGroupQueueRepository?
    private let coordinator: ShareSubmissionCoordinator?
    private let keychain = KeychainCredentialStore()
    private let api = WebTagAPIClient()
    private var pendingIdentityMigration: QueueEntry?
    private let loader: SettingsSnapshotLoader?
    private let clock: SettingsWallClock
    private let cooldownTimer: SettingsCooldownTimer

    /// `repository` is injectable so a test can drive a real repository in a
    /// temporary directory. Without it the only way in is the app group container,
    /// which a unit test host does not reliably have.
    init(clock: SettingsWallClock = SystemSettingsWallClock(), repository injected: AppGroupQueueRepository? = nil) {
        let resolved = injected ?? (try? AppGroupQueueRepository())
        repository = resolved
        coordinator = resolved.map { ShareSubmissionCoordinator(repository: $0) }
        loader = resolved.map { SettingsSnapshotLoader(repository: $0) }
        self.clock = clock
        cooldownTimer = SettingsCooldownTimer(clock: clock)
        if let repository {
            do {
                if let stored = try keychain.loadConfig() {
                    let active = try repository.activeSessionIdentity()
                    if active != stored.identity {
                        try? repository.activate(session: stored.identity)
                    }
                    origin = stored.identity.origin
                    apiKey = stored.apiKey
                    status = stored.identity.canWrite ? "连接正常" : "缺少 write 权限"
                }
            } catch {
                status = ""
            }
        }
        reload()
    }

    var activeIdentity: QueueIdentity? {
        guard let repository else { return nil }
        do { return try repository.activeIdentity() } catch { return nil }
    }

    /// One identity-fenced read, committed only if it is still the current one.
    ///
    /// A snapshot that lost the race — taken under an identity that has since been
    /// replaced, or overtaken by a newer read — is dropped rather than shown. The
    /// old failure mode was the opposite: whichever read finished last won, so a
    /// slow load from the previous identity could repaint the screen with its data.
    func reload() {
        guard let loader, let projection = loader.loadProjection() else { return }
        apply(projection)
    }

    /// The foreground contract: read once on becoming active, let the existing
    /// drain/reconcile run, then read once more so anything it changed is on
    /// screen. Two reads exactly — no polling loop, no retry.
    func onForegroundActive() {
        reload()
        guard let coordinator else { return }
        Task {
            await coordinator.reconcileAndDrain()
            reload()
        }
    }

    /// Drops any armed cooldown timer. The screen going away must not leave a
    /// callback holding this model alive to update something nobody is looking at.
    func dispose() {
        cooldownTimer.invalidate()
    }

    private func apply(_ projection: SettingsProjection) {
        self.projection = projection
        refreshGate = SettingsRefreshGatePolicy.evaluate(recent: projection.recent, now: clock.now)
        // Re-arming on every projection means identity switches and recent
        // replacements invalidate the previous deadline for free: `arm` bumps the
        // generation, so the timer that was in flight for the old row is ignored.
        // The timer callback is not actor-isolated, so the hop back to the main
        // actor is explicit. The work itself is view state only: the deadline says
        // nothing new about the database, so recomputing it reads and writes none.
        cooldownTimer.arm(until: refreshGate.cooldownUntil) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshGate = SettingsRefreshGatePolicy.evaluate(recent: self.projection.recent, now: self.clock.now)
            }
        }
    }

    func saveAndTest() {
        guard !isBusy else { return }
        var previousConfiguration: CredentialConfig?
        if let repository {
            do {
                previousConfiguration = try keychain.loadConfig()
            } catch {
                previousConfiguration = nil
            }
        }
        var activated = false
        isBusy = true
        status = ""
        Task {
            do {
                let normalized = try OriginNormalizer.normalize(origin)
                let result = await api.validateSession(origin: normalized, apiKey: apiKey)
                switch result {
                    case .success(let identity):
                    if !identity.canWrite {
                        status = "缺少 write 权限"
                    } else {
                        guard let repository else { throw CoreError.database }
                        let newConfiguration = CredentialConfig(identity: identity, apiKey: apiKey)
                        try keychain.save(config: newConfiguration)
                        do {
                            try repository.activate(session: identity)
                        } catch {
                            if let previousConfiguration {
                                try? keychain.save(config: previousConfiguration)
                            } else {
                                keychain.clear()
                            }
                            throw error
                        }
                        activated = true
                        _ = try? repository.retryIdentityBlocked(identity: QueueIdentity(origin: identity.origin, namespace: identity.namespace))
                        origin = normalized
                        status = "连接正常"
                    }
                case .failure(let failure):
                    status = statusText(for: failure.category)
                }
            } catch CoreError.invalidOrigin {
                status = "无法连接服务器"
            } catch {
                status = "无法连接服务器"
            }
            if !activated, let previousConfiguration {
                origin = previousConfiguration.identity.origin
                apiKey = previousConfiguration.apiKey
            } else if !activated {
                origin = ""
                apiKey = ""
            }
            isBusy = false
            reload()
        }
    }

    func retry(_ entry: QueueEntry) {
        if entry.state == .failedPermanent {
            pendingRetryID = entry.id
            showPermanentRetryConfirmation = true
            return
        }
        guard [.retryWait, .blockedAuth, .blockedScope, .blockedQuota, .expired].contains(entry.state) else { return }
        performRetry(id: entry.id)
    }

    func confirmPermanentRetry() {
        guard let pendingRetryID else { return }
        self.pendingRetryID = nil
        performRetry(id: pendingRetryID)
    }

    var identityMigrationMessage: String {
        guard let pendingIdentityMigration, let target = activeIdentity else {
            return "请先完成新的身份配置。"
        }
        return "旧身份：\(pendingIdentityMigration.identity.origin) · \(namespaceFingerprint(pendingIdentityMigration.identity.namespace))\n" +
            "新身份：\(target.origin) · \(namespaceFingerprint(target.namespace))\n" +
            "URL 会用新身份重新进入队列，并生成新的幂等 key。"
    }

    func requestIdentityMigration(_ entry: QueueEntry) {
        guard entry.state == .blockedIdentity, activeIdentity != nil else { return }
        pendingIdentityMigration = entry
        showIdentityMigrationConfirmation = true
    }

    func confirmIdentityMigration() {
        guard let entry = pendingIdentityMigration, let target = activeIdentity, let repository else { return }
        pendingIdentityMigration = nil
        showIdentityMigrationConfirmation = false
        do {
            guard try repository.migrateIdentity(id: entry.id, to: target) else {
                status = "无法迁移本地条目"
                reload()
                return
            }
            status = "已迁移，等待提交"
            reload()
            drain()
        } catch {
            status = "无法迁移本地条目"
            reload()
        }
    }

    private var pendingRetryID: String?

    private func performRetry(id: String) {
        guard let repository else { return }
        BackgroundUploadSessionController.shared.cancelAll(queueID: id)
        try? repository.resetForRetry(id: id)
        reload()
        drain()
    }

    func delete(_ entry: QueueEntry) {
        guard let repository else { return }
        BackgroundUploadSessionController.shared.cancelAll(queueID: entry.id)
        try? repository.delete(id: entry.id)
        reload()
        drain()
    }

    func retryRecoverable() {
        queue.filter { [.retryWait, .blockedAuth, .blockedScope, .blockedQuota, .expired].contains($0.state) }
            .forEach { try? repository?.resetForRetry(id: $0.id) }
        reload()
        drain()
    }

    func clearQueue() {
        queue.forEach { BackgroundUploadSessionController.shared.cancelAll(queueID: $0.id) }
        try? repository?.clearQueue()
        reload()
        drain()
    }

    func clearRecent() {
        try? repository?.clearRecent()
        reload()
    }

    func refreshRecent() {
        guard !refreshBusy, let recent, !recent.isIdentityMismatch, let identity = activeIdentity, recent.identity == identity, let repository else { return }
        let storedConfiguration: CredentialConfig?
        do { storedConfiguration = try keychain.loadConfig() } catch { return }
        guard let storedConfiguration else { return }
        let activeSession: SessionIdentity?
        do { activeSession = try repository.activeSessionIdentity() } catch { return }
        guard let activeSession,
              storedConfiguration.identity == activeSession,
              activeSession.canWrite else { return }
        guard let capture = try? repository.refreshCapture(identity: identity) else { return }
        let storedKey = storedConfiguration.apiKey
        refreshBusy = true
        Task {
            let session = await api.validateSession(origin: identity.origin, apiKey: storedKey)
            switch session {
            case .failure(let failure):
                status = statusText(for: failure.category)
            case .success(let verified):
                guard verified.canWrite else {
                    status = "缺少 write 权限"
                    refreshBusy = false
                    reload()
                    return
                }
                guard QueueIdentity(origin: verified.origin, namespace: verified.namespace) == identity else {
                    status = "身份已变更"
                    refreshBusy = false
                    reload()
                    return
                }
                let result = await api.refresh(identity: verified, apiKey: storedKey, linkID: recent.linkID)
                switch result {
                case .success(let response):
                    if sameLinkID(recent.linkID, response.linkID),
                       (try? repository.recordRefreshSuccess(capture: capture, response: response)) == .applied {
                        status = "连接正常"
                    } else {
                        status = "身份或最近结果已变更"
                    }
                case .failure(let failure):
                    let now = Date()
                    switch failure.category {
                    case .cooldown:
                        let delay = RetryPolicy.retryAfter(failure.retryAfter, now: now) ?? RetryPolicy.minimumRetryAfter
                        _ = try? repository.recordRefreshBlocked(capture: capture, notBefore: now.addingTimeInterval(delay), reason: "cooldown_active")
                    case .quota:
                        _ = try? repository.recordRefreshBlocked(capture: capture, notBefore: nil, reason: "quota_exceeded")
                    default:
                        break
                    }
                    status = statusText(for: failure.category)
                }
            }
            refreshBusy = false
            reload()
        }
    }

    private func statusText(for category: ErrorCategory) -> String {
        switch category {
        case .auth: return "凭证无效"
        case .scope: return "缺少 write 权限"
        case .cooldown: return "请稍后重新解析"
        case .quota: return "配额已用完"
        case .identityMismatch: return "身份已变更"
        default: return "无法连接服务器"
        }
    }

    private func drain() {
        guard let coordinator else { return }
        Task { await coordinator.reconcileAndDrain() }
    }
}

struct SettingsScreen: View {
    @ObservedObject var model: WebTagSettingsModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("WebTag Share")
                        .font(.largeTitle.weight(.semibold))
                    Text("分享即收藏")
                        .foregroundStyle(.secondary)
                }

                GroupBox("服务器配置") {
                    VStack(spacing: 12) {
                        TextField("https://webtag.alpenl.com", text: $model.origin)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .accessibilityIdentifier("settings.origin")
                            .disabled(model.isBusy)
                        HStack {
                            Group {
                                if model.keyVisible {
                                    TextField("API Key", text: $model.apiKey)
                                        .accessibilityIdentifier("settings.api-key")
                                } else {
                                    SecureField("API Key", text: $model.apiKey)
                                        .accessibilityIdentifier("settings.api-key")
                                }
                            }
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.password)
                            .disabled(model.isBusy)
                            Button {
                                model.keyVisible.toggle()
                            } label: {
                                Image(systemName: model.keyVisible ? "eye.slash" : "eye")
                            }
                            .accessibilityLabel(model.keyVisible ? "隐藏 API Key" : "显示 API Key")
                        }
                        Button("保存并测试连接") { model.saveAndTest() }
                            .buttonStyle(.borderedProminent)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("settings.save")
                            .disabled(model.isBusy || model.origin.isEmpty || model.apiKey.isEmpty)
                        if model.isBusy { ProgressView() }
                        if !model.status.isEmpty {
                            Text(model.status)
                                .font(.footnote)
                                .foregroundStyle(model.status == "连接正常" ? .green : .red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                // The header counts every durable row, including rows in sections
                // that are hidden, so it stays a count of what is stored rather
                // than of what happens to be on screen.
                if model.projection.queue.total > 0 {
                    GroupBox("待处理 · \(model.projection.queue.total) 条") {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(model.projection.queue.groups, id: \.group) { section in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("\(section.group.title) · \(section.count) 条")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .accessibilityIdentifier("settings.queue.group.\(section.group.rawValue)")
                                    ForEach(section.rows, id: \.id) { entry in
                                        QueueEntryRow(
                                            entry: entry,
                                            retry: { model.retry(entry) },
                                            migrate: { model.requestIdentityMigration(entry) },
                                            delete: { model.delete(entry) }
                                        )
                                    }
                                }
                            }
                            HStack {
                                Button("重试可恢复条目") { model.retryRecoverable() }
                                Spacer()
                                Button("清空", role: .destructive) { model.showClearConfirmation = true }
                            }
                        }
                    }
                }

                if let recent = model.recent {
                    GroupBox("最近一条结果") {
                        VStack(alignment: .leading, spacing: 10) {
                            if recent.isIdentityMismatch {
                                Text("身份已变更")
                                    .foregroundStyle(.red)
                            } else {
                                Text(recent.url)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                                Text(statusText(recent.status))
                                    .foregroundStyle(recent.status == "failed" ? .red : .green)
                            }
                            // Everything below the identity check is redacted on a
                            // mismatch: the link ID, the job ID and the result time
                            // all describe another identity's data.
                            if !recent.isIdentityMismatch {
                                Text("链接 ID：\(recent.linkID)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("settings.recent.link-id")
                                if let jobID = recent.jobID {
                                    Text("任务 ID：\(jobID)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let resultTime = SettingsTimeFormatter.absolute(recent.createdAt) {
                                    Text("结果时间：\(resultTime)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .accessibilityIdentifier("settings.recent.result-time")
                                }
                            }
                            if !recent.isIdentityMismatch, let reason = model.refreshGate.blockReason {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(reason == SettingsRefreshGatePolicy.cooldownReason ? "重新解析冷却中" : reason == SettingsRefreshGatePolicy.quotaReason ? "配额已用完，处理额度后可手动重试" : reason)
                                    if let until = SettingsTimeFormatter.absolute(model.refreshGate.cooldownUntil) {
                                        Text("可在 \(until) 后重试")
                                    }
                                }
                                .font(.footnote)
                                .foregroundStyle(.red)
                            }
                            if recent.status == "failed", !recent.isIdentityMismatch {
                                // The gate is recomputed by the cooldown timer at the
                                // exact deadline, so this unlocks on its own instead
                                // of waiting for the next redraw to notice.
                                Button("重新解析") { model.refreshRecent() }
                                    .disabled(model.refreshBusy || !model.refreshGate.isEnabled)
                            }
                            Button {
                                model.clearRecent()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel("删除最近结果")
                        }
                    }
                }

                Text("在任意 APP 中点击分享，选择 WebTag 即可收藏")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("v0.1.0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
                .padding(20)
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            // Becoming active is the only reload trigger. A background change made
            // by the share extension or a background completion leaves no signal in
            // this process, so without this the screen can sit on a stale snapshot
            // for as long as it stays open.
            .onAppear { model.onForegroundActive() }
            .onChange(of: scenePhase) { phase in
                if phase == .active { model.onForegroundActive() }
            }
            .onDisappear { model.dispose() }
            .confirmationDialog("清空待处理条目？", isPresented: $model.showClearConfirmation) {
                Button("确认", role: .destructive) { model.clearQueue() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这会删除本地队列中的 \(model.projection.queue.total) 条记录。")
            }
            .confirmationDialog("再次提交失败条目？", isPresented: $model.showPermanentRetryConfirmation) {
                Button("确认重试") { model.confirmPermanentRetry() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这会复用原 URL，但会重新进入提交流程；服务端失败链接不会被隐式解析。")
            }
            .confirmationDialog("迁移并重试？", isPresented: $model.showIdentityMigrationConfirmation) {
                Button("迁移并重试") { model.confirmIdentityMigration() }
                Button("取消", role: .cancel) {}
            } message: {
                Text(model.identityMigrationMessage)
            }
        }
    }

    private func statusText(_ status: String) -> String {
        switch status {
        case "pending", "processing": return "已收藏"
        case "done": return "已在库中"
        case "failed": return "已在库中，解析失败"
        default: return "提交失败"
        }
    }
}

struct QueueEntryRow: View {
    let entry: QueueEntry
    let retry: () -> Void
    let migrate: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.state == .blockedIdentity ? "身份已变更" : entry.url)
                    .lineLimit(3)
                Text(label(for: entry.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Only rendered when the field exists. A placeholder would sit in
                // the same position as a real timestamp and read as if the value
                // were known and empty.
                if let firstFailed = SettingsTimeFormatter.absolute(entry.firstFailedAt) {
                    Text("首次失败：\(firstFailed)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let nextRetry = SettingsTimeFormatter.absolute(entry.nextAttemptAt) {
                    Text("下次重试：\(nextRetry)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if entry.state == .blockedIdentity {
                Button("迁移并重试", action: migrate)
                    .accessibilityLabel("迁移并重试")
            } else {
                Button(action: retry) {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("重试")
                .disabled(entry.state == .pendingSubmit)
            }
            Button(role: .destructive, action: delete) {
                Image(systemName: "trash")
            }
            .accessibilityLabel("删除")
        }
        .padding(.vertical, 4)
    }

    private func label(for state: QueueState) -> String {
        switch state {
        case .pendingSubmit: return "待提交"
        case .retryWait: return "等待重试"
        case .blockedAuth: return "凭证无效"
        case .blockedScope: return "缺少 write 权限"
        case .blockedQuota: return "配额已用完"
        case .blockedIdentity: return "身份已变更"
        case .failedPermanent: return "提交失败"
        case .expired: return "已过期"
        }
    }
}

private func namespaceFingerprint(_ namespace: String) -> String {
    let digest = SHA256.hash(data: Data(namespace.utf8))
    return digest.prefix(4).map { String(format: "%02x", Int($0)) }.joined()
}
