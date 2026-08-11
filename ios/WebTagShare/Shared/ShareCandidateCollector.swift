import Foundation

/// Finds the links a user actually wrote inside shared text.
enum ShareTextLinkScanner {
    private static let detector: NSDataDetector? = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    /// Returns the literal substrings of `text` that the system link detector
    /// covered and that already spell out an http(s) scheme.
    ///
    /// The detector is used only to locate ranges. Its `url` is deliberately
    /// discarded: it invents a scheme for a bare `example.org`, turns
    /// `a@b.example` into a `mailto:` URL and resolves app links, and none of
    /// those are things the user asked to save. Returning the original
    /// substring also keeps the exact bytes - casing and percent-encoding
    /// included - that the submission is required to preserve.
    static func explicitHTTPSubstrings(in text: String) -> [String] {
        guard let detector else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, range: range).compactMap { match in
            guard let matched = Range(match.range, in: text) else { return nil }
            let substring = String(text[matched])
            guard hasExplicitHTTPScheme(substring) else { return nil }
            return substring
        }
    }

    static func hasExplicitHTTPScheme(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://")
    }
}

struct ShareCandidateCollection: Equatable {
    let candidates: [URLCandidate]
    /// Requests whose callback landed before the shared deadline. A request is
    /// listed even when it produced no usable value, because "answered nothing"
    /// and "never answered" are different failures.
    let completedRequests: [ShareRepresentationRequest]
    let reachedDeadline: Bool
}

enum ShareCandidateCollector {
    /// One budget for the whole collection phase rather than one per
    /// representation: the share sheet has to feel instant, and a single slow
    /// provider must not be able to spend everybody else's time.
    static let collectionBudget: TimeInterval = 2

    /// Collector plus the foreground HTTP attempt of the single-candidate path,
    /// measured from the same start instant so the budget is never reopened.
    static let interactionBudget: TimeInterval = 2.5

    /// Starts every declared representation of every attachment and arms the
    /// shared deadline, all before the caller's first `await`.
    static func start(
        items: [[ShareRepresentationLoading]],
        clock: ShareMonotonicClock,
        budget: TimeInterval = collectionBudget
    ) -> ShareCollectionRun {
        var requests: [ShareRepresentationRequest] = []
        var providers: [ShareRepresentationLoading] = []
        for (itemIndex, attachments) in items.enumerated() {
            for (attachmentIndex, provider) in attachments.enumerated() {
                for kind in provider.declaredRepresentations {
                    requests.append(
                        ShareRepresentationRequest(
                            itemIndex: itemIndex,
                            attachmentIndex: attachmentIndex,
                            kind: kind
                        )
                    )
                    providers.append(provider)
                }
            }
        }
        let run = ShareCollectionRun(
            requests: requests,
            startedAt: clock.nowSeconds,
            budget: budget,
            clock: clock
        )
        run.start(providers: providers, clock: clock)
        return run
    }
}

/// One collection phase: every load already in flight, one deadline, one result.
///
/// Unchecked `Sendable`: provider callbacks, the deadline timer and the
/// awaiting `Task` all touch this from different queues, and the `NSLock` below
/// is what serialises them.
final class ShareCollectionRun: @unchecked Sendable {
    private struct Slot {
        let request: ShareRepresentationRequest
        var value: String?
        /// The load answered in time. Distinct from `isClosed`, which a late or
        /// duplicate callback also sets but which must never count as a result.
        var didComplete = false
        var isClosed = false
        var cancellation: ShareLoadCancelling?
    }

    /// Every representation this run asked for, in frozen input order. Readable
    /// synchronously so callers - and tests - can see what was started without
    /// waiting for anything.
    let startedRequests: [ShareRepresentationRequest]
    let startedAt: TimeInterval
    let deadline: TimeInterval

    private let lock = NSLock()
    private var slots: [Slot]
    private var outstanding: Int
    private var isDecided = false
    private let clock: ShareMonotonicClock
    private let gate = ShareSingleShotGate<ShareCandidateCollection>()

    fileprivate init(
        requests: [ShareRepresentationRequest],
        startedAt: TimeInterval,
        budget: TimeInterval,
        clock: ShareMonotonicClock
    ) {
        startedRequests = requests
        self.startedAt = startedAt
        deadline = startedAt + budget
        self.clock = clock
        slots = requests.map { Slot(request: $0) }
        outstanding = requests.count
    }

    fileprivate func start(providers: [ShareRepresentationLoading], clock: ShareMonotonicClock) {
        for (index, provider) in providers.enumerated() {
            let cancellation = provider.loadRepresentation(startedRequests[index].kind) { [weak self] value in
                self?.deliver(index: index, value: value)
            }
            store(cancellation: cancellation, at: index)
        }
        // Armed only after every load is in flight, so the two seconds cover the
        // slowest provider instead of restarting once per representation.
        clock.schedule(after: max(0, deadline - clock.nowSeconds)) { [weak self] in
            self?.deadlineReached()
        }
        if startedRequests.isEmpty { decide(reachedDeadline: false) }
    }

    /// The collected candidates. Safe to call before or after the race is
    /// decided, and safe to call more than once.
    func value() async -> ShareCandidateCollection {
        await gate.value()
    }

    private func store(cancellation: ShareLoadCancelling?, at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        // A provider that answered synchronously has already closed its slot;
        // holding on to its progress would let the deadline cancel a finished
        // load.
        guard !slots[index].isClosed else { return }
        slots[index].cancellation = cancellation
    }

    private func deliver(index: Int, value: String?) {
        let completedAt = clock.nowSeconds
        lock.lock()
        guard !slots[index].isClosed else {
            // A duplicate callback, or one provoked by cancelling this load.
            // This flag - not the single-shot gate downstream, which such a
            // callback never reaches - is what stops a second answer from
            // becoming a candidate.
            lock.unlock()
            return
        }
        slots[index].isClosed = true
        slots[index].cancellation = nil
        guard !isDecided, completedAt < deadline else {
            // Late: the deadline has passed or already produced the result.
            // Closing the slot is the only effect a late callback is allowed to
            // have. Checking the clock as well as `isDecided` keeps a delayed
            // timer callback from extending the absolute deadline.
            lock.unlock()
            return
        }
        slots[index].value = value
        slots[index].didComplete = true
        outstanding -= 1
        guard outstanding == 0 else {
            lock.unlock()
            return
        }
        isDecided = true
        let snapshot = slots
        lock.unlock()
        gate.resolve(Self.collect(from: snapshot, reachedDeadline: false))
    }

    private func deadlineReached() {
        lock.lock()
        guard !isDecided else {
            lock.unlock()
            return
        }
        isDecided = true
        let abandoned = slots.compactMap { $0.isClosed ? nil : $0.cancellation }
        for index in slots.indices where !slots[index].isClosed {
            slots[index].cancellation = nil
        }
        let snapshot = slots
        lock.unlock()
        // Best effort and outside the lock: cancelling may call straight back
        // into `deliver`, and the result must not depend on it succeeding. Such
        // a re-entrant callback changes nothing because `snapshot` is already
        // frozen and `isDecided` is already set - the gate is never reached.
        for cancellation in abandoned { cancellation.cancelLoad() }
        gate.resolve(Self.collect(from: snapshot, reachedDeadline: true))
    }

    private func decide(reachedDeadline: Bool) {
        lock.lock()
        guard !isDecided else {
            lock.unlock()
            return
        }
        isDecided = true
        let snapshot = slots
        lock.unlock()
        gate.resolve(Self.collect(from: snapshot, reachedDeadline: reachedDeadline))
    }

    /// Assembles the result from the frozen input order: every structured URL
    /// first, then every text-derived link in input and range order. Completion
    /// order never reaches this function.
    private static func collect(from slots: [Slot], reachedDeadline: Bool) -> ShareCandidateCollection {
        var rawValues: [String] = []
        for slot in slots where slot.request.kind == .url {
            guard let value = slot.value else { continue }
            rawValues.append(value)
        }
        for slot in slots where slot.request.kind == .plainText {
            guard let text = slot.value else { continue }
            rawValues.append(contentsOf: ShareTextLinkScanner.explicitHTTPSubstrings(in: text))
        }

        var candidates: [URLCandidate] = []
        var seen = Set<String>()
        for raw in rawValues {
            // Re-validated here as well as at the source: a structured URL
            // representation is free to hand back ftp:// or a userinfo URL, and
            // being structured earns it no trust.
            guard let value = URLCandidateExtractor.normalizedCandidate(raw),
                  let label = URLDisplayLabel.of(value) else { continue }
            guard seen.insert(URLCandidateExtractor.deduplicationKey(value)).inserted else { continue }
            candidates.append(URLCandidate(submissionValue: value, displayLabel: label))
        }
        return ShareCandidateCollection(
            candidates: candidates,
            completedRequests: slots.filter(\.didComplete).map(\.request),
            reachedDeadline: reachedDeadline
        )
    }
}
