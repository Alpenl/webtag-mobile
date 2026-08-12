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

    static func reset() {
        reply = nil
        failure = nil
        failNextRequest = false
        requestObserver = nil
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        // Status, headers and call count only. `URLSession` strips the body
        // from the request it hands to a `URLProtocol`, so anything that has to
        // assert on the bytes uses `RecordingTransport` instead.
        Self.requestObserver?(request)
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

/// The transport the client sends through, held still so the test can read it.
///
/// This sits directly beneath `WebTagAPIClient` and above `URLSession`, so the
/// `URLRequest` recorded here is the one the client built, body included. A
/// custom `URLProtocol` cannot serve the same purpose: by the time `URLSession`
/// hands the request over, the body has been taken off it.
private final class RecordingTransport: HTTPTransport {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var parked: [CheckedContinuation<(Data, URLResponse), Error>] = []
    private let pauseAfterRequest: Bool
    private let onRequest: ((URLRequest) -> Void)?
    private let reply: (URLRequest) throws -> (Data, URLResponse)

    /// - Parameter pauseAfterRequest: accept the request and never answer it,
    ///   which is the only way to observe what a client does when its own
    ///   deadline expires while the request is still outstanding.
    init(
        pauseAfterRequest: Bool = false,
        onRequest: ((URLRequest) -> Void)? = nil,
        reply: @escaping (URLRequest) throws -> (Data, URLResponse) = { _ in throw CoreError.invalidResponse }
    ) {
        self.pauseAfterRequest = pauseAfterRequest
        self.onRequest = onRequest
        self.reply = reply
    }

    /// Every request the client handed over, in order.
    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        record(request)
        onRequest?(request)
        guard pauseAfterRequest else { return try reply(request) }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
            self.park(continuation)
        }
    }

    /// Fails every parked request, so no continuation outlives the test.
    func releaseParked() {
        lock.lock()
        let waiting = parked
        parked = []
        lock.unlock()
        for continuation in waiting { continuation.resume(throwing: CancellationError()) }
    }

    /// Locking lives in these synchronous frames on purpose: `NSLock` is
    /// unavailable from an asynchronous one, and a scoped lock around a single
    /// mutation is the whole critical section either way.
    private func record(_ request: URLRequest) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
    }

    private func park(_ continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        lock.lock()
        parked.append(continuation)
        lock.unlock()
    }
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

        let wakeScheduler = RecordingWakeScheduler()
        let coordinator = ShareSubmissionCoordinator(repository: repository, wakeScheduler: wakeScheduler)
        await coordinator.handleBackgroundCompletion(result, now: start.addingTimeInterval(3))

        XCTAssertEqual(try repository.entry(id: entry.id)?.leaseOwner, "new-owner")
        XCTAssertNil(try repository.recent())
        // A callback that lost its claim still recomputes what is due, so the
        // rejection cannot leave the queue without an alarm. The row is held by
        // a live lease, so that lease's expiry is the next thing to wake for.
        XCTAssertEqual(wakeScheduler.deadlines.count, 1)
        XCTAssertEqual(wakeScheduler.deadlines.last!, start.addingTimeInterval(12))
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
        let transport = RecordingTransport { (_: URLRequest) -> (Data, URLResponse) in
            let response: URLResponse = HTTPURLResponse(
                url: url,
                statusCode: 202,
                httpVersion: "HTTP/1.1",
                headerFields: ["X-WebTag-Data-Namespace": namespace]
            )!
            return (Data(#"{"link_id":"44444444-4444-4444-4444-444444444444","status":"done"}"#.utf8), response)
        }
        let api = WebTagAPIClient(transport: transport)
        let identity = SessionIdentity(origin: "https://example.org", namespace: namespace, scopes: ["write"], representationContract: "v2")
        let result = await api.submit(identity: identity, apiKey: key, url: "https://example.org/article", idempotencyKey: "stable-key")
        guard case .success(let response) = result else {
            XCTFail("expected successful submit")
            return
        }
        XCTAssertEqual(response.status, "done")
        // Asserted after the fact rather than inside a reply closure: an
        // assertion that only runs if the closure runs cannot tell a wrong
        // request apart from a request that was never sent.
        XCTAssertEqual(transport.requests.count, 1)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "stable-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        // The body is exactly one member and nothing else, byte for byte.
        XCTAssertEqual(
            request.httpBody.flatMap { String(data: $0, encoding: .utf8) },
            #"{"url":"https://example.org/article"}"#
        )
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
        // Accepted and never answered, so the interaction deadline is what ends
        // the foreground attempt - with the request still in flight.
        let transport = RecordingTransport(pauseAfterRequest: true, onRequest: { _ in
            requestStarted.fulfill()
        })
        defer { transport.releaseParked() }
        let scheduler = RecordingUploadScheduler()
        let coordinator = ShareSubmissionCoordinator(
            repository: repository,
            credentials: keychain,
            api: WebTagAPIClient(transport: transport),
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
        let sent = transport.requests
        let bodies: [String] = sent.map { (request: URLRequest) -> String in
            guard let body = request.httpBody else { return "" }
            return String(data: body, encoding: .utf8) ?? ""
        }
        // From the item provider all the way into the request body, byte for byte.
        XCTAssertEqual(bodies, ["{\"url\":\"\(shared)\"}"])
        XCTAssertEqual(sent.count, 1, "the budget must not be reopened")
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

    /// One alarm, for the earliest durable deadline. It has to move when a
    /// nearer row appears and to disappear - not slide into the future - when
    /// the last row goes.
    func testEarliestWakeFollowsTheNearestDeadlineAndClearsWithTheQueue() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try AppGroupQueueRepository(containerURL: directory)
        let identity = QueueIdentity(origin: "https://example.org", namespace: String(repeating: "k", count: 43))
        try activate(repository, identity)
        let start = Date(timeIntervalSince1970: 30_000)
        // An empty queue asks for no alarm at all rather than a guessed one.
        XCTAssertNil(try repository.earliestWake(now: start))

        let late = try repository.enqueue(url: "https://example.org/late", identity: identity, now: start)
        XCTAssertTrue(try repository.claim(id: late.id, owner: "late-owner", now: start))
        XCTAssertEqual(
            try repository.applyFailure(
                entry: try XCTUnwrap(try repository.entry(id: late.id)), owner: "late-owner",
                state: .retryWait, category: .server, errorCode: nil, status: 503,
                nextAttemptAt: start.addingTimeInterval(600), firstFailedAt: start, now: start
            ),
            .applied
        )
        XCTAssertEqual(try repository.earliestWake(now: start), start.addingTimeInterval(600))

        let early = try repository.enqueue(url: "https://example.org/early", identity: identity, now: start.addingTimeInterval(1))
        XCTAssertTrue(try repository.claim(id: early.id, owner: "early-owner", now: start.addingTimeInterval(1)))
        XCTAssertEqual(
            try repository.applyFailure(
                entry: try XCTUnwrap(try repository.entry(id: early.id)), owner: "early-owner",
                state: .retryWait, category: .rateLimit, errorCode: "rate_limited", status: 429,
                nextAttemptAt: start.addingTimeInterval(120), firstFailedAt: start.addingTimeInterval(1),
                now: start.addingTimeInterval(1)
            ),
            .applied
        )
        // The nearer deadline replaces the pending one instead of joining it.
        XCTAssertEqual(try repository.earliestWake(now: start.addingTimeInterval(1)), start.addingTimeInterval(120))
        XCTAssertTrue(try repository.due(now: start.addingTimeInterval(119)).isEmpty)

        try repository.delete(id: early.id)
        XCTAssertEqual(try repository.earliestWake(now: start.addingTimeInterval(1)), start.addingTimeInterval(600))
        try repository.delete(id: late.id)
        XCTAssertNil(try repository.earliestWake(now: start.addingTimeInterval(1)))
    }

    /// Two rows that come due at the same instant still drain in one order, and
    /// it is the order they were created in - never whatever SQLite felt like.
    func testDueOrdersByDeadlineAndBreaksTiesByCreation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try AppGroupQueueRepository(containerURL: directory)
        let identity = QueueIdentity(origin: "https://example.org", namespace: String(repeating: "o", count: 43))
        try activate(repository, identity)
        let start = Date(timeIntervalSince1970: 40_000)
        let tieFirst = try repository.enqueue(url: "https://example.org/tie-first", identity: identity, now: start)
        let nearest = try repository.enqueue(url: "https://example.org/nearest", identity: identity, now: start.addingTimeInterval(1))
        let tieLast = try repository.enqueue(url: "https://example.org/tie-last", identity: identity, now: start.addingTimeInterval(2))
        let plan: [(QueueEntry, String, TimeInterval)] = [
            (tieFirst, "tie-first", 300),
            (nearest, "nearest", 120),
            (tieLast, "tie-last", 300),
        ]
        for (entry, owner, offset) in plan {
            XCTAssertTrue(try repository.claim(id: entry.id, owner: owner, now: start.addingTimeInterval(3)))
            XCTAssertEqual(
                try repository.applyFailure(
                    entry: try XCTUnwrap(try repository.entry(id: entry.id)), owner: owner,
                    state: .retryWait, category: .server, errorCode: nil, status: 503,
                    nextAttemptAt: start.addingTimeInterval(offset), firstFailedAt: start.addingTimeInterval(3),
                    now: start.addingTimeInterval(3)
                ),
                .applied
            )
        }

        XCTAssertEqual(
            try repository.due(now: start.addingTimeInterval(600)).map(\.id),
            [nearest.id, tieFirst.id, tieLast.id]
        )
    }

    /// A refresh answer that arrives after the recent link was replaced is
    /// `recent_replaced` whichever of the three answers it is, and none of them
    /// may touch the link that took its place.
    func testEveryRefreshResultClassReportsRecentReplacedAfterTheLinkChanged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try AppGroupQueueRepository(containerURL: directory)
        let identity = QueueIdentity(origin: "https://example.org", namespace: String(repeating: "y", count: 43))
        try activate(repository, identity)
        let first = try repository.enqueue(url: "https://example.org/refresh-first", identity: identity)
        XCTAssertTrue(try repository.claim(id: first.id, owner: "refresh-first"))
        XCTAssertEqual(
            try repository.finishSuccess(
                entry: try XCTUnwrap(try repository.entry(id: first.id)), owner: "refresh-first",
                response: SubmitResponse(linkID: "11111111-1111-1111-1111-111111111111", status: "done", jobID: nil)
            ),
            .applied
        )
        let capture = try XCTUnwrap(try repository.refreshCapture(identity: identity))

        let second = try repository.enqueue(url: "https://example.org/refresh-second", identity: identity)
        XCTAssertTrue(try repository.claim(id: second.id, owner: "refresh-second"))
        XCTAssertEqual(
            try repository.finishSuccess(
                entry: try XCTUnwrap(try repository.entry(id: second.id)), owner: "refresh-second",
                response: SubmitResponse(linkID: "22222222-2222-2222-2222-222222222222", status: "processing", jobID: nil)
            ),
            .applied
        )

        XCTAssertEqual(
            try repository.recordRefreshSuccess(
                capture: capture,
                response: SubmitResponse(linkID: "11111111-1111-1111-1111-111111111111", status: "done", jobID: nil)
            ),
            .recentReplaced
        )
        XCTAssertEqual(
            try repository.recordRefreshBlocked(capture: capture, notBefore: Date(timeIntervalSince1970: 50_000), reason: "cooldown_active"),
            .recentReplaced
        )
        XCTAssertEqual(
            try repository.recordRefreshBlocked(capture: capture, notBefore: nil, reason: "quota_exceeded"),
            .recentReplaced
        )

        let recent = try XCTUnwrap(try repository.recent(identity: identity))
        XCTAssertEqual(recent.linkID, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(recent.status, "processing")
        XCTAssertNil(recent.refreshNotBefore)
        XCTAssertNil(recent.refreshBlockReason)
    }

    /// The other side of the lease boundary. The expired-owner test pins the
    /// instant of expiry as stale; this pins one millisecond earlier as still
    /// committable, which is what makes that instant a boundary rather than a
    /// rounded-off window.
    func testCompletionOneMillisecondInsideTheLeaseStillCommits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try AppGroupQueueRepository(containerURL: directory)
        let identity = QueueIdentity(origin: "https://example.org", namespace: String(repeating: "z", count: 43))
        try activate(repository, identity)
        let start = Date(timeIntervalSince1970: 50_000)
        let entry = try repository.enqueue(url: "https://example.org/boundary", identity: identity, now: start)
        XCTAssertTrue(try repository.claim(id: entry.id, owner: "boundary", now: start, leaseDuration: 60))
        XCTAssertEqual(
            try repository.finishSuccess(
                entry: try XCTUnwrap(try repository.entry(id: entry.id)), owner: "boundary",
                response: SubmitResponse(linkID: "99999999-9999-9999-9999-999999999999", status: "pending", jobID: nil),
                now: start.addingTimeInterval(59.999)
            ),
            .applied
        )
        XCTAssertTrue(try repository.list().isEmpty)
        XCTAssertEqual(try repository.recent(identity: identity)?.linkID, "99999999-9999-9999-9999-999999999999")
    }

    // MARK: - Settings queue grouping, recent projection and lifecycle

    func testSettingsQueueGroupingFollowsTheSharedFixture() throws {
        let data = try Data(contentsOf: settingsQueueFixtureURL())
        let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // The same file drives the Android JVM test. A platform that quietly stops
        // reading it would keep passing on its own hand-written expectations.
        let declaredGroups = try XCTUnwrap(fixture["groups"] as? [[String: Any]])
        XCTAssertEqual(
            declaredGroups.map { $0["key"] as? String },
            SettingsQueueGroup.allCases.map(\.rawValue),
            "the fixture's section order is the frozen render order"
        )
        for group in declaredGroups {
            let key = try XCTUnwrap(group["key"] as? String)
            let states = try XCTUnwrap(group["states"] as? [String])
            for rawState in states {
                let state = try XCTUnwrap(QueueState(rawValue: rawState))
                XCTAssertEqual(SettingsQueueGroup.group(for: state).rawValue, key, rawState)
            }
        }

        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for testCase in cases {
            let caseID = try XCTUnwrap(testCase["id"] as? String)
            let rows = try XCTUnwrap(testCase["rows"] as? [[String: Any]])
            let entries = try rows.map { try settingsQueueEntry(from: $0) }
            let projection = SettingsQueuePresenter.project(entries)

            XCTAssertEqual(projection.total, testCase["expected_total"] as? Int, caseID)
            let expectedGroups = try XCTUnwrap(testCase["expected_groups"] as? [[String: Any]])
            XCTAssertEqual(
                projection.groups.map(\.group.rawValue),
                expectedGroups.map { $0["key"] as? String },
                "\(caseID): only non-empty sections render, in the frozen order"
            )
            for (rendered, expected) in zip(projection.groups, expectedGroups) {
                XCTAssertEqual(rendered.count, expected["count"] as? Int, caseID)
                XCTAssertEqual(
                    rendered.rows.map(\.id),
                    expected["row_ids"] as? [String],
                    "\(caseID): repository order is preserved inside a section"
                )
            }
        }
    }

    func testSettingsQueueTotalCountsRowsInHiddenSectionsToo() throws {
        // Guards the difference between "what is stored" and "what is on screen":
        // the header must not shrink when a section is hidden.
        let entries = [
            settingsEntry(id: "a", state: .expired),
            settingsEntry(id: "b", state: .expired),
        ]
        let projection = SettingsQueuePresenter.project(entries)
        XCTAssertEqual(projection.total, 2)
        XCTAssertEqual(projection.groups.count, 1)
        XCTAssertEqual(SettingsQueuePresenter.project([]).total, 0)
        XCTAssertTrue(SettingsQueuePresenter.project([]).groups.isEmpty)
    }

    func testSettingsTimeFormatterIsAbsoluteLocaleAwareAndSilentOnMissingValues() {
        let locale = Locale(identifier: "zh_Hans_CN")
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        let utc = TimeZone(identifier: "UTC")!
        let moment = Date(timeIntervalSince1970: 1_754_881_200)

        // Expectations are rendered, never spelled out: CLDR data changes between
        // OS releases, so a literal like "2026/8/11 11:00" pins the OS, not the code.
        let reference = DateFormatter()
        reference.locale = locale
        reference.timeZone = shanghai
        reference.dateStyle = .medium
        reference.timeStyle = .short
        XCTAssertEqual(
            SettingsTimeFormatter.absolute(moment, locale: locale, timeZone: shanghai),
            reference.string(from: moment)
        )
        // A time zone that does not reach the output would make the assertion above
        // pass against a formatter that ignores both arguments.
        XCTAssertNotEqual(
            SettingsTimeFormatter.absolute(moment, locale: locale, timeZone: shanghai),
            SettingsTimeFormatter.absolute(moment, locale: locale, timeZone: utc)
        )
        // Absolute, not relative: the date part has to be there.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai
        let year = String(calendar.component(.year, from: moment))
        XCTAssertEqual(SettingsTimeFormatter.absolute(moment, locale: locale, timeZone: shanghai)?.contains(year), true)
        // No placeholder. A missing timestamp renders nothing at all.
        XCTAssertNil(SettingsTimeFormatter.absolute(nil, locale: locale, timeZone: shanghai))
    }

    func testRecentRefreshGateRedactsAndDisablesOnIdentityMismatch() {
        let now = Date(timeIntervalSince1970: 20_000)
        let matched = settingsRecent(mismatch: false, notBefore: nil, reason: nil)
        XCTAssertEqual(
            SettingsRefreshGatePolicy.evaluate(recent: matched, now: now),
            SettingsRecentRefreshGate(isEnabled: true, cooldownUntil: nil, blockReason: nil)
        )
        // A mismatched row keeps its blocked state visible but nothing else: no
        // refresh, no deadline, no reason string that could describe another
        // identity's data.
        let mismatched = settingsRecent(mismatch: true, notBefore: now.addingTimeInterval(60), reason: "cooldown_active")
        XCTAssertEqual(SettingsRefreshGatePolicy.evaluate(recent: mismatched, now: now), .unavailable)
        XCTAssertEqual(SettingsRefreshGatePolicy.evaluate(recent: nil, now: now), .unavailable)
    }

    func testRecentRefreshGateTreatsQuotaAsABlockWithoutADeadline() {
        let now = Date(timeIntervalSince1970: 30_000)
        let quota = settingsRecent(mismatch: false, notBefore: nil, reason: SettingsRefreshGatePolicy.quotaReason)
        let gate = SettingsRefreshGatePolicy.evaluate(recent: quota, now: now)
        XCTAssertFalse(gate.isEnabled)
        // No countdown: quota is not a timed cooldown, and arming a timer would
        // promise a recovery time the server never gave.
        XCTAssertNil(gate.cooldownUntil)

        let clock = FakeSettingsClock(now: now)
        let timer = SettingsCooldownTimer(clock: clock)
        timer.arm(until: gate.cooldownUntil) { XCTFail("a quota block must not arm a timer") }
        XCTAssertEqual(clock.pendingCount, 0)
    }

    func testCooldownUnlocksExactlyAtTheDeadlineWithoutReadingTheDatabase() {
        let start = Date(timeIntervalSince1970: 40_000)
        let deadline = start.addingTimeInterval(120)
        let recent = settingsRecent(mismatch: false, notBefore: deadline, reason: SettingsRefreshGatePolicy.cooldownReason)
        let repository = CountingSettingsRepository()
        let clock = FakeSettingsClock(now: start)
        let timer = SettingsCooldownTimer(clock: clock)

        var gate = SettingsRefreshGatePolicy.evaluate(recent: recent, now: clock.now)
        XCTAssertFalse(gate.isEnabled)
        XCTAssertEqual(gate.cooldownUntil, deadline)
        timer.arm(until: gate.cooldownUntil) {
            gate = SettingsRefreshGatePolicy.evaluate(recent: recent, now: clock.now)
        }

        clock.advance(to: deadline.addingTimeInterval(-0.001))
        XCTAssertFalse(gate.isEnabled, "one millisecond before the deadline the block still holds")
        clock.advance(to: deadline)
        XCTAssertTrue(gate.isEnabled, "the exact deadline unlocks without anything else happening")
        XCTAssertNil(gate.cooldownUntil)
        // The deadline changes what is displayed, not what is stored.
        XCTAssertEqual(repository.reads, 0)
        XCTAssertEqual(repository.writes, 0)
    }

    func testCooldownTimerIgnoresAnArmingThatWasReplacedOrDisposed() {
        let start = Date(timeIntervalSince1970: 50_000)
        let clock = FakeSettingsClock(now: start)
        let timer = SettingsCooldownTimer(clock: clock)
        var fired: [String] = []

        // Replacement: the recent row changed while the first deadline was pending.
        timer.arm(until: start.addingTimeInterval(60)) { fired.append("first") }
        timer.arm(until: start.addingTimeInterval(90)) { fired.append("second") }
        clock.advance(to: start.addingTimeInterval(60))
        XCTAssertEqual(fired, [], "the replaced arming must not fire")
        clock.advance(to: start.addingTimeInterval(90))
        XCTAssertEqual(fired, ["second"])

        // Dispose: the screen went away while a deadline was pending.
        fired.removeAll()
        timer.arm(until: start.addingTimeInterval(200)) { fired.append("disposed") }
        timer.invalidate()
        clock.advance(to: start.addingTimeInterval(200))
        XCTAssertEqual(fired, [])

        // A deadline already in the past is not worth arming for.
        timer.arm(until: start) { fired.append("past") }
        XCTAssertEqual(clock.pendingCount, 0)
        XCTAssertEqual(fired, [])
    }

    func testForegroundReadShowsWhatAnotherRepositoryWroteWhileInactive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = try AppGroupQueueRepository(containerURL: directory)
        let identity = QueueIdentity(origin: "https://example.org", namespace: String(repeating: "l", count: 43))
        try activate(repository, identity)
        let loader = SettingsSnapshotLoader(repository: repository)
        _ = try repository.enqueue(url: "https://example.org/a", identity: identity)
        XCTAssertEqual(loader.loadProjection()?.queue.total, 1)

        // The share extension writes through its own repository handle and cannot
        // invalidate anything in this process, so only a fresh read can see B.
        let other = try AppGroupQueueRepository(containerURL: directory)
        _ = try other.enqueue(url: "https://example.org/b", identity: identity)

        let afterForeground = try XCTUnwrap(loader.loadProjection())
        XCTAssertEqual(afterForeground.queue.total, 2)
        XCTAssertEqual(
            afterForeground.queue.groups.flatMap(\.rows).map(\.url),
            ["https://example.org/a", "https://example.org/b"]
        )
    }

    func testSecondReadAfterDrainShowsWhatTheDrainChanged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = try AppGroupQueueRepository(containerURL: directory)
        let identity = QueueIdentity(origin: "https://example.org", namespace: String(repeating: "m", count: 43))
        try activate(repository, identity)
        let loader = SettingsSnapshotLoader(repository: repository)
        let b = try repository.enqueue(url: "https://example.org/b", identity: identity)

        let first = try XCTUnwrap(loader.loadProjection())
        XCTAssertEqual(first.queue.groups.flatMap(\.rows).map(\.id), [b.id])

        // Stands in for the drain: it is the second read, not the first, that has to
        // show what reconcile/drain did.
        let c = try repository.enqueue(url: "https://example.org/c", identity: identity)
        try repository.delete(id: b.id)

        let second = try XCTUnwrap(loader.loadProjection())
        XCTAssertEqual(second.queue.groups.flatMap(\.rows).map(\.id), [c.id])
    }

    func testALateSnapshotFromAReplacedIdentityIsNotCommitted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = try AppGroupQueueRepository(containerURL: directory)
        let first = QueueIdentity(origin: "https://example.org", namespace: String(repeating: "n", count: 43))
        let second = QueueIdentity(origin: "https://example.org", namespace: String(repeating: "o", count: 43))
        try activate(repository, first)
        _ = try repository.enqueue(url: "https://example.org/first", identity: first)
        let loader = SettingsSnapshotLoader(repository: repository)

        // A read that started under the first identity and has not been committed yet.
        let stale = try loader.snapshot()

        try activate(repository, second)
        _ = try repository.enqueue(url: "https://example.org/second", identity: second)
        let current = try loader.snapshot()
        XCTAssertTrue(loader.commit(current))

        // Released only now, after the newer one already landed.
        XCTAssertFalse(loader.commit(stale), "a snapshot from a replaced identity must not repaint the screen")

        // A → B → A gets a third revision, so an in-flight A load is still stale.
        try activate(repository, first)
        XCTAssertFalse(loader.commit(stale))
    }

    func testCompanionTodoPresenterBuildsSevenDayAndStableSections() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_753_747_200) // 2025-07-29 00:00:00Z
        let items = [
            companionTodo(id: "00000000-0000-0000-0000-000000000001", text: "overdue", dueAt: now.addingTimeInterval(-86_400)),
            companionTodo(id: "00000000-0000-0000-0000-000000000002", text: "today", dueAt: now.addingTimeInterval(18 * 3_600)),
            companionTodo(id: "00000000-0000-0000-0000-000000000003", text: "later", dueAt: now.addingTimeInterval(2 * 86_400)),
            companionTodo(id: "00000000-0000-0000-0000-000000000004", text: "none", dueAt: nil),
            companionTodo(id: "00000000-0000-0000-0000-000000000005", text: "done", dueAt: now, done: true),
        ]

        let projection = CompanionTodoPresenter.project(items, now: now, calendar: calendar)

        XCTAssertEqual(projection.days.count, 7)
        XCTAssertEqual(projection.openCount, 4)
        XCTAssertEqual(projection.overdueCount, 1)
        XCTAssertEqual(projection.todayCount, 1)
        XCTAssertEqual(projection.sections.map(\.section), CompanionTodoSection.allCases)
        XCTAssertEqual(projection.sections.map { $0.items.map(\.text) }, [["overdue"], ["today"], ["later"], ["none"], ["done"]])
    }

    func testCompanionTodoStateIsEncryptedAndPersistsDesiredState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data(repeating: 7, count: 32)
        let identity = QueueIdentity(origin: "https://example.org", namespace: String(repeating: "t", count: 43))
        let repository = try CompanionTodoRepository(
            containerURL: directory,
            cipher: CompanionTodoAESGCMCipher(keyData: key)
        )

        let localID = try repository.stageCreate(
            identity: identity,
            request: CompanionTodoCreate(text: "private offline task", dueAt: nil),
            now: Date(timeIntervalSince1970: 1_000)
        )
        let first = try repository.snapshot(identity: identity)
        XCTAssertEqual(first.items.map(\.id), [localID])
        XCTAssertEqual(first.items.first?.text, "private offline task")
        XCTAssertTrue(first.items.first?.localOnly == true)
        XCTAssertEqual(first.pendingOperations, 1)

        let disk = try Data(contentsOf: directory.appendingPathComponent("companion-todo-state.v1"))
        XCTAssertNil(String(data: disk, encoding: .utf8)?.range(of: "private offline task"))

        let reopened = try CompanionTodoRepository(
            containerURL: directory,
            cipher: CompanionTodoAESGCMCipher(keyData: key)
        )
        XCTAssertEqual(try reopened.snapshot(identity: identity), first)
    }

    func testCompanionTodoLeaseExpiresRebindsAndRejectsStaleOwner() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try CompanionTodoRepository(
            containerURL: directory,
            cipher: CompanionTodoAESGCMCipher(keyData: Data(repeating: 8, count: 32))
        )
        let identity = QueueIdentity(origin: "https://example.org", namespace: String(repeating: "u", count: 43))
        let start = Date(timeIntervalSince1970: 2_000)
        let localID = try repository.stageCreate(
            identity: identity,
            request: CompanionTodoCreate(text: "created offline", dueAt: nil),
            now: start
        )
        _ = try repository.stagePatch(
            identity: identity,
            todoID: localID,
            patch: CompanionTodoPatch(text: "edited offline", dueAt: nil, dueAtSet: false, done: nil, expectedHostRevision: nil),
            now: start.addingTimeInterval(1)
        )
        let first = try XCTUnwrap(repository.claimDue(identity: identity, now: start, leaseDuration: 10))
        XCTAssertNil(
            try repository.claimDue(identity: identity, now: start.addingTimeInterval(1), leaseDuration: 10),
            "a later operation for the same TODO must not overtake its leased create"
        )
        let second = try XCTUnwrap(repository.claimDue(identity: identity, now: start.addingTimeInterval(11), leaseDuration: 10))
        XCTAssertEqual(first.operation.id, second.operation.id)
        XCTAssertNotEqual(first.owner, second.owner)

        XCTAssertThrowsError(try repository.completeCreate(
            identity: identity,
            operationID: first.operation.id,
            owner: first.owner,
            created: companionTodo(id: "10000000-0000-0000-0000-000000000001", text: "server", dueAt: nil)
        )) { error in
            XCTAssertEqual(error as? TodoStateError, .staleClaim)
        }

        let server = companionTodo(
            id: "10000000-0000-0000-0000-000000000001",
            text: "server",
            dueAt: nil
        )
        try repository.completeCreate(
            identity: identity,
            operationID: second.operation.id,
            owner: second.owner,
            created: server,
            now: start.addingTimeInterval(12)
        )
        let snapshot = try repository.snapshot(identity: identity)
        XCTAssertEqual(snapshot.items.map(\.id), [server.id])
        XCTAssertEqual(snapshot.items.first?.text, "edited offline")
        XCTAssertTrue(snapshot.items.first?.pending == true)
        XCTAssertEqual(snapshot.pendingOperations, 1)
    }

    func testCompanionTodoConflictRebasesDesiredDoneWithANewOperationID() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try CompanionTodoRepository(
            containerURL: directory,
            cipher: CompanionTodoAESGCMCipher(keyData: Data(repeating: 9, count: 32))
        )
        let identity = QueueIdentity(origin: "https://example.org", namespace: String(repeating: "w", count: 43))
        let item = CompanionTodoItem(
            id: "30000000-0000-0000-0000-000000000001",
            text: "projected",
            dueAt: nil,
            done: false,
            originKind: .note,
            originHostKind: "note",
            originHostID: "note-one",
            hostRevision: 2,
            createdAt: Date(timeIntervalSince1970: 3_000),
            updatedAt: Date(timeIntervalSince1970: 3_000)
        )
        try repository.replaceServerSnapshot(identity: identity, items: [item])
        let firstCreatedAt = Date(timeIntervalSince1970: 3_010)
        let originalID = try repository.stagePatch(
            identity: identity,
            todoID: item.id,
            patch: CompanionTodoPatch(text: nil, dueAt: nil, dueAtSet: false, done: true, expectedHostRevision: 2),
            now: firstCreatedAt
        )
        let laterID = try repository.stagePatch(
            identity: identity,
            todoID: item.id,
            patch: CompanionTodoPatch(text: nil, dueAt: nil, dueAtSet: false, done: false, expectedHostRevision: 2),
            now: firstCreatedAt
        )
        let original = try XCTUnwrap(repository.claimDue(identity: identity))
        let refreshed = CompanionTodoItem(
            id: item.id,
            text: item.text,
            dueAt: nil,
            done: false,
            originKind: .note,
            originHostKind: "note",
            originHostID: "note-one",
            hostRevision: 3,
            createdAt: item.createdAt,
            updatedAt: Date(timeIntervalSince1970: 3_100)
        )

        try repository.rebaseDoneConflict(
            identity: identity,
            operationID: original.operation.id,
            owner: original.owner,
            desiredDone: true,
            current: refreshed,
            snapshot: [refreshed],
            now: firstCreatedAt.addingTimeInterval(2)
        )

        let rebased = try XCTUnwrap(repository.claimDue(identity: identity))
        XCTAssertEqual(original.operation.id, originalID)
        XCTAssertNotEqual(rebased.operation.id, original.operation.id)
        XCTAssertNotEqual(rebased.operation.id, laterID, "a later operation must not overtake a rebased conflict")
        XCTAssertEqual(rebased.operation.createdAt, firstCreatedAt)
        XCTAssertEqual(rebased.operation.patch?.done, true)
        XCTAssertEqual(rebased.operation.patch?.expectedHostRevision, 3)

        let completed = CompanionTodoItem(
            id: refreshed.id,
            text: refreshed.text,
            dueAt: nil,
            done: true,
            originKind: .note,
            originHostKind: "note",
            originHostID: "note-one",
            hostRevision: 4,
            createdAt: refreshed.createdAt,
            updatedAt: firstCreatedAt.addingTimeInterval(3)
        )
        try repository.completePatch(
            identity: identity,
            operationID: rebased.operation.id,
            owner: rebased.owner,
            updated: completed
        )
        let later = try XCTUnwrap(repository.claimDue(identity: identity))
        XCTAssertEqual(later.operation.id, laterID)
        XCTAssertEqual(later.operation.patch?.expectedHostRevision, 4)
    }

    func testCompanionTodoAPIUsesPaginationNamespaceAndStableIdempotencyKey() async throws {
        let namespace = String(repeating: "v", count: 43)
        let identity = SessionIdentity(
            origin: "https://example.org",
            namespace: namespace,
            scopes: ["write"],
            representationContract: "v2"
        )
        let firstItem = companionTodo(id: "20000000-0000-0000-0000-000000000001", text: "first", dueAt: nil)
        let secondItem = companionTodo(id: "20000000-0000-0000-0000-000000000002", text: "second", dueAt: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let transport = RecordingTransport { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["X-WebTag-Data-Namespace": namespace]
            ))
            let after = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "after" })?.value
            let page: [String: Any]
            if after == nil {
                page = ["items": [try jsonObject(firstItem, encoder: encoder)], "next_after": "page-two"]
            } else {
                XCTAssertEqual(after, "page-two")
                page = ["items": [try jsonObject(secondItem, encoder: encoder)]]
            }
            return (try JSONSerialization.data(withJSONObject: page), response)
        }
        let api = CompanionTodoAPIClient(transport: transport)

        let listed = try await api.listTodos(identity: identity, apiKey: "secret").get()

        XCTAssertEqual(listed.map(\.id), [firstItem.id, secondItem.id])
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests.first?.url?.path, "/api/todos")
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(transport.requests.first?.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "limit" })?.value,
            "200"
        )

        let createTransport = RecordingTransport { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "offline-operation-id")
            XCTAssertEqual(request.httpMethod, "POST")
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 201,
                httpVersion: "HTTP/1.1",
                headerFields: ["X-WebTag-Data-Namespace": namespace]
            ))
            return (try encoder.encode(firstItem), response)
        }
        let createAPI = CompanionTodoAPIClient(transport: createTransport)
        _ = try await createAPI.createTodo(
            identity: identity,
            apiKey: "secret",
            request: CompanionTodoCreate(text: "first", dueAt: nil),
            idempotencyKey: "offline-operation-id"
        ).get()
        XCTAssertEqual(createTransport.requests.count, 1)
    }

    @MainActor
    func testLifecycleReloadDoesNotOverwriteUnsavedCredentialDrafts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let keychain = KeychainCredentialStore()
        keychain.clear()
        defer { keychain.clear() }

        let repository = try AppGroupQueueRepository(containerURL: directory)
        let identity = QueueIdentity(origin: "https://example.org", namespace: String(repeating: "p", count: 43))
        try activate(repository, identity)
        let model = WebTagSettingsModel(clock: FakeSettingsClock(now: Date(timeIntervalSince1970: 60_000)), repository: repository)

        model.origin = "https://half-typed.example"
        model.apiKey = "half-typed-key"
        _ = try repository.enqueue(url: "https://example.org/queued", identity: identity)

        model.reload()

        XCTAssertEqual(model.projection.queue.total, 1, "the reload really did replace the projection")
        XCTAssertEqual(model.origin, "https://half-typed.example")
        XCTAssertEqual(model.apiKey, "half-typed-key")
    }
}

private func companionTodo(
    id: String,
    text: String,
    dueAt: Date?,
    done: Bool = false
) -> CompanionTodoItem {
    CompanionTodoItem(
        id: id,
        text: text,
        dueAt: dueAt,
        done: done,
        originKind: .standalone,
        hostRevision: 0,
        completedAt: done ? Date(timeIntervalSince1970: 4_000) : nil,
        createdAt: Date(timeIntervalSince1970: 3_000),
        updatedAt: Date(timeIntervalSince1970: 4_000)
    )
}

private func jsonObject(_ item: CompanionTodoItem, encoder: JSONEncoder) throws -> [String: Any] {
    try XCTUnwrap(try JSONSerialization.jsonObject(with: encoder.encode(item)) as? [String: Any])
}

// MARK: - Settings projection test doubles

private func settingsQueueFixtureURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("shared/fixtures/queue-states.json")
}

private let settingsFixtureIdentity = QueueIdentity(
    origin: "https://example.org",
    namespace: String(repeating: "q", count: 43)
)

private func settingsEntry(
    id: String,
    state: QueueState,
    url: String = "https://example.org/row",
    firstFailedAt: Date? = nil,
    nextAttemptAt: Date? = nil
) -> QueueEntry {
    QueueEntry(
        id: id,
        schemaVersion: 1,
        url: url,
        idempotencyKey: "key-\(id)",
        requestFingerprint: "fingerprint-\(id)",
        identity: settingsFixtureIdentity,
        identityRevision: 1,
        state: state,
        createdAt: Date(timeIntervalSince1970: 1_000),
        firstFailedAt: firstFailedAt,
        attemptCount: 0,
        nextAttemptAt: nextAttemptAt,
        lastError: nil,
        lastErrorCode: nil,
        lastHTTPStatus: nil,
        linkID: nil,
        jobID: nil,
        leaseOwner: nil,
        leaseExpiresAt: nil
    )
}

/// Milliseconds in the shared fixture, seconds in `Date`. Kept in one place so the
/// two platforms cannot drift into disagreeing about the unit.
private func settingsFixtureDate(_ milliseconds: Any?) -> Date? {
    guard let milliseconds = milliseconds as? Double else { return nil }
    return Date(timeIntervalSince1970: milliseconds / 1000)
}

private func settingsQueueEntry(from row: [String: Any]) throws -> QueueEntry {
    let id = try XCTUnwrap(row["id"] as? String)
    let state = try XCTUnwrap(QueueState(rawValue: try XCTUnwrap(row["state"] as? String)))
    return settingsEntry(
        id: id,
        state: state,
        url: (row["url"] as? String) ?? "",
        firstFailedAt: settingsFixtureDate(row["first_failed_at"]),
        nextAttemptAt: settingsFixtureDate(row["next_attempt_at"])
    )
}

private func settingsRecent(mismatch: Bool, notBefore: Date?, reason: String?) -> RecentResult {
    RecentResult(
        url: mismatch ? "" : "https://example.org/recent",
        linkID: mismatch ? "" : "44444444-4444-4444-4444-444444444444",
        jobID: mismatch ? nil : "job-1",
        status: "failed",
        createdAt: Date(timeIntervalSince1970: 5_000),
        identity: settingsFixtureIdentity,
        identityRevision: 1,
        refreshNotBefore: notBefore,
        refreshBlockReason: reason,
        isIdentityMismatch: mismatch
    )
}

/// Counts every touch so "the deadline performs no database work" can be asserted
/// rather than assumed. There is no write path here at all: reaching for one would
/// not compile, which is a stronger statement than a counter that stays at zero.
private final class CountingSettingsRepository: SettingsSnapshotReading {
    var snapshot: ActiveSessionSnapshot?
    var entries: [QueueEntry] = []
    var recentResult: RecentResult?
    private(set) var reads = 0
    private(set) var writes = 0

    func activeSessionSnapshot() throws -> ActiveSessionSnapshot? {
        reads += 1
        return snapshot
    }

    func list(identity: QueueIdentity?) throws -> [QueueEntry] {
        reads += 1
        return entries
    }

    func recent(identity: QueueIdentity?) throws -> RecentResult? {
        reads += 1
        return recentResult
    }
}

/// Wall clock under test control. `advance(to:)` runs exactly the callbacks whose
/// deadline the move crossed, so "one millisecond before" and "at the deadline" are
/// two different observations rather than one racy one.
private final class FakeSettingsClock: SettingsWallClock {
    private(set) var now: Date
    private var pending: [(deadline: Date, body: () -> Void)] = []

    init(now: Date) {
        self.now = now
    }

    var pendingCount: Int { pending.count }

    func schedule(after delay: TimeInterval, _ body: @escaping () -> Void) {
        pending.append((now.addingTimeInterval(delay), body))
    }

    func advance(to date: Date) {
        now = date
        let due = pending.filter { $0.deadline <= date }
        pending.removeAll { $0.deadline <= date }
        for item in due { item.body() }
    }
}
