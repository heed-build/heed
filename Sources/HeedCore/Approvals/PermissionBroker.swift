import Foundation
import Synchronization

/// Heed's side of the permission round trip, keyed by ask id: who is waiting on each ask, and each answer once given.
/// A hook that lost its connection and comes back with the same ask joins it again instead of making a second one;
/// an answer is given once, and a hook that asks again after it gets that same answer. Answers are kept a while
/// (`keep`, at most `limit`), so a late or repeated ask never reaches the queue again.
public final class PermissionBroker: Sendable {
    /// How a hook's ask joins: a new one (to queue), one already waiting (a hook back after a drop), or one already
    /// answered (that answer, at once).
    public enum Join: Equatable, Sendable {
        case new
        case rejoined
        case answered(PermissionAnswer)
    }

    /// How long an answer is kept for a hook that asks again.
    public static let keep: TimeInterval = 600
    /// The most answers kept.
    public static let limit = 512

    private struct Entry {
        var answer: PermissionAnswer?
        var at: Date
        /// Connections waiting on this ask: a hook joins with each connection, and leaves when one closes.
        var attached = 0
        var waiters: [CheckedContinuation<PermissionAnswer, Never>] = []
    }

    private let entries = Mutex<[String: Entry]>([:])

    public init() {}

    /// A hook's ask arrives on a connection: it is counted as waiting until `detach`.
    public func join(_ id: String, now: Date = Date()) -> Join {
        entries.withLock { entries in
            Self.prune(&entries, now: now)
            if let answer = entries[id]?.answer { return .answered(answer) }
            if entries[id] != nil {
                entries[id]?.attached += 1
                return .rejoined
            }
            entries[id] = Entry(at: now, attached: 1)
            return .new
        }
    }

    /// Suspends until the ask is answered (at once when it was). Every hook waiting on it hears the same answer.
    public func wait(_ id: String) async -> PermissionAnswer {
        await withCheckedContinuation { continuation in
            let answer: PermissionAnswer? = entries.withLock { entries in
                if let answer = entries[id]?.answer { return answer }
                entries[id, default: Entry(at: Date())].waiters.append(continuation)
                return nil
            }
            if let answer { continuation.resume(returning: answer) }
        }
    }

    /// Answers the ask, once: false (and nothing changes) when it was answered before. An ask heed never saw is
    /// remembered as answered too, so if it arrives late it is not asked again.
    @discardableResult
    public func resolve(_ id: String, _ answer: PermissionAnswer, now: Date = Date()) -> Bool {
        let waiters: [CheckedContinuation<PermissionAnswer, Never>]? = entries.withLock { entries in
            guard entries[id]?.answer == nil else { return nil }
            let waiters = entries[id]?.waiters ?? []
            entries[id] = Entry(answer: answer, at: now)
            Self.prune(&entries, now: now)
            return waiters
        }
        guard let waiters else { return false }
        for waiter in waiters {
            waiter.resume(returning: answer)
        }
        return true
    }

    /// One connection waiting on the ask closed. True when it is still unanswered and no hook waits on it any more.
    public func detach(_ id: String) -> Bool {
        entries.withLock { entries in
            guard var entry = entries[id], entry.answer == nil else { return false }
            entry.attached = max(entry.attached - 1, 0)
            entries[id] = entry
            return entry.attached == 0
        }
    }

    /// Whether the ask is known and still unanswered, with no hook waiting on it.
    public func abandoned(_ id: String) -> Bool {
        entries.withLock { entries in
            guard let entry = entries[id] else { return false }
            return entry.answer == nil && entry.attached == 0
        }
    }

    /// Whether the ask is known and not yet answered.
    public func isOpen(_ id: String) -> Bool {
        entries.withLock { $0[id].map { $0.answer == nil } ?? false }
    }

    /// Answers older than `keep` go, then the oldest past `limit`; asks still waiting are never dropped.
    private static func prune(_ entries: inout [String: Entry], now: Date) {
        entries = entries.filter { $0.value.answer == nil || now.timeIntervalSince($0.value.at) < keep }
        let answered = entries.filter { $0.value.answer != nil }
        guard answered.count > limit else { return }
        for (id, _) in answered.sorted(by: { $0.value.at < $1.value.at }).prefix(answered.count - limit) {
            entries[id] = nil
        }
    }
}
