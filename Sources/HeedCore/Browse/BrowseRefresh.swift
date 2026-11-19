import Foundation

/// When Browse asks GitHub again on its own, and what it may do with the answer while you hold an item.
public enum BrowseRefreshPolicy {
    /// What brought you back.
    public enum Trigger: Equatable, Sendable {
        /// The view switched to Browse.
        case viewSwitch
        /// The app became active while Browse is in front.
        case appActive
        /// The window regained key while Browse is in front.
        case windowKey
    }

    /// Everything the decision reads, as plain values.
    public struct State: Equatable, Sendable {
        public var trigger = Trigger.viewSwitch
        public var autoRefresh = true
        /// Seconds the last answer for this very scope and query stays fresh.
        public var refreshAfter = BrowseSettings.defaultRefreshAfter
        /// Seconds since the last successful answer for this scope and query; nil: none this session.
        public var age: TimeInterval?
        /// A Browse fetch is running.
        public var inFlight = false
        /// Failed fetches in a row, and the seconds since the last one.
        public var failures = 0
        public var sinceFailure: TimeInterval?
        public var fixture = false
        /// Browse is the view in front (and its window the key one).
        public var frontIsBrowse = true
        /// There is a scope or a query to ask for.
        public var hasQuery = true
        // What holds the list still:
        /// The cursor row is the one the reader shows.
        public var cursorInReader = false
        public var picks = 0
        /// The reader is pushed over the list (half and third widths).
        public var readerPushed = false
        /// An agent run is live on an item.
        public var runLive = false
        /// The builder, the palette, a sheet or the org builder is open.
        public var overlayOpen = false
        /// A bulk form is open.
        public var bulkOpen = false

        public init() {}

        /// Something is selected: new, gone and reordered rows wait.
        public var holds: Bool {
            cursorInReader || picks > 0 || readerPushed || runLive || overlayOpen || bulkOpen
        }
    }

    /// Seconds to wait after `failures` failures in a row: `refreshAfter`, doubled each time, ten minutes at most.
    public static func backoff(failures: Int, refreshAfter: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(Double(max(refreshAfter, 1)) * pow(2, Double(min(failures, 10) - 1)), 600)
    }

    /// Whether to ask GitHub for the current scope and query now, and whether the new, gone and reordered rows of the
    /// answer must wait for you (a held item) instead of landing.
    public static func decide(state: State) -> (fetch: Bool, holdStructural: Bool) {
        let hold = state.holds
        guard !state.fixture, state.hasQuery, !state.inFlight else { return (false, hold) }
        // Off: entering Browse asks as it always did; coming back to the app or the window does nothing.
        if !state.autoRefresh { return (state.trigger == .viewSwitch, hold) }
        guard state.frontIsBrowse else { return (false, hold) }
        if let age = state.age, age < Double(state.refreshAfter) { return (false, hold) }
        if state.failures > 0, let since = state.sinceFailure,
           since < backoff(failures: state.failures, refreshAfter: state.refreshAfter) { return (false, hold) }
        return (true, hold)
    }
}

/// Making a held diff the list: the new rows, and where the cursor and the picks end up.
public enum BrowseRefreshApply {
    public struct Outcome: Equatable, Sendable {
        public var rows: [BrowseItem]
        /// The cursor's row index in `rows`.
        public var cursor: Int
        public var cursorID: String?
        /// The row the cursor was on is gone: the cursor moved to the nearest row that stayed.
        public var cursorGone = false
        /// Picked ids whose item is gone.
        public var droppedPicks: [String] = []
        /// The ids that came with this diff: the rows the list marks as new.
        public var fresh: Set<String> = []
        /// What to say once: the cursor's row gone, the picks gone.
        public var note: String?
    }

    /// `diff` applied to `current`. The cursor stays on its item by id; when that item is gone it goes to the nearest
    /// row below that stayed, else above. Picks stay by id, those gone are dropped and counted.
    public static func apply(
        _ diff: BrowseDiff, to current: [BrowseItem], cursorID: String?, cursorIndex: Int, picks: Set<String>
    ) -> Outcome {
        let rows = diff.target
        let index = Dictionary(rows.enumerated().map { ($1.id, $0) }) { first, _ in first }
        var outcome = Outcome(rows: rows, cursor: 0, cursorID: nil, fresh: Set(diff.added.map(\.id)))
        var notes: [String] = []
        if rows.isEmpty {
            outcome.cursor = 0
        } else if let cursorID, let at = index[cursorID] {
            outcome.cursor = at
            outcome.cursorID = cursorID
        } else if let cursorID, let was = current.firstIndex(where: { $0.id == cursorID }) {
            // Gone: the nearest row of the old list, after it first, that is still here.
            let stayers = (1 ..< max(current.count, 1)).flatMap { [was + $0, was - $0] }
                .filter { current.indices.contains($0) }
            let near = stayers.lazy.compactMap { index[current[$0].id] }.first
            outcome.cursor = near ?? min(max(cursorIndex, 0), rows.count - 1)
            outcome.cursorID = rows[outcome.cursor].id
            outcome.cursorGone = true
            notes.append("the item under the cursor is gone, the cursor moved to the nearest row")
        } else {
            outcome.cursor = min(max(cursorIndex, 0), rows.count - 1)
            outcome.cursorID = rows[outcome.cursor].id
        }
        outcome.droppedPicks = picks.filter { index[$0] == nil }.sorted()
        if !outcome.droppedPicks.isEmpty {
            let count = outcome.droppedPicks.count
            notes.append(count == 1 ? "1 picked item is gone" : "\(count) picked items are gone")
        }
        outcome.note = notes.isEmpty ? nil : notes.joined(separator: "; ")
        return outcome
    }

    /// The rows of `shown` that a fetch of `fetched` should have returned but did not: the ones GitHub no longer
    /// lists (closed, moved out of the view). A capped answer vouches only for items updated since its oldest, as it
    /// is the newest first.
    public static func gone(shown: [BrowseItem], fetched: [BrowseItem], capped: Bool) -> Set<String> {
        let have = Set(fetched.map(\.id))
        let floor = capped ? fetched.map(\.updatedAt).min() : nil
        if capped, floor == nil { return [] }
        return Set(shown.filter { item in
            guard !have.contains(item.id) else { return false }
            return floor.map { item.updatedAt >= $0 } ?? true
        }.map(\.id))
    }
}
