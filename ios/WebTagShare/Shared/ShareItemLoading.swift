import Foundation
import UniformTypeIdentifiers

/// The representations the share extension is willing to read from an
/// attachment.
///
/// Both kinds are loaded for every provider that declares them. A provider that
/// answers a URL can still carry a different link in its text - a "share" from a
/// reader app typically registers the canonical URL plus a quote that contains
/// the real article link - so neither kind may suppress the other.
enum ShareRepresentationKind: String, CaseIterable {
    case url
    case plainText

    var contentType: UTType {
        switch self {
        case .url: return .url
        case .plainText: return .plainText
        }
    }
}

/// Where one representation sits in the frozen input order: extension item,
/// then attachment, then the provider's own registration order.
///
/// Candidates are emitted in this order no matter which callback lands first,
/// so a slow provider cannot reshuffle the list under the user's finger.
struct ShareRepresentationRequest: Equatable {
    let itemIndex: Int
    let attachmentIndex: Int
    let kind: ShareRepresentationKind
}

/// Best-effort cancellation for a load that is still in flight when the shared
/// deadline passes.
protocol ShareLoadCancelling: AnyObject {
    func cancelLoad()
}

extension Progress: ShareLoadCancelling {
    func cancelLoad() { cancel() }
}

/// The slice of `NSItemProvider` the collector depends on, so the ordering and
/// deadline rules can be exercised with providers that never answer.
protocol ShareRepresentationLoading: AnyObject {
    /// Kinds this attachment declares, in registration order.
    var declaredRepresentations: [ShareRepresentationKind] { get }

    /// Starts the load. The collector tolerates repeated or late completions,
    /// but every call must eventually be safe to ignore.
    func loadRepresentation(
        _ kind: ShareRepresentationKind,
        completion: @escaping (String?) -> Void
    ) -> ShareLoadCancelling?
}

extension NSItemProvider: ShareRepresentationLoading {
    var declaredRepresentations: [ShareRepresentationKind] {
        var ordered: [ShareRepresentationKind] = []
        for identifier in registeredTypeIdentifiers {
            guard let type = UTType(identifier) else { continue }
            for kind in ShareRepresentationKind.allCases
            where !ordered.contains(kind) && type.conforms(to: kind.contentType) {
                ordered.append(kind)
            }
        }
        // A dynamically declared type is absent from `registeredTypeIdentifiers`
        // on some hosts while conformance still resolves; without this pass such
        // an attachment would be dropped without ever being asked.
        for kind in ShareRepresentationKind.allCases
        where !ordered.contains(kind) && hasItemConformingToTypeIdentifier(kind.contentType.identifier) {
            ordered.append(kind)
        }
        return ordered
    }

    func loadRepresentation(
        _ kind: ShareRepresentationKind,
        completion: @escaping (String?) -> Void
    ) -> ShareLoadCancelling? {
        // `loadObject` is used rather than `loadItem` because it is the only
        // typed loader that hands back a `Progress`, which is what makes the
        // deadline able to stop work instead of merely ignoring it.
        switch kind {
        case .url:
            return loadObject(ofClass: URL.self) { value, _ in completion(value?.absoluteString) }
        case .plainText:
            return loadObject(ofClass: String.self) { value, _ in completion(value) }
        }
    }
}

/// A clock that only moves forward.
///
/// The share budget must not be measured against wall time: `Date()` jumps when
/// NTP or the user corrects the clock, which would either cut the budget to zero
/// or stretch it far past the point where iOS kills the extension.
protocol ShareMonotonicClock: AnyObject {
    var nowSeconds: TimeInterval { get }
    func schedule(after delay: TimeInterval, _ body: @escaping () -> Void)
}

final class SystemMonotonicClock: ShareMonotonicClock {
    private let queue: DispatchQueue

    init(queue: DispatchQueue = DispatchQueue.global(qos: .userInitiated)) {
        self.queue = queue
    }

    var nowSeconds: TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    func schedule(after delay: TimeInterval, _ body: @escaping () -> Void) {
        queue.asyncAfter(deadline: .now() + max(0, delay), execute: body)
    }
}

/// Resolves at most once and remembers the answer.
///
/// Both deadlines race a callback against a timer, and both resume a
/// `CheckedContinuation`, which traps the process if it is resumed twice. The
/// single-shot guarantee - including for a caller that only starts awaiting
/// after the race is already decided - is therefore load-bearing, not a
/// convenience.
///
/// Unchecked rather than checked: every deadline in this module hands the gate
/// to a timer on one queue and to a `Task` on another, and the `NSLock` above -
/// not the compiler - is what makes that safe.
final class ShareSingleShotGate<Value>: @unchecked Sendable {
    private enum State {
        case pending
        case resolved(Value)
    }

    private let lock = NSLock()
    private var state: State = .pending
    private var waiters: [CheckedContinuation<Value, Never>] = []

    /// Returns true only for the caller that actually decided the race.
    @discardableResult
    func resolve(_ value: Value) -> Bool {
        lock.lock()
        guard case .pending = state else {
            lock.unlock()
            return false
        }
        state = .resolved(value)
        let pending = waiters
        waiters = []
        lock.unlock()
        for continuation in pending { continuation.resume(returning: value) }
        return true
    }

    func value() async -> Value {
        await withCheckedContinuation { continuation in
            lock.lock()
            if case .resolved(let value) = state {
                lock.unlock()
                continuation.resume(returning: value)
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}
