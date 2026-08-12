import CryptoKit
import Foundation
import Security

enum CompanionTodoOrigin: String, Codable, CaseIterable, Hashable {
    case standalone
    case thought
    case note
    case inbox
}

struct CompanionTodoItem: Codable, Equatable, Identifiable {
    var id: String
    var text: String
    var dueAt: Date?
    var done: Bool
    var originKind: CompanionTodoOrigin
    var originHostKind: String?
    var originHostID: String?
    var hostRevision: Int64
    var completedAt: Date?
    var expired: Bool
    var createdAt: Date
    var updatedAt: Date
    var sourceHref: String?
    var localOnly: Bool = false
    var pending: Bool = false

    var isStandalone: Bool { originKind == .standalone }

    enum CodingKeys: String, CodingKey {
        case id, text, done, expired
        case dueAt = "due_at"
        case originKind = "origin_kind"
        case originHostKind = "origin_host_kind"
        case originHostID = "origin_host_id"
        case hostRevision = "host_revision"
        case completedAt = "completed_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case sourceHref = "source_href"
        case localOnly, pending
    }

    init(
        id: String,
        text: String,
        dueAt: Date?,
        done: Bool,
        originKind: CompanionTodoOrigin,
        originHostKind: String? = nil,
        originHostID: String? = nil,
        hostRevision: Int64,
        completedAt: Date? = nil,
        expired: Bool = false,
        createdAt: Date,
        updatedAt: Date,
        sourceHref: String? = nil,
        localOnly: Bool = false,
        pending: Bool = false
    ) {
        self.id = id
        self.text = text
        self.dueAt = dueAt
        self.done = done
        self.originKind = originKind
        self.originHostKind = originHostKind
        self.originHostID = originHostID
        self.hostRevision = hostRevision
        self.completedAt = completedAt
        self.expired = expired
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceHref = sourceHref
        self.localOnly = localOnly
        self.pending = pending
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        guard Self.isUUID(id) else { throw TodoStateError.invalidData }
        text = try values.decode(String.self, forKey: .text)
        dueAt = try values.decodeIfPresent(Date.self, forKey: .dueAt)
        done = try values.decode(Bool.self, forKey: .done)
        originKind = try values.decode(CompanionTodoOrigin.self, forKey: .originKind)
        originHostKind = try values.decodeIfPresent(String.self, forKey: .originHostKind)
        originHostID = try values.decodeIfPresent(String.self, forKey: .originHostID)
        hostRevision = try values.decode(Int64.self, forKey: .hostRevision)
        completedAt = try values.decodeIfPresent(Date.self, forKey: .completedAt)
        expired = try values.decode(Bool.self, forKey: .expired)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        sourceHref = try values.decodeIfPresent(String.self, forKey: .sourceHref)
        localOnly = try values.decodeIfPresent(Bool.self, forKey: .localOnly) ?? false
        pending = try values.decodeIfPresent(Bool.self, forKey: .pending) ?? false

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 4096,
              hostRevision >= 0,
              originKind == .standalone || hostRevision > 0,
              sourceHref.map(Self.isSafeSourceHref) != false else {
            throw TodoStateError.invalidData
        }
    }

    private static func isUUID(_ value: String) -> Bool {
        guard let parsed = UUID(uuidString: value) else { return false }
        return parsed.uuidString.caseInsensitiveCompare(value) == .orderedSame
    }

    static func isSafeSourceHref(_ value: String) -> Bool {
        guard value.hasPrefix("/"), !value.hasPrefix("//"),
              let components = URLComponents(string: value),
              components.scheme == nil, components.host == nil, components.user == nil else {
            return false
        }
        return true
    }
}

struct CompanionTodoCreate: Codable, Equatable {
    let text: String
    let dueAt: Date?

    enum CodingKeys: String, CodingKey {
        case text
        case dueAt = "due_at"
    }
}

struct CompanionTodoPatch: Codable, Equatable {
    var text: String?
    var dueAt: Date?
    var dueAtSet: Bool
    var done: Bool?
    var expectedHostRevision: Int64?
}

struct CompanionTodoCapabilities: Equatable {
    let todos: Bool
    let home: Bool
    let inbox: Bool
}

enum CompanionTodoFilter: CaseIterable, Hashable {
    case all
    case standalone
    case projected
}

enum CompanionTodoSection: CaseIterable, Hashable {
    case overdue
    case today
    case upcoming
    case unscheduled
    case completed
}

struct CompanionTodoSectionView: Identifiable, Equatable {
    let section: CompanionTodoSection
    let items: [CompanionTodoItem]
    var id: CompanionTodoSection { section }
}

struct CompanionTodoDayCount: Identifiable, Equatable {
    let date: Date
    let count: Int
    var id: Date { date }
}

struct CompanionTodoProjection: Equatable {
    let sections: [CompanionTodoSectionView]
    let days: [CompanionTodoDayCount]
    let openCount: Int
    let overdueCount: Int
    let todayCount: Int

    var isEmpty: Bool { sections.allSatisfy(\.items.isEmpty) }
}

enum CompanionTodoPresenter {
    static func project(
        _ items: [CompanionTodoItem],
        now: Date = Date(),
        calendar: Calendar = .current,
        filter: CompanionTodoFilter = .all,
        visibleDays: Int = 7
    ) -> CompanionTodoProjection {
        precondition(visibleDays > 0)
        let start = calendar.startOfDay(for: now)
        let filtered = items.filter { item in
            switch filter {
            case .all: return true
            case .standalone: return item.isStandalone
            case .projected: return !item.isStandalone
            }
        }.sorted(by: orderedBefore)

        var buckets = Dictionary(uniqueKeysWithValues: CompanionTodoSection.allCases.map { ($0, [CompanionTodoItem]()) })
        for item in filtered {
            buckets[section(for: item, today: start, calendar: calendar), default: []].append(item)
        }
        let open = filtered.filter { !$0.done }
        let days = (0..<visibleDays).compactMap { offset -> CompanionTodoDayCount? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return CompanionTodoDayCount(
                date: date,
                count: open.filter { item in
                    item.dueAt.map { calendar.isDate($0, inSameDayAs: date) } ?? false
                }.count
            )
        }
        return CompanionTodoProjection(
            sections: CompanionTodoSection.allCases.map { CompanionTodoSectionView(section: $0, items: buckets[$0] ?? []) },
            days: days,
            openCount: open.count,
            overdueCount: buckets[.overdue]?.count ?? 0,
            todayCount: buckets[.today]?.count ?? 0
        )
    }

    static func todayItems(
        _ items: [CompanionTodoItem],
        now: Date = Date(),
        calendar: Calendar = .current,
        limit: Int = 5
    ) -> [CompanionTodoItem] {
        let projection = project(items, now: now, calendar: calendar)
        let urgent = projection.sections
            .filter { $0.section == .overdue || $0.section == .today }
            .flatMap(\.items)
        if urgent.count >= limit { return Array(urgent.prefix(limit)) }
        let unscheduled = projection.sections.first(where: { $0.section == .unscheduled })?.items ?? []
        return Array((urgent + unscheduled).prefix(limit))
    }

    private static func section(for item: CompanionTodoItem, today: Date, calendar: Calendar) -> CompanionTodoSection {
        if item.done { return .completed }
        guard let due = item.dueAt else { return .unscheduled }
        let dueDay = calendar.startOfDay(for: due)
        if dueDay < today { return .overdue }
        if dueDay == today { return .today }
        return .upcoming
    }

    private static func orderedBefore(_ left: CompanionTodoItem, _ right: CompanionTodoItem) -> Bool {
        if left.done != right.done { return !left.done }
        if left.done {
            if left.completedAt != right.completedAt {
                return (left.completedAt ?? .distantPast) > (right.completedAt ?? .distantPast)
            }
            return left.updatedAt > right.updatedAt
        }
        switch (left.dueAt, right.dueAt) {
        case let (left?, right?) where left != right: return left < right
        case (nil, _?): return false
        case (_?, nil): return true
        default:
            if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
            return left.id < right.id
        }
    }
}

enum CompanionTodoOutboxKind: String, Codable, Hashable {
    case create
    case patch
    case delete
}

enum CompanionTodoOutboxState: String, Codable, Hashable {
    case pending
    case retryWait = "retry_wait"
    case blockedAuth = "blocked_auth"
    case blockedScope = "blocked_scope"
    case blockedIdentity = "blocked_identity"
    case conflict
    case failedPermanent = "failed_permanent"

    var isDueState: Bool { self == .pending || self == .retryWait }
}

struct CompanionTodoOperation: Codable, Equatable, Identifiable {
    let id: String
    var targetTodoID: String
    let kind: CompanionTodoOutboxKind
    let create: CompanionTodoCreate?
    var patch: CompanionTodoPatch?
    var state: CompanionTodoOutboxState
    var attemptCount: Int
    var nextAttemptAt: Date?
    var lastError: ErrorCategory?
    var leaseOwner: String?
    var leaseExpiresAt: Date?
    let createdAt: Date
    var updatedAt: Date
}

struct CompanionTodoSnapshot: Equatable {
    let items: [CompanionTodoItem]
    let pendingOperations: Int
    let blockedOperations: Int
    let lastSyncedAt: Date?
    let todosEnabled: Bool?

    static let empty = CompanionTodoSnapshot(
        items: [], pendingOperations: 0, blockedOperations: 0,
        lastSyncedAt: nil, todosEnabled: nil
    )
}

struct ClaimedCompanionTodoOperation: Equatable {
    let operation: CompanionTodoOperation
    let owner: String
}

enum TodoStateError: Error, Equatable {
    case invalidData
    case unavailable
    case staleClaim
}

private struct CompanionTodoPartition: Codable, Equatable {
    let origin: String
    let namespace: String
    var cache: [CompanionTodoItem]
    var outbox: [CompanionTodoOperation]
    var todosEnabled: Bool?
    var homeEnabled: Bool?
    var inboxEnabled: Bool?
    var lastSyncedAt: Date?

    var identity: QueueIdentity { QueueIdentity(origin: origin, namespace: namespace) }
}

private struct CompanionTodoState: Codable, Equatable {
    var version: Int
    var partitions: [CompanionTodoPartition]

    static let empty = CompanionTodoState(version: 1, partitions: [])
}

private struct CompanionTodoEncryptedEnvelope: Codable {
    let version: Int
    let sealedState: Data
}

protocol CompanionTodoStateCrypting {
    func seal(_ plaintext: Data) throws -> Data
    func open(_ ciphertext: Data) throws -> Data
}

final class CompanionTodoAESGCMCipher: CompanionTodoStateCrypting {
    private let key: SymmetricKey

    init(keyData: Data? = nil) throws {
        let data: Data
        if let keyData {
            data = keyData
        } else {
            data = try CompanionTodoStateKeychain().loadOrCreate()
        }
        key = SymmetricKey(data: data)
    }

    func seal(_ plaintext: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: key).combined else {
            throw TodoStateError.unavailable
        }
        return combined
    }

    func open(_ ciphertext: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: key)
    }
}

private final class CompanionTodoStateKeychain {
    private let account = "companion-todo-state-v1"
    private let service = "com.alpenl.webtag.share.todo-state"

    func loadOrCreate() throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound else { throw TodoStateError.unavailable }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw TodoStateError.unavailable
        }
        let data = Data(bytes)
        query.removeValue(forKey: kSecReturnData as String)
        query.removeValue(forKey: kSecMatchLimit as String)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecSuccess { return data }
        if addStatus == errSecDuplicateItem { return try loadOrCreate() }
        throw TodoStateError.unavailable
    }
}

final class CompanionTodoRepository {
    static let leaseDuration: TimeInterval = 30

    private let lock = NSLock()
    private let fileURL: URL
    private let cipher: CompanionTodoStateCrypting
    private let encoder = TodoWire.encoder()
    private let decoder = TodoWire.decoder()

    init(containerURL: URL? = nil, cipher: CompanionTodoStateCrypting? = nil) throws {
        let container: URL
        if let containerURL {
            container = containerURL
        } else {
            container = try Self.defaultContainerURL()
        }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        fileURL = container.appendingPathComponent("companion-todo-state.v1", isDirectory: false)
        if let cipher {
            self.cipher = cipher
        } else {
            self.cipher = try CompanionTodoAESGCMCipher()
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try synchronized { try readUnlocked() }
        }
    }

    func snapshot(identity: QueueIdentity) throws -> CompanionTodoSnapshot {
        try validate(identity)
        return try synchronized {
            let state = try readUnlocked()
            guard let partition = state.partitions.first(where: { $0.origin == identity.origin && $0.namespace == identity.namespace }) else {
                return .empty
            }
            return Self.snapshot(of: partition)
        }
    }

    @discardableResult
    func stageCreate(identity: QueueIdentity, request: CompanionTodoCreate, now: Date = Date()) throws -> String {
        try validate(identity)
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4096 else { throw TodoStateError.invalidData }
        let localID = UUID().uuidString.lowercased()
        let operationID = UUID().uuidString.lowercased()
        try mutatePartition(identity: identity) { partition in
            partition.outbox.append(CompanionTodoOperation(
                id: operationID,
                targetTodoID: localID,
                kind: .create,
                create: CompanionTodoCreate(text: text, dueAt: request.dueAt),
                patch: nil,
                state: .pending,
                attemptCount: 0,
                nextAttemptAt: nil,
                lastError: nil,
                leaseOwner: nil,
                leaseExpiresAt: nil,
                createdAt: now,
                updatedAt: now
            ))
        }
        return localID
    }

    @discardableResult
    func stagePatch(identity: QueueIdentity, todoID: String, patch: CompanionTodoPatch, now: Date = Date()) throws -> String {
        try validate(identity)
        guard UUID(uuidString: todoID) != nil,
              patch.text != nil || patch.dueAtSet || patch.done != nil || patch.expectedHostRevision != nil,
              patch.text.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 4096 }) != false else {
            throw TodoStateError.invalidData
        }
        let operationID = UUID().uuidString.lowercased()
        var cleanPatch = patch
        cleanPatch.text = patch.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        try mutatePartition(identity: identity) { partition in
            partition.outbox.append(CompanionTodoOperation(
                id: operationID,
                targetTodoID: todoID,
                kind: .patch,
                create: nil,
                patch: cleanPatch,
                state: .pending,
                attemptCount: 0,
                nextAttemptAt: nil,
                lastError: nil,
                leaseOwner: nil,
                leaseExpiresAt: nil,
                createdAt: now,
                updatedAt: now
            ))
        }
        return operationID
    }

    @discardableResult
    func stageDelete(identity: QueueIdentity, todoID: String, now: Date = Date()) throws -> String {
        try validate(identity)
        guard UUID(uuidString: todoID) != nil else { throw TodoStateError.invalidData }
        let operationID = UUID().uuidString.lowercased()
        try mutatePartition(identity: identity) { partition in
            partition.outbox.append(CompanionTodoOperation(
                id: operationID,
                targetTodoID: todoID,
                kind: .delete,
                create: nil,
                patch: nil,
                state: .pending,
                attemptCount: 0,
                nextAttemptAt: nil,
                lastError: nil,
                leaseOwner: nil,
                leaseExpiresAt: nil,
                createdAt: now,
                updatedAt: now
            ))
        }
        return operationID
    }

    func claimDue(identity: QueueIdentity, now: Date = Date(), leaseDuration: TimeInterval = leaseDuration) throws -> ClaimedCompanionTodoOperation? {
        try validate(identity)
        var claimed: ClaimedCompanionTodoOperation?
        try mutatePartition(identity: identity) { partition in
            let ordered = partition.outbox.indices.sorted(by: {
                let left = partition.outbox[$0]
                let right = partition.outbox[$1]
                return left.createdAt == right.createdAt ? $0 < $1 : left.createdAt < right.createdAt
            })
            guard let position = ordered.indices.first(where: { position in
                let index = ordered[position]
                let operation = partition.outbox[index]
                guard operation.state.isDueState,
                      operation.nextAttemptAt.map({ $0 <= now }) ?? true,
                      operation.leaseExpiresAt.map({ $0 <= now }) ?? true else {
                    return false
                }
                return !ordered[..<position].contains(where: {
                    partition.outbox[$0].targetTodoID == operation.targetTodoID
                })
            }) else { return }
            let index = ordered[position]
            let owner = UUID().uuidString.lowercased()
            partition.outbox[index].leaseOwner = owner
            partition.outbox[index].leaseExpiresAt = now.addingTimeInterval(leaseDuration)
            partition.outbox[index].updatedAt = now
            claimed = ClaimedCompanionTodoOperation(operation: partition.outbox[index], owner: owner)
        }
        return claimed
    }

    func completeCreate(
        identity: QueueIdentity,
        operationID: String,
        owner: String,
        created: CompanionTodoItem,
        now: Date = Date()
    ) throws {
        try mutateOwned(identity: identity, operationID: operationID, owner: owner) { partition, index in
            let localID = partition.outbox[index].targetTodoID
            partition.cache.removeAll { $0.id == localID || $0.id == created.id }
            partition.cache.append(created)
            for pendingIndex in partition.outbox.indices where pendingIndex != index && partition.outbox[pendingIndex].targetTodoID == localID {
                partition.outbox[pendingIndex].targetTodoID = created.id
                partition.outbox[pendingIndex].updatedAt = now
            }
            partition.outbox.remove(at: index)
        }
    }

    func completePatch(identity: QueueIdentity, operationID: String, owner: String, updated: CompanionTodoItem) throws {
        try mutateOwned(identity: identity, operationID: operationID, owner: owner) { partition, index in
            let previousRevision = partition.outbox[index].patch?.expectedHostRevision
            partition.cache.removeAll { $0.id == updated.id }
            partition.cache.append(updated)
            if let previousRevision {
                for pendingIndex in partition.outbox.indices where pendingIndex != index && partition.outbox[pendingIndex].targetTodoID == updated.id {
                    if partition.outbox[pendingIndex].patch?.expectedHostRevision == previousRevision {
                        partition.outbox[pendingIndex].patch?.expectedHostRevision = updated.hostRevision
                    }
                }
            }
            partition.outbox.remove(at: index)
        }
    }

    func completeDelete(identity: QueueIdentity, operationID: String, owner: String) throws {
        try mutateOwned(identity: identity, operationID: operationID, owner: owner) { partition, index in
            let target = partition.outbox[index].targetTodoID
            partition.cache.removeAll { $0.id == target }
            partition.outbox.remove(at: index)
        }
    }

    func discard(identity: QueueIdentity, operationID: String, owner: String) throws {
        try mutateOwned(identity: identity, operationID: operationID, owner: owner) { partition, index in
            partition.outbox.remove(at: index)
        }
    }

    func markFailure(
        identity: QueueIdentity,
        operationID: String,
        owner: String,
        state: CompanionTodoOutboxState,
        category: ErrorCategory,
        nextAttemptAt: Date?,
        now: Date = Date()
    ) throws {
        try mutateOwned(identity: identity, operationID: operationID, owner: owner) { partition, index in
            partition.outbox[index].state = state
            partition.outbox[index].attemptCount += 1
            partition.outbox[index].nextAttemptAt = nextAttemptAt
            partition.outbox[index].lastError = category
            partition.outbox[index].leaseOwner = nil
            partition.outbox[index].leaseExpiresAt = nil
            partition.outbox[index].updatedAt = now
        }
    }

    func replaceServerSnapshot(identity: QueueIdentity, items: [CompanionTodoItem], now: Date = Date()) throws {
        try validate(identity)
        guard Set(items.map(\.id)).count == items.count else { throw TodoStateError.invalidData }
        try mutatePartition(identity: identity) { partition in
            partition.cache = items
            partition.lastSyncedAt = now
        }
    }

    func recordCapabilities(identity: QueueIdentity, capabilities: CompanionTodoCapabilities) throws {
        try validate(identity)
        try mutatePartition(identity: identity) { partition in
            partition.todosEnabled = capabilities.todos
            partition.homeEnabled = capabilities.home
            partition.inboxEnabled = capabilities.inbox
        }
    }

    func retryCredentialBlocked(identity: QueueIdentity, now: Date = Date()) throws {
        try validate(identity)
        try mutatePartition(identity: identity) { partition in
            for index in partition.outbox.indices where
                partition.outbox[index].state == .blockedAuth ||
                partition.outbox[index].state == .blockedScope ||
                partition.outbox[index].state == .blockedIdentity {
                partition.outbox[index].state = .pending
                partition.outbox[index].nextAttemptAt = nil
                partition.outbox[index].lastError = nil
                partition.outbox[index].leaseOwner = nil
                partition.outbox[index].leaseExpiresAt = nil
                partition.outbox[index].updatedAt = now
            }
        }
    }

    func rebaseDoneConflict(
        identity: QueueIdentity,
        operationID: String,
        owner: String,
        desiredDone: Bool,
        current: CompanionTodoItem?,
        snapshot: [CompanionTodoItem],
        now: Date = Date()
    ) throws {
        try mutateOwned(identity: identity, operationID: operationID, owner: owner) { partition, index in
            let operation = partition.outbox[index]
            let target = operation.targetTodoID
            let previousRevision = operation.patch?.expectedHostRevision
            partition.cache = snapshot
            partition.lastSyncedAt = now
            partition.outbox.remove(at: index)
            guard let current else { return }
            if let previousRevision {
                for pendingIndex in partition.outbox.indices where partition.outbox[pendingIndex].targetTodoID == target {
                    if partition.outbox[pendingIndex].patch?.expectedHostRevision == previousRevision {
                        partition.outbox[pendingIndex].patch?.expectedHostRevision = current.hostRevision
                    }
                }
            }
            partition.outbox.insert(CompanionTodoOperation(
                id: UUID().uuidString.lowercased(),
                targetTodoID: target,
                kind: .patch,
                create: nil,
                patch: CompanionTodoPatch(
                    text: nil,
                    dueAt: nil,
                    dueAtSet: false,
                    done: desiredDone,
                    expectedHostRevision: current.hostRevision
                ),
                state: .pending,
                attemptCount: 0,
                nextAttemptAt: nil,
                lastError: nil,
                leaseOwner: nil,
                leaseExpiresAt: nil,
                createdAt: operation.createdAt,
                updatedAt: now
            ), at: min(index, partition.outbox.endIndex))
        }
    }

    private func mutateOwned(
        identity: QueueIdentity,
        operationID: String,
        owner: String,
        body: (inout CompanionTodoPartition, Int) throws -> Void
    ) throws {
        try validate(identity)
        try mutatePartition(identity: identity) { partition in
            guard let index = partition.outbox.firstIndex(where: { $0.id == operationID }),
                  partition.outbox[index].leaseOwner == owner else {
                throw TodoStateError.staleClaim
            }
            try body(&partition, index)
        }
    }

    private func mutatePartition(identity: QueueIdentity, body: (inout CompanionTodoPartition) throws -> Void) throws {
        try synchronized {
            var state = try readUnlocked()
            let index: Int
            if let existing = state.partitions.firstIndex(where: { $0.origin == identity.origin && $0.namespace == identity.namespace }) {
                index = existing
            } else {
                state.partitions.append(CompanionTodoPartition(
                    origin: identity.origin,
                    namespace: identity.namespace,
                    cache: [],
                    outbox: [],
                    todosEnabled: nil,
                    homeEnabled: nil,
                    inboxEnabled: nil,
                    lastSyncedAt: nil
                ))
                index = state.partitions.index(before: state.partitions.endIndex)
            }
            try body(&state.partitions[index])
            try writeUnlocked(state)
        }
    }

    private static func snapshot(of partition: CompanionTodoPartition) -> CompanionTodoSnapshot {
        var visible: [String: CompanionTodoItem] = [:]
        for item in partition.cache { visible[item.id] = item }
        for operation in partition.outbox.sorted(by: { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }) {
            switch operation.kind {
            case .create:
                guard let request = operation.create else { continue }
                visible[operation.targetTodoID] = CompanionTodoItem(
                    id: operation.targetTodoID,
                    text: request.text,
                    dueAt: request.dueAt,
                    done: false,
                    originKind: .standalone,
                    hostRevision: 0,
                    createdAt: operation.createdAt,
                    updatedAt: operation.updatedAt,
                    localOnly: true,
                    pending: true
                )
            case .patch:
                guard let patch = operation.patch, var item = visible[operation.targetTodoID] else { continue }
                if let text = patch.text { item.text = text }
                if patch.dueAtSet { item.dueAt = patch.dueAt }
                if let done = patch.done {
                    item.done = done
                    item.completedAt = done ? operation.updatedAt : nil
                }
                item.updatedAt = operation.updatedAt
                item.pending = true
                visible[operation.targetTodoID] = item
            case .delete:
                visible.removeValue(forKey: operation.targetTodoID)
            }
        }
        let operations = partition.outbox
        return CompanionTodoSnapshot(
            items: visible.values.sorted(by: CompanionTodoPresenterOrder.before),
            pendingOperations: operations.filter { $0.state.isDueState }.count,
            blockedOperations: operations.filter { !$0.state.isDueState }.count,
            lastSyncedAt: partition.lastSyncedAt,
            todosEnabled: partition.todosEnabled
        )
    }

    private func readUnlocked() throws -> CompanionTodoState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        let envelope = try decoder.decode(CompanionTodoEncryptedEnvelope.self, from: Data(contentsOf: fileURL))
        guard envelope.version == 1 else { throw TodoStateError.invalidData }
        let state = try decoder.decode(CompanionTodoState.self, from: cipher.open(envelope.sealedState))
        guard state.version == 1 else { throw TodoStateError.invalidData }
        var partitionKeys = Set<String>()
        for partition in state.partitions {
            try validate(partition.identity)
            guard partitionKeys.insert(partition.origin + "\n" + partition.namespace).inserted,
                  Set(partition.cache.map(\.id)).count == partition.cache.count,
                  Set(partition.outbox.map(\.id)).count == partition.outbox.count else {
                throw TodoStateError.invalidData
            }
        }
        return state
    }

    private func writeUnlocked(_ state: CompanionTodoState) throws {
        let plaintext = try encoder.encode(state)
        let envelope = CompanionTodoEncryptedEnvelope(version: 1, sealedState: try cipher.seal(plaintext))
        try encoder.encode(envelope).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = fileURL
        try mutableURL.setResourceValues(values)
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func defaultContainerURL() throws -> URL {
        guard !AppIdentifiers.appGroup.isEmpty,
              let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroup) else {
            throw TodoStateError.unavailable
        }
        return url
    }

    private func validate(_ identity: QueueIdentity) throws {
        guard let origin = try? OriginNormalizer.normalize(identity.origin), origin == identity.origin,
              identity.namespace.utf8.count == 43,
              identity.namespace.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value) || (65...90).contains(scalar.value) ||
                  (97...122).contains(scalar.value) || scalar.value == 95 || scalar.value == 45
              }) else {
            throw TodoStateError.invalidData
        }
    }
}

private enum CompanionTodoPresenterOrder {
    static func before(_ left: CompanionTodoItem, _ right: CompanionTodoItem) -> Bool {
        if left.done != right.done { return !left.done }
        if left.dueAt != right.dueAt { return (left.dueAt ?? .distantFuture) < (right.dueAt ?? .distantFuture) }
        if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
        return left.id < right.id
    }
}

private enum TodoWire {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let values = try decoder.singleValueContainer()
            let raw = try values.decode(String.self)
            guard let date = parseDate(raw) else {
                throw DecodingError.dataCorruptedError(in: values, debugDescription: "Invalid RFC3339 date")
            }
            return date
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var values = encoder.singleValueContainer()
            try values.encode(formatDate(date))
        }
        return encoder
    }

    static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func formatDate(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: value)
    }
}

protocol CompanionTodoAPI {
    func capabilities(identity: SessionIdentity, apiKey: String) async -> Result<CompanionTodoCapabilities, ClassifiedFailure>
    func listTodos(identity: SessionIdentity, apiKey: String) async -> Result<[CompanionTodoItem], ClassifiedFailure>
    func createTodo(identity: SessionIdentity, apiKey: String, request: CompanionTodoCreate, idempotencyKey: String) async -> Result<CompanionTodoItem, ClassifiedFailure>
    func patchTodo(identity: SessionIdentity, apiKey: String, todoID: String, patch: CompanionTodoPatch, idempotencyKey: String) async -> Result<CompanionTodoItem, ClassifiedFailure>
    func deleteTodo(identity: SessionIdentity, apiKey: String, todoID: String, idempotencyKey: String) async -> Result<Void, ClassifiedFailure>
}

final class CompanionTodoAPIClient: NSObject, URLSessionTaskDelegate, CompanionTodoAPI {
    private let suppliedTransport: HTTPTransport?
    private lazy var transport: HTTPTransport = {
        if let suppliedTransport { return suppliedTransport }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(transport: HTTPTransport? = nil) {
        suppliedTransport = transport
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func capabilities(identity: SessionIdentity, apiKey: String) async -> Result<CompanionTodoCapabilities, ClassifiedFailure> {
        await send(identity: identity, apiKey: apiKey, method: "GET", path: "/api/capabilities", accepted: [200]) { data in
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let reader = root["reader"] as? [String: Any],
                  let todos = reader["todos"] as? Bool,
                  let home = reader["home"] as? Bool,
                  let inbox = reader["inbox"] as? Bool else {
                throw TodoStateError.invalidData
            }
            return CompanionTodoCapabilities(todos: todos, home: home, inbox: inbox)
        }
    }

    func listTodos(identity: SessionIdentity, apiKey: String) async -> Result<[CompanionTodoItem], ClassifiedFailure> {
        var all: [CompanionTodoItem] = []
        var after: String?
        var seen = Set<String>()
        for _ in 0..<100 {
            var components = URLComponents(string: identity.origin + "/api/todos")
            components?.queryItems = [URLQueryItem(name: "limit", value: "200")]
            if let after { components?.queryItems?.append(URLQueryItem(name: "after", value: after)) }
            guard let url = components?.url else { return .failure(Self.invalidFailure()) }
            let result: Result<CompanionTodoPage, ClassifiedFailure> = await send(
                identity: identity,
                apiKey: apiKey,
                method: "GET",
                absoluteURL: url,
                accepted: [200]
            ) { data in
                try TodoWire.decoder().decode(CompanionTodoPage.self, from: data)
            }
            switch result {
            case .failure(let failure): return .failure(failure)
            case .success(let page):
                all.append(contentsOf: page.items)
                guard let next = page.nextAfter, !next.isEmpty else { return .success(all) }
                guard seen.insert(next).inserted else { return .failure(Self.invalidFailure()) }
                after = next
            }
        }
        return .failure(Self.invalidFailure())
    }

    func createTodo(
        identity: SessionIdentity,
        apiKey: String,
        request: CompanionTodoCreate,
        idempotencyKey: String
    ) async -> Result<CompanionTodoItem, ClassifiedFailure> {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4096, !idempotencyKey.isEmpty else { return .failure(Self.invalidFailure()) }
        var object: [String: Any] = ["text": text]
        object["due_at"] = request.dueAt.map(TodoWire.formatDate) ?? NSNull()
        return await todoWrite(
            identity: identity, apiKey: apiKey, method: "POST", path: "/api/todos",
            body: object, idempotencyKey: idempotencyKey, accepted: [201]
        )
    }

    func patchTodo(
        identity: SessionIdentity,
        apiKey: String,
        todoID: String,
        patch: CompanionTodoPatch,
        idempotencyKey: String
    ) async -> Result<CompanionTodoItem, ClassifiedFailure> {
        guard UUID(uuidString: todoID) != nil, !idempotencyKey.isEmpty else { return .failure(Self.invalidFailure()) }
        var object: [String: Any] = [:]
        if let text = patch.text { object["text"] = text }
        if patch.dueAtSet { object["due_at"] = patch.dueAt.map(TodoWire.formatDate) ?? NSNull() }
        if let done = patch.done { object["done"] = done }
        if let revision = patch.expectedHostRevision { object["expected_host_revision"] = revision }
        guard !object.isEmpty else { return .failure(Self.invalidFailure()) }
        return await todoWrite(
            identity: identity, apiKey: apiKey, method: "PATCH", path: "/api/todos/\(todoID)",
            body: object, idempotencyKey: idempotencyKey, accepted: [200]
        )
    }

    func deleteTodo(
        identity: SessionIdentity,
        apiKey: String,
        todoID: String,
        idempotencyKey: String
    ) async -> Result<Void, ClassifiedFailure> {
        guard UUID(uuidString: todoID) != nil, !idempotencyKey.isEmpty else { return .failure(Self.invalidFailure()) }
        return await send(
            identity: identity, apiKey: apiKey, method: "DELETE", path: "/api/todos/\(todoID)",
            idempotencyKey: idempotencyKey, accepted: [204]
        ) { _ in () }
    }

    private func todoWrite(
        identity: SessionIdentity,
        apiKey: String,
        method: String,
        path: String,
        body: [String: Any],
        idempotencyKey: String,
        accepted: Set<Int>
    ) async -> Result<CompanionTodoItem, ClassifiedFailure> {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(Self.invalidFailure())
        }
        return await send(
            identity: identity, apiKey: apiKey, method: method, path: path, body: data,
            idempotencyKey: idempotencyKey, accepted: accepted
        ) { data in try TodoWire.decoder().decode(CompanionTodoItem.self, from: data) }
    }

    private func send<T>(
        identity: SessionIdentity,
        apiKey: String,
        method: String,
        path: String? = nil,
        absoluteURL: URL? = nil,
        body: Data? = nil,
        idempotencyKey: String? = nil,
        accepted: Set<Int>,
        decode: (Data) throws -> T
    ) async -> Result<T, ClassifiedFailure> {
        guard identity.canWrite,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let normalized = try? OriginNormalizer.normalize(identity.origin), normalized == identity.origin,
              let url = absoluteURL ?? path.flatMap({ URL(string: identity.origin + $0) }) else {
            return .failure(Self.invalidFailure())
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        do {
            let (data, response) = try await transport.send(request)
            guard let http = response as? HTTPURLResponse else { throw TodoStateError.invalidData }
            let namespace = http.value(forHTTPHeaderField: "X-WebTag-Data-Namespace")
            guard accepted.contains(http.statusCode) else {
                if (200..<300).contains(http.statusCode) { return .failure(Self.successPayloadFailure(status: http.statusCode)) }
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let error = object?["error"] as? [String: Any]
                return .failure(ErrorClassifier.http(
                    status: http.statusCode,
                    errorCode: error?["error_code"] as? String,
                    retryAfter: http.value(forHTTPHeaderField: "Retry-After")
                ))
            }
            guard namespace == identity.namespace else {
                return .failure(ClassifiedFailure(category: .identityMismatch, status: http.statusCode, errorCode: nil, retryAfter: nil))
            }
            do { return .success(try decode(data)) }
            catch { return .failure(Self.successPayloadFailure(status: http.statusCode)) }
        } catch {
            return .failure(ErrorClassifier.transport(error))
        }
    }

    private static func invalidFailure() -> ClassifiedFailure {
        ClassifiedFailure(category: .invalidClientResponse, status: nil, errorCode: nil, retryAfter: nil)
    }

    private static func successPayloadFailure(status: Int) -> ClassifiedFailure {
        ClassifiedFailure(category: .invalidSuccessPayload, status: status, errorCode: nil, retryAfter: nil)
    }
}

private struct CompanionTodoPage: Decodable {
    let items: [CompanionTodoItem]
    let nextAfter: String?

    enum CodingKeys: String, CodingKey {
        case items
        case nextAfter = "next_after"
    }
}

struct CompanionTodoSyncResult: Equatable {
    let pushed: Int
    let pulled: Bool
    let error: ErrorCategory?
}

final class CompanionTodoSyncCoordinator {
    private let repository: CompanionTodoRepository
    private let queueRepository: AppGroupQueueRepository
    private let credentials: KeychainCredentialStore
    private let api: CompanionTodoAPI

    init(
        repository: CompanionTodoRepository,
        queueRepository: AppGroupQueueRepository,
        credentials: KeychainCredentialStore = KeychainCredentialStore(),
        api: CompanionTodoAPI = CompanionTodoAPIClient()
    ) {
        self.repository = repository
        self.queueRepository = queueRepository
        self.credentials = credentials
        self.api = api
    }

    func synchronize(maxPushes: Int = 50) async -> CompanionTodoSyncResult {
        let configuration: CredentialConfig
        let activation: ActiveSessionSnapshot
        do {
            guard let stored = try credentials.loadConfig(),
                  let active = try queueRepository.activeSessionSnapshot(),
                  stored.identity == active.identity,
                  stored.identity.canWrite else {
                return CompanionTodoSyncResult(pushed: 0, pulled: false, error: .identityMismatch)
            }
            configuration = stored
            activation = active
        } catch {
            return CompanionTodoSyncResult(pushed: 0, pulled: false, error: .localDataUnreadable)
        }
        let identity = QueueIdentity(origin: activation.identity.origin, namespace: activation.identity.namespace)

        switch await api.capabilities(identity: activation.identity, apiKey: configuration.apiKey) {
        case .failure(let failure):
            return CompanionTodoSyncResult(pushed: 0, pulled: false, error: failure.category)
        case .success(let capabilities):
            guard stillCurrent(activation, configuration: configuration) else {
                return CompanionTodoSyncResult(pushed: 0, pulled: false, error: .identityMismatch)
            }
            do { try repository.recordCapabilities(identity: identity, capabilities: capabilities) }
            catch { return CompanionTodoSyncResult(pushed: 0, pulled: false, error: .localDataUnreadable) }
            guard capabilities.todos else { return CompanionTodoSyncResult(pushed: 0, pulled: false, error: nil) }
            do { try repository.retryCredentialBlocked(identity: identity) }
            catch { return CompanionTodoSyncResult(pushed: 0, pulled: false, error: .localDataUnreadable) }
        }

        var pushed = 0
        while pushed < maxPushes {
            let claim: ClaimedCompanionTodoOperation?
            do { claim = try repository.claimDue(identity: identity) }
            catch { return CompanionTodoSyncResult(pushed: pushed, pulled: false, error: .localDataUnreadable) }
            guard let claim else { break }
            let shouldContinue = await send(
                claim: claim,
                identity: identity,
                activation: activation,
                configuration: configuration
            )
            if !shouldContinue { break }
            pushed += 1
        }

        switch await api.listTodos(identity: activation.identity, apiKey: configuration.apiKey) {
        case .failure(let failure):
            return CompanionTodoSyncResult(pushed: pushed, pulled: false, error: failure.category)
        case .success(let items):
            guard stillCurrent(activation, configuration: configuration) else {
                return CompanionTodoSyncResult(pushed: pushed, pulled: false, error: .identityMismatch)
            }
            do { try repository.replaceServerSnapshot(identity: identity, items: items) }
            catch { return CompanionTodoSyncResult(pushed: pushed, pulled: false, error: .localDataUnreadable) }
            return CompanionTodoSyncResult(pushed: pushed, pulled: true, error: nil)
        }
    }

    private func send(
        claim: ClaimedCompanionTodoOperation,
        identity: QueueIdentity,
        activation: ActiveSessionSnapshot,
        configuration: CredentialConfig
    ) async -> Bool {
        let operation = claim.operation
        let result: Result<CompanionTodoItem?, ClassifiedFailure>
        switch operation.kind {
        case .create:
            guard let create = operation.create else { return false }
            result = await api.createTodo(
                identity: activation.identity,
                apiKey: configuration.apiKey,
                request: create,
                idempotencyKey: operation.id
            ).map { Optional($0) }
        case .patch:
            guard let patch = operation.patch else { return false }
            result = await api.patchTodo(
                identity: activation.identity,
                apiKey: configuration.apiKey,
                todoID: operation.targetTodoID,
                patch: patch,
                idempotencyKey: operation.id
            ).map { Optional($0) }
        case .delete:
            result = await api.deleteTodo(
                identity: activation.identity,
                apiKey: configuration.apiKey,
                todoID: operation.targetTodoID,
                idempotencyKey: operation.id
            ).map { nil as CompanionTodoItem? }
        }

        guard stillCurrent(activation, configuration: configuration) else {
            try? repository.markFailure(
                identity: identity,
                operationID: operation.id,
                owner: claim.owner,
                state: .blockedIdentity,
                category: .identityMismatch,
                nextAttemptAt: nil
            )
            return false
        }
        switch result {
        case .success(let item):
            do {
                switch operation.kind {
                case .create:
                    try repository.completeCreate(
                        identity: identity, operationID: operation.id, owner: claim.owner,
                        created: try require(item)
                    )
                case .patch:
                    try repository.completePatch(
                        identity: identity, operationID: operation.id, owner: claim.owner,
                        updated: try require(item)
                    )
                case .delete:
                    try repository.completeDelete(identity: identity, operationID: operation.id, owner: claim.owner)
                }
                return true
            } catch {
                return false
            }
        case .failure(let failure):
            return await handleFailure(
                failure,
                claim: claim,
                identity: identity,
                activation: activation,
                configuration: configuration
            )
        }
    }

    private func handleFailure(
        _ failure: ClassifiedFailure,
        claim: ClaimedCompanionTodoOperation,
        identity: QueueIdentity,
        activation: ActiveSessionSnapshot,
        configuration: CredentialConfig
    ) async -> Bool {
        let operation = claim.operation
        if failure.category == .http409, let desiredDone = operation.patch?.done {
            if case .success(let items) = await api.listTodos(identity: activation.identity, apiKey: configuration.apiKey),
               stillCurrent(activation, configuration: configuration) {
                let current = items.first(where: { $0.id == operation.targetTodoID })
                if current?.done == desiredDone {
                    do {
                        try repository.discard(identity: identity, operationID: operation.id, owner: claim.owner)
                        try repository.replaceServerSnapshot(identity: identity, items: items)
                        return true
                    } catch { return false }
                }
                do {
                    try repository.rebaseDoneConflict(
                        identity: identity,
                        operationID: operation.id,
                        owner: claim.owner,
                        desiredDone: desiredDone,
                        current: current,
                        snapshot: items
                    )
                    return current != nil
                } catch { return false }
            }
            try? repository.markFailure(
                identity: identity, operationID: operation.id, owner: claim.owner,
                state: .conflict, category: failure.category, nextAttemptAt: nil
            )
            return false
        }

        let state = Self.state(for: failure.category)
        let next = state == .retryWait
            ? Date().addingTimeInterval(Self.retryDelay(attempt: operation.attemptCount + 1))
            : nil
        try? repository.markFailure(
            identity: identity,
            operationID: operation.id,
            owner: claim.owner,
            state: state,
            category: failure.category,
            nextAttemptAt: next
        )
        return false
    }

    private func stillCurrent(_ expected: ActiveSessionSnapshot, configuration: CredentialConfig) -> Bool {
        guard configuration.identity == expected.identity,
              let active = try? queueRepository.activeSessionSnapshot(), active == expected,
              let stored = try? credentials.loadConfig(), stored == configuration else {
            return false
        }
        return true
    }

    private func require<T>(_ value: T?) throws -> T {
        guard let value else { throw TodoStateError.invalidData }
        return value
    }

    static func state(for category: ErrorCategory) -> CompanionTodoOutboxState {
        switch category {
        case .noNetwork, .dnsTimeout, .connectionReset, .clientDeadline, .http408, .http425,
             .rateLimit, .cooldown, .server:
            return .retryWait
        case .auth: return .blockedAuth
        case .scope: return .blockedScope
        case .identityMismatch: return .blockedIdentity
        case .http409: return .conflict
        default: return .failedPermanent
        }
    }

    static func retryDelay(attempt: Int) -> TimeInterval {
        let exponent = min(max(attempt, 1) - 1, 10)
        return min(6 * 60 * 60, 30 * pow(2, Double(exponent)))
    }
}
