import Foundation
import HeedCore
import Observation

/// History's dashboard (`history.dashboard`): the event log's last `range` days, summed off the main actor, and the
/// cursor on its recent sessions. Fixtures (and shots) read `Fixtures.dashboardEvents`, with no IO.
@MainActor
@Observable
final class DashboardBrowser {
    private(set) var board = Dashboard(days: Dashboard.ranges[1], start: .distantPast)
    private(set) var range = Dashboard.ranges[1]
    private(set) var cursor = 0
    /// No event log: nothing to sum.
    private(set) var unavailable = false
    @ObservationIgnored private let fixture: Bool
    @ObservationIgnored private var log: EventLog?
    @ObservationIgnored private var domain: () -> Domain = { .empty }

    init(fixture: Bool) {
        self.fixture = fixture
    }

    func attach(log: EventLog?, domain: @escaping () -> Domain) {
        self.log = log
        self.domain = domain
    }

    var selected: Dashboard.Recent? { board.recent.indices.contains(cursor) ? board.recent[cursor] : nil }

    func setCursor(_ index: Int) {
        guard !board.recent.isEmpty else { return }
        cursor = min(max(index, 0), board.recent.count - 1)
    }

    /// `dashboard.range`: the next range, or the one named in days.
    func cycleRange(_ named: String?) {
        if let named, let days = Int(named.filter(\.isNumber)), days > 0 {
            range = named.hasSuffix("w") ? days * 7 : days
        } else {
            let index = Dashboard.ranges.firstIndex(of: range) ?? 0
            range = Dashboard.ranges[(index + 1) % Dashboard.ranges.count]
        }
        reload()
    }

    func reload() {
        let domain = domain()
        let days = range
        let now = Clock.now
        if fixture {
            apply(Dashboard.build(
                events: Fixtures.dashboardEvents, sessions: domain.sessions, closed: domain.history,
                pulls: domain.github, days: days, now: now
            ))
            return
        }
        guard let log else {
            unavailable = true
            return
        }
        let since = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        Task { [weak self] in
            guard let events = try? await log.events(
                from: since, kinds: [.state, .sessionStarted, .sessionReopened, .pullMerged, .questionAnswered],
                limit: 500_000
            ) else { return }
            let board = await Task.detached(priority: .utility) {
                Dashboard.build(
                    events: events, sessions: domain.sessions, closed: domain.history, pulls: domain.github,
                    days: days, now: now
                )
            }.value
            self?.apply(board)
        }
    }

    private func apply(_ fresh: Dashboard) {
        if fresh != board { board = fresh }
        cursor = min(cursor, max(board.recent.count - 1, 0))
    }
}
