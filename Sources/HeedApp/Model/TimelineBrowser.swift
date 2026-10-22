import Foundation
import HeedCore
import Observation

/// What History's timeline shows: the event log's last `days` days as lines (`Timeline.items`), narrowed by the filters
/// and `/`, the cursor, and the facts of the line under it. Reads run on the event log's actor; while the timeline is
/// open it reads again every five seconds. Fixtures (and shots) read `Fixtures.events`, with no IO.
@MainActor
@Observable
final class TimelineBrowser {
    /// How far back it reads.
    static let days = 30

    private(set) var items: [TimelineItem] = []
    /// `items` the filters and `/` leave, newest first.
    private(set) var rows: [TimelineItem] = []
    private(set) var cursor = 0
    private(set) var filter = TimelineFilter()
    /// The facts of the line under the cursor.
    private(set) var facts = TimelineFacts()
    /// No event log: nothing to show.
    private(set) var unavailable = false
    @ObservationIgnored private var events: [LoggedEvent] = []
    @ObservationIgnored private var search = ""
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

    var selected: TimelineItem? { rows.indices.contains(cursor) ? rows[cursor] : nil }

    /// The repos and places the lines are in, for the filters.
    var choices: (repos: [String], places: [String]) { Timeline.choices(items) }

    var dayGroups: [Timeline.Day] { Timeline.days(rows, now: Clock.now) }

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
        guard !rows.isEmpty else { return }
        cursor = min(max(index, 0), rows.count - 1)
        loadFacts()
    }

    func setSearch(_ text: String) {
        guard text != search else { return }
        search = text
        cursor = 0
        refilter()
    }

    func change(_ edit: (inout TimelineFilter) -> Void) {
        var next = filter
        edit(&next)
        guard next != filter else { return }
        filter = next
        cursor = 0
        refilter()
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
        if next != items { items = next }
        refilter()
    }

    /// Only what changed is written; the cursor stays on its line.
    private func refilter() {
        let current = selected?.id
        let fresh = items.filter { item in
            filter.matches(item) && FilterQuery.matches(
                search, [item.lead, item.name, item.detail, item.badge, item.place, item.repo ?? ""]
            )
        }
        if fresh != rows { rows = fresh }
        if let current, let index = rows.firstIndex(where: { $0.id == current }) {
            cursor = index
        } else {
            cursor = min(cursor, max(rows.count - 1, 0))
        }
        loadFacts()
    }

    /// The selected line's facts: its worktree's life from the loaded events, its session's agent time from that
    /// session's `state` events (read on demand: there are many).
    private func loadFacts() {
        guard let item = selected else {
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
        Task { [weak self] in
            let states = await (try? log.events(session: session, kinds: [.state], limit: 5000)) ?? []
            guard self?.selected?.id == item.id else { return }
            self?.facts = Timeline.facts(for: item, events: events, states: states, now: now)
        }
    }
}
