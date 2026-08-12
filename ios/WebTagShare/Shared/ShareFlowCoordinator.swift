import Foundation

/// One extension item, reduced to the attachments the collector can read.
///
/// The share extension receives `NSExtensionItem`s, which cannot be built with
/// stub providers in a unit test. Going through this protocol is what lets the
/// flattening rules - a nil attachment list is an empty item, never a dropped
/// one - be pinned by tests instead of only by the running share sheet.
protocol ShareInputItem {
    var shareAttachments: [ShareRepresentationLoading] { get }
}

extension NSExtensionItem: ShareInputItem {
    var shareAttachments: [ShareRepresentationLoading] {
        (attachments ?? []).map { $0 as ShareRepresentationLoading }
    }
}

/// Every decision the share sheet makes, with no UIKit in sight.
///
/// `ShareViewController` owns pixels, `extensionContext`, the keychain and the
/// queue; this owns the decisions - which links were found, whether the user has
/// to pick one, which deadline a submission inherits, and that exactly one
/// submission may ever leave. The split exists so those rules are reachable from
/// a test: the frozen one is that the interaction budget is measured from the
/// instant collection started and is never reopened, and it has no other
/// implementation site.
final class ShareFlowCoordinator: @unchecked Sendable {
    /// A URL that is about to be submitted, with the budget it inherits.
    struct SubmissionRequest: Equatable {
        /// Exactly what the collector produced, byte for byte.
        let value: String
        /// Absolute instant on the shared clock, or nil when a human was in the
        /// loop and no budget applies to what follows.
        let deadline: TimeInterval?
    }

    enum Presentation: Equatable {
        /// Nothing in the share carried a link.
        case noCandidate
        /// Exactly one link: submitted without asking, still inside the budget
        /// that started with collection.
        case automatic(SubmissionRequest)
        /// More than one link, so the user picks and the budget is dropped.
        case selection([URLCandidate])
    }

    private let clock: ShareMonotonicClock
    private let interactionBudget: TimeInterval
    private let lock = NSLock()
    private var run: ShareCollectionRun?
    private var interactionDeadline: TimeInterval?
    private var submittedValue: String?

    init(
        clock: ShareMonotonicClock,
        interactionBudget: TimeInterval = ShareCandidateCollector.interactionBudget
    ) {
        self.clock = clock
        self.interactionBudget = interactionBudget
    }

    /// One attachment list per extension item, in input order.
    ///
    /// An item that carries no attachment still occupies its index: the item
    /// index is half of what later orders the candidates, so collapsing empty
    /// items would silently renumber every attachment after them.
    static func attachments(of items: [ShareInputItem]) -> [[ShareRepresentationLoading]] {
        items.map { $0.shareAttachments }
    }

    /// Starts every representation of every attachment and arms the interaction
    /// deadline from the same instant, all before the caller's first `await`.
    @discardableResult
    func start(items: [[ShareRepresentationLoading]]) -> ShareCollectionRun {
        let started = ShareCandidateCollector.start(items: items, clock: clock)
        lock.lock()
        run = started
        // Measured from where collection began rather than from where it ended:
        // loading and the foreground request share one budget, so a slow
        // provider spends the request's time and not somebody else's.
        interactionDeadline = started.startedAt + interactionBudget
        lock.unlock()
        return started
    }

    /// The collected candidates, or an empty collection when nothing was
    /// started.
    func collect() async -> ShareCandidateCollection {
        guard let started = startedRun() else {
            return ShareCandidateCollection(candidates: [], completedRequests: [], reachedDeadline: false)
        }
        return await started.value()
    }

    /// Reads the run under the lock from a synchronous frame.
    ///
    /// The lock never spans the suspension point either way - it is taken and
    /// released around this one read - but taking it inside an async function
    /// is what `NSLock` is unavailable for, since the frame that unlocks may no
    /// longer be the thread that locked.
    private func startedRun() -> ShareCollectionRun? {
        lock.lock()
        defer { lock.unlock() }
        return run
    }

    /// What the sheet must do with what was collected.
    func presentation(for candidates: [URLCandidate]) -> Presentation {
        guard !candidates.isEmpty else { return .noCandidate }
        lock.lock()
        defer { lock.unlock() }
        guard ShareCandidatePresenter.requiresSelection(candidates) else {
            return .automatic(SubmissionRequest(value: candidates[0].submissionValue, deadline: interactionDeadline))
        }
        // Waiting for a human is not part of the interaction budget - and the
        // budget is not reopened once they answer either, which is why the
        // deadline is dropped here rather than recomputed on their tap.
        interactionDeadline = nil
        return .selection(candidates)
    }

    /// The request for the row the user picked, or nil for an index that does
    /// not exist. The value comes from the row itself, never from its label.
    func selection(_ candidates: [URLCandidate], at index: Int) -> SubmissionRequest? {
        guard let value = ShareCandidatePresenter.submissionValue(candidates, at: index) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return SubmissionRequest(value: value, deadline: interactionDeadline)
    }

    /// Returns the request only to the first caller: one share is one
    /// submission, however many rows were tapped.
    func beginSubmission(_ request: SubmissionRequest) -> SubmissionRequest? {
        lock.lock()
        defer { lock.unlock() }
        guard submittedValue == nil else { return nil }
        submittedValue = request.value
        return request
    }
}

/// The single line the share sheet shows once a submission is over.
///
/// Kept beside the flow rather than in the view controller because which
/// outcomes are terminal - and which of them are successful enough to close the
/// sheet on the user's behalf - is a decision, not drawing.
enum ShareTerminalMessage {
    struct Message: Equatable {
        let text: String
        /// The share succeeded well enough to dismiss the sheet by itself.
        let completesRequest: Bool
    }

    static func of(_ outcome: SubmissionOutcome) -> Message {
        switch outcome {
        case .submitted(let response):
            switch response.status {
            case "pending", "processing": return Message(text: "已收藏", completesRequest: true)
            case "done": return Message(text: "已在库中", completesRequest: true)
            case "failed": return Message(text: "已在库中，解析失败", completesRequest: true)
            // The row is durable either way, so an unknown status still ends the
            // share; it just refuses to claim the link was saved.
            default: return Message(text: "提交失败", completesRequest: true)
            }
        case .scheduled, .queued(_, _):
            return Message(text: "已加入队列", completesRequest: true)
        case .staleClaim:
            return Message(text: "已加入队列", completesRequest: true)
        case .blocked(let state, _):
            return Message(text: blockedText(state), completesRequest: false)
        case .configurationRequired:
            return Message(text: "请先打开 WebTag 完成设置", completesRequest: false)
        case .noCandidate:
            return Message(text: "没找到链接", completesRequest: false)
        }
    }

    /// A blocked share always leaves the sheet open: every one of these needs
    /// the user to go and change something before a retry can work.
    private static func blockedText(_ state: QueueState) -> String {
        switch state {
        case .blockedAuth: return "凭证无效，请检查设置"
        case .blockedScope: return "API Key 缺少 write 权限"
        case .blockedQuota: return "配额已用完"
        case .blockedIdentity: return "身份已变更"
        default: return "提交失败"
        }
    }
}
