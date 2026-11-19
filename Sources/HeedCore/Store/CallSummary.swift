import Foundation

/// What a call log row says about a retry: the page size a GitHub call asked for and which attempt it was. Kept in the
/// row's `detail` under `heed.` keys, which no GraphQL variable shares (no schema change: an old row has none and
/// reads as an ordinary call).
public struct CallRetry: Equatable, Sendable {
    /// Nodes the page asked for.
    public var pageSize: Int
    /// 0 for the first ask of a page, 1 for the retry after its failure, and so on.
    public var attempt: Int
    /// The heavy parts of a pull request were left out (the ladder's last rung).
    public var light: Bool

    public init(pageSize: Int, attempt: Int = 0, light: Bool = false) {
        self.pageSize = pageSize
        self.attempt = attempt
        self.light = light
    }

    public static let pageKey = "heed.page"
    public static let attemptKey = "heed.retry"
    public static let lightKey = "heed.light"
    /// The keys the row's detail pane shows as fields, not as one more block of text.
    public static let keys: Set<String> = [pageKey, attemptKey, lightKey]

    /// What is written next to a call's other detail.
    public var detail: [String: String] {
        var detail = [Self.pageKey: String(pageSize)]
        if attempt > 0 { detail[Self.attemptKey] = String(attempt) }
        if light { detail[Self.lightKey] = "1" }
        return detail
    }

    /// The marker a row carries; nil for any call that did not say (every call before this, and every other caller).
    public init?(_ call: LoggedCall) {
        guard let page = call.detail[Self.pageKey].flatMap({ Int($0) }), page > 0 else { return nil }
        self.init(
            pageSize: page, attempt: max(call.detail[Self.attemptKey].flatMap { Int($0) } ?? 0, 0),
            light: call.detail[Self.lightKey] == "1"
        )
    }

    public var isRetry: Bool { attempt > 0 }

    /// `retry · 50/page` on a retry, `100/page` on the first ask; `light` when the heavy parts were left out.
    public var chip: String {
        let page = "\(pageSize)/page" + (light ? " · light" : "")
        return isRetry ? "retry · \(page)" : page
    }
}

/// One caller's numbers over the calls shown: how often it ran, how often it failed, how long it took, and what it
/// cost GitHub's rate limit.
public struct CallerSummary: Equatable, Sendable, Identifiable {
    public var caller: String
    public var calls: Int
    public var failures: Int
    /// Retries among them (GitHub calls that were an ask again).
    public var retries: Int
    public var median: TimeInterval
    public var p95: TimeInterval
    /// Rate-limit points the calls spent, from those that said.
    public var rateCost: Int
    public var id: String { caller }

    /// Callers by how much is wrong first (failures), then by how often they ran, then by name.
    public static func of(_ rows: [LoggedCall]) -> [CallerSummary] {
        let grouped = Dictionary(grouping: rows, by: \.caller)
        return grouped.map { caller, calls in
            let took = calls.map(\.duration).sorted()
            return CallerSummary(
                caller: caller, calls: calls.count, failures: calls.count(where: \.failed),
                retries: calls.count(where: { CallRetry($0)?.isRetry == true }),
                median: percentile(took, 0.5), p95: percentile(took, 0.95),
                rateCost: calls.reduce(0) { $0 + ($1.rateCost ?? 0) }
            )
        }
        .sorted { ($1.failures, $1.calls, $0.caller) < ($0.failures, $0.calls, $1.caller) }
    }

    /// The nearest-rank percentile of an ascending list: the smallest value at least `fraction` of them are at or
    /// below.
    static func percentile(_ sorted: [TimeInterval], _ fraction: Double) -> TimeInterval {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}

public extension CallLogQuery {
    /// The view as `log.see` opens it: this caller's calls, whatever else was filtered.
    static func seeing(caller: String) -> CallLogQuery {
        var query = CallLogQuery()
        query.caller = caller
        return query
    }

    /// Every caller, then each of `known` in turn (`log.callers`); a name sets it, the same name again goes back to
    /// every caller.
    mutating func cycleCaller(among known: [String], named: String? = nil) {
        if let named {
            caller = named == "all" || caller == named ? nil : named
            return
        }
        let order: [String?] = [nil] + known.sorted()
        let index = order.firstIndex { $0 == caller } ?? 0
        caller = order[(index + 1) % order.count]
    }
}

public enum CallLogSelection {
    /// The row to put the cursor on when the view opens on a failure: the newest call that failed (rows are newest
    /// first), else the newest call.
    public static func newestFailed(in rows: [LoggedCall]) -> Int? {
        rows.firstIndex(where: \.failed) ?? (rows.isEmpty ? nil : 0)
    }
}
