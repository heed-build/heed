import Foundation
import HeedCore
import Observation

/// What Insights › History shows: the sessions that ended as pieces of work by day (`HistoryFeed`), each with its
/// story from the event log's last `days` days (`Timeline.items`), narrowed by the outcome, the timeline's filters and
/// `/`; every event as its own line when unfolded (`history.events`). The cursor, and the facts of the line under it.
/// Reads run on the event log's actor; while History is open it reads again every five seconds. Fixtures (and shots)
/// read `Fixtures.events`, with no IO.
@MainActor
@Observable
final class HistoryBrowser {
    /// How far back it reads events.
    static let days = 30

    private(set) var items: [TimelineItem] = []
    private(set) var entries: [HistoryEntry] = []
    /// What the narrowing leaves, by day.
    private(set) var feed = HistoryFeed()
    private(set) var narrowing = HistoryFeed.Narrowing()
    private(set) var cursor = 0
    /// The facts of the line under the cursor (its session's agent time, its worktree's life).
    private(set) var facts = TimelineFacts()
    /// No event log: the work is listed without its stories.
    private(set) var unavailable = false
    @ObservationIgnored private var events: [LoggedEvent] = []
    @ObservationIgnored private var live: Task<Void, Never>?
    @ObservationIgnored private let fixture: Bool
    @ObservationIgnored private var log: EventLog?
    @ObservationIgnored private var domain: () -> Domain = { .empty }

    init(fixture: Bool) {
        self.fixture = fixture
    }

    /// Where to read from, and the domain the lines are told against (titles, chats, which worktrees still exist).
    func attach(log: EventLog?, domain: @escaping () -> Domain) {
        self.log = log
        self.domain = domain
    }

    var lines: [HistoryFeed.Line] { feed.lines }
    var selected: HistoryFeed.Line? { lines.indices.contains(cursor) ? lines[cursor] : nil }
    var outcome: Outcome? { narrowing.outcome }
    var filter: TimelineFilter { narrowing.filter }
    var everyEvent: Bool { narrowing.everyEvent }

    /// The history entry of the line under the cursor: its work, or the session its event is about.
    var selectedEntry: HistoryEntry? {
        switch selected {
        case let .work(work): work.entry
        case let .event(item): item.session.flatMap { id in entries.first { $0.id == id } }
        case nil: nil
        }
    }

    /// The repos and places to filter by.
    var choices: (repos: [String], places: [String]) { HistoryFeed.choices(entries: entries, items: items) }
    var outcomeCounts: [Outcome: Int] { HistoryFeed.outcomeCounts(entries: entries, narrowing: narrowing) }
    var repoCounts: [String: Int] { HistoryFeed.repoCounts(entries: entries) }

    /// The story of a session that ended, oldest first, whatever the filters (the detail tells it whole).
    func story(of id: String) -> [TimelineItem] {
        items.filter { $0.session == id }.sorted { $0.at < $1.at }
    }

    func opened() {
        reload()
        guard !fixture, live == nil else { return }
        live = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.reload()
            }
        }
    }

    func closed() {
        live?.cancel()
        live = nil
    }

    func setCursor(_ index: Int) {
        guard !lines.isEmpty else { return }
        cursor = min(max(index, 0), lines.count - 1)
        loadFacts()
    }

    /// The sessions that ended, as the domain has them now.
    func setEntries(_ fresh: [HistoryEntry]) {
        guard fresh != entries else { return }
        entries = fresh
        rebuild()
    }

    func setSearch(_ text: String) {
        guard text != narrowing.search else { return }
        narrowing.search = text
        cursor = 0
        rebuild()
    }

    func change(_ edit: (inout TimelineFilter) -> Void) {
        var next = narrowing.filter
        edit(&next)
        guard next != narrowing.filter else { return }
        narrowing.filter = next
        cursor = 0
        rebuild()
    }

    /// `history.outcome`: the next outcome, or the one named.
    func cycleOutcome(named words: [String]) {
        narrowing.outcome = Outcome.filter(after: narrowing.outcome, named: words)
        cursor = 0
        rebuild()
    }

    /// `history.events`: every event as its own line, or folded into its work again. The cursor stays on what it was
    /// on: a piece of work unfolds to its last event, an event folds into its work.
    func toggleEvents() {
        let session = selected?.session
        narrowing.everyEvent.toggle()
        rebuild(keeping: nil)
        if let session, let index = lines.firstIndex(where: { $0.session == session }) {
            cursor = index
            loadFacts()
        }
    }

    func reload() {
        if fixture {
            apply(Fixtures.events)
            return
        }
        guard let log else {
            unavailable = true
            return
        }
        let since = Clock.now.addingTimeInterval(-TimeInterval(Self.days) * 86400)
        Task { [weak self] in
            guard let events = try? await log.events(from: since, kinds: Timeline.kinds, limit: 5000) else { return }
            self?.apply(events)
        }
    }

    private func apply(_ fresh: [LoggedEvent]) {
        events = fresh
        let next = Timeline.items(from: fresh, domain: domain())
        guard next != items else { return }
        items = next
        rebuild()
    }

    /// Only what changed is written; the cursor stays on its line.
    private func rebuild() {
        rebuild(keeping: selected?.id)
    }

    private func rebuild(keeping current: String?) {
        let fresh = HistoryFeed.build(entries: entries, items: items, narrowing: narrowing, now: Clock.now)
        if fresh != feed { feed = fresh }
        if let current, let index = lines.firstIndex(where: { $0.id == current }) {
            cursor = index
        } else {
            cursor = min(cursor, max(lines.count - 1, 0))
        }
        loadFacts()
    }

    /// The selected line's facts: its worktree's life from the loaded events, its session's agent time from that
    /// session's `state` events (read on demand: there are many).
    private func loadFacts() {
        guard let line = selected else {
            facts = TimelineFacts()
            return
        }
        let item: TimelineItem? = switch line {
        case let .event(item): item
        case let .work(work): work.story.last { $0.worktree != nil } ?? work.story.first
        }
        guard let item else {
            facts = TimelineFacts()
            return
        }
        let events = events
        let now = Clock.now
        if fixture || item.session == nil {
            let states = fixture ? Fixtures.events.filter { $0.kind == .state } : []
            facts = Timeline.facts(for: item, events: events, states: states, now: now)
            return
        }
        guard let log, let session = item.session else { return }
        let id = line.id
        Task { [weak self] in
            let states = await (try? log.events(session: session, kinds: [.state], limit: 5000)) ?? []
            guard self?.selected?.id == id else { return }
            self?.facts = Timeline.facts(for: item, events: events, states: states, now: now)
        }
    }
}
