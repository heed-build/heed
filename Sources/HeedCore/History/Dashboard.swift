import Foundation

/// Insights' dashboard (`history.dashboard`): what the work amounted to over a range, set against the range before
/// it, from the event log and the sessions heed knows. No model, no estimate where nothing was reported: agent time is
/// the sum of `working` stretches (marked an estimate when some were read from the screen), cost only where an agent
/// reported one, a wait for you from a question's `question.asked` to its `question.answered`.
public struct Dashboard: Equatable, Sendable {
    /// The ranges `dashboard.range` steps through, in days.
    public static let ranges = [7, 28, 84]
    /// The calendar's length: twelve weeks of agent time per day (this one so far and the eleven before it), whatever
    /// the range.
    public static let calendarWeeks = 12

    public struct Share: Equatable, Sendable {
        public var name: String
        public var seconds: TimeInterval
        public var estimated: Bool
    }

    /// A PR merged in the range: what it was, where, by which agent, and how long from its session's start.
    public struct Shipped: Equatable, Sendable, Identifiable {
        /// `org/name#12`.
        public var ref: String
        public var title: String
        /// `org/name`.
        public var repo: String
        public var number: Int?
        public var agent: String?
        public var session: String?
        public var mergedAt: Date
        /// From its session's start to the merge; nil when the log did not see the session start.
        public var took: TimeInterval?
        public var id: String { ref }

        public var pull: PullRef? {
            let parts = repo.split(separator: "/", maxSplits: 1)
            guard parts.count == 2, let number else { return nil }
            return PullRef(repo: Repo(org: String(parts[0]), name: String(parts[1])), number: number)
        }
    }

    /// A personal best: what, how much, and when or what it was.
    public struct Best: Equatable, Sendable {
        public enum Kind: String, Sendable {
            case fastestMerge, mostAtOnce, longestStreak, mostInADay
        }

        public var kind: Kind
        public var value: String
        public var detail: String
        /// The best is from this range.
        public var current: Bool
    }

    /// One agent's record in the range: what its sessions that ended came to, and its working time.
    public struct AgentScore: Equatable, Sendable {
        public var agent: String
        public var merged = 0
        public var abandoned = 0
        /// Sessions that ended, however.
        public var ended = 0
        public var seconds: TimeInterval = 0
        public var estimated = false
    }

    public var days: Int
    public var start: Date
    public var sessions = 0
    public var agentTime: TimeInterval = 0
    public var agentTimeBefore: TimeInterval = 0
    public var estimated = false
    public var merged = 0
    public var mergedBefore = 0
    public var answered = 0
    /// Most agents working at the same moment in the range.
    public var mostAtOnce = 0
    /// The median wait from an agent asking to your answer, in the range and the one before; nil with none.
    public var medianWait: TimeInterval?
    public var medianWaitBefore: TimeInterval?
    /// Every wait in the range, summed, and the longest.
    public var waited: TimeInterval = 0
    public var longestWait: TimeInterval?
    public var tokens = 0
    /// Only what agents reported; nil when none did.
    public var cost: Double?
    public var costBefore: Double?
    /// Agent time per day, from `start`, one entry per day.
    public var perDay: [TimeInterval] = []
    public var mergedPerDay: [Int] = []
    /// The median wait each day (0: no question that day).
    public var waitPerDay: [TimeInterval] = []
    /// Reported cost of the sessions started each day.
    public var costPerDay: [Double] = []
    /// Agent time per day over `calendarWeeks` weeks, Monday `calendarStart` to today.
    public var calendar: [TimeInterval] = []
    public var calendarStart: Date
    /// Days in a row with something merged, up to today (or yesterday, while today has none yet).
    public var streak = 0
    public var shipped: [Shipped] = []
    public var fastest: TimeInterval?
    public var medianToMerge: TimeInterval?
    public var bests: [Best] = []
    /// The first day the log has anything: what "since" the bests mean.
    public var since: Date?
    public var agents: [AgentScore] = []
    public var byAgent: [Share] = []
    public var byRepo: [Share] = []

    public init(days: Int, start: Date) {
        self.days = days
        self.start = start
        calendarStart = start
    }

    /// Nothing was recorded in the range.
    public var isEmpty: Bool { sessions == 0 && agentTime == 0 && merged == 0 && answered == 0 }

    /// What was reported per merged PR; nil without a cost or a merge.
    public var costPerMerge: Double? { cost.flatMap { merged > 0 ? $0 / Double(merged) : nil } }
    public var costPerMergeBefore: Double? {
        costBefore.flatMap { mergedBefore > 0 ? $0 / Double(mergedBefore) : nil }
    }

    /// A working stretch of a session's agent.
    struct Stretch {
        var session: String
        var from: Date
        var to: Date
        var guessed: Bool
    }

    /// Builds it from the log's events (`state`, `session.started`, `session.reopened`, `session.closed`,
    /// `pr.merged`, `question.asked`, `question.answered`, any order, as far back as there are) and the sessions heed
    /// knows, open and closed (for titles, agents, repos and usage the events do not carry).
    public static func build(
        events: [LoggedEvent], sessions: [Session], closed: [HistoryEntry], pulls: GitHubState, days: Int, now: Date,
        calendar: Calendar = .current
    ) -> Dashboard {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        let before = calendar.date(byAdding: .day, value: -days, to: start) ?? start
        var board = Dashboard(days: days, start: start)
        board.calendarStart = calendarStart(today: today, calendar: calendar)
        let calendarLength = (calendar.dateComponents([.day], from: board.calendarStart, to: today).day ?? 0) + 1
        board.mergedPerDay = Array(repeating: 0, count: days)
        board.waitPerDay = Array(repeating: 0, count: days)
        board.costPerDay = Array(repeating: 0, count: days)
        board.since = events.map(\.at).min()
        func offset(_ date: Date, from origin: Date) -> Int {
            calendar.dateComponents([.day], from: origin, to: calendar.startOfDay(for: date)).day ?? -1
        }
        func inRange(_ date: Date) -> Bool { date >= start && date <= now }
        func inBefore(_ date: Date) -> Bool { date >= before && date < start }

        let known = Dictionary((sessions + closed.map(\.session)).map { ($0.id, $0) }) { first, _ in first }
        let ends = Dictionary(closed.map { ($0.id, $0) }) { first, _ in first }
        var agents: [String: String] = [:]
        var repos: [String: String] = [:]
        var titles: [String: String] = [:]
        var chats: Set<String> = []
        var startedAt: [String: Date] = [:]
        var started: [String: Date] = [:]
        var startedBefore: [String] = []
        for event in events where event.kind == .sessionStarted || event.kind == .sessionReopened {
            guard let id = event.session else { continue }
            if let agent = event.payload["agent"] { agents[id] = agent }
            if let repo = event.repo { repos[id] = repo }
            if !event.text.isEmpty { titles[id] = event.text }
            if event.payload["chat"] != nil { chats.insert(id) }
            guard event.kind == .sessionStarted else { continue }
            startedAt[id] = min(startedAt[id] ?? event.at, event.at)
            if inRange(event.at) {
                board.sessions += 1
                started[id] = event.at
            } else if inBefore(event.at) {
                startedBefore.append(id)
            }
        }
        func agent(of id: String?) -> String? { id.flatMap { known[$0]?.agent ?? agents[$0] } }
        func repoName(of id: String) -> String {
            known[id]?.repos.first?.name ?? repos[id].map { String($0.split(separator: "/").last ?? "") }
                ?? (known[id]?.isChat == true || chats.contains(id) ? "chats" : "unknown")
        }

        // Merges: the first time the log saw each PR merged.
        var merges: [String: LoggedEvent] = [:]
        for event in events where event.kind == .pullMerged {
            guard let ref = event.subject else { continue }
            if let seen = merges[ref], seen.at <= event.at { continue }
            merges[ref] = event
        }
        for merge in merges.values {
            if inRange(merge.at) {
                board.merged += 1
                let day = offset(merge.at, from: start)
                if board.mergedPerDay.indices.contains(day) { board.mergedPerDay[day] += 1 }
            } else if inBefore(merge.at) {
                board.mergedBefore += 1
            }
        }
        board.answered = events.count { $0.kind == .questionAnswered && inRange($0.at) }

        // Working stretches per session, each until the next state change (the last one until the session ended, or
        // now).
        var stretches: [Stretch] = []
        let states = Dictionary(grouping: events.filter { $0.kind == .state && $0.session != nil }) { $0.session! }
        for (id, list) in states {
            let sorted = list.sorted { $0.at < $1.at }
            for (index, event) in sorted.enumerated() where event.payload["state"] == AgentState.working.rawValue {
                let end = index + 1 < sorted.count ? sorted[index + 1].at : (ends[id]?.closedAt ?? now)
                let to = min(end, now)
                guard to > event.at else { continue }
                stretches.append(Stretch(session: id, from: event.at, to: to, guessed: event.guessed))
            }
        }
        board.perDay = perDay(stretches, from: start, days: days, now: now, calendar: calendar)
        board.calendar = perDay(
            stretches, from: board.calendarStart, days: calendarLength, now: now, calendar: calendar
        )
        board.mostAtOnce = mostAtOnce(stretches.map { ($0.from, $0.to) }, within: start ... max(start, now)).count

        var perAgent: [String: (TimeInterval, Bool)] = [:]
        var perRepo: [String: (TimeInterval, Bool)] = [:]
        for stretch in stretches {
            let inside = overlap(stretch.from, stretch.to, start, now)
            board.agentTimeBefore += overlap(stretch.from, stretch.to, before, start)
            guard inside > 0 else { continue }
            board.agentTime += inside
            if stretch.guessed { board.estimated = true }
            let name = agent(of: stretch.session) ?? "unknown"
            let repo = repoName(of: stretch.session)
            perAgent[name] = ((perAgent[name]?.0 ?? 0) + inside, (perAgent[name]?.1 ?? false) || stretch.guessed)
            perRepo[repo] = ((perRepo[repo]?.0 ?? 0) + inside, (perRepo[repo]?.1 ?? false) || stretch.guessed)
        }
        func shares(_ map: [String: (TimeInterval, Bool)]) -> [Share] {
            map.map { Share(name: $0.key, seconds: $0.value.0, estimated: $0.value.1) }
                .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.name < $1.name }
        }
        board.byAgent = shares(perAgent)
        board.byRepo = shares(perRepo)

        // Waits for you: each answer against the question its session asked first since the last answer.
        let waits = waits(events)
        let inside = waits.filter { inRange($0.answered) }
        board.medianWait = median(inside.map(\.wait))
        board.medianWaitBefore = median(waits.filter { inBefore($0.answered) }.map(\.wait))
        board.waited = inside.map(\.wait).reduce(0, +)
        board.longestWait = inside.map(\.wait).max()
        for (day, list) in Dictionary(grouping: inside, by: { offset($0.answered, from: start) })
            where board.waitPerDay.indices.contains(day)
        {
            board.waitPerDay[day] = median(list.map(\.wait)) ?? 0
        }

        // What the sessions started in the range (and the one before) used, as their agents reported it.
        var costs: [Double] = []
        for (id, at) in started {
            guard let usage = known[id]?.usage else { continue }
            board.tokens += usage.tokens.allInput + usage.tokens.output
            guard let cost = usage.costUSD else { continue }
            costs.append(cost)
            let day = offset(at, from: start)
            if board.costPerDay.indices.contains(day) { board.costPerDay[day] += cost }
        }
        board.cost = costs.isEmpty ? nil : costs.reduce(0, +)
        let earlier = startedBefore.compactMap { known[$0]?.usage?.costUSD }
        board.costBefore = earlier.isEmpty ? nil : earlier.reduce(0, +)

        // Shipped: the range's merges, newest first, with how long each took from its session's start.
        func shipped(_ merge: LoggedEvent) -> Shipped {
            let ref = merge.subject ?? ""
            let parts = ref.split(separator: "#")
            let number = parts.count == 2 ? Int(parts[1]) : nil
            let repo = parts.first.map(String.init) ?? merge.repo ?? ""
            let pull = number.flatMap { number in
                pulls.pulls.first { $0.ref.repo.slug == repo && $0.ref.number == number }
            }
            let title = merge.session.flatMap { known[$0]?.title ?? titles[$0] } ?? pull?.title ?? ref
            let took = merge.session.flatMap { startedAt[$0] }.map { merge.at.timeIntervalSince($0) }
            return Shipped(
                ref: ref, title: title, repo: repo, number: number, agent: agent(of: merge.session),
                session: merge.session, mergedAt: merge.at, took: took.map { max($0, 0) }
            )
        }
        let all = merges.values.map(shipped)
        board.shipped = all.filter { inRange($0.mergedAt) }
            .sorted { $0.mergedAt != $1.mergedAt ? $0.mergedAt > $1.mergedAt : $0.ref < $1.ref }
        board.fastest = board.shipped.compactMap(\.took).min()
        board.medianToMerge = median(board.shipped.compactMap(\.took))

        // Days in a row with a merge.
        let mergeDays = Set(merges.values.map { calendar.startOfDay(for: $0.at) })
        board.streak = currentStreak(mergeDays, today: today, calendar: calendar)

        // How the agents' sessions that ended in the range came out (chats have nothing to merge).
        var scores: [String: AgentScore] = [:]
        var endedIDs: Set<String> = []
        for event in events where event.kind == .sessionClosed && inRange(event.at) {
            guard let id = event.session, !endedIDs.contains(id), known[id]?.isChat != true, !chats.contains(id)
            else { continue }
            endedIDs.insert(id)
            let outcome = ends[id]?.outcome.rawValue ?? event.text
            let name = agent(of: id) ?? "unknown"
            var score = scores[name] ?? AgentScore(agent: name)
            score.ended += 1
            if outcome == Outcome.merged.rawValue { score.merged += 1 }
            if outcome == Outcome.abandoned.rawValue { score.abandoned += 1 }
            scores[name] = score
        }
        for share in board.byAgent {
            var score = scores[share.name] ?? AgentScore(agent: share.name)
            score.seconds = share.seconds
            score.estimated = share.estimated
            scores[share.name] = score
        }
        board.agents = scores.values.sorted {
            $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.agent < $1.agent
        }

        board.bests = bests(
            shipped: all, mergeDays: mergeDays, events: events, ends: ends, start: start, now: now, calendar: calendar
        )
        return board
    }

    /// The Monday `calendarWeeks - 1` weeks before this week's.
    public static func calendarStart(today: Date, calendar: Calendar) -> Date {
        let back = (calendar.component(.weekday, from: today) + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -back, to: today) ?? today
        return calendar.date(byAdding: .day, value: -7 * (calendarWeeks - 1), to: monday) ?? monday
    }

    /// Seconds of `stretches` per day, for `days` days from `origin`, split at midnight.
    static func perDay(
        _ stretches: [Stretch], from origin: Date, days: Int, now: Date, calendar: Calendar
    ) -> [TimeInterval] {
        var result = Array(repeating: TimeInterval(0), count: days)
        for stretch in stretches {
            var from = max(stretch.from, origin)
            let to = min(stretch.to, now)
            while from < to {
                let day = calendar.startOfDay(for: from)
                let next = calendar.date(byAdding: .day, value: 1, to: day) ?? to
                let offset = calendar.dateComponents([.day], from: origin, to: day).day ?? -1
                if result.indices.contains(offset) { result[offset] += min(next, to).timeIntervalSince(from) }
                from = min(next, to)
            }
        }
        return result
    }

    static func overlap(_ from: Date, _ to: Date, _ start: Date, _ end: Date) -> TimeInterval {
        max(0, min(to, end).timeIntervalSince(max(from, start)))
    }

    /// The most intervals open at the same moment inside `window`, and the first moment it was so. An interval that
    /// ends as another starts does not overlap it.
    public static func mostAtOnce(_ intervals: [(Date, Date)], within window: ClosedRange<Date>)
        -> (count: Int, at: Date?)
    {
        var edges: [(Date, Int)] = []
        for (from, to) in intervals {
            let start = max(from, window.lowerBound)
            let end = min(to, window.upperBound)
            guard end > start else { continue }
            edges.append((start, 1))
            edges.append((end, -1))
        }
        // Ends before starts at the same moment.
        edges.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var open = 0
        var most = 0
        var at: Date?
        for (date, change) in edges {
            open += change
            if open > most {
                most = open
                at = date
            }
        }
        return (most, at)
    }

    /// A question answered and how long it waited for you.
    public struct Wait: Equatable, Sendable {
        public var session: String
        public var answered: Date
        public var wait: TimeInterval
    }

    /// Each `question.answered` against the first `question.asked` of its session since the answer before it; an
    /// answer with no question before it (asked before the log began) waited for nothing heed saw, and is left out.
    public static func waits(_ events: [LoggedEvent]) -> [Wait] {
        let relevant = events
            .filter { ($0.kind == .questionAsked || $0.kind == .questionAnswered) && $0.session != nil }
        var result: [Wait] = []
        for (id, list) in Dictionary(grouping: relevant, by: { $0.session! }) {
            var asked: Date?
            for event in list.sorted(by: { $0.at < $1.at }) {
                if event.kind == .questionAsked {
                    asked = asked ?? event.at
                } else if let from = asked {
                    result.append(Wait(session: id, answered: event.at, wait: event.at.timeIntervalSince(from)))
                    asked = nil
                }
            }
        }
        return result.sorted { $0.answered < $1.answered }
    }

    public static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Days in a row in `days` (each a start of day) up to `today`; a today without one yet does not break it.
    public static func currentStreak(_ days: Set<Date>, today: Date, calendar: Calendar) -> Int {
        var day = days.contains(today) ? today : (calendar.date(byAdding: .day, value: -1, to: today) ?? today)
        var count = 0
        while days.contains(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    /// The longest run of days in a row in `days` (each a start of day), and the day it started (the earliest run
    /// when two are as long).
    public static func longestStreak(_ days: Set<Date>, calendar: Calendar) -> (count: Int, from: Date?) {
        var best = 0
        var from: Date?
        for day in days {
            // Only from the first day of a run.
            if let previous = calendar.date(byAdding: .day, value: -1, to: day), days.contains(previous) { continue }
            var count = 0
            var next = day
            while days.contains(next) {
                count += 1
                guard let after = calendar.date(byAdding: .day, value: 1, to: next) else { break }
                next = after
            }
            if count > best || (count == best && from.map { day < $0 } == true) {
                best = count
                from = day
            }
        }
        return (best, from)
    }

    /// The bests since the log began: the fastest merge from a session's start, the most sessions open at once, the
    /// longest run of days with a merge, the most merged in a day. Each says whether it is from the range.
    static func bests(
        shipped: [Shipped], mergeDays: Set<Date>, events: [LoggedEvent], ends: [String: HistoryEntry], start: Date,
        now: Date, calendar: Calendar
    ) -> [Best] {
        func day(_ date: Date) -> String { DashboardWords.day(date, now: now, calendar: calendar) }
        var bests: [Best] = []
        let timed = shipped.compactMap { item in item.took.map { (item, $0) } }
        if let (fastest, took) = timed.min(by: { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.ref < $1.0.ref }) {
            bests.append(Best(
                kind: .fastestMerge, value: DashboardWords.duration(took),
                detail: "\(fastest.title), \(day(fastest.mergedAt))", current: fastest.mergedAt >= start
            ))
        }
        // Sessions open at once: from each start (or reopen) to its close, or now.
        var intervals: [(Date, Date)] = []
        var opened: [String: Date] = [:]
        for event in events.sorted(by: { $0.at < $1.at }) {
            guard let id = event.session else { continue }
            switch event.kind {
            case .sessionStarted, .sessionReopened: opened[id] = opened[id] ?? event.at
            case .sessionClosed:
                if let from = opened.removeValue(forKey: id) { intervals.append((from, event.at)) }
            default: break
            }
        }
        for (id, from) in opened {
            intervals.append((from, ends[id]?.closedAt ?? now))
        }
        let first = events.map(\.at).min() ?? now
        let most = mostAtOnce(intervals, within: first ... max(first, now))
        if most.count > 1, let at = most.at {
            bests.append(Best(
                kind: .mostAtOnce, value: "\(most.count) sessions", detail: "open at once, \(day(at))",
                current: at >= start
            ))
        }
        let streak = longestStreak(mergeDays, calendar: calendar)
        if streak.count > 1, let from = streak.from {
            let last = calendar.date(byAdding: .day, value: streak.count - 1, to: from) ?? from
            let today = calendar.startOfDay(for: now)
            let running = last == today || calendar.date(byAdding: .day, value: 1, to: last) == today
            bests.append(Best(
                kind: .longestStreak, value: "\(streak.count) days",
                detail: (running ? "a merge every day since " : "a merge every day from ") + day(from),
                current: last >= start
            ))
        }
        let perDay = Dictionary(grouping: shipped) { calendar.startOfDay(for: $0.mergedAt) }
        if let busiest = perDay.max(by: {
            $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key > $1.key
        }), busiest.value.count > 1 {
            bests.append(Best(
                kind: .mostInADay, value: "\(busiest.value.count) merged", detail: "in one day, \(day(busiest.key))",
                current: busiest.key >= start
            ))
        }
        return bests
    }

    /// The step (0 none, 1…4 more) a day's agent time falls in, against the busiest day of `days` (the range's when
    /// nil): the calendar's shades.
    public func level(_ seconds: TimeInterval, in days: [TimeInterval]? = nil) -> Int {
        guard seconds > 0, let most = (days ?? perDay).max(), most > 0 else { return 0 }
        return min(4, max(1, Int((seconds / most * 4).rounded(.up))))
    }

    /// The sentence that leads the dashboard, its figure apart so the view can colour it (`lead` + `figure` +
    /// `tail`), and the line under it.
    public struct Headline: Equatable, Sendable {
        public var lead: String
        public var figure: String
        public var tail: String
        public var detail: String
    }

    /// `A good week: 9 PRs merged, 3 more than the week before.` Only what was recorded: no merges says so.
    public var headline: Headline {
        let period = DashboardWords.period(days)
        let previous = DashboardWords.previous(days)
        let figure = "\(merged) PR\(merged == 1 ? "" : "s") merged"
        var headline = if merged == 0 {
            Headline(
                lead: agentTime > 0 ? "Nothing merged in this \(period) yet" : "A quiet \(period)", figure: "",
                tail: ".", detail: ""
            )
        } else if merged > mergedBefore {
            Headline(
                lead: "A good \(period): ", figure: figure,
                tail: mergedBefore == 0 ? ", none \(previous)." : ", \(merged - mergedBefore) more than \(previous).",
                detail: ""
            )
        } else if merged == mergedBefore {
            Headline(lead: "", figure: figure, tail: ", as many as \(previous).", detail: "")
        } else {
            Headline(lead: "", figure: figure, tail: ", \(mergedBefore - merged) fewer than \(previous).", detail: "")
        }
        var parts: [String] = []
        if agentTime > 0 {
            var sentence = "Your agents worked \((estimated ? "about " : "") + DashboardWords.hours(agentTime))"
            if waited > 0 { sentence += "; they waited \(DashboardWords.duration(waited)) in all on your answers" }
            parts.append(sentence + ".")
        }
        if streak > 1 { parts.append("\(streak) days in a row with something merged.") }
        headline.detail = parts.joined(separator: " ")
        return headline
    }
}

/// How the dashboard says its numbers.
public enum DashboardWords {
    /// `week`, `four weeks`, `twelve weeks`, `10 days`.
    public static func period(_ days: Int) -> String {
        switch days {
        case 7: "week"
        case 28: "four weeks"
        case 84: "twelve weeks"
        default: days % 7 == 0 ? "\(days / 7) weeks" : "\(days) days"
        }
    }

    /// `the week before`, `the four weeks before`.
    public static func previous(_ days: Int) -> String { "the \(period(days)) before" }

    /// `31 h`, `3 h 12 m`, `41 m`.
    public static func hours(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 600 { return "\(minutes / 60) h" }
        if minutes >= 60 { return "\(minutes / 60) h \(minutes % 60) m" }
        return "\(minutes) m"
    }

    /// `40 s`, `18 m`, `1 h 40 m`, `2 d 3 h`.
    public static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds)) s" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) m" }
        if minutes < 48 * 60 { return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) m" }
        return "\(minutes / 1440) d \((minutes % 1440) / 60) h"
    }

    /// `today`, `yesterday`, `Mon` (within the week), `Thu 8 Oct`.
    public static func day(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: now).day ?? 0
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = days < 7 ? "EEE" : "EEE d MMM"
        return formatter.string(from: date)
    }

    /// A change against the period before, for a tile: `▲ 3`, `▼ 12%`, `= 0`; nil with nothing to set it against.
    public static func delta(_ now: Double, _ before: Double?, percent: Bool) -> String? {
        guard let before else { return nil }
        if percent {
            guard before > 0 else { return nil }
            let change = Int(((now - before) / before * 100).rounded())
            return change == 0 ? "= 0%" : "\(change > 0 ? "▲" : "▼") \(abs(change))%"
        }
        let change = (now - before).rounded()
        return change == 0 ? "= 0" : "\(change > 0 ? "▲" : "▼") \(Int(abs(change)))"
    }
}
