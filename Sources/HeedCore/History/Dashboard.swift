import Foundation

/// History's dashboard (`history.dashboard`): what the work amounted to over a range, from the event log and the
/// sessions heed knows. No model, no estimate where nothing was reported: agent time is the sum of `working`
/// stretches (marked an estimate when some were read from the screen), cost only where an agent reported one.
public struct Dashboard: Equatable, Sendable {
    /// The ranges `dashboard.range` steps through, in days.
    public static let ranges = [7, 28, 84]

    public struct Share: Equatable, Sendable {
        public var name: String
        public var seconds: TimeInterval
        public var estimated: Bool
    }

    public struct Recent: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var place: String
        public var startedAt: Date
        public var agentTime: TimeInterval
        /// In words: `merged`, `PR open`, `parked`, `working`, `closed`.
        public var outcome: String
    }

    public var days: Int
    public var start: Date
    public var sessions = 0
    public var agentTime: TimeInterval = 0
    public var estimated = false
    public var merged = 0
    public var answered = 0
    public var tokens = 0
    /// Only what agents reported; nil when none did.
    public var cost: Double?
    /// Agent time per day, from `start`, one entry per day.
    public var perDay: [TimeInterval] = []
    public var byAgent: [Share] = []
    public var byRepo: [Share] = []
    public var recent: [Recent] = []

    public init(days: Int, start: Date) {
        self.days = days
        self.start = start
    }

    /// Nothing was recorded in the range.
    public var isEmpty: Bool { sessions == 0 && agentTime == 0 && merged == 0 && answered == 0 }

    /// Builds it from the log's events (`state`, `session.started`, `pr.merged`, `question.answered`, any order) and
    /// the sessions heed knows, open and closed (for agents, repos, usage and outcomes the events do not carry).
    public static func build(
        events: [LoggedEvent], sessions: [Session], closed: [HistoryEntry], pulls: GitHubState, days: Int, now: Date,
        calendar: Calendar = .current
    ) -> Dashboard {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        var board = Dashboard(days: days, start: start)
        board.perDay = Array(repeating: 0, count: days)
        let known = Dictionary((sessions + closed.map(\.session)).map { ($0.id, $0) }) { first, _ in first }
        let ends = Dictionary(closed.map { ($0.id, $0) }) { first, _ in first }
        var agents: [String: String] = [:]
        var repos: [String: String] = [:]
        var started: [String: Date] = [:]
        for event in events where event.kind == .sessionStarted || event.kind == .sessionReopened {
            guard let id = event.session else { continue }
            if let agent = event.payload["agent"] { agents[id] = agent }
            if let repo = event.repo { repos[id] = repo }
            if event.kind == .sessionStarted, event.at >= start, event.at <= now {
                board.sessions += 1
                started[id] = event.at
            }
        }
        board.merged = Set(events.filter { $0.kind == .pullMerged && $0.at >= start && $0.at <= now }
            .compactMap(\.subject)).count
        board.answered = events.count { $0.kind == .questionAnswered && $0.at >= start && $0.at <= now }

        // Working stretches per session, cut to the range and split at midnight.
        var perAgent: [String: (TimeInterval, Bool)] = [:]
        var perRepo: [String: (TimeInterval, Bool)] = [:]
        var perSession: [String: TimeInterval] = [:]
        let states = Dictionary(grouping: events.filter { $0.kind == .state && $0.session != nil }) { $0.session! }
        for (id, list) in states {
            let sorted = list.sorted { $0.at < $1.at }
            for (index, event) in sorted.enumerated() where event.payload["state"] == AgentState.working.rawValue {
                let end = index + 1 < sorted.count ? sorted[index + 1].at : (ends[id]?.closedAt ?? now)
                var from = max(event.at, start)
                let to = min(end, now)
                guard to > from else { continue }
                while from < to {
                    let day = calendar.startOfDay(for: from)
                    let next = calendar.date(byAdding: .day, value: 1, to: day) ?? to
                    let slice = min(next, to).timeIntervalSince(from)
                    let offset = calendar.dateComponents([.day], from: start, to: day).day ?? 0
                    if board.perDay.indices.contains(offset) { board.perDay[offset] += slice }
                    from = min(next, to)
                }
                let worked = to.timeIntervalSince(max(event.at, start))
                board.agentTime += worked
                if event.guessed { board.estimated = true }
                perSession[id, default: 0] += worked
                let agent = known[id]?.agent ?? agents[id] ?? "unknown"
                let repo = known[id]?.repos.first?.name ?? repos[id].map { String($0.split(separator: "/").last ?? "") }
                    ?? (known[id]?.isChat == true ? "chats" : "unknown")
                perAgent[agent] = ((perAgent[agent]?.0 ?? 0) + worked, (perAgent[agent]?.1 ?? false) || event.guessed)
                perRepo[repo] = ((perRepo[repo]?.0 ?? 0) + worked, (perRepo[repo]?.1 ?? false) || event.guessed)
            }
        }
        func shares(_ map: [String: (TimeInterval, Bool)]) -> [Share] {
            map.map { Share(name: $0.key, seconds: $0.value.0, estimated: $0.value.1) }
                .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.name < $1.name }
        }
        board.byAgent = shares(perAgent)
        board.byRepo = shares(perRepo)

        // What the sessions started in the range used, as their agents reported it.
        var costs: [Double] = []
        for id in started.keys {
            guard let usage = known[id]?.usage else { continue }
            board.tokens += usage.tokens.allInput + usage.tokens.output
            if let cost = usage.costUSD { costs.append(cost) }
        }
        board.cost = costs.isEmpty ? nil : costs.reduce(0, +)

        board.recent = started.sorted { $0.value > $1.value }.prefix(8).compactMap { id, at in
            guard let session = known[id] else { return nil }
            return Recent(
                id: id, title: session.title,
                place: session
                    .isChat ? "chat" : (session.repos.first?.name ?? "") + (session.host.map { " @\($0)" } ?? ""),
                startedAt: at, agentTime: perSession[id] ?? 0,
                outcome: outcome(session, closed: ends[id], pulls: pulls)
            )
        }
        return board
    }

    /// The words a recent row says how it went with.
    static func outcome(_ session: Session, closed: HistoryEntry?, pulls: GitHubState) -> String {
        if let closed { return closed.outcome.rawValue }
        let states = session.trackedPRs.compactMap { pulls.pull($0)?.state }
        if !states.isEmpty, states.allSatisfy({ $0 == .merged }) { return "merged" }
        if states.contains(.open) { return "PR open" }
        if session.parked { return "parked" }
        return session.state.state == .working ? "working" : session.state.state.rawValue
    }

    /// The step (0 none, 1…4 more) a day's agent time falls in, against the busiest day: the heatmap's shades.
    public func level(_ seconds: TimeInterval) -> Int {
        guard seconds > 0, let most = perDay.max(), most > 0 else { return 0 }
        return min(4, max(1, Int((seconds / most * 4).rounded(.up))))
    }
}
