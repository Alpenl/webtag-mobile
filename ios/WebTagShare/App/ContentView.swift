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
    @Published var queue: [QueueEntry] = []
    @Published var recent: RecentResult?
    @Published var showClearConfirmation = false
    @Published var showPermanentRetryConfirmation = false
    @Published var showIdentityMigrationConfirmation = false
    @Published var refreshBusy = false

    private let repository: AppGroupQueueRepository?
    private let coordinator: ShareSubmissionCoordinator?
    private let keychain = KeychainCredentialStore()
    private let api = WebTagAPIClient()
    private var pendingIdentityMigration: QueueEntry?

    init() {
        repository = try? AppGroupQueueRepository()
        coordinator = repository.map { ShareSubmissionCoordinator(repository: $0) }
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

    func reload() {
        guard let repository else { return }
        queue = (try? repository.list(identity: activeIdentity)) ?? []
        recent = try? repository.recent(identity: activeIdentity)
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

struct ContentView: View {
    @StateObject private var model = WebTagSettingsModel()

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

                if !model.queue.isEmpty {
                    GroupBox("待处理 · \(model.queue.count) 条") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(model.queue, id: \.id) { entry in
                                QueueEntryRow(
                                    entry: entry,
                                    retry: { model.retry(entry) },
                                    migrate: { model.requestIdentityMigration(entry) },
                                    delete: { model.delete(entry) }
                                )
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
                            if let reason = recent.refreshBlockReason {
                                Text(reason == "cooldown_active" ? "重新解析冷却中" : reason == "quota_exceeded" ? "配额已用完，处理额度后可手动重试" : reason)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                            if recent.status == "failed", !recent.isIdentityMismatch {
                                Button("重新解析") { model.refreshRecent() }
                                    .disabled(model.refreshBusy || (recent.refreshBlockReason == "cooldown_active" && (recent.refreshNotBefore ?? .distantPast) > Date()))
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
            .navigationTitle("WebTag Share")
            .confirmationDialog("清空待处理条目？", isPresented: $model.showClearConfirmation) {
                Button("确认", role: .destructive) { model.clearQueue() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这会删除本地队列中的 \(model.queue.count) 条记录。")
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

private struct QueueEntryRow: View {
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

#Preview { ContentView() }
