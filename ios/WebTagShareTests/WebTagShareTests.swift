import Foundation
import XCTest
@testable import WebTagShare

private final class WebTagURLProtocol: URLProtocol {
    struct Reply {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    static var reply: ((URLRequest) -> Reply)?
    static var failure: Error?
    static var failNextRequest = false
    static var requestObserver: ((URLRequest) -> Void)?
    static var requestCount = 0
    /// Accepts the request and then never answers, which is the only way to
    /// observe what a client does when its own deadline expires first.
    static var pauseAfterRequest = false

    static func reset() {
        reply = nil
        failure = nil
        failNextRequest = false
        requestObserver = nil
        requestCount = 0
        pauseAfterRequest = false
    }

    static func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while true {
            let count = stream.read(buffer, maxLength: bufferSize)
            guard count >= 0 else { return nil }
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        Self.requestObserver?(request)
        if Self.pauseAfterRequest { return }
        if Self.failNextRequest {
            Self.failNextRequest = false
            client?.urlProtocol(
                self,
                didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
            )
            return
        }
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        guard let reply = Self.reply?(request), let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
            client?.urlProtocol(self, didFailWithError: CoreError.invalidResponse)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RecordingUploadScheduler: QueueUploadScheduling {
    private(set) var scheduledEntry: QueueEntry?
    private(set) var scheduledOwner: String?
    private(set) var claims: Set<BackgroundUploadClaim> = []

    func schedule(entry: QueueEntry, identity: SessionIdentity, apiKey: String, owner: String) throws {
        scheduledEntry = entry
        scheduledOwner = owner
        claims.insert(BackgroundUploadClaim(queueID: entry.id, owner: owner))
        _ = identity
        _ = apiKey
    }

    func activeClaims() async -> Set<BackgroundUploadClaim> { claims }

    func cancel(claim: BackgroundUploadClaim) {
        claims.remove(claim)
    }

    func reconcile(repository: AppGroupQueueRepository, now: Date) async -> Set<BackgroundUploadClaim> {
        claims = Set(claims.filter {
            guard let result = try? repository.reconcileBackgroundClaim($0, now: now),
                  case .matched = result else { return false }
            return true
        })
        return claims
    }
}

private final class RecordingWakeScheduler: QueueWakeScheduling {
    private(set) var deadlines: [Date?] = []

    func schedule(deadline: Date?) {
        deadlines.append(deadline)
    }
}

/// A clock the test moves by hand, so deadline behaviour is decided by the
/// assertions instead of by how busy the machine is.
private final class FakeMonotonicClock: ShareMonotonicClock {
    private let lock = NSLock()
    private var seconds: TimeInterval = 0
    private var scheduled: [(fireAt: TimeInterval, body: () -> Void)] = []
    private var armed: [TimeInterval] = []

    var nowSeconds: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return seconds
    }

    /// Every deadline ever armed on this clock, as an absolute instant, kept
    /// after firing. How many timers a component arms - and not merely when the
    /// earliest of them goes off - is the only way to tell one shared deadline
    /// from several coincident per-item ones.
    var armedDeadlines: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return armed
    }

    func schedule(after delay: TimeInterval, _ body: @escaping () -> Void) {
        lock.lock()
        let fireAt = seconds + max(0, delay)
        scheduled.append((fireAt, body))
        armed.append(fireAt)
        lock.unlock()
    }

    /// Moves the monotonic clock without dispatching due timers. A busy run
    /// loop can delay timer delivery in production, but it must not extend an
    /// absolute deadline.
    func elapseWithoutFiring(to target: TimeInterval) {
        lock.lock()
        seconds = max(seconds, target)
        lock.unlock()
    }

    /// Moves time forward and runs everything that has come due, so a test can
    /// stand 1ms short of a deadline and then step exactly onto it.
    func advance(to target: TimeInterval) {
        while true {
            lock.lock()
            seconds = max(seconds, target)
            guard let index = scheduled.firstIndex(where: { $0.fireAt <= target }) else {
                lock.unlock()
                return
            }
            let due = scheduled.remove(at: index)
            lock.unlock()
            due.body()
        }
    }
}

private final class FakeLoadCancellation: ShareLoadCancelling {
    private(set) var cancelCount = 0

    func cancelLoad() { cancelCount += 1 }
}

private func activate(_ repository: AppGroupQueueRepository, _ identity: QueueIdentity) throws {
    _ = try repository.activate(session: SessionIdentity(
        origin: identity.origin,
        namespace: identity.namespace,
        scopes: ["write"],
        representationContract: "v2"
    ))
}

private final class FakeItemProvider: ShareRepresentationLoading {
    enum Response {
        case immediate(String?)
        /// Answers only when the test says so - possibly never.
        case deferred
    }

    let declaredRepresentations: [ShareRepresentationKind]
    private let responses: [ShareRepresentationKind: Response]
    private(set) var startedKinds: [ShareRepresentationKind] = []
    private(set) var cancellations: [ShareRepresentationKind: FakeLoadCancellation] = [:]
    private var pending: [ShareRepresentationKind: (String?) -> Void] = [:]

    init(_ responses: [(ShareRepresentationKind, Response)]) {
        declaredRepresentations = responses.map(\.0)
        self.responses = Dictionary(uniqueKeysWithValues: responses)
    }

    func loadRepresentation(
        _ kind: ShareRepresentationKind,
        completion: @escaping (String?) -> Void
    ) -> ShareLoadCancelling? {
        startedKinds.append(kind)
        let cancellation = FakeLoadCancellation()
        cancellations[kind] = cancellation
        switch responses[kind] ?? .deferred {
        case .immediate(let value): completion(value)
        case .deferred: pending[kind] = completion
        }
        return cancellation
    }

    /// Delivers a callback the collector may or may not still be waiting for;
    /// the second case is exactly what a late provider looks like.
    func complete(_ kind: ShareRepresentationKind, with value: String?) {
        pending[kind]?(value)
    }
}

/// One shared item, standing in for an `NSExtensionItem` that no test can
/// populate with stub providers.
private struct FakeInputItem: ShareInputItem {
    let shareAttachments: [ShareRepresentationLoading]

    init(_ attachments: [ShareRepresentationLoading]) {
        shareAttachments = attachments
    }
}

final class WebTagShareTests: XCTestCase {
    override func setUp() {
        super.setUp()
        WebTagURLProtocol.reset()
    }

    override func tearDown() {
        WebTagURLProtocol.reset()
        super.tearDown()
    }

    func testAppGroupAndKeychainIdentifiersAreInjectedByTheBuildConfiguration() {
        XCTAssertTrue(AppIdentifiers.appGroup.hasPrefix("group."))
        XCTAssertTrue(AppIdentifiers.keychainAccessGroup.contains("com.alpenl.webtag.share"))
    }

    func testSharedFixturesProduceTheRecordedCandidatesAndOutcome() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("shared/fixtures/share-payloads.json")
        let data = try Data(contentsOf: sourceURL)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 200)
        for fixture in cases {
            let id = try XCTUnwrap(fixture["id"] as? String)
            let structured = try XCTUnwrap(fixture["structured_urls"] as? [String])
            let text = fixture["plain_text"] as? String
            let actual = URLCandidateExtractor.extract(SharePayload(structuredURLs: structured, plainText: text)).map(\.submissionValue)
            let expected = try XCTUnwrap(fixture["expected_candidates"] as? [String])
            XCTAssertEqual(actual, expected, id)
            let outcome = try XCTUnwrap(fixture["expected_outcome"] as? String)
            let actualOutcome: String
            switch actual.count {
            case 0: actualOutcome = "reject"
            case 1: actualOutcome = "submit"
            default: actualOutcome = "choose"
            }
            XCTAssertEqual(actualOutcome, outcome, id)
            XCTAssertEqual(actual.count > 1, outcome == "choose", id)
        }
    }

    func testOriginNormalizerRejectsCrossOriginInputs() throws {
        XCTAssertEqual(try OriginNormalizer.normalize(" HTTPS://Example.org/ "), "https://example.org")
        XCTAssertEqual(try OriginNormalizer.normalize("https://example.org:8443"), "https://example.org:8443")
        XCTAssertThrowsError(try OriginNormalizer.normalize("http://example.org"))
        XCTAssertThrowsError(try OriginNormalizer.normalize("https://user:pass@example.org"))
        XCTAssertThrowsError(try OriginNormalizer.normalize("https://example.org/path"))
        XCTAssertThrowsError(try OriginNormalizer.normalize("https://example.org/?q=1"))
    }

    func testRetryPolicyKeepsTrustFailuresPermanentAndCapsDelay() {
        XCTAssertEqual(RetryPolicy.retryAfter("1", now: Date(timeIntervalSince1970: 0)), 60)
        XCTAssertTrue(RetryPolicy.delay(attempt: 20) <= RetryPolicy.sixHours)
        XCTAssertTrue(RetryPolicy.shouldExpire(firstFailedAt: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: RetryPolicy.sevenDays)))
    }

    func testQueueFailurePolicyCoversAllFrozenStateBranches() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(QueueFailurePolicy.state(for: .auth, firstFailedAt: now, now: now), .blockedAuth)
        XCTAssertEqual(QueueFailurePolicy.state(for: .scope, firstFailedAt: now, now: now), .blockedScope)
        XCTAssertEqual(QueueFailurePolicy.state(for: .quota, firstFailedAt: now, now: now), .blockedQuota)
        XCTAssertEqual(QueueFailurePolicy.state(for: .identityMismatch, firstFailedAt: now, now: now), .blockedIdentity)
        XCTAssertEqual(QueueFailurePolicy.state(for: .tlsTrustFailure, firstFailedAt: now, now: now), .failedPermanent)
        XCTAssertEqual(QueueFailurePolicy.state(for: .server, firstFailedAt: now, now: now), .retryWait)
        XCTAssertEqual(
            QueueFailurePolicy.state(
                for: .server,
                firstFailedAt: now.addingTimeInterval(-RetryPolicy.sevenDays),
                now: now
            ),
            .expired
        )
        XCTAssertNil(QueueFailurePolicy.nextAttemptAt(for: .quota, attempt: 1, retryAfter: "60", firstFailedAt: now, now: now))
        XCTAssertNotNil(QueueFailurePolicy.nextAttemptAt(for: .rateLimit, attempt: 1, retryAfter: "1", firstFailedAt: now, now: now))
    }

    func testErrorClassifierSeparatesDeadlineDNSAndTLS() {
        XCTAssertEqual(ErrorClassifier.transport(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)).category, .clientDeadline)
        XCTAssertEqual(ErrorClassifier.transport(NSError(domain: NSURLErrorDomain, code: NSURLErrorDNSLookupFailed)).category, .dnsTimeout)
        XCTAssertEqual(ErrorClassifier.transport(NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed)).category, .tlsTrustFailure)
    }

    func testErrorClassifierScansUnderlyingTransportErrors() {
        let wrapped = NSError(
            domain: "WebTagShareTest",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted)]
        )

        XCTAssertEqual(ErrorClassifier.transport(wrapped).category, .tlsTrustFailure)
    }

    func testRepositoryLeaseExpiryAndAtomicSuccess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try AppGroupQueueRepository(containerURL: directory)
        let identity = QueueIdentity(origin: "https://example.org", namespace: String(repeating: "n", count: 43))
        try activate(repository, identity)
        let start = Date(timeIntervalSince1970: 1_000)
        let entry = try repository.enqueue(url: "https://example.org/article", identity: identity, now: start)
        XCTAssertTrue(try repository.claim(id: entry.id, owner: "owner-a", now: start, leaseDuration: 10))
        XCTAssertFalse(try repository.claim(id: entry.id, owner: "owner-b", now: start.addingTimeInterval(1), leaseDuration: 10))
        XCTAssertEqual(try repository.entry(id: entry.id)?.leaseOwner, "owner-a")
        XCTAssertEqual(try repository.due(now: start.addingTimeInterval(11)).map(\.id), [entry.id])
        try repository.releaseExpiredLeases(now: start.addingTimeInterval(11))
        XCTAssertTrue(try repository.claim(id: entry.id, owner: "owner-b", now: start.addingTimeInterval(11), leaseDuration: 10))
        let claimed = try XCTUnwrap(try repository.entry(id: entry.id))
        let response = SubmitResponse(linkID: "11111111-1111-1111-1111-111111111111", status: "pending", jobID: nil)
        try repository.finishSuccess(entry: claimed, owner: "owner-b", response: response, now: start.addingTimeInterval(12))
        XCTAssertTrue(try repository.list().isEmpty)
        let recent = try XCTUnwrap(try repository.recent(identity: identity))
        XCTAssertEqual(recent.linkID, response.linkID)
        XCTAssertFalse(recent.isIdentityMismatch)
    }

    func testFailedSubmitStatusIsStoredAsRecentWithoutLeavingAQueueRow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try AppGroupQueueRepository(containerURL: directory)
        let identity = QueueIdentity(origin: "https://example.org", namespace: String(repeating: "f", count: 43))
        try activate(repository, identity)
        let start = Date(timeIntervalSince1970: 1_100)
        let entry = try repository.enqueue(url: "https://example.org/failed", identity: identity, now: start)
        XCTAssertTrue(try repository.claim(id: entry.id, owner: "failed-owner", now: start))
        let claimed = try XCTUnwrap(try repository.entry(id: entry.id))
        let response = SubmitResponse(linkID: "22222222-2222-2222-2222-222222222222", status: "failed", jobID: nil)

        try repository.finishSuccess(entry: claimed, owner: "failed-owner", response: response, now: start.addingTimeInterval(1))

        XCTAssertTrue(try repository.list().isEmpty)
        XCTAssertEqual(try repository.recent(identity: identity)?.status, "failed")
        XCTAssertEqual(try repository.recent(identity: identity)?.linkID, response.linkID)
    }

    func testFailedSubmitDoesNotImplicitlyRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let namespace = String(repeating: "g", count: 43)
        let identity = SessionIdentity(origin: "https://example.org", namespace: namespace, scopes: ["write"], representationContract: "v2")
        let queue = try AppGroupQueueRepository(containerURL: directory)
        try queue.activate(session: identity)
        let keychain = KeychainCredentialStore()
        keychain.clear()
        try keychain.save(config: CredentialConfig(identity: identity, apiKey: "test-key"))
        defer { keychain.clear() }

        WebTagURLProtocol.requestCount = 0
        WebTagURLProtocol.failure = nil
        WebTagURLProtocol.reply = { request in
            XCTAssertEqual(request.url?.path, "/api/links")
            return WebTagURLProtocol.Reply(
                status: 202,
                headers: ["X-WebTag-Data-Namespace": namespace],
                body: Data(#"{"link_id":"66666666-6666-6666-6666-666666666666","status":"failed"}"#.utf8)
            )
        }
        defer {
            WebTagURLProtocol.reply = nil
            WebTagURLProtocol.failure = nil
            WebTagURLProtocol.requestCount = 0
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebTagURLProtocol.self]
        let api = WebTagAPIClient(session: URLSession(configuration: configuration))
        let coordinator = ShareSubmissionCoordinator(repository: queue, credentials: keychain, api: api)

        let outcome = await coordinator.submit(url: "https://example.org/failed", identity: identity, now: Date(timeIntervalSince1970: 1_200))

        guard case .submitted(let response) = outcome else {
            XCTFail("expected failed submit to be a completed result")
            return
        }
        XCTAssertEqual(response.status, "failed")
        XCTAssertEqual(WebTagURLProtocol.requestCount, 1)
        XCTAssertTrue(try queue.list().isEmpty)
        XCTAssertEqual(try queue.recent(identity: QueueIdentity(origin: identity.origin, namespace: identity.namespace))?.status, "failed")
    }

    func testRepositoryClaimRejectsFutureRetryAndTerminalRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try AppGroupQueueRepository(containerURL: directory)
        let identity = QueueIdentity(origin: "https://example.org", namespace: String(repeating: "q", count: 43))
        try activate(repository, identity)
        let now = Date(timeIntervalSince1970: 1_200)

        let future = try repository.enqueue(url: "https://example.org/future", identity: identity, now: now)
        XCTAssertTrue(try repository.claim(id: future.id, owner: "future-owner", now: now))
        let claimedFuture = try XCTUnwrap(try repository.entry(id: future.id))
        try repository.applyFailure(
            entry: claimedFuture,
            owner: "future-owner",
            state: .retryWait,
            category: .server,
            errorCode: nil,
            status: 503,
            nextAttemptAt: now.addingTimeInterval(60),
            firstFailedAt: now,
            now: now.addingTimeInterval(1)
        )
        XCTAssertFalse(try repository.claim(id: future.id, owner: "early-owner", now: now.addingTimeInterval(2)))

        let terminal = try repository.enqueue(url: "https://example.org/terminal", identity: identity, now: now)
        XCTAssertTrue(try repository.claim(id: terminal.id, owner: "terminal-owner", now: now))
        let claimedTerminal = try XCTUnwrap(try repository.entry(id: terminal.id))
        try repository.applyFailure(
            entry: claimedTerminal,
            owner: "terminal-owner",
            state: .failedPermanent,
            category: .tlsTrustFailure,
            errorCode: nil,
            status: nil,
            nextAttemptAt: nil,
            firstFailedAt: now,
            now: now.addingTimeInterval(1)
        )
        XCTAssertFalse(try repository.claim(id: terminal.id, owner: "terminal-retry", now: now.addingTimeInterval(2)))
    }

    func testRepositoryFindReusableKeepsPendingRetryIdentityAndKeyTogether() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try AppGroupQueueRepository(containerURL: directory)
        let identity = QueueIdentity(origin: "https://example.org", namespace: String(repeating: "u", count: 43))
        try activate(repository, identity)
        let start = Date(timeIntervalSince1970: 1_500)
        let url = "https://example.org/reuse"
        let entry = try repository.enqueue(url: url, identity: identity, now: start)

        let reusablePending = try XCTUnwrap(try repository.findReusable(url: url, identity: identity))
        XCTAssertEqual(reusablePending.id, entry.id)
        XCTAssertEqual(reusablePending.idempotencyKey, entry.idempotencyKey)

        XCTAssertTrue(try repository.claim(id: entry.id, owner: "retry-owner", now: start, leaseDuration: 10))
        let claimed = try XCTUnwrap(try repository.entry(id: entry.id))
        try repository.applyFailure(
            entry: claimed,
            owner: "retry-owner",
            state: .retryWait,
            category: .server,
            errorCode: nil,
            status: 503,
            nextAttemptAt: start.addingTimeInterval(60),
            firstFailedAt: start,
            now: start.addingTimeInterval(1)
        )

        let reusableRetry = try XCTUnwrap(try repository.findReusable(url: url, identity: identity))
        XCTAssertEqual(reusableRetry.id, entry.id)
        XCTAssertEqual(reusableRetry.idempotencyKey, entry.idempotencyKey)
        XCTAssertEqual(reusableRetry.nextAttemptAt, start.addingTimeInterval(60))
        XCTAssertNil(try repository.findReusable(url: url, identity: QueueIdentity(origin: identity.origin, namespace: String(repeating: "v", count: 43))))
    }

    func testRepositoryEnqueueOrReuseAtomicallyKeepsTheExistingIdempotencyKey() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try AppGroupQueueRepository(containerURL: directory)
        let identity = QueueIdentity(origin: "https://example.org", namespace: String(repeating: "a", count: 43))
        try activate(repository, identity)
        let url = "https://example.org/atomic-reuse"

        let first = try repository.enqueueOrReuse(url: url, identity: identity, now: Date(timeIntervalSince1970: 1_600))
        let second = try repository.enqueueOrReuse(url: url, identity: identity, now: Date(timeIntervalSince1970: 1_601))

        XCTAssertFalse(first.reused)
        XCTAssertTrue(second.reused)
        XCTAssertEqual(first.entry.id, second.entry.id)
        XCTAssertEqual(first.entry.idempotencyKey, second.entry.idempotencyKey)
        XCTAssertEqual(try repository.list().count, 1)
    }

    func testSuccessRollsBackWhenLeaseWasReclaimed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try AppGroupQueueRepository(containerURL: directory)
        let identity = QueueIdentity(origin: "https://example.org", namespace: String(repeating: "r", count: 43))
        try activate(repository, identity)
        let start = Date(timeIntervalSince1970: 2_000)
        let entry = try repository.enqueue(url: "https://example.org/reclaimed", identity: identity, now: start)
        XCTAssertTrue(try repository.claim(id: entry.id, owner: "owner-a", now: start, leaseDuration: 1))
        XCTAssertTrue(try repository.claim(id: entry.id, owner: "owner-b", now: start.addingTimeInterval(2), leaseDuration: 10))
        let stale = try XCTUnwrap(try repository.entry(id: entry.id))

        XCTAssertEqual(try repository.finishSuccess(
            entry: stale,
            owner: "owner-a",
            response: SubmitResponse(linkID: "55555555-5555-5555-5555-555555555555", status: "pending", jobID: nil),
            now: start.addingTimeInterval(3)
        ), .staleClaim)
        XCTAssertEqual(try repository.entry(id: entry.id)?.leaseOwner, "owner-b")
        XCTAssertNil(try repository.recent())
    }

    func testExpiredOwnerCannotCommitSuccessBeforeItIsReclaimed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try AppGroupQueueRepository(containerURL: directory)
        let identity = QueueIdentity(origin: "https://example.org", namespace: String(repeating: "e", count: 43))
        try activate(repository, identity)
        let start = Date(timeIntervalSince1970: 2_500)
        let entry = try repository.enqueue(url: "https://example.org/expired", identity: identity, now: start)
        XCTAssertTrue(try repository.claim(id: entry.id, owner: "expired-owner", now: start, leaseDuration: 1))
        let expired = try XCTUnwrap(try repository.entry(id: entry.id))

        XCTAssertEqual(try repository.finishSuccess(
            entry: expired,
            owner: "expired-owner",
            response: SubmitResponse(linkID: "66666666-6666-6666-6666-666666666666", status: "pending", jobID: nil),
            now: start.addingTimeInterval(1)
        ), .staleClaim)
        XCTAssertEqual(try repository.entry(id: entry.id)?.leaseOwner, "expired-owner")
        XCTAssertNil(try repository.recent())
    }

    func testBackgroundCompletionRejectsAReclaimedLeaseOwner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try AppGroupQueueRepository(containerURL: directory)
        let identity = QueueIdentity(origin: "https://example.org", namespace: String(repeating: "b", count: 43))
        try activate(repository, identity)
        let start = Date(timeIntervalSince1970: 2_700)
        let entry = try repository.enqueue(url: "https://example.org/background", identity: identity, now: start)
        XCTAssertTrue(try repository.claim(id: entry.id, owner: "old-owner", now: start, leaseDuration: 1))
        XCTAssertTrue(try repository.claim(id: entry.id, owner: "new-owner", now: start.addingTimeInterval(2), leaseDuration: 10))

        let response = HTTPURLResponse(
            url: URL(string: "https://example.org/api/links")!,
            statusCode: 202,
            httpVersion: "HTTP/1.1",
            headerFields: ["X-WebTag-Data-Namespace": identity.namespace]
        )!
        let result = BackgroundUploadResult(
            queueID: entry.id,
            owner: "old-owner",
            data: Data(#"{"link_id":"88888888-8888-8888-8888-888888888888","status":"done"}"#.utf8),
            response: response,
            error: nil
        )

        let coordinator = ShareSubmissionCoordinator(repository: repository)
        await coordinator.handleBackgroundCompletion(result, now: start.addingTimeInterval(3))

        XCTAssertEqual(try repository.entry(id: entry.id)?.leaseOwner, "new-owner")
        XCTAssertNil(try repository.recent())
    }

    func testRetryableForegroundFailurePersistsDeadlineBeforeAnyBackgroundWake() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let namespace = String(repeating: "h", count: 43)
        let identity = SessionIdentity(origin: "https://example.org", namespace: namespace, scopes: ["write"], representationContract: "v2")
        let repository = try AppGroupQueueRepository(containerURL: directory)
        try repository.activate(session: identity)
        let keychain = KeychainCredentialStore()
        keychain.clear()
        try keychain.save(config: CredentialConfig(identity: identity, apiKey: "test-key"))
        defer { keychain.clear() }

        WebTagURLProtocol.requestCount = 0
        WebTagURLProtocol.reply = { _ in
            WebTagURLProtocol.Reply(
                status: 503,
                headers: ["X-WebTag-Data-Namespace": namespace],
                body: Data(#"{"error":{"error_code":"internal_error"}}"#.utf8)
            )
        }
        defer {
            WebTagURLProtocol.reply = nil
            WebTagURLProtocol.requestCount = 0
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebTagURLProtocol.self]
        let api = WebTagAPIClient(session: URLSession(configuration: configuration))
        let scheduler = RecordingUploadScheduler()
        let wakeScheduler = RecordingWakeScheduler()
        let coordinator = ShareSubmissionCoordinator(
            repository: repository,
            credentials: keychain,
            api: api,
            background: scheduler,
            wakeScheduler: wakeScheduler
        )

        let outcome = await coordinator.submit(
            url: "https://example.org/foreground-first",
            identity: identity,
            now: Date(timeIntervalSince1970: 8_000)
        )

        guard case .queued(.server, let deadline) = outcome else {
            XCTFail("expected retryable foreground failure to persist a retry deadline")
            return
        }
        XCTAssertEqual(WebTagURLProtocol.requestCount, 1)
        let entry = try XCTUnwrap(try repository.list().first)
        XCTAssertEqual(entry.state, .retryWait)
        XCTAssertEqual(entry.nextAttemptAt, deadline)
        XCTAssertNil(entry.leaseOwner)
        XCTAssertNil(scheduler.scheduledEntry)
        XCTAssertEqual(wakeScheduler.deadlines.last!, deadline)
    }

    func testResponseLossReplaysWithTheSameIdempotencyKeyAndCommitsOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let namespace = String(repeating: "p", count: 43)
        let identity = SessionIdentity(origin: "https://example.org", namespace: namespace, scopes: ["write"], representationContract: "v2")
        let repository = try AppGroupQueueRepository(containerURL: directory)
        try repository.activate(session: identity)
        let keychain = KeychainCredentialStore()
        keychain.clear()
        try keychain.save(config: CredentialConfig(identity: identity, apiKey: "test-key"))
        defer { keychain.clear() }

        var requestKeys: [String] = []
        WebTagURLProtocol.requestCount = 0
        WebTagURLProtocol.failNextRequest = true
        WebTagURLProtocol.failure = nil
        WebTagURLProtocol.requestObserver = { request in
            requestKeys.append(request.value(forHTTPHeaderField: "Idempotency-Key") ?? "")
        }
        WebTagURLProtocol.reply = { _ in
            WebTagURLProtocol.Reply(
                status: 202,
                headers: ["X-WebTag-Data-Namespace": namespace],
                body: Data(#"{"link_id":"55555555-5555-5555-5555-555555555555","status":"pending"}"#.utf8)
            )
        }
        defer {
            WebTagURLProtocol.reply = nil
            WebTagURLProtocol.failNextRequest = false
            WebTagURLProtocol.requestObserver = nil
            WebTagURLProtocol.requestCount = 0
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebTagURLProtocol.self]
        let api = WebTagAPIClient(session: URLSession(configuration: configuration))
        let coordinator = ShareSubmissionCoordinator(repository: repository, credentials: keychain, api: api)
        let start = Date(timeIntervalSince1970: 8_500)

        let first = await coordinator.submit(url: "https://example.org/response-loss", identity: identity, now: start)
        guard case .queued = first else {
            XCTFail("expected the lost response to remain retryable")
            return
        }

        let drained = await coordinator.drainOne(now: start.addingTimeInterval(120))
        XCTAssertTrue(drained)
        XCTAssertEqual(requestKeys.count, 2)
        XCTAssertEqual(requestKeys[0], requestKeys[1])
        let entry = try XCTUnwrap(try repository.recent(identity: QueueIdentity(origin: identity.origin, namespace: identity.namespace)))
        XCTAssertTrue(try repository.list().isEmpty)
        XCTAssertEqual(entry.linkID, "55555555-5555-5555-5555-555555555555")
        XCTAssertFalse(requestKeys[0].isEmpty)
    }

    func testRecentIdentityMismatchIsRedactedButDeletable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try AppGroupQueueRepository(containerURL: directory)
        let storedIdentity = QueueIdentity(origin: "https://old.example", namespace: String(repeating: "o", count: 43))
        let activeIdentity = QueueIdentity(origin: "https://new.example", namespace: String(repeating: "n", count: 43))
        try activate(repository, storedIdentity)
        let entry = try repository.enqueue(url: "https://old.example/private", identity: storedIdentity)
        XCTAssertTrue(try repository.claim(id: entry.id, owner: "owner"))
        let claimed = try XCTUnwrap(try repository.entry(id: entry.id))
        try repository.finishSuccess(
            entry: claimed,
            owner: "owner",
            response: SubmitResponse(linkID: "22222222-2222-2222-2222-222222222222", status: "done", jobID: nil)
        )
        try activate(repository, activeIdentity)
        let redacted = try XCTUnwrap(try repository.recent(identity: activeIdentity))
        XCTAssertTrue(redacted.isIdentityMismatch)
        XCTAssertEqual(redacted.url, "")
        XCTAssertEqual(redacted.linkID, "")
        try repository.clearRecent()
        XCTAssertNil(try repository.recent())
    }

    func testResetForRetryRejectsPendingAndIdentityStates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try AppGroupQueueRepository(containerURL: directory)
        let identity = QueueIdentity(origin: "https://example.org", namespace: String(repeating: "t", count: 43))
        try activate(repository, identity)
        let now = Date(timeIntervalSince1970: 3_000)

        let pending = try repository.enqueue(url: "https://example.org/pending", identity: identity, now: now)
        XCTAssertFalse(try repository.resetForRetry(id: pending.id, now: now))

        let identityEntry = try repository.enqueue(url: "https://example.org/identity", identity: identity, now: now)
        XCTAssertTrue(try repository.claim(id: identityEntry.id, owner: "identity-owner", now: now))
        let claimedIdentityEntry = try XCTUnwrap(try repository.entry(id: identityEntry.id))
        try repository.applyFailure(
            entry: claimedIdentityEntry,
            owner: "identity-owner",
            state: .blockedIdentity,
            category: .identityMismatch,
            errorCode: nil,
            status: nil,
            nextAttemptAt: nil,
            firstFailedAt: now,
            now: now
        )
        XCTAssertFalse(try repository.resetForRetry(id: identityEntry.id, now: now))

        let retryEntry = try repository.enqueue(url: "https://example.org/retry", identity: identity, now: now)
        XCTAssertTrue(try repository.claim(id: retryEntry.id, owner: "retry-owner", now: now))
        let claimedRetryEntry = try XCTUnwrap(try repository.entry(id: retryEntry.id))
        try repository.applyFailure(
            entry: claimedRetryEntry,
            owner: "retry-owner",
            state: .retryWait,
            category: .server,
            errorCode: nil,
            status: 500,
            nextAttemptAt: now.addingTimeInterval(60),
            firstFailedAt: now,
            now: now
        )
        XCTAssertTrue(try repository.resetForRetry(id: retryEntry.id, now: now))
    }

    func testIdentityMigrationPreservesAuditFieldsAndResetsTransientState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try AppGroupQueueRepository(containerURL: directory)
        let oldIdentity = QueueIdentity(origin: "https://old.example", namespace: String(repeating: "o", count: 43))
        let newIdentity = QueueIdentity(origin: "https://new.example", namespace: String(repeating: "n", count: 43))
        try activate(repository, oldIdentity)
        let now = Date(timeIntervalSince1970: 4_000)
        let entry = try repository.enqueue(url: "https://example.org/migrate", identity: oldIdentity, now: now)

        XCTAssertTrue(try repository.claim(id: entry.id, owner: "migration-owner", now: now, leaseDuration: 10))
        let claimed = try XCTUnwrap(try repository.entry(id: entry.id))
        try repository.applyFailure(
            entry: claimed,
            owner: "migration-owner",
            state: .blockedIdentity,
            category: .identityMismatch,
            errorCode: "namespace_changed",
            status: 409,
            nextAttemptAt: now.addingTimeInterval(60),
            firstFailedAt: now.addingTimeInterval(-10),
            now: now.addingTimeInterval(1)
        )
        let before = try XCTUnwrap(try repository.entry(id: entry.id))

        try activate(repository, newIdentity)
        XCTAssertTrue(try repository.migrateIdentity(id: entry.id, to: newIdentity, now: now.addingTimeInterval(2)))

        let migrated = try XCTUnwrap(try repository.entry(id: entry.id))
        XCTAssertEqual(migrated.id, before.id)
        XCTAssertEqual(migrated.createdAt, before.createdAt)
        XCTAssertEqual(migrated.url, before.url)
        XCTAssertEqual(migrated.requestFingerprint, before.requestFingerprint)
        XCTAssertNotEqual(migrated.idempotencyKey, before.idempotencyKey)
        XCTAssertEqual(migrated.identity, newIdentity)
        XCTAssertEqual(migrated.state, .pendingSubmit)
        XCTAssertNil(migrated.firstFailedAt)
        XCTAssertEqual(migrated.attemptCount, 0)
        XCTAssertNil(migrated.nextAttemptAt)
        XCTAssertNil(migrated.lastError)
        XCTAssertNil(migrated.lastErrorCode)
        XCTAssertNil(migrated.lastHTTPStatus)
        XCTAssertNil(migrated.linkID)
        XCTAssertNil(migrated.jobID)
        XCTAssertNil(migrated.leaseOwner)
        XCTAssertNil(migrated.leaseExpiresAt)
    }

    func testIdentityMigrationRejectsActiveLeaseAndSameIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try AppGroupQueueRepository(containerURL: directory)
        let oldIdentity = QueueIdentity(origin: "https://old.example", namespace: String(repeating: "l", count: 43))
        let newIdentity = QueueIdentity(origin: "https://new.example", namespace: String(repeating: "m", count: 43))
        try activate(repository, oldIdentity)
        let now = Date(timeIntervalSince1970: 4_500)
        let entry = try repository.enqueue(url: "https://example.org/leased", identity: oldIdentity, now: now)

        XCTAssertTrue(try repository.claim(id: entry.id, owner: "active-owner", now: now, leaseDuration: 10))
        XCTAssertFalse(try repository.migrateIdentity(id: entry.id, to: newIdentity, now: now.addingTimeInterval(1)))
        XCTAssertFalse(try repository.migrateIdentity(id: entry.id, to: oldIdentity, now: now.addingTimeInterval(1)))

        let unchanged = try XCTUnwrap(try repository.entry(id: entry.id))
        XCTAssertEqual(unchanged.identity, oldIdentity)
        XCTAssertEqual(unchanged.leaseOwner, "active-owner")
        XCTAssertEqual(unchanged.url, "https://example.org/leased")
    }

    func testIdentityMatchedAuthAndScopeBlocksAutomaticallyReturnToPending() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try AppGroupQueueRepository(containerURL: directory)
        let identity = QueueIdentity(origin: "https://example.org", namespace: String(repeating: "i", count: 43))
        try activate(repository, identity)
        let now = Date(timeIntervalSince1970: 4_800)

        for (index, state) in [QueueState.blockedAuth, QueueState.blockedScope].enumerated() {
            let entry = try repository.enqueue(url: "https://example.org/recovery-\(index)", identity: identity, now: now)
            XCTAssertTrue(try repository.claim(id: entry.id, owner: "recovery-owner-\(index)", now: now))
            let claimed = try XCTUnwrap(try repository.entry(id: entry.id))
            try repository.applyFailure(
                entry: claimed,
                owner: "recovery-owner-\(index)",
                state: state,
                category: state == .blockedAuth ? .auth : .scope,
                errorCode: nil,
                status: state == .blockedAuth ? 401 : 403,
                nextAttemptAt: nil,
                firstFailedAt: now,
                now: now
            )
        }

        XCTAssertEqual(try repository.retryIdentityBlocked(identity: identity, now: now.addingTimeInterval(1)), 2)
        XCTAssertTrue(try repository.list().allSatisfy { $0.state == .pendingSubmit })
    }

    func testBackgroundSubmitResponseMatrixUsesStrict202AndNamespaceGate() {
        let api = WebTagAPIClient()
        let url = URL(string: "https://example.org/api/links")!
        let namespace = String(repeating: "a", count: 43)
        let validBody = Data(#"{"link_id":"33333333-3333-3333-3333-333333333333","status":"pending"}"#.utf8)
        let cases: [(Int, String?, ErrorCategory)] = [
            (200, namespace, .invalidSuccessPayload),
            (202, "wrong", .identityMismatch),
            (301, namespace, .invalidClientResponse),
            (401, namespace, .auth),
            (403, namespace, .invalidClientResponse),
            (408, namespace, .http408),
            (425, namespace, .http425),
            (429, namespace, .rateLimit),
            (500, namespace, .server),
        ]
        for (status, responseNamespace, expected) in cases {
            var headers: [String: String] = [:]
            if let responseNamespace { headers["X-WebTag-Data-Namespace"] = responseNamespace }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            let errorCode = status == 429 ? "rate_limited" : "quota_exceeded"
            let body = status == 401 || status == 403 || status == 429
                ? Data("{\"error\":{\"error_code\":\"\(errorCode)\"}}".utf8)
                : validBody
            let result = api.decodeBackgroundSubmit(data: body, response: response, error: nil, expectedNamespace: namespace)
            guard case .failure(let failure) = result else {
                XCTFail("expected failure for HTTP \(status)")
                continue
            }
            XCTAssertEqual(failure.category, expected, "HTTP \(status)")
        }
    }

    func testSubmitUsesStableIdempotencyHeaderAndMinimalBody() async throws {
        let namespace = String(repeating: "s", count: 43)
        let key = "test-key"
        let url = URL(string: "https://example.org/api/links")!
        WebTagURLProtocol.reply = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "stable-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(WebTagURLProtocol.bodyData(for: request).flatMap { String(data: $0, encoding: .utf8) }, #"{"url":"https://example.org/article"}"#)
            return WebTagURLProtocol.Reply(
                status: 202,
                headers: ["X-WebTag-Data-Namespace": namespace],
                body: Data(#"{"link_id":"44444444-4444-4444-4444-444444444444","status":"done"}"#.utf8)
            )
        }
        defer { WebTagURLProtocol.reply = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebTagURLProtocol.self]
        let api = WebTagAPIClient(session: URLSession(configuration: configuration))
        let identity = SessionIdentity(origin: "https://example.org", namespace: namespace, scopes: ["write"], representationContract: "v2")
        let result = await api.submit(identity: identity, apiKey: key, url: "https://example.org/article", idempotencyKey: "stable-key")
        guard case .success(let response) = result else {
            XCTFail("expected successful submit")
            return
        }
        XCTAssertEqual(response.status, "done")
    }

    func testForegroundSubmitResponseMatrixUsesStrict202AndNamespaceGate() async {
        let namespace = String(repeating: "m", count: 43)
        let identity = SessionIdentity(origin: "https://example.org", namespace: namespace, scopes: ["write"], representationContract: "v2")
        let validBody = "{\"link_id\":\"77777777-7777-7777-7777-777777777777\",\"status\":\"pending\"}"
        let cases: [(Int, String?, String, ErrorCategory)] = [
            (200, namespace, validBody, .invalidSuccessPayload),
            (202, "wrong", validBody, .identityMismatch),
            (202, namespace, "not-json", .invalidSuccessPayload),
            (301, namespace, validBody, .invalidClientResponse),
            (401, namespace, "{\"error\":{\"error_code\":\"invalid_api_key\"}}", .auth),
            (403, namespace, "{\"error\":{\"error_code\":\"insufficient_scope\"}}", .scope),
            (429, namespace, "{\"error\":{\"error_code\":\"rate_limit_exceeded\"}}", .rateLimit),
            (500, namespace, validBody, .server),
        ]
        defer {
            WebTagURLProtocol.reply = nil
            WebTagURLProtocol.failure = nil
        }
        for (status, responseNamespace, body, expected) in cases {
            WebTagURLProtocol.failure = nil
            WebTagURLProtocol.reply = { _ in
                var headers: [String: String] = [:]
                if let responseNamespace { headers["X-WebTag-Data-Namespace"] = responseNamespace }
                return WebTagURLProtocol.Reply(status: status, headers: headers, body: Data(body.utf8))
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [WebTagURLProtocol.self]
            let api = WebTagAPIClient(session: URLSession(configuration: configuration))
            let result = await api.submit(identity: identity, apiKey: "test-key", url: "https://example.org/article", idempotencyKey: "matrix-key")
            guard case .failure(let failure) = result else {
                XCTFail("expected failure for HTTP \(status)")
                continue
            }
            XCTAssertEqual(failure.category, expected, "HTTP \(status)")
        }
    }

    func testForegroundSubmitSeparatesTimeoutAndTLSTransportFailures() async {
        let namespace = String(repeating: "t", count: 43)
        let identity = SessionIdentity(origin: "https://example.org", namespace: namespace, scopes: ["write"], representationContract: "v2")
        let errors: [(Int, ErrorCategory)] = [
            (NSURLErrorTimedOut, .clientDeadline),
            (NSURLErrorSecureConnectionFailed, .tlsTrustFailure),
        ]
        defer { WebTagURLProtocol.failure = nil }
        for (code, expected) in errors {
            WebTagURLProtocol.reply = nil
            WebTagURLProtocol.failure = NSError(domain: NSURLErrorDomain, code: code)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [WebTagURLProtocol.self]
            let api = WebTagAPIClient(session: URLSession(configuration: configuration))
            let result = await api.submit(identity: identity, apiKey: "test-key", url: "https://example.org/article", idempotencyKey: "transport-key")
            guard case .failure(let failure) = result else {
                XCTFail("expected transport failure")
                continue
            }
            XCTAssertEqual(failure.category, expected)
        }
    }

    func testRefreshRejectsNonUUIDBeforeCreatingARequest() async {
        let namespace = String(repeating: "q", count: 43)
        let identity = SessionIdentity(origin: "https://example.org", namespace: namespace, scopes: ["write"], representationContract: "v2")
        let result = await WebTagAPIClient().refresh(identity: identity, apiKey: "test-key", linkID: "not-a-uuid")
        guard case .failure(let failure) = result else {
            XCTFail("expected invalid link ID")
            return
        }
        XCTAssertEqual(failure.category, .invalidClientResponse)
    }

    func testRefreshRejectsAResponseForADifferentLink() async {
        let namespace = String(repeating: "w", count: 43)
        let identity = SessionIdentity(origin: "https://example.org", namespace: namespace, scopes: ["write"], representationContract: "v2")
        WebTagURLProtocol.reply = { _ in
            WebTagURLProtocol.Reply(
                status: 202,
                headers: ["X-WebTag-Data-Namespace": namespace],
                body: Data(#"{"link_id":"22222222-2222-2222-2222-222222222222","status":"processing"}"#.utf8)
            )
        }
        defer { WebTagURLProtocol.reply = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebTagURLProtocol.self]
        let api = WebTagAPIClient(session: URLSession(configuration: configuration))

        let result = await api.refresh(
            identity: identity,
            apiKey: "test-key",
            linkID: "11111111-1111-1111-1111-111111111111"
        )

        guard case .failure(let failure) = result else {
            XCTFail("expected mismatched refresh identifier to be rejected")
            return
        }
        XCTAssertEqual(failure.category, .invalidSuccessPayload)
    }

    func testSessionRejectsInvalidNamespaceCharacters() async {
        let namespace = String(repeating: "n", count: 42) + "!"
        WebTagURLProtocol.reply = { _ in
            WebTagURLProtocol.Reply(
                status: 200,
                headers: ["X-WebTag-Data-Namespace": namespace],
                body: Data("{\"client_data_namespace\":\"\(namespace)\",\"representation_contract\":\"v2\",\"scopes\":[\"write\"]}".utf8)
            )
        }
        defer { WebTagURLProtocol.reply = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebTagURLProtocol.self]
        let api = WebTagAPIClient(session: URLSession(configuration: configuration))

        let result = await api.validateSession(origin: "https://example.org", apiKey: "test-key")
        guard case .failure(let failure) = result else {
            XCTFail("expected invalid namespace")
            return
        }
        XCTAssertEqual(failure.category, .invalidSuccessPayload)
    }

    func testSessionNormalizesOriginBeforeRequestAndIdentityCreation() async {
        let namespace = String(repeating: "o", count: 43)
        WebTagURLProtocol.reply = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.org/api/session")
            return WebTagURLProtocol.Reply(
                status: 200,
                headers: ["X-WebTag-Data-Namespace": namespace],
                body: Data("{\"client_data_namespace\":\"\(namespace)\",\"representation_contract\":\"v2\",\"scopes\":[\"write\"]}".utf8)
            )
        }
        defer { WebTagURLProtocol.reply = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebTagURLProtocol.self]
        let api = WebTagAPIClient(session: URLSession(configuration: configuration))

        let result = await api.validateSession(origin: " HTTPS://Example.ORG/ ", apiKey: "test-key")
        guard case .success(let identity) = result else {
            XCTFail("expected normalized session identity")
            return
        }
        XCTAssertEqual(identity.origin, "https://example.org")
    }

    func testSessionRejectsBlankAPIKeyBeforeCreatingARequest() async {
        WebTagURLProtocol.requestCount = 0
        WebTagURLProtocol.reply = { _ in
            XCTFail("blank API key must not create a request")
            return WebTagURLProtocol.Reply(status: 200, headers: [:], body: Data())
        }
        defer {
            WebTagURLProtocol.reply = nil
            WebTagURLProtocol.requestCount = 0
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebTagURLProtocol.self]
        let api = WebTagAPIClient(session: URLSession(configuration: configuration))

        let result = await api.validateSession(origin: "https://example.org", apiKey: " \t")

        guard case .failure(let failure) = result else {
            XCTFail("expected blank API key failure")
            return
        }
        XCTAssertEqual(failure.category, .invalidClientResponse)
        XCTAssertEqual(WebTagURLProtocol.requestCount, 0)
    }

    func testSubmitRejectsBlankIdempotencyKeyAndNonCanonicalOriginBeforeCreatingARequest() async {
        let namespace = String(repeating: "g", count: 43)
        WebTagURLProtocol.requestCount = 0
        WebTagURLProtocol.reply = { _ in
            XCTFail("invalid submit arguments must not create a request")
            return WebTagURLProtocol.Reply(status: 202, headers: [:], body: Data())
        }
        defer {
            WebTagURLProtocol.reply = nil
            WebTagURLProtocol.requestCount = 0
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebTagURLProtocol.self]
        let api = WebTagAPIClient(session: URLSession(configuration: configuration))
        let identity = SessionIdentity(origin: "https://example.org", namespace: namespace, scopes: ["write"], representationContract: "v2")

        let blankKey = await api.submit(identity: identity, apiKey: "test-key", url: "https://example.org/a", idempotencyKey: " ")
        let invalidOrigin = await api.submit(
            identity: SessionIdentity(origin: "https://example.org/path", namespace: namespace, scopes: ["write"], representationContract: "v2"),
            apiKey: "test-key",
            url: "https://example.org/a",
            idempotencyKey: "stable-key"
        )

        guard case .failure(let blankFailure) = blankKey,
              case .failure(let originFailure) = invalidOrigin else {
            XCTFail("expected invalid submit arguments")
            return
        }
        XCTAssertEqual(blankFailure.category, .invalidClientResponse)
        XCTAssertEqual(originFailure.category, .invalidClientResponse)
        XCTAssertEqual(WebTagURLProtocol.requestCount, 0)
    }

    func testBackgroundSubmitRejectsNonCanonicalResponseIdentifier() {
        let namespace = String(repeating: "c", count: 43)
        let url = URL(string: "https://example.org/api/links")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 202,
            httpVersion: "HTTP/1.1",
            headerFields: ["X-WebTag-Data-Namespace": namespace]
        )!
        let result = WebTagAPIClient().decodeBackgroundSubmit(
            data: Data("{\"link_id\":\"not-a-uuid\",\"status\":\"pending\"}".utf8),
            response: response,
            error: nil,
            expectedNamespace: namespace
        )
        guard case .failure(let failure) = result else {
            XCTFail("expected invalid response identifier")
            return
        }
        XCTAssertEqual(failure.category, .invalidSuccessPayload)
    }

    // MARK: - Item provider collection

    private func submissionValues(fromSharedText text: String) async -> [String] {
        let provider = FakeItemProvider([(.plainText, .immediate(text))])
        let run = ShareCandidateCollector.start(items: [[provider]], clock: FakeMonotonicClock())
        return await run.value().candidates.map(\.submissionValue)
    }

    func testCollectorStartsEveryDeclaredRepresentationBeforeTheFirstAwait() {
        let clock = FakeMonotonicClock()
        // A start instant that is neither zero nor the budget, so an arming bug
        // cannot coincide with the right answer.
        clock.advance(to: 5)
        let first = FakeItemProvider([(.url, .deferred), (.plainText, .deferred)])
        let second = FakeItemProvider([(.plainText, .deferred)])
        let third = FakeItemProvider([(.url, .deferred)])

        let run = ShareCandidateCollector.start(items: [[first, second], [third]], clock: clock)

        // Nothing has been awaited yet, so every load must already be in flight.
        XCTAssertEqual(first.startedKinds, [.url, .plainText])
        XCTAssertEqual(second.startedKinds, [.plainText])
        XCTAssertEqual(third.startedKinds, [.url])
        XCTAssertEqual(
            run.startedRequests,
            [
                ShareRepresentationRequest(itemIndex: 0, attachmentIndex: 0, kind: .url),
                ShareRepresentationRequest(itemIndex: 0, attachmentIndex: 0, kind: .plainText),
                ShareRepresentationRequest(itemIndex: 0, attachmentIndex: 1, kind: .plainText),
                ShareRepresentationRequest(itemIndex: 1, attachmentIndex: 0, kind: .url),
            ]
        )
        // Four loads in flight, one timer: the budget belongs to the collection
        // and not to each representation. Arming it per slot would leave four
        // entries here even though they all fall due at the same instant.
        XCTAssertEqual(clock.armedDeadlines, [run.startedAt + ShareCandidateCollector.collectionBudget])
        XCTAssertEqual(run.startedAt, 5)
    }

    func testCollectorStillCollectsLaterProvidersWhenTheFirstNeverAnswers() async {
        let clock = FakeMonotonicClock()
        let stuck = FakeItemProvider([(.url, .deferred)])
        let quick = FakeItemProvider([(.plainText, .immediate("read https://example.org/second"))])

        let run = ShareCandidateCollector.start(items: [[stuck, quick]], clock: clock)
        clock.advance(to: ShareCandidateCollector.collectionBudget)
        let collection = await run.value()

        XCTAssertEqual(collection.candidates.map(\.submissionValue), ["https://example.org/second"])
        XCTAssertTrue(collection.reachedDeadline)
        XCTAssertEqual(
            collection.completedRequests,
            [ShareRepresentationRequest(itemIndex: 0, attachmentIndex: 1, kind: .plainText)]
        )
        // The wait ended on the one deadline the collector armed for the whole
        // run, not on a second per-item one. Asserted on what was armed rather
        // than on where the clock ended up: the test moved the clock itself, so
        // its position proves nothing about the collector.
        XCTAssertEqual(clock.armedDeadlines, [run.startedAt + ShareCandidateCollector.collectionBudget])
    }

    func testCollectorCancelsOnlyTheLoadsStillRunningAtTheDeadline() async {
        let clock = FakeMonotonicClock()
        let stuck = FakeItemProvider([(.url, .deferred)])
        let quick = FakeItemProvider([(.plainText, .immediate("https://example.org/done"))])

        let run = ShareCandidateCollector.start(items: [[stuck, quick]], clock: clock)
        clock.advance(to: ShareCandidateCollector.collectionBudget)
        _ = await run.value()

        XCTAssertEqual(stuck.cancellations[.url]?.cancelCount, 1)
        XCTAssertEqual(quick.cancellations[.plainText]?.cancelCount, 0)
    }

    func testCollectorLoadsBothRepresentationsOfOneProviderWithoutSuppression() async {
        let provider = FakeItemProvider([
            (.url, .immediate("https://example.org/structured")),
            (.plainText, .immediate("also see https://example.org/from-text")),
        ])

        let run = ShareCandidateCollector.start(items: [[provider]], clock: FakeMonotonicClock())
        let collection = await run.value()

        XCTAssertEqual(
            collection.candidates.map(\.submissionValue),
            ["https://example.org/structured", "https://example.org/from-text"]
        )
        XCTAssertFalse(collection.reachedDeadline)
    }

    func testCollectorKeepsTheTextLinkWhenTheURLRepresentationIsNotHTTP() async {
        let provider = FakeItemProvider([
            (.url, .immediate("ftp://example.org/file")),
            (.plainText, .immediate("mirror at https://example.org/file")),
        ])

        let run = ShareCandidateCollector.start(items: [[provider]], clock: FakeMonotonicClock())
        let collection = await run.value()

        XCTAssertEqual(collection.candidates.map(\.submissionValue), ["https://example.org/file"])
    }

    func testCollectorOutputFollowsInputOrderWhenCallbacksCompleteInReverse() async {
        let first = FakeItemProvider([(.url, .deferred), (.plainText, .deferred)])
        let second = FakeItemProvider([(.plainText, .deferred)])
        let third = FakeItemProvider([(.url, .deferred)])
        let run = ShareCandidateCollector.start(items: [[first, second], [third]], clock: FakeMonotonicClock())

        third.complete(.url, with: "https://example.org/fourth")
        second.complete(.plainText, with: "see https://example.org/third")
        first.complete(.plainText, with: "see https://example.org/second")
        first.complete(.url, with: "https://example.org/first")
        let collection = await run.value()

        XCTAssertEqual(
            collection.candidates.map(\.submissionValue),
            [
                "https://example.org/first",
                "https://example.org/fourth",
                "https://example.org/second",
                "https://example.org/third",
            ]
        )
        XCTAssertFalse(collection.reachedDeadline)
        XCTAssertEqual(collection.completedRequests, run.startedRequests)
    }

    func testCollectorTakesResultsUpToTheDeadlineAndIgnoresLateOrRepeatedOnes() async {
        let clock = FakeMonotonicClock()
        let early = FakeItemProvider([(.url, .deferred)])
        let late = FakeItemProvider([(.url, .deferred)])
        let run = ShareCandidateCollector.start(items: [[early, late]], clock: clock)

        clock.advance(to: ShareCandidateCollector.collectionBudget - 0.001)
        early.complete(.url, with: "https://example.org/in-time")
        clock.advance(to: ShareCandidateCollector.collectionBudget)
        // Both of these are late: the deadline already decided the run. The
        // first is stopped by `isDecided`, the second by the slot's own closed
        // flag - neither reaches the gate, and neither may add a candidate.
        late.complete(.url, with: "https://example.org/too-late")
        late.complete(.url, with: "https://example.org/too-late")
        let collection = await run.value()

        XCTAssertEqual(collection.candidates.map(\.submissionValue), ["https://example.org/in-time"])
        XCTAssertTrue(collection.reachedDeadline)
        XCTAssertEqual(
            collection.completedRequests,
            [ShareRepresentationRequest(itemIndex: 0, attachmentIndex: 0, kind: .url)]
        )
    }

    func testCollectorRejectsALateCallbackWhenDeadlineTimerDeliveryIsDelayed() async {
        let clock = FakeMonotonicClock()
        let provider = FakeItemProvider([(.url, .deferred)])
        let run = ShareCandidateCollector.start(items: [[provider]], clock: clock)

        clock.elapseWithoutFiring(to: ShareCandidateCollector.collectionBudget)
        provider.complete(.url, with: "https://example.org/too-late")
        clock.advance(to: ShareCandidateCollector.collectionBudget)
        let collection = await run.value()

        XCTAssertEqual(collection.candidates, [])
        XCTAssertTrue(collection.reachedDeadline)
        XCTAssertEqual(collection.completedRequests, [])
    }

    func testCollectorAcceptsOnlyExplicitHTTPSubstringsOfTheOriginalText() async {
        var values = await submissionValues(fromSharedText: "visit example.org or www.example.net today")
        XCTAssertEqual(values, [], "a detector-synthesised scheme is not something the user shared")

        values = await submissionValues(fromSharedText: "write to someone@example.org or dial tel:+1-555-0100")
        XCTAssertEqual(values, [])

        values = await submissionValues(fromSharedText: "(https://example.org/a) and https://example.org/b.")
        XCTAssertEqual(values, ["https://example.org/a", "https://example.org/b"])

        values = await submissionValues(fromSharedText: "参考 https://example.org/guide 谢谢")
        XCTAssertEqual(values, ["https://example.org/guide"])

        values = await submissionValues(fromSharedText: "https://one.example.org/1 then https://two.example.org/2")
        XCTAssertEqual(values, ["https://one.example.org/1", "https://two.example.org/2"])

        // Split, because one assertion over both would stay green if only one of
        // them were rejected - and would not say which.
        values = await submissionValues(fromSharedText: "broken https:///no-host here")
        XCTAssertEqual(values, [], "a URL without a host must never reach submission")

        // The scanner does hand this one on; it is candidate validation that
        // throws it out. Without this the assertion below could pass merely
        // because the detector never matched it in the first place.
        XCTAssertFalse(
            ShareTextLinkScanner.explicitHTTPSubstrings(in: "login at https://user:pass@example.org/x here").isEmpty,
            "the detector must reach this text for the rejection below to mean anything"
        )
        values = await submissionValues(fromSharedText: "login at https://user:pass@example.org/x here")
        XCTAssertEqual(values, [], "embedded credentials must never reach submission")

        values = await submissionValues(fromSharedText: "HTTPS://Example.org/Path is fine")
        XCTAssertEqual(values, ["HTTPS://Example.org/Path"], "the shared casing is what gets submitted")
    }

    func testCollectorDeduplicationKeepsTheFirstSubmissionString() async {
        let provider = FakeItemProvider([
            (.url, .immediate("https://Example.org/Article?ref=Share")),
            (.plainText, .immediate("again: https://example.org/Article?ref=Share")),
        ])

        let run = ShareCandidateCollector.start(items: [[provider]], clock: FakeMonotonicClock())
        let collection = await run.value()

        XCTAssertEqual(collection.candidates.map(\.submissionValue), ["https://Example.org/Article?ref=Share"])
    }

    func testDisplayLabelShowsHostAndPathOnly() {
        XCTAssertEqual(URLDisplayLabel.of("https://Example.ORG/Path%20A?token=secret#frag"), "example.org/Path%20A")
        XCTAssertEqual(URLDisplayLabel.of("https://example.org"), "example.org/")
        XCTAssertEqual(URLDisplayLabel.of("https://example.org:443/a"), "example.org/a")
        XCTAssertEqual(URLDisplayLabel.of("http://example.org:80/a"), "example.org/a")
        XCTAssertEqual(URLDisplayLabel.of("https://example.org:8443/a"), "example.org:8443/a")
        XCTAssertEqual(URLDisplayLabel.of("http://[2001:db8::1]:8080/a"), "[2001:db8::1]:8080/a")
        XCTAssertEqual(URLDisplayLabel.of("https://[2001:db8::1]"), "[2001:db8::1]/")
        XCTAssertNil(URLDisplayLabel.of("mailto:someone@example.org"))
    }

    func testPresenterResolvesASelectionToItsExactSubmissionValue() {
        // Two candidates that differ only in their query share one label, so a
        // presenter that resolved a choice by label would submit the wrong URL.
        let candidates = [
            URLCandidate(submissionValue: "https://example.org/A?ref=first", displayLabel: "example.org/A"),
            URLCandidate(submissionValue: "https://example.org/A?ref=second", displayLabel: "example.org/A"),
        ]

        XCTAssertTrue(ShareCandidatePresenter.requiresSelection(candidates))
        XCTAssertFalse(ShareCandidatePresenter.requiresSelection([candidates[0]]))
        XCTAssertEqual(ShareCandidatePresenter.displayLabel(candidates, at: 1), "example.org/A")
        XCTAssertEqual(ShareCandidatePresenter.submissionValue(candidates, at: 1), "https://example.org/A?ref=second")
        XCTAssertNil(ShareCandidatePresenter.submissionValue(candidates, at: 2))
        XCTAssertNil(ShareCandidatePresenter.displayLabel(candidates, at: -1))
    }

    func testCandidateSubmissionValueIsNotRebuiltFromItsLabel() async {
        let shared = "https://Example.ORG/Path%20A/x?q=%E4%B8%AD&b=1#frag"
        let provider = FakeItemProvider([(.url, .immediate(shared))])

        let run = ShareCandidateCollector.start(items: [[provider]], clock: FakeMonotonicClock())
        let candidate = await run.value().candidates.first

        XCTAssertEqual(candidate?.submissionValue, shared)
        XCTAssertEqual(candidate?.displayLabel, "example.org/Path%20A/x")
    }

    // MARK: - Share flow

    func testFlowKeepsOneAttachmentListPerItemIncludingTheEmptyOnes() {
        let carrier = FakeItemProvider([(.url, .deferred)])
        let items: [ShareInputItem] = [FakeInputItem([]), FakeInputItem([carrier])]

        let attachments = ShareFlowCoordinator.attachments(of: items)

        XCTAssertEqual(attachments.map(\.count), [0, 1])
        let run = ShareCandidateCollector.start(items: attachments, clock: FakeMonotonicClock())
        // The item that carried nothing still holds index 0, so the loaded one
        // is item 1. Dropping it, or flattening both levels into one, would
        // renumber every attachment behind it.
        XCTAssertEqual(
            run.startedRequests,
            [ShareRepresentationRequest(itemIndex: 1, attachmentIndex: 0, kind: .url)]
        )
    }

    func testFlowMeasuresTheInteractionDeadlineFromWhereCollectionStarted() async {
        let clock = FakeMonotonicClock()
        clock.advance(to: 7)
        let flow = ShareFlowCoordinator(clock: clock)
        let provider = FakeItemProvider([(.url, .deferred)])

        let run = flow.start(items: [[provider]])
        // Collection itself spends 1.5s of the budget. What is left for the
        // foreground request is the remainder, never a fresh budget.
        clock.advance(to: 8.5)
        provider.complete(.url, with: "https://example.org/only")
        let collection = await flow.collect()

        XCTAssertEqual(run.startedAt, 7)
        guard case .automatic(let request) = flow.presentation(for: collection.candidates) else {
            XCTFail("a single candidate is submitted without asking")
            return
        }
        XCTAssertEqual(request.value, "https://example.org/only")
        XCTAssertEqual(request.deadline, 7 + ShareCandidateCollector.interactionBudget)
    }

    func testFlowDropsTheInteractionDeadlineOnceTheUserHasToChoose() async throws {
        let clock = FakeMonotonicClock()
        clock.advance(to: 3)
        let flow = ShareFlowCoordinator(clock: clock)
        let provider = FakeItemProvider([
            (.url, .immediate("https://example.org/first")),
            (.plainText, .immediate("also see https://example.org/second")),
        ])

        flow.start(items: [[provider]])
        let collection = await flow.collect()

        guard case .selection(let candidates) = flow.presentation(for: collection.candidates) else {
            XCTFail("two candidates must be offered to the user")
            return
        }
        XCTAssertEqual(
            candidates.map(\.submissionValue),
            ["https://example.org/first", "https://example.org/second"]
        )
        let chosen = try XCTUnwrap(flow.selection(candidates, at: 1))
        // The value comes from the row, not from its label.
        XCTAssertEqual(chosen.value, "https://example.org/second")
        // Reading time is not part of the budget, and the budget is not reopened
        // for the tap either: the deadline is gone for good.
        XCTAssertNil(chosen.deadline)
        XCTAssertNil(flow.selection(candidates, at: candidates.count))
    }

    func testFlowReportsNoCandidateWhenNothingSharedCarriedALink() async {
        let flow = ShareFlowCoordinator(clock: FakeMonotonicClock())
        let provider = FakeItemProvider([(.plainText, .immediate("nothing to see here"))])

        flow.start(items: [[provider]])
        let collection = await flow.collect()

        XCTAssertEqual(
            flow.presentation(for: collection.candidates),
            ShareFlowCoordinator.Presentation.noCandidate
        )
    }

    func testFlowSubmitsOnceHoweverManyRowsAreTapped() {
        let flow = ShareFlowCoordinator(clock: FakeMonotonicClock())
        let first = ShareFlowCoordinator.SubmissionRequest(value: "https://example.org/a", deadline: nil)
        let second = ShareFlowCoordinator.SubmissionRequest(value: "https://example.org/b", deadline: 9)

        XCTAssertEqual(flow.beginSubmission(first), first)
        // A second tap - on another row or on the same one - must not start a
        // second submission, however fast the finger was.
        XCTAssertNil(flow.beginSubmission(second))
        XCTAssertNil(flow.beginSubmission(first))
    }

    func testTerminalMessageClosesTheSheetOnlyForOutcomesThatAreOver() {
        func message(_ outcome: SubmissionOutcome) -> ShareTerminalMessage.Message {
            ShareTerminalMessage.of(outcome)
        }
        func expected(_ text: String, closesSheet: Bool) -> ShareTerminalMessage.Message {
            ShareTerminalMessage.Message(text: text, completesRequest: closesSheet)
        }
        func submitted(_ status: String) -> SubmissionOutcome {
            .submitted(SubmitResponse(linkID: "9f1c0f1e", status: status, jobID: nil))
        }

        XCTAssertEqual(message(submitted("pending")), expected("已收藏", closesSheet: true))
        XCTAssertEqual(message(submitted("processing")), expected("已收藏", closesSheet: true))
        XCTAssertEqual(message(submitted("done")), expected("已在库中", closesSheet: true))
        XCTAssertEqual(message(submitted("failed")), expected("已在库中，解析失败", closesSheet: true))
        // An unknown status is still a durable row, so the share is over; it
        // just refuses to claim the link was saved.
        XCTAssertEqual(message(submitted("brand-new")), expected("提交失败", closesSheet: true))

        XCTAssertEqual(message(.scheduled), expected("已加入队列", closesSheet: true))
        XCTAssertEqual(message(.queued(.noNetwork, nil)), expected("已加入队列", closesSheet: true))

        // Everything below needs the user to go and change something, so the
        // sheet stays open and says what.
        XCTAssertEqual(message(.blocked(.blockedAuth, .auth)), expected("凭证无效，请检查设置", closesSheet: false))
        XCTAssertEqual(message(.blocked(.blockedScope, .scope)), expected("API Key 缺少 write 权限", closesSheet: false))
        XCTAssertEqual(message(.blocked(.blockedQuota, .quota)), expected("配额已用完", closesSheet: false))
        XCTAssertEqual(
            message(.blocked(.blockedIdentity, .identityMismatch)),
            expected("身份已变更", closesSheet: false)
        )
        XCTAssertEqual(
            message(.blocked(.failedPermanent, .invalidClientResponse)),
            expected("提交失败", closesSheet: false)
        )
        XCTAssertEqual(
            message(.configurationRequired),
            expected("请先打开 WebTag 完成设置", closesSheet: false)
        )
        XCTAssertEqual(message(.noCandidate), expected("没找到链接", closesSheet: false))
    }

    func testInteractionDeadlineHandsOffTheDurableRowInsteadOfReopeningTheBudget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let namespace = String(repeating: "d", count: 43)
        let identity = SessionIdentity(origin: "https://example.org", namespace: namespace, scopes: ["write"], representationContract: "v2")
        let repository = try AppGroupQueueRepository(containerURL: directory)
        try repository.activate(session: identity)
        let keychain = KeychainCredentialStore()
        keychain.clear()
        try keychain.save(config: CredentialConfig(identity: identity, apiKey: "test-key"))
        defer { keychain.clear() }

        let shared = "https://Example.ORG/Path%20A/x?q=%E4%B8%AD&b=1#frag"
        let clock = FakeMonotonicClock()
        let provider = FakeItemProvider([(.url, .immediate(shared))])
        let run = ShareCandidateCollector.start(items: [[provider]], clock: clock)
        // Hoisted out of XCTUnwrap: its argument is a non-async autoclosure.
        let collected = await run.value()
        let candidate = try XCTUnwrap(collected.candidates.first)
        let interactionDeadline = run.startedAt + ShareCandidateCollector.interactionBudget

        let requestStarted = expectation(description: "the foreground request reached the transport")
        let bodyLock = NSLock()
        var observedBodies: [String] = []
        WebTagURLProtocol.requestCount = 0
        WebTagURLProtocol.pauseAfterRequest = true
        WebTagURLProtocol.requestObserver = { request in
            bodyLock.lock()
            observedBodies.append(WebTagURLProtocol.bodyData(for: request).flatMap { String(data: $0, encoding: .utf8) } ?? "")
            bodyLock.unlock()
            requestStarted.fulfill()
        }
        defer {
            WebTagURLProtocol.pauseAfterRequest = false
            WebTagURLProtocol.requestObserver = nil
            WebTagURLProtocol.requestCount = 0
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebTagURLProtocol.self]
        let scheduler = RecordingUploadScheduler()
        let coordinator = ShareSubmissionCoordinator(
            repository: repository,
            credentials: keychain,
            api: WebTagAPIClient(session: URLSession(configuration: configuration)),
            background: scheduler,
            clock: clock
        )

        let submission = Task {
            await coordinator.submit(
                url: candidate.submissionValue,
                identity: identity,
                interactionDeadline: interactionDeadline,
                now: Date(timeIntervalSince1970: 9_000)
            )
        }
        await fulfillment(of: [requestStarted], timeout: 5)
        clock.advance(to: interactionDeadline)
        let outcome = await submission.value

        guard case .scheduled = outcome else {
            XCTFail("an exhausted interaction budget must hand off, not fail")
            return
        }
        bodyLock.lock()
        let bodies = observedBodies
        bodyLock.unlock()
        // From the item provider all the way into the request body, byte for byte.
        XCTAssertEqual(bodies, ["{\"url\":\"\(shared)\"}"])
        XCTAssertEqual(WebTagURLProtocol.requestCount, 1, "the budget must not be reopened")
        let entry = try XCTUnwrap(try repository.list().first)
        XCTAssertEqual(entry.url, shared)
        XCTAssertEqual(entry.state, .pendingSubmit)
        XCTAssertEqual(scheduler.scheduledEntry?.id, entry.id)
        XCTAssertEqual(scheduler.scheduledOwner, entry.leaseOwner)
    }

    func testBackgroundInventoryUsesExactOwnerAndRenewsOnlyAtThreshold() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try AppGroupQueueRepository(containerURL: directory)
        let identity = QueueIdentity(origin: "https://example.org", namespace: String(repeating: "w", count: 43))
        try activate(repository, identity)
        let start = Date(timeIntervalSince1970: 10_000)
        let entry = try repository.enqueue(url: "https://example.org/renew", identity: identity, now: start)
        XCTAssertTrue(try repository.claim(id: entry.id, owner: "owner-1", now: start))
        let firstClaim = BackgroundUploadClaim(queueID: entry.id, owner: "owner-1")

        XCTAssertEqual(
            try repository.reconcileBackgroundClaim(firstClaim, now: start.addingTimeInterval(239)),
            .matched(leaseExpiresAt: start.addingTimeInterval(QueueLeasePolicy.duration), renewed: false)
        )
        XCTAssertEqual(
            try repository.reconcileBackgroundClaim(firstClaim, now: start.addingTimeInterval(240)),
            .matched(leaseExpiresAt: start.addingTimeInterval(540), renewed: true)
        )
        XCTAssertEqual(
            try repository.reconcileBackgroundClaim(firstClaim, now: start.addingTimeInterval(240)),
            .matched(leaseExpiresAt: start.addingTimeInterval(540), renewed: false)
        )

        let reclaimed = try repository.enqueue(url: "https://example.org/reclaimed-owner", identity: identity, now: start)
        XCTAssertTrue(try repository.claim(id: reclaimed.id, owner: "old-owner", now: start, leaseDuration: 1))
        XCTAssertTrue(try repository.claim(id: reclaimed.id, owner: "new-owner", now: start.addingTimeInterval(2)))
        XCTAssertEqual(
            try repository.reconcileBackgroundClaim(BackgroundUploadClaim(queueID: reclaimed.id, owner: "old-owner"), now: start.addingTimeInterval(3)),
            .stale
        )
        XCTAssertEqual(try repository.entry(id: reclaimed.id)?.leaseOwner, "new-owner")
    }

    func testIdentityRevisionRejectsAThenBThenACompletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try AppGroupQueueRepository(containerURL: directory)
        let identityA = QueueIdentity(origin: "https://a.example", namespace: String(repeating: "a", count: 43))
        let identityB = QueueIdentity(origin: "https://b.example", namespace: String(repeating: "b", count: 43))
        try activate(repository, identityA)
        let entry = try repository.enqueue(url: "https://example.org/a", identity: identityA)
        XCTAssertTrue(try repository.claim(id: entry.id, owner: "owner-a"))
        let claimed = try XCTUnwrap(try repository.entry(id: entry.id))
        let firstRevision = claimed.identityRevision

        try activate(repository, identityB)
        try activate(repository, identityA)
        let active = try XCTUnwrap(try repository.activeSessionSnapshot())
        XCTAssertGreaterThan(active.revision, firstRevision)
        XCTAssertEqual(
            try repository.finishSuccess(
                entry: claimed,
                owner: "owner-a",
                response: SubmitResponse(linkID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", status: "done", jobID: nil)
            ),
            .identityChanged
        )
        XCTAssertNil(try repository.recent(identity: identityA))
        XCTAssertEqual(try repository.entry(id: entry.id)?.identityRevision, active.revision)
    }

    func testRefreshCASRejectsReplacedLinkAndIdentityChangeWithoutSideEffects() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try AppGroupQueueRepository(containerURL: directory)
        let identity = QueueIdentity(origin: "https://example.org", namespace: String(repeating: "c", count: 43))
        try activate(repository, identity)
        let first = try repository.enqueue(url: "https://example.org/one", identity: identity)
        XCTAssertTrue(try repository.claim(id: first.id, owner: "first"))
        XCTAssertEqual(try repository.finishSuccess(entry: try XCTUnwrap(try repository.entry(id: first.id)), owner: "first", response: SubmitResponse(linkID: "11111111-1111-1111-1111-111111111111", status: "done", jobID: nil)), .applied)
        let capture = try XCTUnwrap(try repository.refreshCapture(identity: identity))

        let second = try repository.enqueue(url: "https://example.org/two", identity: identity)
        XCTAssertTrue(try repository.claim(id: second.id, owner: "second"))
        XCTAssertEqual(try repository.finishSuccess(entry: try XCTUnwrap(try repository.entry(id: second.id)), owner: "second", response: SubmitResponse(linkID: "22222222-2222-2222-2222-222222222222", status: "done", jobID: nil)), .applied)
        XCTAssertEqual(
            try repository.recordRefreshBlocked(capture: capture, notBefore: Date().addingTimeInterval(60), reason: "cooldown_active"),
            .recentReplaced
        )
        XCTAssertNil(try repository.recent(identity: identity)?.refreshNotBefore)

        let secondCapture = try XCTUnwrap(try repository.refreshCapture(identity: identity))
        try activate(repository, identity)
        XCTAssertEqual(
            try repository.recordRefreshSuccess(capture: secondCapture, response: SubmitResponse(linkID: "22222222-2222-2222-2222-222222222222", status: "done", jobID: nil)),
            .identityChanged
        )
    }

    func testRetryDeadlineSurvivesRepositoryRecoveryAndDoesNotSendEarly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = QueueIdentity(origin: "https://example.org", namespace: String(repeating: "d", count: 43))
        let start = Date(timeIntervalSince1970: 20_000)
        let first = try AppGroupQueueRepository(containerURL: directory)
        try activate(first, identity)
        let entry = try first.enqueue(url: "https://example.org/retry", identity: identity, now: start)
        XCTAssertTrue(try first.claim(id: entry.id, owner: "retry", now: start))
        let deadline = start.addingTimeInterval(120)
        XCTAssertEqual(try first.applyFailure(entry: try XCTUnwrap(try first.entry(id: entry.id)), owner: "retry", state: .retryWait, category: .server, errorCode: nil, status: 503, nextAttemptAt: deadline, firstFailedAt: start, now: start), .applied)
        XCTAssertEqual(try first.earliestWake(now: start), deadline)

        let recovered = try AppGroupQueueRepository(containerURL: directory)
        XCTAssertTrue(try recovered.due(now: deadline.addingTimeInterval(-0.001)).isEmpty)
        XCTAssertEqual(try recovered.due(now: deadline).map(\.id), [entry.id])
    }
}
