import Foundation

/// Insights › History (`history.list`): the sessions that ended, as pieces of work by day, each with the story the
/// event log tells of it folded into one line under it; what belongs to no session is a quiet line of its own. With
/// every event unfolded (`history.events`) it is the old timeline: each event its own line.
public struct HistoryFeed: Equatable, Sendable {
    /// A piece of work: a session (or a chat) that ended, and what the log saw happen to it, oldest first.
    public struct Work: Equatable, Sendable, Identifiable {
        public var entry: HistoryEntry
        public var story: [TimelineItem]
        public var id: String { entry.id }
        /// A chat: drawn as a quiet line, not a row of work.
        public var quiet: Bool { entry.session.isChat }

        public init(entry: HistoryEntry, story: [TimelineItem]) {
            self.entry = entry
            self.story = story
        }
    }

    /// One line of the list: a piece of work, or an event on its own.
    public enum Line: Equatable, Sendable, Identifiable {
        case work(Work)
        case event(TimelineItem)

        public var id: String {
            switch self {
            case let .work(work): "work-\(work.id)"
            case let .event(item): item.id
            }
        }

        /// When it lands in its day: a piece of work when it ended, an event when it happened.
        public var at: Date {
            switch self {
            case let .work(work): work.entry.closedAt
            case let .event(item): item.at
            }
        }

        /// The session it is about, if any.
        public var session: String? {
            switch self {
            case let .work(work): work.id
            case let .event(item): item.session
            }
        }

        public var work: Work? {
            if case let .work(work) = self { return work }
            return nil
        }
    }

    /// What a day amounted to, as its header says it.
    public struct Totals: Equatable, Sendable {
        public var outcomes: [Outcome: Int] = [:]
        public var answered = 0

        public init() {}

        /// `3 merged · 1 abandoned · 1 question answered`: only what happened, merged first.
        public var text: String {
            var parts = Outcome.allCases.compactMap { outcome in
                outcomes[outcome].map { "\($0) \(outcome.rawValue)" }
            }
            if answered > 0 { parts.append("\(answered) question\(answered == 1 ? "" : "s") answered") }
            return parts.joined(separator: " · ")
        }
    }

    public struct Day: Equatable, Sendable {
        /// `Today`, `Yesterday`, `Monday 12 Oct`.
        public let title: String
        public let start: Date
        public let indices: [Int]
        public let totals: Totals
    }

    public var lines: [Line] = []
    public var days: [Day] = []

    public init() {}

    /// What narrows the list: the outcome (nil: every one), the timeline's filters (kinds, repo, where, removed
    /// worktrees), `/`'s text, and whether every event is a line of its own.
    public struct Narrowing: Equatable, Sendable {
        public var outcome: Outcome?
        public var filter = TimelineFilter()
        public var search = ""
        public var everyEvent = false

        public init(
            outcome: Outcome? = nil,
            filter: TimelineFilter = TimelineFilter(),
            search: String = "",
            everyEvent: Bool = false
        ) {
            self.outcome = outcome
            self.filter = filter
            self.search = search
            self.everyEvent = everyEvent
        }
    }

    /// The list for `entries` (closed sessions) and `items` (the timeline's lines, any order), newest first. Folded,
    /// an event of a session that ended goes into its story; one of no session stays a line of its own; one of a
    /// session still open is left to Sessions until it ends. Unfolded, every event the filters keep is a line.
    public static func build(
        entries: [HistoryEntry], items: [TimelineItem], narrowing: Narrowing, now: Date, calendar: Calendar = .current
    ) -> HistoryFeed {
        let ids = Set(entries.map(\.id))
        let outcomes = Dictionary(entries.map { ($0.id, $0.outcome) }) { first, _ in first }
        var stories: [String: [TimelineItem]] = [:]
        for item in items {
            if let id = item.session, ids.contains(id) { stories[id, default: []].append(item) }
        }
        var lines: [Line] = []
        if narrowing.everyEvent {
            for item in items where narrowing.filter.matches(item) && matches(item, narrowing.search) {
                if let outcome = narrowing.outcome, item.session.flatMap({ outcomes[$0] }) != outcome { continue }
                lines.append(.event(item))
            }
        } else {
            for entry in entries where keeps(entry, narrowing) {
                let story = (stories[entry.id] ?? []).filter { narrowing.filter.showGone || !$0.gone }
                lines.append(.work(Work(entry: entry, story: story.sorted { $0.at < $1.at })))
            }
            if narrowing.outcome == nil {
                for item in items where item.session == nil && narrowing.filter.matches(item)
                    && matches(item, narrowing.search)
                {
                    lines.append(.event(item))
                }
            }
        }
        lines.sort { $0.at != $1.at ? $0.at > $1.at : $0.id < $1.id }

        // Questions answered count in their day whatever the list shows, in the repo and place the filters keep.
        var answered: [Date: Int] = [:]
        for item in items where item.kind == .questions {
            var place = narrowing.filter
            place.kinds = Set(TimelineItem.Kind.allCases)
            if place.matches(item) { answered[calendar.startOfDay(for: item.at), default: 0] += 1 }
        }
        var feed = HistoryFeed()
        feed.lines = lines
        var days: [(start: Date, indices: [Int], totals: Totals)] = []
        for (index, line) in lines.enumerated() {
            let start = calendar.startOfDay(for: line.at)
            if days.last?.start != start {
                var totals = Totals()
                totals.answered = answered[start] ?? 0
                days.append((start, [], totals))
            }
            days[days.count - 1].indices.append(index)
            if let work = line.work,
               !work.quiet { days[days.count - 1].totals.outcomes[work.entry.outcome, default: 0] += 1 }
        }
        feed.days = days.map { day in
            Day(
                title: AwaySummary.dayTitle(day.start, now: now, calendar: calendar), start: day.start,
                indices: day.indices, totals: day.totals
            )
        }
        return feed
    }

    /// Whether the narrowing keeps a piece of work: its outcome, its kind (a chat is shown with Chats, the rest with
    /// Sessions), its repo and place, and `/`.
    static func keeps(_ entry: HistoryEntry, _ narrowing: Narrowing) -> Bool {
        let session = entry.session
        let filter = narrowing.filter
        if let outcome = narrowing.outcome, entry.outcome != outcome { return false }
        if !filter.kinds.contains(session.isChat ? .chats : .sessions) { return false }
        if let repo = filter.repo, !session.repos.contains(where: { $0.slug == repo }) { return false }
        if let place = filter.place, place != (session.host ?? "local") { return false }
        return FilterQuery.matches(
            narrowing.search,
            [session.title, session.prompt, session.branch, session.agent, session.location.label]
                + session.repos.map(\.name)
        )
    }

    static func matches(_ item: TimelineItem, _ search: String) -> Bool {
        FilterQuery.matches(search, [item.lead, item.name, item.detail, item.badge, item.place, item.repo ?? ""])
    }

    /// How many pieces of work each outcome has, with the rest of the narrowing as it is (the kinds only while folded):
    /// the counts beside the outcome filter.
    public static func outcomeCounts(entries: [HistoryEntry], narrowing: Narrowing) -> [Outcome: Int] {
        var open = narrowing
        open.outcome = nil
        // Unfolded, the kinds pick events, not work: every piece of work counts.
        if narrowing.everyEvent { open.filter.kinds = Set(TimelineItem.Kind.allCases) }
        var counts: [Outcome: Int] = [:]
        for entry in entries where keeps(entry, open) {
            counts[entry.outcome, default: 0] += 1
        }
        return counts
    }

    /// How many pieces of work each repo (`org/name`) has: the counts beside the repo filter.
    public static func repoCounts(entries: [HistoryEntry]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for entry in entries {
            for repo in entry.session.repos {
                counts[repo.slug, default: 0] += 1
            }
        }
        return counts
    }

    /// The repos and places to filter by: the timeline's, and those of the work that ended.
    public static func choices(entries: [HistoryEntry], items: [TimelineItem]) -> (repos: [String], places: [String]) {
        let timeline = Timeline.choices(items)
        let repos = Set(timeline.repos + entries.flatMap { $0.session.repos.map(\.slug) }).sorted {
            ($0.split(separator: "/").last.map(String.init) ?? $0) <
                ($1.split(separator: "/").last.map(String.init) ?? $1)
        }
        let hosts = Set(timeline.places.filter { $0 != "local" } + entries.compactMap(\.session.host)).sorted()
        let local = timeline.places.contains("local") || entries.contains { $0.session.host == nil } ? ["local"] : []
        return (repos, local + hosts)
    }

    /// An event as the folded story says it, in a word or three (`started`, `PR #2810`, `you answered`); nil for one
    /// the line leaves to the detail (the worktree made with the session, a merged session's own end).
    public static func storyWord(_ item: TimelineItem, outcome: Outcome?) -> String? {
        switch item.event {
        case .sessionStarted: return "started"
        case .sessionReopened: return "reopened"
        case .sessionParked: return "parked"
        case .sessionClosed:
            if outcome == .merged || item.badge == Outcome.merged.rawValue { return nil }
            return item.badge == Outcome.closed.rawValue ? "closed" : item.badge
        case .worktreeCreated: return nil
        case .worktreeRemoved:
            return item.saved != nil ? "worktree removed, work saved" : "worktree removed"
        case .worktreeArchived: return "work saved"
        case .pullTracked: return "PR \(item.name)"
        case .pullMerged: return "merged"
        case .questionAnswered: return "you answered"
        default: return item.badge
        }
    }

    /// An event as the detail's story says it, in a sentence.
    public static func storySentence(_ item: TimelineItem, agent: String?) -> String {
        switch item.event {
        case .sessionStarted: ["started", agent].compactMap(\.self).joined(separator: " · ")
        case .sessionReopened: "reopened"
        case .sessionParked: "parked; the agent kept running"
        case .sessionClosed: "ended, \(item.badge)"
        case .worktreeCreated: "worktree \(item.name) created"
        case .worktreeRemoved:
            "worktree removed" + (item.saved.map { "; \($0)" } ?? "")
        case .worktreeArchived: item.saved ?? "work saved"
        case .pullTracked: "opened PR \(item.name)"
        case .pullMerged: "PR \(item.name) merged"
        case .questionAnswered: "you answered \(agent ?? "the agent")"
        default: "\(item.lead) \(item.name)"
        }
    }
}
