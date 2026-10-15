import Foundation

/// One thing that happened while you were away, projected from what the domain keeps: a PR merged, a background run
/// ended, a session's agent finished, a review arrived, a session closed.
public struct AwayEvent: Hashable, Sendable {
    /// The summary's groups, in the order a day lists them.
    public enum Kind: Int, CaseIterable, Comparable, Sendable {
        case merged, runs, finished, reviews, closed

        public var title: String {
            switch self {
            case .merged: "Merged"
            case .runs: "Runs"
            case .finished: "Finished"
            case .reviews: "New reviews"
            case .closed: "Closed"
            }
        }

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let at: Date
    public let kind: Kind
    /// What it is about, in mono: `docs-builder #2836`, `get it green #412`, a session's name.
    public let subject: String
    /// A few words on what happened.
    public let text: String

    public init(at: Date, kind: Kind, subject: String, text: String) {
        self.at = at
        self.kind = kind
        self.subject = subject
        self.text = text
    }
}

/// "While you were away": what still waits on you, then what happened since you last looked, by day and by kind.
public struct AwaySummary: Equatable, Sendable {
    /// A session in Needs you right now.
    public struct Waiting: Hashable, Sendable, Identifiable {
        public let id: String
        public let state: AgentState
        public let guessed: Bool
        public let name: String
        public let reason: String

        public init(id: String, state: AgentState, guessed: Bool = false, name: String, reason: String) {
            self.id = id
            self.state = state
            self.guessed = guessed
            self.name = name
            self.reason = reason
        }
    }

    public struct Row: Hashable, Sendable {
        public let subject: String
        public let text: String
        public let at: Date
    }

    public struct Group: Hashable, Sendable {
        public let kind: AwayEvent.Kind
        public let rows: [Row]
    }

    public struct Day: Hashable, Sendable {
        /// `Today`, `Yesterday`, `Monday 12 Oct`.
        public let title: String
        public let start: Date
        public let groups: [Group]
    }

    public let since: Date
    /// `since yesterday 18:20`.
    public let sinceText: String
    public let waiting: [Waiting]
    /// Newest first.
    public let days: [Day]
    /// The waiting row under the cursor.
    public var cursor = 0

    /// Nothing happened and nothing waits: not worth opening on its own.
    public var isEmpty: Bool { waiting.isEmpty && days.isEmpty }

    public var selected: Waiting? { waiting.indices.contains(cursor) ? waiting[cursor] : nil }

    public mutating func move(by delta: Int) {
        guard !waiting.isEmpty else { return }
        cursor = max(0, min(waiting.count - 1, cursor + delta))
    }

    /// The events since `since` (up to `now`) by day, newest first, then by kind; within a kind, newest first. Rows of
    /// one subject on one day become one row (a review and its threads), except runs, which are each their own.
    public static func build(
        events: [AwayEvent], waiting: [Waiting], since: Date, now: Date, calendar: Calendar = .current
    ) -> AwaySummary {
        let kept = events.filter { $0.at >= since && $0.at <= now }
        let byDay = Dictionary(grouping: kept) { calendar.startOfDay(for: $0.at) }
        let days = byDay.keys.sorted(by: >).map { start in
            let byKind = Dictionary(grouping: byDay[start] ?? []) { $0.kind }
            let groups = byKind.keys.sorted().map { kind in
                Group(kind: kind, rows: rows(byKind[kind] ?? [], merging: kind != .runs))
            }
            return Day(title: dayTitle(start, now: now, calendar: calendar), start: start, groups: groups)
        }
        return AwaySummary(
            since: since, sinceText: sinceText(since, now: now, calendar: calendar), waiting: waiting, days: days
        )
    }

    private static func rows(_ events: [AwayEvent], merging: Bool) -> [Row] {
        let sorted = events.sorted { $0.at > $1.at }
        guard merging else { return sorted.map { Row(subject: $0.subject, text: $0.text, at: $0.at) } }
        var order: [String] = []
        var texts: [String: [String]] = [:]
        var newest: [String: Date] = [:]
        for event in sorted {
            if texts[event.subject] == nil {
                order.append(event.subject)
                newest[event.subject] = event.at
            }
            // Oldest first within the row reads as it happened.
            var list = texts[event.subject] ?? []
            if !list.contains(event.text) { list.insert(event.text, at: 0) }
            texts[event.subject] = list
        }
        return order.map { Row(subject: $0, text: (texts[$0] ?? []).joined(separator: " · "), at: newest[$0] ?? .now) }
    }

    /// `Today`, `Yesterday`, else the weekday and date.
    public static func dayTitle(_ start: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(start, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(start, inSameDayAs: yesterday) { return "Yesterday" }
        return format("EEEE d MMM", start, calendar: calendar)
    }

    /// `since 07:10`, `since yesterday 18:20`, `since Monday 18:20`, `since 2 Oct 18:20`; a midnight drops the time.
    public static func sinceText(_ since: Date, now: Date, calendar: Calendar = .current) -> String {
        let midnight = calendar.startOfDay(for: since) == since
        let time = midnight ? "" : " " + format("HH:mm", since, calendar: calendar)
        if calendar.isDate(since, inSameDayAs: now) { return midnight ? "since midnight" : "since" + time }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: since), to: calendar.startOfDay(for: now)
        ).day ?? 0
        if days == 1 { return "since yesterday" + time }
        if days < 7 { return "since " + format("EEEE", since, calendar: calendar) + time }
        return "since " + format("d MMM", since, calendar: calendar) + time
    }

    private static func format(_ pattern: String, _ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    // MARK: When it opens

    /// Whether coming back (to the Mac, or launching heed) after `lastActive` is long enough away to show the summary.
    /// `awayHours` 0 turns it off.
    public static func shouldOffer(lastActive: Date?, now: Date, awayHours: Double) -> Bool {
        guard awayHours > 0, let lastActive else { return false }
        return now.timeIntervalSince(lastActive) >= awayHours * 3600
    }

    /// Where `summary` (asked for by hand) starts: the start of yesterday, or further back when the summary that opened
    /// on its own in the last `recent` seconds went back further (a weekend away).
    public static func askedSince(
        lastAway: Date?, shownAt: Date?, now: Date, calendar: Calendar = .current, recent: TimeInterval = 12 * 3600
    ) -> Date {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        guard let lastAway, let shownAt, now.timeIntervalSince(shownAt) < recent else { return yesterday }
        return min(lastAway, yesterday)
    }

    // MARK: From the domain

    /// What needs you now: sessions asking, blocked or rate limited, in the order given.
    public static func waiting(from sessions: [Session]) -> [Waiting] {
        sessions.filter { $0.state.state.needsYou || $0.state.state == .limited }.map { session in
            let activity = session.activity.isEmpty ? session.state.state.rawValue : session.activity
            return Waiting(
                id: session.id, state: session.state.state, guessed: session.state.source == .guessed,
                name: session.worktreeName, reason: "\(session.agent) · \(activity)"
            )
        }
    }

    /// Every event the domain can tell, at any time (`build` picks the window): merges and review threads from the
    /// pilot log, reviews from the PRs' details, ended runs, sessions whose agent is done, closed sessions.
    public static func events(from domain: Domain) -> [AwayEvent] {
        let viewer = domain.github.viewer
        func title(_ ref: PullRef) -> String? {
            domain.pullDetails[ref.description]?.title ?? domain.github.pulls.first { $0.ref == ref }?.title
        }
        func subject(_ ref: PullRef) -> String { "\(ref.repo.name) #\(ref.number)" }
        var events: [AwayEvent] = []
        for event in domain.pilotLog {
            switch event.kind {
            case .merged:
                events.append(AwayEvent(
                    at: event.at, kind: .merged, subject: subject(event.ref), text: title(event.ref) ?? event.text
                ))
            case .items where event.text.contains("review thread"):
                events.append(AwayEvent(at: event.at, kind: .reviews, subject: subject(event.ref), text: event.text))
            default: break
            }
        }
        for detail in domain.pullDetails.values {
            for review in detail.reviews {
                guard let at = review.submittedAt, review.author != viewer else { continue }
                let verb = switch review.state {
                case "APPROVED": "approved"
                case "CHANGES_REQUESTED": "requested changes"
                case "COMMENTED": "commented"
                default: ""
                }
                guard !verb.isEmpty else { continue }
                events.append(AwayEvent(
                    at: at, kind: .reviews, subject: subject(detail.ref), text: "@\(review.author) \(verb)"
                ))
            }
        }
        for run in domain.runs {
            guard let ended = run.endedAt, let outcome = run.outcome else { continue }
            let took = PilotDuration.text(ended.timeIntervalSince(run.startedAt))
            events.append(AwayEvent(
                at: ended, kind: .runs, subject: "\(run.goal.rawValue) #\(run.ref.number)",
                text: "\(run.agent) · \(outcome.text) · \(took)"
            ))
        }
        for session in domain.sessions where session.state.state == .done {
            let text = session.activity.hasPrefix("done") ? "\(session.agent) \(session.activity)"
                : "\(session.agent) done"
            events.append(AwayEvent(
                at: session.lastActivity, kind: .finished, subject: session.worktreeName, text: text
            ))
        }
        for entry in domain.history {
            events.append(AwayEvent(
                at: entry.closedAt, kind: .closed, subject: entry.session.worktreeName,
                text: "\(entry.outcome.rawValue) · \(entry.session.title)"
            ))
        }
        return events
    }
}
