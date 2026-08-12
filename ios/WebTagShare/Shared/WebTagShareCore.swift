import Foundation
import Security
import CryptoKit
#if canImport(SQLite3)
import SQLite3
#endif

struct SharePayload {
    let structuredURLs: [String]
    let plainText: String?
}

struct URLCandidate: Equatable {
    /// Exactly what will be sent to the API, byte for byte as it was shared.
    let submissionValue: String
    /// What the user is shown. Lossy on purpose and never parsed back into a
    /// URL - submission always reads `submissionValue`.
    let displayLabel: String
}

/// Renders the only part of a shared URL that is safe to put on screen.
///
/// Shared links routinely carry credentials, tracking identifiers and referrer
/// state in the query or fragment, and the share sheet is drawn over whatever
/// app the user came from. Everything after the path is dropped rather than
/// truncated, so nothing sensitive can be shoulder-surfed or read aloud by a
/// screen reader.
enum URLDisplayLabel {
    private static let defaultHTTPPort = 80
    private static let defaultHTTPSPort = 443

    /// Returns `host[:port]path` for a URL that already passed candidate
    /// validation, or nil when it cannot be parsed. The host is lower-cased
    /// because host comparison is case-insensitive and mixed case is a classic
    /// spoofing trick; the path keeps its original bytes because path
    /// comparison is case-sensitive and percent-encoding must survive.
    static func of(_ url: String) -> String? {
        guard let components = URLComponents(string: url), let rawHost = components.host else { return nil }
        var host = rawHost.lowercased()
        // `host` carries brackets on some OS versions and not others; strip
        // first so the bracketed IPv6 form is produced exactly once.
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty else { return nil }
        var label = host.contains(":") ? "[\(host)]" : host
        if let port = components.port, port != defaultPort(for: components.scheme) {
            label += ":\(port)"
        }
        let path = components.percentEncodedPath
        label += path.isEmpty ? "/" : path
        return label
    }

    private static func defaultPort(for scheme: String?) -> Int {
        switch scheme?.lowercased() {
        case "http": return defaultHTTPPort
        case "https": return defaultHTTPSPort
        default: return -1
        }
    }
}

/// Deterministic share-sheet logic, kept free of UIKit so the label/value split
/// can be pinned by unit tests.
///
/// A candidate is identified by its position and submitted by its own value.
/// Labels are lossy - two candidates that differ only in their query collapse to
/// the same `host + path` - so resolving a choice by label would submit the
/// wrong URL.
enum ShareCandidatePresenter {
    /// A chooser is only meaningful while more than one candidate exists.
    static func requiresSelection(_ candidates: [URLCandidate]) -> Bool { candidates.count > 1 }

    static func displayLabel(_ candidates: [URLCandidate], at index: Int) -> String? {
        candidates.indices.contains(index) ? candidates[index].displayLabel : nil
    }

    /// The verbatim URL that must be submitted for a chosen row.
    static func submissionValue(_ candidates: [URLCandidate], at index: Int) -> String? {
        candidates.indices.contains(index) ? candidates[index].submissionValue : nil
    }
}

enum QueueState: String, Codable, CaseIterable {
    case pendingSubmit = "pending_submit"
    case retryWait = "retry_wait"
    case blockedAuth = "blocked_auth"
    case blockedScope = "blocked_scope"
    case blockedQuota = "blocked_quota"
    case blockedIdentity = "blocked_identity"
    case failedPermanent = "failed_permanent"
    case expired
}

enum ErrorCategory: String, Codable {
    case noNetwork = "no_network"
    case dnsTimeout = "dns_timeout"
    case connectionReset = "connection_reset"
    case clientDeadline = "client_deadline"
    case tlsTrustFailure = "tls_trust_failure"
    case http408 = "http_408"
    case http425 = "http_425"
    case http409 = "http_409"
    case rateLimit = "rate_limit_exceeded"
    case cooldown = "cooldown_active"
    case quota = "quota_exceeded"
    case auth = "auth"
    case scope = "insufficient_scope"
    case server = "server_error"
    case invalidSuccessPayload = "invalid_success_payload"
    case invalidClientResponse = "invalid_client_response"
    case identityMismatch = "identity_mismatch"
    case localDataUnreadable = "local_data_unreadable"
}

struct QueueIdentity: Equatable {
    let origin: String
    let namespace: String
}

struct ActiveSessionSnapshot: Equatable {
    let identity: SessionIdentity
    let revision: Int64
}

struct SessionIdentity: Equatable {
    let origin: String
    let namespace: String
    let scopes: Set<String>
    let representationContract: String

    var canWrite: Bool { scopes.contains("write") && representationContract == "v2" }
}

struct SubmitResponse: Equatable, Codable {
    let linkID: String
    let status: String
    let jobID: String?
}

struct CredentialConfig: Equatable {
    let identity: SessionIdentity
    let apiKey: String
}

struct QueueEntry {
    let id: String
    let schemaVersion: Int
    let url: String
    let idempotencyKey: String
    let requestFingerprint: String
    let identity: QueueIdentity
    let identityRevision: Int64
    var state: QueueState
    let createdAt: Date
    var firstFailedAt: Date?
    var attemptCount: Int
    var nextAttemptAt: Date?
    var lastError: ErrorCategory?
    var lastErrorCode: String?
    var lastHTTPStatus: Int?
    var linkID: String?
    var jobID: String?
    var leaseOwner: String?
    var leaseExpiresAt: Date?
}

struct QueueEnqueueResult {
    let entry: QueueEntry
    let reused: Bool
}

struct RecentResult {
    let url: String
    let linkID: String
    let jobID: String?
    let status: String
    let createdAt: Date
    let identity: QueueIdentity
    let identityRevision: Int64
    let refreshNotBefore: Date?
    let refreshBlockReason: String?
    let isIdentityMismatch: Bool
}

enum QueueCommitResult: Equatable {
    case applied
    case staleClaim
    case identityChanged
}

struct RefreshCommitCapture: Equatable {
    let identity: QueueIdentity
    let identityRevision: Int64
    let expectedLinkID: String
}

enum RefreshCommitResult: String, Equatable {
    case applied
    case identityChanged = "identity_changed"
    case recentReplaced = "recent_replaced"
}

enum SubmissionOutcome {
    case submitted(SubmitResponse)
    case scheduled
    case queued(ErrorCategory, Date?)
    case blocked(QueueState, ErrorCategory)
    case staleClaim
    case configurationRequired
    case noCandidate
}

enum URLCandidateExtractor {
    private static let regex: NSRegularExpression = {
        let pattern = #"(?i)https?://[^\s<>"'\u2018-\u201f\u3000-\u303f\uff00-\uffef\u4e00-\u9fff]+"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    static func extract(_ payload: SharePayload) -> [URLCandidate] {
        var values = payload.structuredURLs
        if let text = payload.plainText {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            values.append(contentsOf: regex.matches(in: text, range: range).compactMap {
                Range($0.range, in: text).map { String(text[$0]) }
            })
        }

        var output: [URLCandidate] = []
        var seen = Set<String>()
        for raw in values {
            guard let value = normalizedCandidate(raw) else { continue }
            // Computed before the dedup key is consumed so an unlabelable URL
            // cannot mask a later, renderable duplicate.
            guard let label = URLDisplayLabel.of(value) else { continue }
            let key = deduplicationKey(value)
            if seen.insert(key).inserted {
                output.append(URLCandidate(submissionValue: value, displayLabel: label))
            }
        }
        return output
    }

    /// Trims the wrappers and sentence punctuation a link picks up in prose and
    /// then re-validates it. Shared with the item-provider collector so a
    /// structured URL representation and a link found in text are held to the
    /// same rules.
    static func normalizedCandidate(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let leading = CharacterSet(charactersIn: "([{<\u{3008}\u{300a}\u{300c}\u{300e}")
        let closing = CharacterSet(charactersIn: ")]}>\u{3009}\u{300b}\u{300d}\u{300f}")
        let punctuation = CharacterSet(charactersIn: ".,!?:;#\u{3002}\u{ff0c}\u{3001}\u{ff01}\u{ff1f}\u{061f}\u{2026}*`")
        while let first = value.unicodeScalars.first, leading.contains(first) { value.removeFirst() }
        while let last = value.unicodeScalars.last, closing.contains(last) { value.removeLast() }
        while let last = value.unicodeScalars.last, punctuation.contains(last) {
            value.removeLast()
            while let closingLast = value.unicodeScalars.last, closing.contains(closingLast) { value.removeLast() }
        }
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil,
              components.user == nil,
              components.password == nil,
              !value.contains(" ") else { return nil }
        return value
    }

    static func deduplicationKey(_ value: String) -> String {
        guard let components = URLComponents(string: value), let host = components.host else { return value }
        var key = "\(components.scheme?.lowercased() ?? "")://\(host.lowercased())"
        if let port = components.port { key += ":\(port)" }
        key += components.percentEncodedPath
        if let query = components.percentEncodedQuery { key += "?\(query)" }
        if let fragment = components.percentEncodedFragment { key += "#\(fragment)" }
        return key
    }
}

enum OriginNormalizer {
    static func normalize(_ raw: String) throws -> String {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw CoreError.invalidOrigin
        }
        let normalizedHost = host.lowercased()
        var result = "https://"
        result += normalizedHost.contains(":") ? "[\(normalizedHost)]" : normalizedHost
        if let port = components.port, port != 443 { result += ":\(port)" }
        return result
    }
}

enum CoreError: Error {
    case invalidOrigin
    case invalidSession
    case invalidResponse
    case identityMismatch
    case keychain
    case database
}

private func validateQueueIdentity(_ identity: QueueIdentity) throws {
    guard let normalizedOrigin = try? OriginNormalizer.normalize(identity.origin),
          normalizedOrigin == identity.origin,
          isValidDataNamespace(identity.namespace) else {
        throw CoreError.invalidOrigin
    }
}

private func validateSessionIdentity(_ identity: SessionIdentity) throws {
    try validateQueueIdentity(QueueIdentity(origin: identity.origin, namespace: identity.namespace))
    guard identity.representationContract == "v2",
          identity.scopes.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
        throw CoreError.invalidSession
    }
}

private func isValidDataNamespace(_ value: String) -> Bool {
    value.utf8.count == 43 && value.unicodeScalars.allSatisfy { scalar in
        (scalar.value >= 48 && scalar.value <= 57) ||
        (scalar.value >= 65 && scalar.value <= 90) ||
        (scalar.value >= 97 && scalar.value <= 122) ||
        scalar == "_" || scalar == "-"
    }
}

enum RetryPolicy {
    static let sevenDays: TimeInterval = 7 * 24 * 60 * 60
    static let sixHours: TimeInterval = 6 * 60 * 60
    static let minimumRetryAfter: TimeInterval = 60

    static func delay(attempt: Int, random: () -> Double = { Double.random(in: 0...1) }) -> TimeInterval {
        let exponent = min(max(attempt, 1) - 1, 10)
        let cap = min(sixHours, 30 * pow(2, Double(exponent)))
        return cap / 2 + random() * cap / 2
    }

    static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value), seconds >= 0 { return max(minimumRetryAfter, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(minimumRetryAfter, date.timeIntervalSince(now))
    }

    static func shouldExpire(firstFailedAt: Date?, now: Date = Date()) -> Bool {
        guard let firstFailedAt else { return false }
        return now.timeIntervalSince(firstFailedAt) >= sevenDays
    }
}

struct ClassifiedFailure: Error {
    let category: ErrorCategory
    let status: Int?
    let errorCode: String?
    let retryAfter: String?
}

enum ErrorClassifier {
    static func http(status: Int, errorCode: String?, retryAfter: String?) -> ClassifiedFailure {
        let category: ErrorCategory
        switch status {
        case 401: category = .auth
        case 403 where errorCode == "insufficient_scope": category = .scope
        case 408: category = .http408
        case 409: category = .http409
        case 425: category = .http425
        case 429 where errorCode == "cooldown_active": category = .cooldown
        case 429 where errorCode == "quota_exceeded": category = .quota
        case 429: category = .rateLimit
        case 500...599: category = .server
        default: category = .invalidClientResponse
        }
        return ClassifiedFailure(category: category, status: status, errorCode: errorCode, retryAfter: retryAfter)
    }

    static func transport(_ error: Error) -> ClassifiedFailure {
        var chain: [NSError] = []
        var current: NSError? = error as NSError
        for _ in 0..<16 {
            guard let value = current else { break }
            chain.append(value)
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let urlErrors = chain.filter { $0.domain == NSURLErrorDomain }
        let tlsCodes: Set<Int> = [
            NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid,
            NSURLErrorSecureConnectionFailed,
            NSURLErrorAppTransportSecurityRequiresSecureConnection,
        ]
        if urlErrors.contains(where: { tlsCodes.contains($0.code) }) {
            return ClassifiedFailure(category: .tlsTrustFailure, status: nil, errorCode: nil, retryAfter: nil)
        }
        if urlErrors.contains(where: { $0.code == NSURLErrorTimedOut }) {
            return ClassifiedFailure(category: .clientDeadline, status: nil, errorCode: nil, retryAfter: nil)
        }
        if urlErrors.contains(where: { [NSURLErrorDNSLookupFailed, NSURLErrorCannotFindHost].contains($0.code) }) {
            return ClassifiedFailure(category: .dnsTimeout, status: nil, errorCode: nil, retryAfter: nil)
        }
        if urlErrors.contains(where: { $0.code == NSURLErrorNotConnectedToInternet }) {
            return ClassifiedFailure(category: .noNetwork, status: nil, errorCode: nil, retryAfter: nil)
        }
        if urlErrors.contains(where: { $0.code == NSURLErrorCancelled }) {
            // Redirects are cancelled by the delegate and must not become retryable.
            return ClassifiedFailure(category: .invalidClientResponse, status: nil, errorCode: nil, retryAfter: nil)
        }
        return urlErrors.isEmpty
            ? ClassifiedFailure(category: .invalidClientResponse, status: nil, errorCode: nil, retryAfter: nil)
            : ClassifiedFailure(category: .connectionReset, status: nil, errorCode: nil, retryAfter: nil)
    }
}

enum QueueFailurePolicy {
    static func state(for category: ErrorCategory, firstFailedAt: Date?, now: Date) -> QueueState {
        switch category {
        case .auth: return .blockedAuth
        case .scope: return .blockedScope
        case .quota: return .blockedQuota
        case .identityMismatch: return .blockedIdentity
        case .tlsTrustFailure, .http409, .invalidSuccessPayload, .invalidClientResponse, .localDataUnreadable:
            return .failedPermanent
        default:
            return RetryPolicy.shouldExpire(firstFailedAt: firstFailedAt, now: now) && isRetryable(category)
                ? .expired
                : .retryWait
        }
    }

    static func nextAttemptAt(for category: ErrorCategory, attempt: Int, retryAfter: String?, firstFailedAt: Date?, now: Date) -> Date? {
        guard state(for: category, firstFailedAt: firstFailedAt, now: now) == .retryWait else { return nil }
        let exponential = RetryPolicy.delay(attempt: attempt)
        let serverDelay = RetryPolicy.retryAfter(retryAfter, now: now) ?? 0
        let delay: TimeInterval = [.rateLimit, .cooldown].contains(category)
            ? (serverDelay == 0 ? RetryPolicy.minimumRetryAfter : serverDelay)
            : max(exponential, serverDelay)
        return now.addingTimeInterval(min(delay, RetryPolicy.sixHours))
    }

    private static func isRetryable(_ category: ErrorCategory) -> Bool {
        switch category {
        case .noNetwork, .dnsTimeout, .connectionReset, .clientDeadline, .http408, .http425, .rateLimit, .cooldown, .server:
            return true
        default:
            return false
        }
    }
}

final class KeychainCredentialStore {
    private let account = "credential-v2"
    private let legacyAccount = "credential-v1"

    func save(config: CredentialConfig) throws {
        try validateSessionIdentity(config.identity)
        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoreError.keychain
        }
        let object: [String: Any] = [
            "api_key": config.apiKey,
            "origin": config.identity.origin,
            "namespace": config.identity.namespace,
            "scopes": config.identity.scopes.sorted(),
            "representation_contract": config.identity.representationContract,
        ]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { throw CoreError.keychain }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if !AppIdentifiers.keychainAccessGroup.isEmpty {
            query[kSecAttrAccessGroup as String] = AppIdentifiers.keychainAccessGroup
        }
        var updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        if !AppIdentifiers.keychainAccessGroup.isEmpty {
            updateQuery[kSecAttrAccessGroup as String] = AppIdentifiers.keychainAccessGroup
        }
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw CoreError.keychain }
        } else if updateStatus != errSecSuccess {
            throw CoreError.keychain
        }
        delete(account: legacyAccount)
    }

    func load() throws -> String? {
        try loadConfig()?.apiKey
    }

    func loadConfig() throws -> CredentialConfig? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !AppIdentifiers.keychainAccessGroup.isEmpty {
            query[kSecAttrAccessGroup as String] = AppIdentifiers.keychainAccessGroup
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CoreError.keychain }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apiKey = object["api_key"] as? String,
              let origin = object["origin"] as? String,
              let namespace = object["namespace"] as? String,
              let scopes = object["scopes"] as? [String],
              let representation = object["representation_contract"] as? String,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let normalizedOrigin = try? OriginNormalizer.normalize(origin),
              normalizedOrigin == origin,
              Self.isNamespace(namespace),
              scopes.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              representation == "v2" else { throw CoreError.keychain }
        return CredentialConfig(
            identity: SessionIdentity(
                origin: origin,
                namespace: namespace,
                scopes: Set(scopes),
                representationContract: representation
            ),
            apiKey: apiKey
        )
    }

    func clear() {
        delete(account: account)
        delete(account: legacyAccount)
    }

    private func delete(account: String) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        if !AppIdentifiers.keychainAccessGroup.isEmpty {
            query[kSecAttrAccessGroup as String] = AppIdentifiers.keychainAccessGroup
        }
        SecItemDelete(query as CFDictionary)
    }

    private static func isNamespace(_ value: String) -> Bool {
        value.utf8.count == 43 && value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) ||
            (scalar.value >= 65 && scalar.value <= 90) ||
            (scalar.value >= 97 && scalar.value <= 122) ||
            scalar == "_" || scalar == "-"
        }
    }
}

private func sha256(_ value: String) -> String {
    // SHA-256 is used as an equality guard; the URL itself remains the value submitted.
    let hash = Array(CryptoKit.SHA256.hash(data: Data(value.utf8)))
    return hash.map { String(format: "%02x", $0) }.joined()
}

#if canImport(SQLite3)
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum QueueLeasePolicy {
    static let duration: TimeInterval = 5 * 60
    static let renewalThreshold: TimeInterval = 60
}

struct BackgroundUploadClaim: Hashable {
    let queueID: String
    let owner: String
}

enum BackgroundClaimReconcileResult: Equatable {
    case matched(leaseExpiresAt: Date, renewed: Bool)
    case stale
}

final class AppGroupQueueRepository {
    private static let queueColumns = """
        id, schema_version, url, idempotency_key, request_fingerprint, api_origin,
        client_data_namespace, identity_revision, state, created_at, first_failed_at,
        attempt_count, next_attempt_at, last_error_kind, last_error_code,
        last_http_status, link_id, job_id, lease_owner, lease_expires_at
        """
    private var database: OpaquePointer?
    private let fileURL: URL
    private let lock = NSLock()

    init(containerURL: URL? = nil) throws {
        let container: URL
        if let containerURL {
            container = containerURL
        } else {
            guard let appGroup = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroup
            ) else { throw CoreError.database }
            container = appGroup
        }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        fileURL = container.appendingPathComponent("webtag-share.sqlite")
        try protect(container)
        var handle: OpaquePointer?
        let openStatus = fileURL.path.withCString {
            sqlite3_open_v2($0, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        }
        guard openStatus == SQLITE_OK,
              let handle else { throw CoreError.database }
        database = handle
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA busy_timeout=5000;")
        try migrate()
        try protect(fileURL)
        try protect(URL(fileURLWithPath: fileURL.path + "-wal"))
        try protect(URL(fileURLWithPath: fileURL.path + "-shm"))
    }

    var databaseURL: URL { fileURL }

    deinit { if let database { sqlite3_close(database) } }

    func enqueue(url: String, identity: QueueIdentity, now: Date = Date()) throws -> QueueEntry {
        try validateQueueIdentity(identity)
        lock.lock(); defer { lock.unlock() }
        let revision = try requireActiveRevisionUnlocked(for: identity)
        let entry = newEntry(url: url, identity: identity, identityRevision: revision, now: now)
        try insertUnlocked(entry, now: now)
        return entry
    }

    func enqueueOrReuse(url: String, identity: QueueIdentity, now: Date = Date()) throws -> QueueEnqueueResult {
        try validateQueueIdentity(identity)
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE;")
        do {
            let revision = try requireActiveRevisionUnlocked(for: identity)
            if let reusable = try findReusableUnlocked(url: url, identity: identity) {
                try execute("COMMIT;")
                return QueueEnqueueResult(entry: reusable, reused: true)
            }
            let entry = newEntry(url: url, identity: identity, identityRevision: revision, now: now)
            try insertUnlocked(entry, now: now)
            try execute("COMMIT;")
            return QueueEnqueueResult(entry: entry, reused: false)
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func newEntry(url: String, identity: QueueIdentity, identityRevision: Int64, now: Date) -> QueueEntry {
        QueueEntry(
            id: UUID().uuidString.lowercased(), schemaVersion: 1, url: url,
            idempotencyKey: UUID().uuidString.lowercased(), requestFingerprint: sha256(url),
            identity: identity, identityRevision: identityRevision,
            state: .pendingSubmit, createdAt: now, firstFailedAt: nil,
            attemptCount: 0, nextAttemptAt: nil, lastError: nil, lastErrorCode: nil,
            lastHTTPStatus: nil, linkID: nil, jobID: nil, leaseOwner: nil, leaseExpiresAt: nil)
    }

    private func insertUnlocked(_ entry: QueueEntry, now: Date) throws {
        let statement = try prepare("""
            INSERT INTO queue_entries
            (id, schema_version, url, idempotency_key, request_fingerprint, api_origin,
             client_data_namespace, identity_revision, state, created_at, attempt_count, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, entry.id); bind(statement, 2, Int32(entry.schemaVersion)); bind(statement, 3, entry.url)
        bind(statement, 4, entry.idempotencyKey); bind(statement, 5, entry.requestFingerprint)
        bind(statement, 6, entry.identity.origin); bind(statement, 7, entry.identity.namespace)
        bind(statement, 8, entry.identityRevision); bind(statement, 9, entry.state.rawValue)
        bind(statement, 10, now.timeIntervalSince1970); bind(statement, 11, Int32(0)); bind(statement, 12, now.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CoreError.database }
    }

    func findReusable(url: String, identity: QueueIdentity) throws -> QueueEntry? {
        lock.lock(); defer { lock.unlock() }
        return try findReusableUnlocked(url: url, identity: identity)
    }

    private func findReusableUnlocked(url: String, identity: QueueIdentity) throws -> QueueEntry? {
        let statement = try prepare("""
            SELECT \(Self.queueColumns)
            FROM queue_entries
            WHERE api_origin=? AND client_data_namespace=?
              AND state IN ('pending_submit', 'retry_wait', 'PENDING_SUBMIT', 'RETRY_WAIT')
            ORDER BY created_at
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, identity.origin); bind(statement, 2, identity.namespace)
        while sqlite3_step(statement) == SQLITE_ROW {
            let entry = makeEntry(statement, identity: nil)
            if entry.url == url,
               sha256(entry.url) == entry.requestFingerprint {
                return entry
            }
        }
        return nil
    }

    func claim(id: String, owner: String, now: Date = Date(), leaseDuration: TimeInterval = QueueLeasePolicy.duration) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let active = try activeSessionSnapshotUnlocked() else { return false }
        let statement = try prepare("""
            UPDATE queue_entries SET lease_owner=?, lease_expires_at=?, updated_at=?
            WHERE id=?
              AND api_origin=? AND client_data_namespace=? AND identity_revision=?
              AND state IN ('pending_submit', 'retry_wait', 'PENDING_SUBMIT', 'RETRY_WAIT')
              AND (next_attempt_at IS NULL OR next_attempt_at<=?)
              AND (lease_owner IS NULL OR lease_expires_at<=?)
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, owner); bind(statement, 2, now.timeIntervalSince1970 + leaseDuration); bind(statement, 3, now.timeIntervalSince1970)
        bind(statement, 4, id); bind(statement, 5, active.identity.origin); bind(statement, 6, active.identity.namespace)
        bind(statement, 7, active.revision); bind(statement, 8, now.timeIntervalSince1970); bind(statement, 9, now.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CoreError.database }
        return sqlite3_changes(database) == 1
    }

    func entry(id: String) throws -> QueueEntry? {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("""
            SELECT \(Self.queueColumns)
            FROM queue_entries WHERE id=?
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return makeEntry(statement, identity: nil)
    }

    func due(now: Date = Date()) throws -> [QueueEntry] {
        lock.lock(); defer { lock.unlock() }
        guard let active = try activeSessionSnapshotUnlocked() else { return [] }
        let statement = try prepare("""
            SELECT \(Self.queueColumns)
            FROM queue_entries
            WHERE api_origin=? AND client_data_namespace=? AND identity_revision=?
              AND state IN ('pending_submit', 'retry_wait', 'PENDING_SUBMIT', 'RETRY_WAIT')
              AND (next_attempt_at IS NULL OR next_attempt_at<=?)
              AND (lease_owner IS NULL OR lease_expires_at<=?)
            ORDER BY COALESCE(next_attempt_at, created_at) ASC, created_at ASC, id ASC
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, active.identity.origin); bind(statement, 2, active.identity.namespace)
        bind(statement, 3, active.revision); bind(statement, 4, now.timeIntervalSince1970); bind(statement, 5, now.timeIntervalSince1970)
        var entries: [QueueEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW { entries.append(makeEntry(statement, identity: nil)) }
        return entries
    }

    func releaseExpiredLeases(now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("UPDATE queue_entries SET lease_owner=NULL, lease_expires_at=NULL, updated_at=? WHERE lease_expires_at IS NOT NULL AND lease_expires_at<=?")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, now.timeIntervalSince1970); bind(statement, 2, now.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CoreError.database }
    }

    /// Reconciliation is deliberately keyed by the full background task
    /// descriptor. A queue ID alone cannot distinguish a reclaimed lease from
    /// an old background task that happens to finish late.
    func reconcileBackgroundClaim(_ claim: BackgroundUploadClaim, now: Date = Date()) throws -> BackgroundClaimReconcileResult {
        lock.lock(); defer { lock.unlock() }
        guard let active = try activeSessionSnapshotUnlocked() else { return .stale }
        let lookup = try prepare("SELECT api_origin, client_data_namespace, identity_revision, lease_owner, lease_expires_at FROM queue_entries WHERE id=?")
        defer { sqlite3_finalize(lookup) }
        bind(lookup, 1, claim.queueID)
        guard sqlite3_step(lookup) == SQLITE_ROW else { return .stale }
        let identity = QueueIdentity(origin: text(lookup, 0), namespace: text(lookup, 1))
        let revision = sqlite3_column_int64(lookup, 2)
        guard identity == QueueIdentity(origin: active.identity.origin, namespace: active.identity.namespace),
              revision == active.revision,
              textOptional(lookup, 3) == claim.owner,
              let expiry = date(lookup, 4), expiry > now else { return .stale }
        guard expiry.timeIntervalSince(now) <= QueueLeasePolicy.renewalThreshold else {
            return .matched(leaseExpiresAt: expiry, renewed: false)
        }
        let renewedUntil = now.addingTimeInterval(QueueLeasePolicy.duration)
        let renew = try prepare("UPDATE queue_entries SET lease_expires_at=?, updated_at=? WHERE id=? AND api_origin=? AND client_data_namespace=? AND identity_revision=? AND lease_owner=? AND lease_expires_at=?")
        defer { sqlite3_finalize(renew) }
        bind(renew, 1, renewedUntil.timeIntervalSince1970); bind(renew, 2, now.timeIntervalSince1970)
        bind(renew, 3, claim.queueID); bind(renew, 4, identity.origin); bind(renew, 5, identity.namespace)
        bind(renew, 6, revision); bind(renew, 7, claim.owner); bind(renew, 8, expiry.timeIntervalSince1970)
        guard sqlite3_step(renew) == SQLITE_DONE, sqlite3_changes(database) == 1 else { return .stale }
        return .matched(leaseExpiresAt: renewedUntil, renewed: true)
    }

    /// The returned deadline is persisted queue state, never an in-memory
    /// retry counter. Active leases wake at their expiry so a crash cannot
    /// strand their body indefinitely; otherwise a row cannot wake before its
    /// durable retry deadline.
    func earliestWake(now: Date = Date()) throws -> Date? {
        lock.lock(); defer { lock.unlock() }
        guard let active = try activeSessionSnapshotUnlocked() else { return nil }
        let statement = try prepare("SELECT next_attempt_at, created_at, lease_expires_at FROM queue_entries WHERE api_origin=? AND client_data_namespace=? AND identity_revision=? AND state IN ('pending_submit', 'retry_wait', 'PENDING_SUBMIT', 'RETRY_WAIT') ORDER BY CASE WHEN lease_expires_at IS NOT NULL AND lease_expires_at>? THEN lease_expires_at ELSE COALESCE(next_attempt_at, created_at) END ASC, created_at ASC, id ASC LIMIT 1")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, active.identity.origin); bind(statement, 2, active.identity.namespace)
        bind(statement, 3, active.revision); bind(statement, 4, now.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        if let lease = date(statement, 2), lease > now { return lease }
        return date(statement, 0) ?? Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
    }

    @discardableResult
    func finishSuccess(entry: QueueEntry, owner: String, response: SubmitResponse, now: Date = Date()) throws -> QueueCommitResult {
        guard sha256(entry.url) == entry.requestFingerprint else { throw CoreError.database }
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE;")
        do {
            let commit = try commitStatusUnlocked(entry: entry, owner: owner, now: now)
            guard commit == .applied else {
                try execute("COMMIT;")
                return commit
            }
            let recent = try prepare("""
                INSERT OR REPLACE INTO recent_result
                (id, url, link_id, job_id, status, created_at, api_origin,
                 client_data_namespace, identity_revision)
                VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(recent) }
            bind(recent, 1, entry.url); bind(recent, 2, response.linkID); bindOptional(recent, 3, response.jobID)
            bind(recent, 4, response.status); bind(recent, 5, now.timeIntervalSince1970)
            bind(recent, 6, entry.identity.origin); bind(recent, 7, entry.identity.namespace)
            bind(recent, 8, entry.identityRevision)
            guard sqlite3_step(recent) == SQLITE_DONE else { throw CoreError.database }
            guard try deleteUnlocked(id: entry.id, owner: owner, identityRevision: entry.identityRevision, now: now) else {
                throw CoreError.database
            }
            try execute("COMMIT;")
            return .applied
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    @discardableResult
    func applyFailure(entry: QueueEntry, owner: String, state: QueueState, category: ErrorCategory,
                      errorCode: String?, status: Int?, nextAttemptAt: Date?, firstFailedAt: Date?,
                      now: Date = Date()) throws -> QueueCommitResult {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE;")
        do {
            let commit = try commitStatusUnlocked(entry: entry, owner: owner, now: now)
            guard commit == .applied else {
                try execute("COMMIT;")
                return commit
            }
            let statement = try prepare("""
                UPDATE queue_entries SET state=?, first_failed_at=?, attempt_count=?, next_attempt_at=?,
                 last_error_kind=?, last_error_code=?, last_http_status=?, lease_owner=NULL,
                 lease_expires_at=NULL, updated_at=?
                WHERE id=? AND api_origin=? AND client_data_namespace=? AND identity_revision=?
                  AND lease_owner=? AND lease_expires_at>?
                """)
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, state.rawValue); bindOptional(statement, 2, firstFailedAt?.timeIntervalSince1970)
            bind(statement, 3, Int32(entry.attemptCount + 1)); bindOptional(statement, 4, nextAttemptAt?.timeIntervalSince1970)
            bind(statement, 5, category.rawValue); bindOptional(statement, 6, errorCode?.prefix(80).description)
            bindOptional(statement, 7, status.map(Int32.init)); bind(statement, 8, now.timeIntervalSince1970)
            bind(statement, 9, entry.id); bind(statement, 10, entry.identity.origin); bind(statement, 11, entry.identity.namespace)
            bind(statement, 12, entry.identityRevision); bind(statement, 13, owner); bind(statement, 14, now.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1 else { throw CoreError.database }
            try execute("COMMIT;")
            return .applied
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func list(identity: QueueIdentity? = nil) throws -> [QueueEntry] {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("""
            SELECT \(Self.queueColumns)
            FROM queue_entries ORDER BY created_at
            """)
        defer { sqlite3_finalize(statement) }
        var entries: [QueueEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            entries.append(makeEntry(statement, identity: identity))
        }
        return entries
    }

    func recent(identity: QueueIdentity? = nil) throws -> RecentResult? {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("SELECT url, link_id, job_id, status, created_at, api_origin, client_data_namespace, identity_revision, refresh_not_before, refresh_block_reason FROM recent_result WHERE id=1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let entryIdentity = QueueIdentity(origin: text(statement, 5), namespace: text(statement, 6))
        let identityMismatch = identity.map { $0 != entryIdentity } ?? false
        return RecentResult(url: identityMismatch ? "" : text(statement, 0),
                            linkID: identityMismatch ? "" : text(statement, 1),
                            jobID: identityMismatch ? nil : textOptional(statement, 2),
                            status: identityMismatch ? "identity_mismatch" : text(statement, 3),
                            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                            identity: entryIdentity, identityRevision: sqlite3_column_int64(statement, 7),
                            refreshNotBefore: date(statement, 8),
                            refreshBlockReason: textOptional(statement, 9), isIdentityMismatch: identityMismatch)
    }

    func activeIdentity() throws -> QueueIdentity? {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("SELECT key, value FROM metadata WHERE key IN ('api_origin', 'client_data_namespace')")
        defer { sqlite3_finalize(statement) }
        var values: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW { values[text(statement, 0)] = text(statement, 1) }
        guard let origin = values["api_origin"], let namespace = values["client_data_namespace"] else { return nil }
        let identity = QueueIdentity(origin: origin, namespace: namespace)
        try validateQueueIdentity(identity)
        return identity
    }

    func activeSessionIdentity() throws -> SessionIdentity? {
        lock.lock(); defer { lock.unlock() }
        return try activeSessionSnapshotUnlocked()?.identity
    }

    func activeSessionSnapshot() throws -> ActiveSessionSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return try activeSessionSnapshotUnlocked()
    }

    private func activeSessionSnapshotUnlocked() throws -> ActiveSessionSnapshot? {
        let statement = try prepare("SELECT key, value FROM metadata WHERE key IN ('api_origin', 'client_data_namespace', 'scopes', 'representation_contract')")
        defer { sqlite3_finalize(statement) }
        var values: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW { values[text(statement, 0)] = text(statement, 1) }
        guard let origin = values["api_origin"], let namespace = values["client_data_namespace"],
              let representation = values["representation_contract"] else { return nil }
        let scopes = Set((values["scopes"] ?? "").split(separator: ",").map(String.init))
        let identity = SessionIdentity(origin: origin, namespace: namespace, scopes: scopes, representationContract: representation)
        try validateSessionIdentity(identity)
        let revisionStatement = try prepare("SELECT value FROM metadata WHERE key='active_identity_revision'")
        defer { sqlite3_finalize(revisionStatement) }
        guard sqlite3_step(revisionStatement) == SQLITE_ROW,
              let revision = Int64(text(revisionStatement, 0)), revision > 0 else { return nil }
        return ActiveSessionSnapshot(identity: identity, revision: revision)
    }

    @discardableResult
    func activate(session: SessionIdentity, now: Date = Date()) throws -> Int64 {
        try validateSessionIdentity(session)
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE;")
        do {
            let counter = try metadataInt64Unlocked(key: "identity_revision_counter") ?? 0
            guard counter < Int64.max else { throw CoreError.database }
            let revision = counter + 1
            let statement = try prepare("INSERT OR REPLACE INTO metadata(key, value) VALUES(?, ?)")
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, "api_origin"); bind(statement, 2, session.origin)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw CoreError.database }
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            bind(statement, 1, "client_data_namespace"); bind(statement, 2, session.namespace)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw CoreError.database }
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            bind(statement, 1, "scopes"); bind(statement, 2, session.scopes.sorted().joined(separator: ","))
            guard sqlite3_step(statement) == SQLITE_DONE else { throw CoreError.database }
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            bind(statement, 1, "representation_contract"); bind(statement, 2, session.representationContract)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw CoreError.database }
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            bind(statement, 1, "identity_revision_counter"); bind(statement, 2, String(revision))
            guard sqlite3_step(statement) == SQLITE_DONE else { throw CoreError.database }
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            bind(statement, 1, "active_identity_revision"); bind(statement, 2, String(revision))
            guard sqlite3_step(statement) == SQLITE_DONE else { throw CoreError.database }

            let adoptQueue = try prepare("""
                UPDATE queue_entries SET identity_revision=?, lease_owner=NULL,
                 lease_expires_at=NULL, updated_at=?
                WHERE api_origin=? AND client_data_namespace=?
                """)
            defer { sqlite3_finalize(adoptQueue) }
            bind(adoptQueue, 1, revision); bind(adoptQueue, 2, now.timeIntervalSince1970)
            bind(adoptQueue, 3, session.origin); bind(adoptQueue, 4, session.namespace)
            guard sqlite3_step(adoptQueue) == SQLITE_DONE else { throw CoreError.database }

            let adoptRecent = try prepare("""
                UPDATE recent_result SET identity_revision=?
                WHERE api_origin=? AND client_data_namespace=?
                """)
            defer { sqlite3_finalize(adoptRecent) }
            bind(adoptRecent, 1, revision); bind(adoptRecent, 2, session.origin); bind(adoptRecent, 3, session.namespace)
            guard sqlite3_step(adoptRecent) == SQLITE_DONE else { throw CoreError.database }
            try execute("COMMIT;")
            return revision
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    @discardableResult
    func resetForRetry(id: String, now: Date = Date()) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let active = try activeSessionSnapshotUnlocked() else { return false }
        let statement = try prepare("UPDATE queue_entries SET state=?, first_failed_at=NULL, attempt_count=CASE WHEN state IN ('expired', 'EXPIRED') THEN 0 ELSE attempt_count END, next_attempt_at=NULL, last_error_kind=NULL, last_error_code=NULL, last_http_status=NULL, lease_owner=NULL, lease_expires_at=NULL, updated_at=? WHERE id=? AND api_origin=? AND client_data_namespace=? AND identity_revision=? AND state IN ('retry_wait', 'blocked_auth', 'blocked_scope', 'blocked_quota', 'failed_permanent', 'expired', 'RETRY_WAIT', 'BLOCKED_AUTH', 'BLOCKED_SCOPE', 'BLOCKED_QUOTA', 'FAILED_PERMANENT', 'EXPIRED') AND (lease_owner IS NULL OR lease_expires_at<=?)")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, QueueState.pendingSubmit.rawValue); bind(statement, 2, now.timeIntervalSince1970); bind(statement, 3, id)
        bind(statement, 4, active.identity.origin); bind(statement, 5, active.identity.namespace); bind(statement, 6, active.revision)
        bind(statement, 7, now.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CoreError.database }
        return sqlite3_changes(database) == 1
    }

    @discardableResult
    func migrateIdentity(id: String, to target: QueueIdentity, now: Date = Date()) throws -> Bool {
        try validateQueueIdentity(target)
        lock.lock(); defer { lock.unlock() }
        guard let active = try activeSessionSnapshotUnlocked(),
              QueueIdentity(origin: active.identity.origin, namespace: active.identity.namespace) == target else { return false }
        let lookup = try prepare("SELECT api_origin, client_data_namespace, lease_owner, lease_expires_at FROM queue_entries WHERE id=?")
        defer { sqlite3_finalize(lookup) }
        bind(lookup, 1, id)
        guard sqlite3_step(lookup) == SQLITE_ROW else { return false }
        let oldOrigin = text(lookup, 0)
        let oldNamespace = text(lookup, 1)
        try validateQueueIdentity(QueueIdentity(origin: oldOrigin, namespace: oldNamespace))
        let oldLeaseOwner = textOptional(lookup, 2)
        let oldLeaseExpiry = date(lookup, 3)
        guard oldOrigin != target.origin || oldNamespace != target.namespace else { return false }
        guard oldLeaseOwner == nil || oldLeaseExpiry.map({ $0 <= now }) == true else { return false }

        let statement = try prepare("""
            UPDATE queue_entries SET idempotency_key=?, api_origin=?, client_data_namespace=?, identity_revision=?,
             state=?, first_failed_at=NULL, attempt_count=0, next_attempt_at=NULL,
             last_error_kind=NULL, last_error_code=NULL, last_http_status=NULL,
             link_id=NULL, job_id=NULL, lease_owner=NULL, lease_expires_at=NULL, updated_at=?
             WHERE id=? AND api_origin=? AND client_data_namespace=?
             AND (lease_owner IS NULL OR lease_expires_at<=?)
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, UUID().uuidString.lowercased())
        bind(statement, 2, target.origin)
        bind(statement, 3, target.namespace)
        bind(statement, 4, active.revision)
        bind(statement, 5, QueueState.pendingSubmit.rawValue)
        bind(statement, 6, now.timeIntervalSince1970)
        bind(statement, 7, id)
        bind(statement, 8, oldOrigin)
        bind(statement, 9, oldNamespace)
        bind(statement, 10, now.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CoreError.database }
        return sqlite3_changes(database) == 1
    }

    @discardableResult
    func retryIdentityBlocked(identity: QueueIdentity, now: Date = Date()) throws -> Int {
        try validateQueueIdentity(identity)
        lock.lock(); defer { lock.unlock() }
        guard let active = try activeSessionSnapshotUnlocked(),
              QueueIdentity(origin: active.identity.origin, namespace: active.identity.namespace) == identity else { return 0 }
        let statement = try prepare("""
            UPDATE queue_entries SET state=?, first_failed_at=NULL, next_attempt_at=NULL,
             last_error_kind=NULL, last_error_code=NULL, last_http_status=NULL,
             lease_owner=NULL, lease_expires_at=NULL, updated_at=?
             WHERE api_origin=? AND client_data_namespace=? AND identity_revision=?
             AND state IN ('blocked_auth', 'blocked_scope', 'BLOCKED_AUTH', 'BLOCKED_SCOPE')
             AND (lease_owner IS NULL OR lease_expires_at<=?)
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, QueueState.pendingSubmit.rawValue)
        bind(statement, 2, now.timeIntervalSince1970)
        bind(statement, 3, identity.origin)
        bind(statement, 4, identity.namespace)
        bind(statement, 5, active.revision)
        bind(statement, 6, now.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CoreError.database }
        return Int(sqlite3_changes(database))
    }

    func clearRecent() throws { lock.lock(); defer { lock.unlock() }; try execute("DELETE FROM recent_result WHERE id=1") }
    func delete(id: String) throws { lock.lock(); defer { lock.unlock() }; try deleteUnlocked(id: id, owner: nil) }
    func clearQueue() throws { lock.lock(); defer { lock.unlock() }; try execute("DELETE FROM queue_entries") }

    @discardableResult
    func recordRefreshSuccess(identity: QueueIdentity, response: SubmitResponse, now: Date = Date()) throws -> Bool {
        guard let capture = try refreshCapture(identity: identity) else { return false }
        return try recordRefreshSuccess(capture: capture, response: response, now: now) == .applied
    }

    @discardableResult
    func recordRefreshBlocked(identity: QueueIdentity, notBefore: Date?, reason: String) throws -> Bool {
        guard let capture = try refreshCapture(identity: identity) else { return false }
        return try recordRefreshBlocked(capture: capture, notBefore: notBefore, reason: reason) == .applied
    }

    /// Captures every value a refresh response is allowed to update. The
    /// capture is deliberately durable-state based: a late HTTP response must
    /// not overwrite a newer recent link or an identity activated meanwhile.
    func refreshCapture(identity: QueueIdentity) throws -> RefreshCommitCapture? {
        lock.lock(); defer { lock.unlock() }
        guard let active = try activeSessionSnapshotUnlocked(),
              QueueIdentity(origin: active.identity.origin, namespace: active.identity.namespace) == identity else { return nil }
        let statement = try prepare("SELECT link_id, api_origin, client_data_namespace, identity_revision FROM recent_result WHERE id=1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let recentIdentity = QueueIdentity(origin: text(statement, 1), namespace: text(statement, 2))
        let revision = sqlite3_column_int64(statement, 3)
        guard recentIdentity == identity, revision == active.revision else { return nil }
        return RefreshCommitCapture(identity: identity, identityRevision: revision, expectedLinkID: text(statement, 0))
    }

    @discardableResult
    func recordRefreshSuccess(capture: RefreshCommitCapture, response: SubmitResponse, now: Date = Date()) throws -> RefreshCommitResult {
        lock.lock(); defer { lock.unlock() }
        guard let active = try activeSessionSnapshotUnlocked(),
              QueueIdentity(origin: active.identity.origin, namespace: active.identity.namespace) == capture.identity,
              active.revision == capture.identityRevision else { return .identityChanged }
        guard UUID(uuidString: response.linkID) == UUID(uuidString: capture.expectedLinkID) else {
            return .recentReplaced
        }
        let statement = try prepare("UPDATE recent_result SET job_id=?, status=?, created_at=?, refresh_not_before=NULL, refresh_block_reason=NULL WHERE id=1 AND api_origin=? AND client_data_namespace=? AND identity_revision=? AND link_id=?")
        defer { sqlite3_finalize(statement) }
        bindOptional(statement, 1, response.jobID); bind(statement, 2, response.status); bind(statement, 3, now.timeIntervalSince1970)
        bind(statement, 4, capture.identity.origin); bind(statement, 5, capture.identity.namespace)
        bind(statement, 6, capture.identityRevision); bind(statement, 7, capture.expectedLinkID)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CoreError.database }
        return sqlite3_changes(database) == 1 ? .applied : .recentReplaced
    }

    @discardableResult
    func recordRefreshBlocked(capture: RefreshCommitCapture, notBefore: Date?, reason: String) throws -> RefreshCommitResult {
        lock.lock(); defer { lock.unlock() }
        guard let active = try activeSessionSnapshotUnlocked(),
              QueueIdentity(origin: active.identity.origin, namespace: active.identity.namespace) == capture.identity,
              active.revision == capture.identityRevision else { return .identityChanged }
        let statement = try prepare("UPDATE recent_result SET refresh_not_before=?, refresh_block_reason=? WHERE id=1 AND api_origin=? AND client_data_namespace=? AND identity_revision=? AND link_id=?")
        defer { sqlite3_finalize(statement) }
        bindOptional(statement, 1, notBefore?.timeIntervalSince1970); bind(statement, 2, reason)
        bind(statement, 3, capture.identity.origin); bind(statement, 4, capture.identity.namespace)
        bind(statement, 5, capture.identityRevision); bind(statement, 6, capture.expectedLinkID)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CoreError.database }
        return sqlite3_changes(database) == 1 ? .applied : .recentReplaced
    }

    private func migrate() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS queue_entries (
              id TEXT PRIMARY KEY, schema_version INTEGER NOT NULL, url TEXT NOT NULL,
              idempotency_key TEXT NOT NULL, request_fingerprint TEXT NOT NULL,
              api_origin TEXT NOT NULL, client_data_namespace TEXT NOT NULL,
              identity_revision INTEGER NOT NULL DEFAULT 0,
              state TEXT NOT NULL, created_at REAL NOT NULL, first_failed_at REAL,
              attempt_count INTEGER NOT NULL, next_attempt_at REAL, last_error_kind TEXT,
              last_error_code TEXT, last_http_status INTEGER, link_id TEXT, job_id TEXT,
              lease_owner TEXT, lease_expires_at REAL, updated_at REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS queue_due ON queue_entries(state, next_attempt_at, created_at);
            CREATE TABLE IF NOT EXISTS recent_result (
              id INTEGER PRIMARY KEY CHECK(id=1), url TEXT NOT NULL, link_id TEXT NOT NULL,
              job_id TEXT, status TEXT NOT NULL, created_at REAL NOT NULL,
              api_origin TEXT NOT NULL, client_data_namespace TEXT NOT NULL,
              identity_revision INTEGER NOT NULL DEFAULT 0,
              refresh_not_before REAL, refresh_block_reason TEXT);
            """)
        try addColumnIfMissing(table: "queue_entries", column: "identity_revision", definition: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing(table: "recent_result", column: "identity_revision", definition: "INTEGER NOT NULL DEFAULT 0")
    }

    @discardableResult
    private func deleteUnlocked(id: String, owner: String?, identityRevision: Int64? = nil, now: Date = Date()) throws -> Bool {
        let statement = try prepare(owner == nil ? "DELETE FROM queue_entries WHERE id=?" : "DELETE FROM queue_entries WHERE id=? AND identity_revision=? AND lease_owner=? AND lease_expires_at>?")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        if let owner {
            bind(statement, 2, identityRevision ?? -1)
            bind(statement, 3, owner)
            bind(statement, 4, now.timeIntervalSince1970)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CoreError.database }
        return sqlite3_changes(database) == 1
    }

    private func makeEntry(_ statement: OpaquePointer, identity: QueueIdentity?) -> QueueEntry {
        let entryIdentity = QueueIdentity(origin: text(statement, 5), namespace: text(statement, 6))
        let identityMismatch = identity.map { $0 != entryIdentity } ?? false
        return QueueEntry(
            id: text(statement, 0), schemaVersion: Int(sqlite3_column_int(statement, 1)),
            url: identityMismatch ? "" : text(statement, 2), idempotencyKey: text(statement, 3),
            requestFingerprint: text(statement, 4), identity: entryIdentity,
            identityRevision: sqlite3_column_int64(statement, 7),
            state: identityMismatch ? .blockedIdentity : (QueueState(rawValue: text(statement, 8)) ?? .failedPermanent),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
            firstFailedAt: date(statement, 10), attemptCount: Int(sqlite3_column_int(statement, 11)),
            nextAttemptAt: date(statement, 12),
            lastError: identityMismatch ? .identityMismatch : ErrorCategory(rawValue: textOptional(statement, 13) ?? ""),
            lastErrorCode: textOptional(statement, 14), lastHTTPStatus: intOptional(statement, 15),
            linkID: textOptional(statement, 16), jobID: textOptional(statement, 17),
            leaseOwner: textOptional(statement, 18), leaseExpiresAt: date(statement, 19))
    }

    private func addColumnIfMissing(table: String, column: String, definition: String) throws {
        let statement = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if text(statement, 1) == column { return }
        }
        try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }

    private func metadataInt64Unlocked(key: String) throws -> Int64? {
        let statement = try prepare("SELECT value FROM metadata WHERE key=?")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, key)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int64(text(statement, 0))
    }

    private func requireActiveRevisionUnlocked(for identity: QueueIdentity) throws -> Int64 {
        guard let active = try activeSessionSnapshotUnlocked(),
              QueueIdentity(origin: active.identity.origin, namespace: active.identity.namespace) == identity else {
            throw CoreError.identityMismatch
        }
        return active.revision
    }

    private func commitStatusUnlocked(entry: QueueEntry, owner: String, now: Date) throws -> QueueCommitResult {
        guard let active = try activeSessionSnapshotUnlocked(),
              QueueIdentity(origin: active.identity.origin, namespace: active.identity.namespace) == entry.identity,
              active.revision == entry.identityRevision else { return .identityChanged }
        let statement = try prepare("SELECT api_origin, client_data_namespace, identity_revision, lease_owner, lease_expires_at FROM queue_entries WHERE id=?")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, entry.id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return .staleClaim }
        let storedIdentity = QueueIdentity(origin: text(statement, 0), namespace: text(statement, 1))
        guard storedIdentity == entry.identity, sqlite3_column_int64(statement, 2) == entry.identityRevision else { return .identityChanged }
        guard textOptional(statement, 3) == owner,
              date(statement, 4).map({ $0 > now }) == true else { return .staleClaim }
        return .applied
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<Int8>?
        let status = sql.withCString { sqlite3_exec(database, $0, nil, nil, &error) }
        guard status == SQLITE_OK else {
            if let error { sqlite3_free(error) }
            throw CoreError.database
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let status = sql.withCString { sqlite3_prepare_v2(database, $0, -1, &statement, nil) }
        guard status == SQLITE_OK, let statement else { throw CoreError.database }
        return statement
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        value.withCString { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) }
    }
    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Int32) { sqlite3_bind_int(statement, index, value) }
    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Int64) { sqlite3_bind_int64(statement, index, sqlite3_int64(value)) }
    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Double) { sqlite3_bind_double(statement, index, value) }
    private func bindOptional(_ statement: OpaquePointer, _ index: Int32, _ value: String?) { if let value { bind(statement, index, value) } else { sqlite3_bind_null(statement, index) } }
    private func bindOptional(_ statement: OpaquePointer, _ index: Int32, _ value: Double?) { if let value { bind(statement, index, value) } else { sqlite3_bind_null(statement, index) } }
    private func bindOptional(_ statement: OpaquePointer, _ index: Int32, _ value: Int32?) { if let value { bind(statement, index, value) } else { sqlite3_bind_null(statement, index) } }
    private func text(_ statement: OpaquePointer, _ index: Int32) -> String { textOptional(statement, index) ?? "" }
    private func textOptional(_ statement: OpaquePointer, _ index: Int32) -> String? { guard let pointer = sqlite3_column_text(statement, index) else { return nil }; return String(cString: pointer) }
    private func intOptional(_ statement: OpaquePointer, _ index: Int32) -> Int? { sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, index)) }
    private func date(_ statement: OpaquePointer, _ index: Int32) -> Date? { sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, index)) }
    private func protect(_ url: URL) throws {
        var url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
#else
final class AppGroupQueueRepository {
    init(containerURL: URL? = nil) throws { throw CoreError.database }
    func enqueue(url: String, identity: QueueIdentity, now: Date = Date()) throws -> QueueEntry { throw CoreError.database }
    func enqueueOrReuse(url: String, identity: QueueIdentity, now: Date = Date()) throws -> QueueEnqueueResult { throw CoreError.database }
    func findReusable(url: String, identity: QueueIdentity) throws -> QueueEntry? { throw CoreError.database }
    func claim(id: String, owner: String, now: Date = Date(), leaseDuration: TimeInterval = 5 * 60) throws -> Bool { throw CoreError.database }
    func entry(id: String) throws -> QueueEntry? { throw CoreError.database }
    func due(now: Date = Date()) throws -> [QueueEntry] { throw CoreError.database }
    func releaseExpiredLeases(now: Date = Date()) throws { throw CoreError.database }
    func finishSuccess(entry: QueueEntry, owner: String, response: SubmitResponse, now: Date = Date()) throws -> QueueCommitResult { throw CoreError.database }
    func applyFailure(entry: QueueEntry, owner: String, state: QueueState, category: ErrorCategory,
                      errorCode: String?, status: Int?, nextAttemptAt: Date?, firstFailedAt: Date?,
                      now: Date = Date()) throws -> QueueCommitResult { throw CoreError.database }
    func list(identity: QueueIdentity? = nil) throws -> [QueueEntry] { throw CoreError.database }
    func recent(identity: QueueIdentity? = nil) throws -> RecentResult? { throw CoreError.database }
    func activeIdentity() throws -> QueueIdentity? { throw CoreError.database }
    func activeSessionIdentity() throws -> SessionIdentity? { throw CoreError.database }
    func activeSessionSnapshot() throws -> ActiveSessionSnapshot? { throw CoreError.database }
    func activate(identity: QueueIdentity) throws { throw CoreError.database }
    func activate(session: SessionIdentity, now: Date = Date()) throws -> Int64 { throw CoreError.database }
    @discardableResult
    func resetForRetry(id: String, now: Date = Date()) throws -> Bool { throw CoreError.database }
    func clearRecent() throws { throw CoreError.database }
    func delete(id: String) throws { throw CoreError.database }
    func clearQueue() throws { throw CoreError.database }
    @discardableResult
    func migrateIdentity(id: String, to target: QueueIdentity, now: Date = Date()) throws -> Bool { throw CoreError.database }
    @discardableResult
    func retryIdentityBlocked(identity: QueueIdentity, now: Date = Date()) throws -> Int { throw CoreError.database }
    func reconcileBackgroundClaim(_ claim: BackgroundUploadClaim, now: Date = Date()) throws -> BackgroundClaimReconcileResult { throw CoreError.database }
    func earliestWake(now: Date = Date()) throws -> Date? { throw CoreError.database }
    func refreshCapture(identity: QueueIdentity) throws -> RefreshCommitCapture? { throw CoreError.database }
    @discardableResult
    func recordRefreshSuccess(identity: QueueIdentity, response: SubmitResponse, now: Date = Date()) throws -> Bool { throw CoreError.database }
    @discardableResult
    func recordRefreshBlocked(identity: QueueIdentity, notBefore: Date?, reason: String) throws -> Bool { throw CoreError.database }
    func recordRefreshSuccess(capture: RefreshCommitCapture, response: SubmitResponse, now: Date = Date()) throws -> RefreshCommitResult { throw CoreError.database }
    func recordRefreshBlocked(capture: RefreshCommitCapture, notBefore: Date?, reason: String) throws -> RefreshCommitResult { throw CoreError.database }
}
#endif

/// The single point at which a fully-built request leaves this process.
///
/// `URLSession` is the only production implementation and satisfies it as-is.
/// The seam exists because everything worth pinning about a request - method,
/// path, headers and the exact body bytes - is decided above it by
/// `WebTagAPIClient`, while the copy of the request that reaches a custom
/// `URLProtocol` has already had its body taken away by `URLSession`. Observing
/// the request here is therefore the only way a test can assert on the bytes
/// the client actually produced.
protocol HTTPTransport: AnyObject {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

final class WebTagAPIClient: NSObject, URLSessionTaskDelegate {
    private let suppliedTransport: HTTPTransport?
    private lazy var transport: HTTPTransport = {
        if let suppliedTransport { return suppliedTransport }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// Defaults to a redirect-refusing ephemeral session; a caller may hand in
    /// its own session instead.
    init(session: URLSession? = nil) {
        suppliedTransport = session
        super.init()
    }

    /// Sends through anything that can carry a `URLRequest`, which is what lets
    /// a test hold the request instead of the network.
    init(transport: HTTPTransport) {
        suppliedTransport = transport
        super.init()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func validateSession(origin: String, apiKey: String) async -> Result<SessionIdentity, ClassifiedFailure> {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let normalizedOrigin = try? OriginNormalizer.normalize(origin) else {
            return .failure(ClassifiedFailure(category: .invalidClientResponse, status: nil, errorCode: nil, retryAfter: nil))
        }
        return await request(origin: normalizedOrigin, apiKey: apiKey, method: "GET", path: "/api/session", body: nil, idempotencyKey: nil, acceptedStatusCodes: [200]) { data, namespace in
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let bodyNamespace = object["client_data_namespace"] as? String,
                  namespace == bodyNamespace else { throw CoreError.identityMismatch }
            guard let representation = object["representation_contract"] as? String,
                  let scopes = object["scopes"] as? [String],
                  Self.isNamespace(bodyNamespace),
                  representation == "v2" else { throw CoreError.invalidSession }
            let identity = SessionIdentity(origin: normalizedOrigin, namespace: bodyNamespace, scopes: Set(scopes), representationContract: representation)
            try validateSessionIdentity(identity)
            return identity
        }
    }

    func submit(identity: SessionIdentity, apiKey: String, url: String, idempotencyKey: String) async -> Result<SubmitResponse, ClassifiedFailure> {
        guard (try? validateSessionIdentity(identity)) != nil else {
            return .failure(ClassifiedFailure(category: .invalidClientResponse, status: nil, errorCode: nil, retryAfter: nil))
        }
        guard identity.canWrite,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let normalizedOrigin = try? OriginNormalizer.normalize(identity.origin),
              normalizedOrigin == identity.origin else {
            return .failure(ClassifiedFailure(category: .invalidClientResponse, status: nil, errorCode: nil, retryAfter: nil))
        }
        let body = try? JSONSerialization.data(withJSONObject: ["url": url])
        return await request(origin: normalizedOrigin, apiKey: apiKey, method: "POST", path: "/api/links", body: body, idempotencyKey: idempotencyKey, acceptedStatusCodes: [202]) { data, namespace in
            guard namespace == identity.namespace else { throw CoreError.identityMismatch }
            return try Self.decodeSubmitPayload(data)
        }
    }

    func refresh(identity: SessionIdentity, apiKey: String, linkID: String) async -> Result<SubmitResponse, ClassifiedFailure> {
        guard (try? validateSessionIdentity(identity)) != nil else {
            return .failure(ClassifiedFailure(category: .invalidClientResponse, status: nil, errorCode: nil, retryAfter: nil))
        }
        guard identity.canWrite,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let normalizedOrigin = try? OriginNormalizer.normalize(identity.origin),
              normalizedOrigin == identity.origin else {
            return .failure(ClassifiedFailure(category: .invalidClientResponse, status: nil, errorCode: nil, retryAfter: nil))
        }
        guard Self.isCanonicalUUID(linkID) else {
            return .failure(ClassifiedFailure(category: .invalidClientResponse, status: nil, errorCode: nil, retryAfter: nil))
        }
        return await request(origin: normalizedOrigin, apiKey: apiKey, method: "POST", path: "/api/links/\(linkID)/refresh", body: nil, idempotencyKey: nil, acceptedStatusCodes: [202]) { data, namespace in
            guard namespace == identity.namespace else { throw CoreError.identityMismatch }
            let response = try Self.decodeSubmitPayload(data)
            guard Self.sameUUID(response.linkID, linkID) else { throw CoreError.invalidResponse }
            return response
        }
    }

    func decodeBackgroundSubmit(data: Data, response: HTTPURLResponse?, error: Error?, expectedNamespace: String) -> Result<SubmitResponse, ClassifiedFailure> {
        guard let response else { return .failure(ErrorClassifier.transport(error ?? CoreError.invalidResponse)) }
        let namespace = response.value(forHTTPHeaderField: "X-WebTag-Data-Namespace")
        guard response.statusCode == 202 else {
            if (200..<300).contains(response.statusCode) {
                return .failure(ClassifiedFailure(category: .invalidSuccessPayload, status: response.statusCode, errorCode: nil, retryAfter: nil))
            }
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let errorObject = object?["error"] as? [String: Any]
            return .failure(ErrorClassifier.http(status: response.statusCode, errorCode: errorObject?["error_code"] as? String, retryAfter: response.value(forHTTPHeaderField: "Retry-After")))
        }
        guard namespace == expectedNamespace else {
            return .failure(ClassifiedFailure(category: .identityMismatch, status: response.statusCode, errorCode: nil, retryAfter: nil))
        }
        do { return .success(try Self.decodeSubmitPayload(data)) }
        catch { return .failure(ClassifiedFailure(category: .invalidSuccessPayload, status: response.statusCode, errorCode: nil, retryAfter: nil)) }
    }

    private func request<T>(origin: String, apiKey: String, method: String, path: String, body: Data?, idempotencyKey: String?, acceptedStatusCodes: Set<Int>, decode: (Data, String?) throws -> T) async -> Result<T, ClassifiedFailure> {
        guard let url = URL(string: origin + path) else { return .failure(ClassifiedFailure(category: .invalidClientResponse, status: nil, errorCode: nil, retryAfter: nil)) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        do {
            let (data, response) = try await transport.send(request)
            guard let http = response as? HTTPURLResponse else { throw CoreError.invalidResponse }
            let namespace = http.value(forHTTPHeaderField: "X-WebTag-Data-Namespace")
            guard acceptedStatusCodes.contains(http.statusCode) else {
                guard !(200..<300).contains(http.statusCode) else {
                    return .failure(ClassifiedFailure(category: .invalidSuccessPayload, status: http.statusCode, errorCode: nil, retryAfter: nil))
                }
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let error = object?["error"] as? [String: Any]
                return .failure(ErrorClassifier.http(status: http.statusCode, errorCode: error?["error_code"] as? String, retryAfter: http.value(forHTTPHeaderField: "Retry-After")))
            }
            do { return .success(try decode(data, namespace)) }
            catch CoreError.identityMismatch {
                return .failure(ClassifiedFailure(category: .identityMismatch, status: http.statusCode, errorCode: nil, retryAfter: nil))
            } catch {
                return .failure(ClassifiedFailure(category: .invalidSuccessPayload, status: http.statusCode, errorCode: nil, retryAfter: nil))
            }
        } catch {
            return .failure(ErrorClassifier.transport(error))
        }
    }

    private static func decodeSubmitPayload(_ data: Data) throws -> SubmitResponse {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let linkID = object["link_id"] as? String,
              Self.isCanonicalUUID(linkID),
              let status = object["status"] as? String,
              ["pending", "processing", "done", "failed"].contains(status) else { throw CoreError.invalidResponse }
        let jobID = object["job_id"] as? String
        guard jobID == nil || Self.isCanonicalUUID(jobID!) else { throw CoreError.invalidResponse }
        return SubmitResponse(linkID: linkID, status: status, jobID: jobID)
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.caseInsensitiveCompare(value) == .orderedSame
    }

    private static func sameUUID(_ left: String, _ right: String) -> Bool {
        guard let leftUUID = UUID(uuidString: left), let rightUUID = UUID(uuidString: right) else { return false }
        return leftUUID == rightUUID
    }

    private static func isNamespace(_ value: String) -> Bool {
        value.utf8.count == 43 && value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) ||
            (scalar.value >= 65 && scalar.value <= 90) ||
            (scalar.value >= 97 && scalar.value <= 122) ||
            scalar == "_" || scalar == "-"
        }
    }
}

struct BackgroundUploadResult {
    let queueID: String
    let owner: String
    let data: Data
    let response: HTTPURLResponse?
    let error: Error?
}

protocol QueueUploadScheduling: AnyObject {
    func schedule(entry: QueueEntry, identity: SessionIdentity, apiKey: String, owner: String) throws
    func activeClaims() async -> Set<BackgroundUploadClaim>
    func cancel(claim: BackgroundUploadClaim)
    func reconcile(repository: AppGroupQueueRepository, now: Date) async -> Set<BackgroundUploadClaim>
}

final class BackgroundUploadSessionController: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, QueueUploadScheduling {
    static let identifier = "com.alpenl.webtag.share.background-submit"

    private struct TaskDescriptor {
        let queueID: String
        let owner: String

        static func encode(queueID: String, owner: String) -> String {
            "\(queueID)|\(owner)"
        }

        static func decode(_ value: String?) -> TaskDescriptor? {
            guard let value, let separator = value.firstIndex(of: "|") else { return nil }
            let queueID = String(value[..<separator])
            let owner = String(value[value.index(after: separator)...])
            guard let canonicalQueueID = UUID(uuidString: queueID)?.uuidString.lowercased(), !owner.isEmpty else { return nil }
            return TaskDescriptor(queueID: canonicalQueueID, owner: owner)
        }

        static func queueID(_ value: String?) -> String? {
            if let descriptor = decode(value) { return descriptor.queueID }
            guard let value, !value.isEmpty, !value.contains("|"), UUID(uuidString: value) != nil else { return nil }
            return value
        }
    }

    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.alpenl.webtag.share.background-submit.delegate"
        return queue
    }()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sharedContainerIdentifier = AppIdentifiers.appGroup
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()
    private let stateLock = NSLock()
    private var responseData: [Int: Data] = [:]
    private var pendingProcessing = 0
    private var didFinishEvents = false
    private var eventCompletionHandler: (() -> Void)?

    var taskCompletionHandler: ((BackgroundUploadResult) async -> Void)?

    static let shared = BackgroundUploadSessionController()

    func schedule(entry: QueueEntry, identity: SessionIdentity, apiKey: String, owner: String) throws {
        try validateSessionIdentity(identity)
        guard identity.canWrite,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !entry.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              [.pendingSubmit, .retryWait].contains(entry.state),
              entry.identity == QueueIdentity(origin: identity.origin, namespace: identity.namespace),
              entry.leaseOwner == owner,
              sha256(entry.url) == entry.requestFingerprint else { throw CoreError.identityMismatch }
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroup) else {
            throw CoreError.database
        }
        let directory = container.appendingPathComponent("Library/Caches/WebTagShareUploads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let claim = BackgroundUploadClaim(queueID: entry.id, owner: owner)
        var bodyURL = uploadFileURL(directory: directory, claim: claim)
        let body = try JSONSerialization.data(withJSONObject: ["url": entry.url])
        try body.write(to: bodyURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: bodyURL.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try bodyURL.setResourceValues(values)

        guard let url = URL(string: identity.origin + "/api/links") else { throw CoreError.invalidOrigin }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(entry.idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        let task = session.uploadTask(with: request, fromFile: bodyURL)
        task.taskDescription = TaskDescriptor.encode(queueID: entry.id, owner: owner)
        task.resume()
    }

    func activeClaims() async -> Set<BackgroundUploadClaim> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Set<BackgroundUploadClaim>, Never>) in
            session.getAllTasks { tasks in
                continuation.resume(returning: Set(tasks.compactMap { task in
                    guard let descriptor = TaskDescriptor.decode(task.taskDescription) else { return nil }
                    return BackgroundUploadClaim(queueID: descriptor.queueID, owner: descriptor.owner)
                }))
            }
        }
    }

    func reconcile(repository: AppGroupQueueRepository, now: Date) async -> Set<BackgroundUploadClaim> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Set<BackgroundUploadClaim>, Never>) in
            session.getAllTasks { tasks in
                var live = Set<BackgroundUploadClaim>()
                for task in tasks {
                    guard let descriptor = TaskDescriptor.decode(task.taskDescription) else {
                        task.cancel()
                        continue
                    }
                    let claim = BackgroundUploadClaim(queueID: descriptor.queueID, owner: descriptor.owner)
                    switch try? repository.reconcileBackgroundClaim(claim, now: now) {
                    case .matched:
                        live.insert(claim)
                    default:
                        task.cancel()
                        self.removeUploadFile(claim: claim)
                    }
                }
                self.cleanupOrphanedUploadFiles(retaining: live)
                continuation.resume(returning: live)
            }
        }
    }

    func cleanupOrphanedUploadFiles(retaining claims: Set<BackgroundUploadClaim>) {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroup) else { return }
        let directory = container.appendingPathComponent("Library/Caches/WebTagShareUploads", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            let name = file.deletingPathExtension().lastPathComponent
            let parts = name.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let queueID = UUID(uuidString: parts[0])?.uuidString.lowercased() else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let claim = BackgroundUploadClaim(queueID: queueID, owner: parts[1])
            if !claims.contains(claim) { try? FileManager.default.removeItem(at: file) }
        }
    }

    func cancel(claim: BackgroundUploadClaim) {
        session.getAllTasks { tasks in
            tasks.filter { TaskDescriptor.decode($0.taskDescription).map { $0.queueID == claim.queueID && $0.owner == claim.owner } == true }.forEach { $0.cancel() }
            self.removeUploadFile(claim: claim)
        }
    }

    /// A user-initiated delete is allowed to remove every outstanding task for
    /// a row, but it still enumerates and cancels each exact descriptor rather
    /// than treating a queue ID as a task identity.
    func cancelAll(queueID: String) {
        session.getAllTasks { tasks in
            tasks.compactMap { task -> BackgroundUploadClaim? in
                guard let descriptor = TaskDescriptor.decode(task.taskDescription), descriptor.queueID == queueID else { return nil }
                return BackgroundUploadClaim(queueID: descriptor.queueID, owner: descriptor.owner)
            }.forEach { self.cancel(claim: $0) }
        }
    }

    func handleEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.identifier else {
            completionHandler()
            return
        }
        _ = session
        stateLock.lock()
        eventCompletionHandler = completionHandler
        didFinishEvents = false
        stateLock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        task.cancel()
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        stateLock.lock(); responseData[dataTask.taskIdentifier, default: Data()].append(data); stateLock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let descriptor = TaskDescriptor.decode(task.taskDescription)
        let queueID = TaskDescriptor.queueID(task.taskDescription)
        let data: Data
        stateLock.lock()
        data = responseData.removeValue(forKey: task.taskIdentifier) ?? Data()
        let handler = taskCompletionHandler
        if handler != nil { pendingProcessing += 1 }
        stateLock.unlock()
        if let descriptor { removeUploadFile(claim: BackgroundUploadClaim(queueID: descriptor.queueID, owner: descriptor.owner)) }
        guard let descriptor, let queueID, let handler else {
            finishTaskProcessing()
            return
        }
        let result = BackgroundUploadResult(queueID: queueID, owner: descriptor.owner, data: data, response: task.response as? HTTPURLResponse, error: error)
        Task {
            await handler(result)
            self.finishTaskProcessing()
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        stateLock.lock(); didFinishEvents = true; stateLock.unlock()
        finishEventsIfReady()
    }

    private func finishTaskProcessing() {
        stateLock.lock()
        if pendingProcessing > 0 { pendingProcessing -= 1 }
        stateLock.unlock()
        finishEventsIfReady()
    }

    private func finishEventsIfReady() {
        stateLock.lock()
        guard didFinishEvents, pendingProcessing == 0, let handler = eventCompletionHandler else {
            stateLock.unlock()
            return
        }
        eventCompletionHandler = nil
        stateLock.unlock()
        DispatchQueue.main.async { handler() }
    }

    private func uploadFileURL(directory: URL, claim: BackgroundUploadClaim) -> URL {
        directory.appendingPathComponent("\(claim.queueID)|\(claim.owner).json")
    }

    private func removeUploadFile(claim: BackgroundUploadClaim) {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroup) else { return }
        let directory = container.appendingPathComponent("Library/Caches/WebTagShareUploads", isDirectory: true)
        let url = uploadFileURL(directory: directory, claim: claim)
        try? FileManager.default.removeItem(at: url)
    }
}

/// The wake-up mechanism is intentionally separate from Room/SQLite state.
/// The database remains authoritative after a force-quit; this object only
/// keeps one best-effort in-process alarm for the earliest durable deadline.
protocol QueueWakeScheduling: AnyObject {
    func schedule(deadline: Date?)
}

final class InProcessQueueWakeScheduler: QueueWakeScheduling {
    private let lock = NSLock()
    private var item: DispatchWorkItem?
    private var onWake: () -> Void

    init(onWake: @escaping () -> Void = {}) { self.onWake = onWake }

    func setOnWake(_ handler: @escaping () -> Void) {
        lock.lock(); onWake = handler; lock.unlock()
    }

    func schedule(deadline: Date?) {
        lock.lock()
        item?.cancel()
        guard let deadline else { item = nil; lock.unlock(); return }
        let handler = onWake
        let work = DispatchWorkItem { handler() }
        item = work
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: work)
    }
}

final class ShareSubmissionCoordinator {
    private let repository: AppGroupQueueRepository
    private let credentials: KeychainCredentialStore
    private let api: WebTagAPIClient
    private let background: QueueUploadScheduling?
    private let clock: ShareMonotonicClock
    private let wakeScheduler: QueueWakeScheduling

    init(repository: AppGroupQueueRepository, credentials: KeychainCredentialStore = KeychainCredentialStore(), api: WebTagAPIClient = WebTagAPIClient(), background: QueueUploadScheduling? = nil, clock: ShareMonotonicClock = SystemMonotonicClock(), wakeScheduler: QueueWakeScheduling = InProcessQueueWakeScheduler()) {
        self.repository = repository; self.credentials = credentials; self.api = api; self.background = background; self.clock = clock; self.wakeScheduler = wakeScheduler
    }

    /// - Parameter interactionDeadline: absolute instant on `clock` at which the
    ///   user-visible attempt must be over. It is the collector's own start plus
    ///   the interaction budget, so the foreground request inherits whatever is
    ///   left and never reopens a fresh one.
    func submit(url: String, identity: SessionIdentity, interactionDeadline: TimeInterval? = nil, now: Date = Date()) async -> SubmissionOutcome {
        guard identity.canWrite else { return .configurationRequired }
        let storedConfiguration: CredentialConfig?
        do { storedConfiguration = try credentials.loadConfig() } catch { return .configurationRequired }
        guard let storedConfiguration, storedConfiguration.identity == identity else { return .configurationRequired }
        do {
            guard try repository.activeSessionIdentity() == identity else { return .configurationRequired }
        } catch {
            return .configurationRequired
        }
        let apiKey = storedConfiguration.apiKey
        do {
            let queueIdentity = QueueIdentity(origin: identity.origin, namespace: identity.namespace)
            let enqueueResult = try repository.enqueueOrReuse(url: url, identity: queueIdentity, now: now)
            let entry = enqueueResult.entry
            if enqueueResult.reused {
                let leaseActive = entry.leaseExpiresAt.map { $0 > now } ?? false
                let retryNotDue = entry.state == .retryWait && entry.nextAttemptAt.map { $0 > now } ?? false
                if leaseActive { return .scheduled }
                if retryNotDue { return .queued(entry.lastError ?? .server, entry.nextAttemptAt) }
            }
            let owner = UUID().uuidString
            guard try repository.claim(id: entry.id, owner: owner, now: now),
                  let claimed = try repository.entry(id: entry.id) else { return .blocked(.failedPermanent, .localDataUnreadable) }
            guard let result = await withinInteractionDeadline(interactionDeadline, work: { [api] in
                await api.submit(identity: identity, apiKey: apiKey, url: url, idempotencyKey: claimed.idempotencyKey)
            }) else {
                // The interaction budget is spent. The row is already durable
                // and still claimed by this owner, so it is handed to the
                // background session rather than retried in the foreground.
                if let background {
                    do {
                        try background.schedule(entry: claimed, identity: identity, apiKey: apiKey, owner: owner)
                        rescheduleWake(now: now)
                        return .scheduled
                    } catch {}
                }
                // Without a background session the durable queue itself is the
                // hand-off; the lease expires and a later drain picks it up.
                rescheduleWake(now: now)
                return .queued(.clientDeadline, nil)
            }
            // A classified retryable response is not handed straight to a
            // second sender. Persisting its deadline and releasing this lease
            // is the boundary that makes retries survive a crash and prevents
            // a foreground/background loop from sending before Retry-After.
            return apply(entry: claimed, owner: owner, result: result, now: now)
        } catch { return .blocked(.failedPermanent, .localDataUnreadable) }
    }

    func reconcileAndDrain(excluding: Set<BackgroundUploadClaim> = [], now: Date = Date()) async {
        try? repository.releaseExpiredLeases(now: now)
        var processed = 0
        while processed < 16, await drainOne(excluding: excluding, now: Date()) { processed += 1 }
        rescheduleWake(now: now)
    }

    func drainOne(excluding: Set<BackgroundUploadClaim> = [], now: Date = Date()) async -> Bool {
        let identity: SessionIdentity
        let apiKey: String
        do {
            guard let value = try repository.activeSessionIdentity(), value.canWrite,
                  let storedConfiguration = try credentials.loadConfig(),
                  storedConfiguration.identity == value else { return false }
            identity = value
            apiKey = storedConfiguration.apiKey
        } catch { return false }
        guard let candidate = (try? repository.due(now: now))?.first(where: { !excluding.contains(BackgroundUploadClaim(queueID: $0.id, owner: $0.leaseOwner ?? "")) }) else { return false }
        let owner = UUID().uuidString
        guard (try? repository.claim(id: candidate.id, owner: owner, now: now)) == true,
              let entry = try? repository.entry(id: candidate.id) else { return false }
        guard entry.identity == QueueIdentity(origin: identity.origin, namespace: identity.namespace),
              sha256(entry.url) == entry.requestFingerprint else {
            let failure = ClassifiedFailure(category: entry.identity == QueueIdentity(origin: identity.origin, namespace: identity.namespace) ? .invalidClientResponse : .identityMismatch, status: nil, errorCode: nil, retryAfter: nil)
            _ = try? repository.applyFailure(entry: entry, owner: owner, state: failure.category == .identityMismatch ? .blockedIdentity : .failedPermanent, category: failure.category, errorCode: nil, status: nil, nextAttemptAt: nil, firstFailedAt: entry.firstFailedAt ?? now, now: now)
            return true
        }
        let result = await api.submit(identity: identity, apiKey: apiKey, url: entry.url, idempotencyKey: entry.idempotencyKey)
        _ = apply(entry: entry, owner: owner, result: result, now: now)
        return true
    }

    func handleBackgroundCompletion(_ result: BackgroundUploadResult, now: Date = Date()) async {
        guard let original = try? repository.entry(id: result.queueID),
              [.pendingSubmit, .retryWait].contains(original.state),
              original.leaseOwner == result.owner,
              original.leaseExpiresAt.map({ $0 > now }) == true else {
            rescheduleWake(now: now)
            return
        }
        let entry = original
        let owner = result.owner
        let parsed = api.decodeBackgroundSubmit(data: result.data, response: result.response, error: result.error, expectedNamespace: entry.identity.namespace)
        _ = apply(entry: entry, owner: owner, result: parsed, now: now)
    }

    func apply(entry: QueueEntry, owner: String, result: Result<SubmitResponse, ClassifiedFailure>, now: Date) -> SubmissionOutcome {
        switch result {
        case .success(let response):
            do {
                switch try repository.finishSuccess(entry: entry, owner: owner, response: response, now: now) {
                case .applied:
                    rescheduleWake(now: now)
                    return .submitted(response)
                case .staleClaim:
                    rescheduleWake(now: now)
                    return .staleClaim
                case .identityChanged:
                    rescheduleWake(now: now)
                    return .configurationRequired
                }
            } catch {
                // applyFailure is conditional on the same live lease, so a
                // reclaimed owner cannot overwrite the current sender.
                _ = try? repository.applyFailure(
                    entry: entry,
                    owner: owner,
                    state: .failedPermanent,
                    category: .localDataUnreadable,
                    errorCode: nil,
                    status: nil,
                    nextAttemptAt: nil,
                    firstFailedAt: entry.firstFailedAt ?? now,
                    now: now
                )
                return .blocked(.failedPermanent, .localDataUnreadable)
            }
        case .failure(let failure):
            let firstFailedAt = entry.firstFailedAt ?? now
            let state = QueueFailurePolicy.state(for: failure.category, firstFailedAt: firstFailedAt, now: now)
            let next = QueueFailurePolicy.nextAttemptAt(
                for: failure.category,
                attempt: entry.attemptCount + 1,
                retryAfter: failure.retryAfter,
                firstFailedAt: firstFailedAt,
                now: now
            )
            do {
                switch try repository.applyFailure(entry: entry, owner: owner, state: state, category: failure.category, errorCode: failure.errorCode, status: failure.status, nextAttemptAt: next, firstFailedAt: firstFailedAt, now: now) {
                case .applied:
                    rescheduleWake(now: now)
                case .staleClaim:
                    rescheduleWake(now: now)
                    return .staleClaim
                case .identityChanged:
                    rescheduleWake(now: now)
                    return .configurationRequired
                }
            } catch { return .blocked(.failedPermanent, .localDataUnreadable) }
            return state == .retryWait ? .queued(failure.category, next) : .blocked(state, failure.category)
        }
    }

    private func rescheduleWake(now: Date) {
        wakeScheduler.schedule(deadline: try? repository.earliestWake(now: now))
    }

    /// Runs the foreground request against the shared interaction deadline.
    ///
    /// Returns nil when the deadline won. That is not a failure of the request
    /// and must never be classified as one: the request is cancelled, and the
    /// caller hands the already-durable row off instead.
    private func withinInteractionDeadline(
        _ deadline: TimeInterval?,
        work: @escaping () async -> Result<SubmitResponse, ClassifiedFailure>
    ) async -> Result<SubmitResponse, ClassifiedFailure>? {
        guard let deadline else { return await work() }
        let remaining = deadline - clock.nowSeconds
        guard remaining > 0 else { return nil }
        let gate = ShareSingleShotGate<Result<SubmitResponse, ClassifiedFailure>?>()
        // Armed before the request is started, and therefore before anything
        // this function does can be observed from outside. Arming it afterwards
        // would let the clock reach the deadline in between, and `schedule` is
        // relative: the timer would then be set `remaining` seconds past an
        // instant that has already gone by, never fire, and leave this `await`
        // hanging forever.
        clock.schedule(after: remaining) { gate.resolve(nil) }
        let request = Task { await work() }
        let deadlineClock = clock
        Task {
            let outcome = await request.value
            // Timer delivery can be delayed when the process is busy. The
            // absolute deadline still wins when the transport completes after
            // it, even if the timer callback has not run yet.
            gate.resolve(deadlineClock.nowSeconds < deadline ? outcome : nil)
        }
        let outcome = await gate.value()
        // Only the deadline resolves to nil, and the gate resolves once, so the
        // cancel happens exactly once and only when the request actually lost.
        if outcome == nil { request.cancel() }
        return outcome
    }

}

// MARK: - Settings projection

/// The six sections the settings queue renders, in the order they render.
///
/// Eight queue states flattened into one list is what this replaces. `blocked_auth`
/// and `expired` need completely different actions from the reader, and a flat list
/// gives no signal about which of the two a row is. The order is frozen as
/// declaration order, so a section cannot be moved by editing a `switch` elsewhere.
///
/// Grouping is a *presentation* fact only. Send priority, claiming and the state
/// machine keep working off `QueueState` and are untouched by anything here.
enum SettingsQueueGroup: String, CaseIterable {
    case pendingAndRetry = "pending_and_retry"
    case blockedCredential = "blocked_credential"
    case blockedIdentity = "blocked_identity"
    case blockedQuota = "blocked_quota"
    case failedPermanent = "failed_permanent"
    case expired = "expired"

    /// The frozen section heading. Kept next to the case so a new section cannot be
    /// added without naming it.
    var title: String {
        switch self {
        case .pendingAndRetry: return "待提交与重试"
        case .blockedCredential: return "凭证阻断"
        case .blockedIdentity: return "身份阻断"
        case .blockedQuota: return "配额阻断"
        case .failedPermanent: return "永久失败"
        case .expired: return "已过期"
        }
    }

    /// The frozen state-to-section mapping, exhaustive on purpose: a new state has
    /// to choose a home here rather than silently disappearing from the list.
    static func group(for state: QueueState) -> SettingsQueueGroup {
        switch state {
        case .pendingSubmit, .retryWait: return .pendingAndRetry
        case .blockedAuth, .blockedScope: return .blockedCredential
        case .blockedIdentity: return .blockedIdentity
        case .blockedQuota: return .blockedQuota
        case .failedPermanent: return .failedPermanent
        case .expired: return .expired
        }
    }
}

/// One rendered section. Never empty: empty sections are dropped in `project`.
struct SettingsQueueGroupView {
    let group: SettingsQueueGroup
    let rows: [QueueEntry]

    var count: Int { rows.count }
}

/// `total` counts every durable row, including rows in sections that are hidden,
/// so the header stays a count of what is stored rather than of what is on screen.
struct SettingsQueueProjection {
    let total: Int
    let groups: [SettingsQueueGroupView]

    static let empty = SettingsQueueProjection(total: 0, groups: [])
}

/// Deterministic grouping, free of SwiftUI so XCTest can pin it directly.
enum SettingsQueuePresenter {
    /// Splits repository order into sections without reordering anything inside one.
    ///
    /// Rows arrive in the order the repository stores them, which is also the order
    /// they will be sent in. Sorting within a section would make the list disagree
    /// with the send order for no reader-visible gain.
    static func project(_ entries: [QueueEntry]) -> SettingsQueueProjection {
        var rowsByGroup: [SettingsQueueGroup: [QueueEntry]] = [:]
        for entry in entries {
            rowsByGroup[SettingsQueueGroup.group(for: entry.state), default: []].append(entry)
        }
        let groups = SettingsQueueGroup.allCases.compactMap { group -> SettingsQueueGroupView? in
            guard let rows = rowsByGroup[group], !rows.isEmpty else { return nil }
            return SettingsQueueGroupView(group: group, rows: rows)
        }
        return SettingsQueueProjection(total: entries.count, groups: groups)
    }
}

/// Whether the recent row may be refreshed right now, and until when if not.
///
/// `cooldownUntil` is non-nil only for a *timed* block that is still in the future.
/// A quota block has no deadline to count down to, so it disables refresh without
/// arming anything — showing a countdown there would promise a recovery time the
/// server never gave us.
struct SettingsRecentRefreshGate: Equatable {
    let isEnabled: Bool
    let cooldownUntil: Date?
    let blockReason: String?

    static let unavailable = SettingsRecentRefreshGate(isEnabled: false, cooldownUntil: nil, blockReason: nil)
}

enum SettingsRefreshGatePolicy {
    static let quotaReason = "quota_exceeded"
    static let cooldownReason = "cooldown_active"

    /// Pure, so the deadline can be evaluated from a timer callback without reading
    /// the database again — the deadline changes what the view shows, not what is
    /// stored, and re-reading would turn a display change into disk traffic.
    ///
    /// The boundary is deliberately exclusive: at `now == cooldownUntil` the block
    /// is over, refresh is enabled and the hint is gone.
    static func evaluate(recent: RecentResult?, now: Date) -> SettingsRecentRefreshGate {
        guard let recent else { return .unavailable }
        guard !recent.isIdentityMismatch else { return .unavailable }
        let reason = recent.refreshBlockReason
        if reason == quotaReason {
            return SettingsRecentRefreshGate(isEnabled: false, cooldownUntil: nil, blockReason: reason)
        }
        if let notBefore = recent.refreshNotBefore, notBefore > now {
            return SettingsRecentRefreshGate(isEnabled: false, cooldownUntil: notBefore, blockReason: reason)
        }
        return SettingsRecentRefreshGate(isEnabled: true, cooldownUntil: nil, blockReason: nil)
    }
}

/// Absolute, platform-locale timestamps.
///
/// `nil` in, `nil` out. A missing timestamp must render nothing at all: a
/// placeholder like "--" sits in the same position as real data and reads as if
/// the value were known and empty.
enum SettingsTimeFormatter {
    static func absolute(_ date: Date?, locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// Wall-clock reads and delayed callbacks, injectable so tests can pin both.
///
/// Wall clock rather than the monotonic one used for the share budget: the value
/// being compared against is `refresh_not_before`, which is stored as an absolute
/// date and must keep meaning the same instant across a process restart.
protocol SettingsWallClock: AnyObject {
    var now: Date { get }
    func schedule(after delay: TimeInterval, _ body: @escaping () -> Void)
}

final class SystemSettingsWallClock: SettingsWallClock {
    private let queue: DispatchQueue

    init(queue: DispatchQueue = DispatchQueue.main) {
        self.queue = queue
    }

    var now: Date { Date() }

    func schedule(after delay: TimeInterval, _ body: @escaping () -> Void) {
        queue.asyncAfter(deadline: .now() + max(0, delay), execute: body)
    }
}

/// Fires once at a cooldown deadline so the button unlocks without a redraw.
///
/// Before this, the cooldown was recomputed inline while rendering, so it only
/// expired when something else happened to redraw the screen — a settings screen
/// left open would stay locked past its own deadline indefinitely.
///
/// Invalidation is by generation counter rather than timer cancellation: the
/// callback checks whether it is still the current arming and does nothing if it
/// is not. A stale timer that still fires is therefore harmless, which matters
/// because dispose, identity change and recent replacement can all land while a
/// timer is in flight.
final class SettingsCooldownTimer {
    private let clock: SettingsWallClock
    private var generation = 0

    init(clock: SettingsWallClock) {
        self.clock = clock
    }

    /// Drops any pending arming. Used on dispose, identity change and whenever the
    /// recent row is replaced.
    func invalidate() {
        generation += 1
    }

    /// Arms for `deadline`, or does nothing when there is nothing to wait for.
    ///
    /// A deadline already in the past is not armed: the gate is open already, and
    /// scheduling a zero delay would fire a redundant recomputation.
    func arm(until deadline: Date?, onFire: @escaping () -> Void) {
        invalidate()
        guard let deadline else { return }
        let remaining = deadline.timeIntervalSince(clock.now)
        guard remaining > 0 else { return }
        let armed = generation
        clock.schedule(after: remaining) { [weak self] in
            guard let self, self.generation == armed else { return }
            onFire()
        }
    }
}

/// One identity-fenced read of the durable state, stamped with the activation
/// revision that was current when it was taken.
///
/// The revision is what makes a late snapshot recognisable: a read started under
/// one identity and released after another has been activated carries the old
/// revision and must not be committed.
struct SettingsSnapshot {
    let activationRevision: Int64
    let identity: QueueIdentity?
    let queue: [QueueEntry]
    let recent: RecentResult?

    /// No credential is active, so nothing may be attributed to an identity.
    static let noActiveSession: Int64 = 0
}

/// Everything the settings queue and recent sections render, derived from one
/// durable snapshot and nothing else.
///
/// There is deliberately no `origin` or `apiKey` here. A lifecycle reload replaces
/// this whole value, so anything reachable from it is something a reload is allowed
/// to overwrite — and the credential fields the user may be halfway through typing
/// are therefore unrepresentable rather than merely carefully avoided.
struct SettingsProjection {
    let activationRevision: Int64
    let identity: QueueIdentity?
    let queue: SettingsQueueProjection
    let recent: RecentResult?

    static let empty = SettingsProjection(
        activationRevision: SettingsSnapshot.noActiveSession,
        identity: nil,
        queue: .empty,
        recent: nil
    )
}

/// The reads the settings screen needs, as a protocol so tests can count them.
///
/// "The deadline performs zero database work" is part of the frozen contract, and
/// a claim about how often something is *not* called can only be tested against a
/// seam that can be counted.
protocol SettingsSnapshotReading: AnyObject {
    func activeSessionSnapshot() throws -> ActiveSessionSnapshot?
    func list(identity: QueueIdentity?) throws -> [QueueEntry]
    func recent(identity: QueueIdentity?) throws -> RecentResult?
}

extension AppGroupQueueRepository: SettingsSnapshotReading {}

/// Takes identity-fenced snapshots and refuses to commit stale ones.
///
/// Two separate guards, because they fail in different ways:
///
/// - `activationRevision != current` rejects a snapshot taken under an identity
///   that is no longer active. Revisions are persistent and never reused, so
///   A → B → A produces a third revision and an in-flight A load is still caught.
/// - `activationRevision < highestCommitted` rejects a snapshot that lost a race
///   to a newer one that already landed, even though both are for the live
///   identity.
final class SettingsSnapshotLoader {
    private let repository: SettingsSnapshotReading
    private var highestCommitted = SettingsSnapshot.noActiveSession

    init(repository: SettingsSnapshotReading) {
        self.repository = repository
    }

    /// One read of everything the screen shows, fenced to the identity that is
    /// active at the moment of the read.
    func snapshot() throws -> SettingsSnapshot {
        let active = try repository.activeSessionSnapshot()
        let identity = active.map { QueueIdentity(origin: $0.identity.origin, namespace: $0.identity.namespace) }
        return SettingsSnapshot(
            activationRevision: active?.revision ?? SettingsSnapshot.noActiveSession,
            identity: identity,
            queue: try repository.list(identity: identity),
            recent: try repository.recent(identity: identity)
        )
    }

    /// Whether this snapshot may still be shown. Committing marks it as the newest
    /// one seen, so a slower load that started earlier can no longer overwrite it.
    func commit(_ snapshot: SettingsSnapshot) -> Bool {
        let current = (try? repository.activeSessionSnapshot())?.revision ?? SettingsSnapshot.noActiveSession
        guard snapshot.activationRevision == current else { return false }
        guard snapshot.activationRevision >= highestCommitted else { return false }
        highestCommitted = snapshot.activationRevision
        return true
    }

    /// Convenience for the common path: read, and hand back the projection only if
    /// it is still current.
    func loadProjection() -> SettingsProjection? {
        guard let snapshot = try? snapshot(), commit(snapshot) else { return nil }
        return SettingsProjection(
            activationRevision: snapshot.activationRevision,
            identity: snapshot.identity,
            queue: SettingsQueuePresenter.project(snapshot.queue),
            recent: snapshot.recent
        )
    }
}
