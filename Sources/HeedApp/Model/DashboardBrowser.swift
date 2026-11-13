import Foundation
import HeedCore
import Observation

/// Insights' dashboard (`history.dashboard`, where `gh` opens): the event log summed off the main actor for the range
/// and the one before it, twelve weeks of agent time, and the bests since the log began; the goals that moved; the
/// cursor on what shipped. Fixtures (and shots) read `Fixtures.dashboardEvents`, with no IO.
@MainActor
@Observable
final class DashboardBrowser {
    /// What the goals' records say, as Goals has them loaded.
    struct GoalsSource {
        var goals: [HeedGoal] = []
        var evidence: [GoalEvidence] = []
        var qualities: [String: GoalQuality] = [:]
    }

    private(set) var board = Dashboard(days: Dashboard.ranges[0], start: .distantPast)
    private(set) var range = Dashboard.ranges[0]
    private(set) var cursor = 0
    private(set) var moved: [DashboardGoals.Moved] = []
    private(set) var next: DashboardGoals.Next?
    /// No event log: nothing to sum.
    private(set) var unavailable = false
    @ObservationIgnored private let fixture: Bool
    @ObservationIgnored private var log: EventLog?
    @ObservationIgnored private var domain: () -> Domain = { .empty }
    @ObservationIgnored private var goals: () -> GoalsSource = { GoalsSource() }

    init(fixture: Bool) {
        self.fixture = fixture
    }

    func attach(log: EventLog?, domain: @escaping () -> Domain, goals: @escaping () -> GoalsSource) {
        self.log = log
        self.domain = domain
        self.goals = goals
    }

    /// The PR under the cursor, among what shipped.
    var selected: Dashboard.Shipped? { board.shipped.indices.contains(cursor) ? board.shipped[cursor] : nil }

    func setCursor(_ index: Int) {
        guard !board.shipped.isEmpty else { return }
        cursor = min(max(index, 0), board.shipped.count - 1)
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

    /// The kinds the board is summed from; `state` events are many, so they are read only as far back as it needs.
    static let light: [EventKind] = [
        .sessionStarted, .sessionReopened, .sessionClosed, .pullMerged, .questionAsked, .questionAnswered,
    ]

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
        // Agent time for the range, the one before it, and the calendar's twelve weeks.
        let back = max(Dashboard.calendarWeeks * 7 + 7, days * 2 + 1)
        let since = Calendar.current.date(byAdding: .day, value: -back, to: now) ?? now
        Task { [weak self] in
            guard let states = try? await log.events(from: since, kinds: [.state], limit: 500_000),
                  let rest = try? await log.events(kinds: Self.light, limit: 200_000) else { return }
            let board = await Task.detached(priority: .utility) {
                Dashboard.build(
                    events: states + rest, sessions: domain.sessions, closed: domain.history, pulls: domain.github,
                    days: days, now: now
                )
            }.value
            self?.apply(board)
        }
    }

    private func apply(_ fresh: Dashboard) {
        if fresh != board { board = fresh }
        cursor = min(cursor, max(board.shipped.count - 1, 0))
        let source = goals()
        let moved = DashboardGoals.moved(
            goals: source.goals, evidence: source.evidence, qualities: source.qualities, since: board.start,
            now: Clock.now
        )
        if moved != self.moved { self.moved = moved }
        let next = DashboardGoals.next(goals: source.goals, qualities: source.qualities)
        if next != self.next { self.next = next }
    }
}
