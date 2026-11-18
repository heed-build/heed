import Foundation

/// What the reader's "heed's read" card and a row's columns show for one item: always one of these.
public enum BrowseReadState: Hashable, Sendable {
    /// No read, and none being written: the row is hatched and says unread.
    case unread
    /// Waiting its turn in the ahead queue, or running.
    case reading(SummaryRun)
    case upToDate(BrowseRead)
    /// The item changed after the read; the old read stays, dimmed, with a re-read on offer.
    case stale(BrowseRead)
    case failed(SummaryFailure, previous: BrowseRead?)
    case off(SummaryCardState.Off)

    public static func of(
        read: BrowseRead?, item: BrowseItem, run: SummaryRun?, failure: SummaryFailure?, mode: AttentionSummaryMode,
        modelCalls: Bool
    ) -> BrowseReadState {
        if let run { return .reading(run) }
        if let failure, read.map({ $0.readAt < failure.at }) ?? true { return .failed(failure, previous: read) }
        if let read { return read.isStale(for: item) ? .stale(read) : .upToDate(read) }
        if !modelCalls { return .off(.modelCalls) }
        if mode == .off { return .off(.summaries) }
        return .unread
    }

    public var read: BrowseRead? {
        switch self {
        case let .upToDate(read), let .stale(read): read
        case let .failed(_, previous): previous
        case .unread, .reading, .off: nil
        }
    }

    /// `up to date`, `stale`, `reading…`, `queued`, `failed`, `unread`, `off`.
    public var chip: String {
        switch self {
        case .unread: "unread"
        case let .reading(run): run.queued ? "queued" : "reading…"
        case .upToDate: "up to date"
        case .stale: "stale"
        case .failed: "failed"
        case .off: "off"
        }
    }

    public func line(item _: BrowseItem, now: Date) -> String {
        switch self {
        case .unread: return "not read yet"
        case let .reading(run):
            if run.queued { return "waiting its turn in the queue" }
            let who = CatchUp.writer(agent: run.agent, model: run.model) ?? "waiting for a model call"
            return "\(who), started \(CatchUp.age(run.startedAt, now: now))"
        case let .upToDate(read):
            return "read \(CatchUp.age(read.readAt, now: now))" + (read.writer.map { " by \($0)" } ?? "")
        case let .stale(read):
            return "read \(CatchUp.age(read.readAt, now: now)); the item changed since"
        case let .failed(failure, _): return failure.text
        case let .off(reason): return reason.text
        }
    }
}

/// When heed reads an item, and the ahead queue over a view's top rows.
public enum BrowseReadQueue {
    public enum Trigger: Hashable, Sendable {
        /// The top rows of the view, after a view settled.
        case ahead
        /// The cursor rested on the item.
        case open
        /// `U`: always, while model calls are on.
        case asked
    }

    /// Whether `item` should be read now. A read that is not stale is never read again but by asking.
    public static func due(
        _ item: BrowseItem, read: BrowseRead?, trigger: Trigger, mode: AttentionSummaryMode, readAhead: Int,
        modelCalls: Bool, failure: SummaryFailure?, running: Bool, now: Date, backoff: TimeInterval
    ) -> Bool {
        guard modelCalls, !running else { return false }
        if trigger == .asked { return true }
        guard mode != .off else { return false }
        if trigger == .ahead, mode != .ahead || readAhead <= 0 { return false }
        if let read, !read.isStale(for: item) { return false }
        if let failure, !failure.mayRetry(updatedAt: item.updatedAt, now: now, backoff: backoff) { return false }
        return true
    }

    /// The ahead queue: the first `top` rows that are due, in the order of the list, cut at `budget`. Returns the ids
    /// in order and how many were left out for the budget.
    public static func ahead(
        _ rows: [BrowseItem], top: Int, budget: Int, due: (BrowseItem) -> Bool
    ) -> (ids: [String], cut: Int) {
        let wanted = rows.prefix(max(top, 0)).filter(due)
        let take = max(0, min(budget, wanted.count))
        return (wanted.prefix(take).map(\.id), wanted.count - take)
    }
}
