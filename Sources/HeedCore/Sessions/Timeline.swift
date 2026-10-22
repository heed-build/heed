import Foundation

/// One line of History's timeline: something that happened, projected from the event log (`EventLog`): a session
/// started or ended, a worktree made or removed, a PR tracked or merged, a question you answered, a chat.
public struct TimelineItem: Identifiable, Hashable, Sendable {
    /// What the timeline can show and hide, as its Show filter lists them.
    public enum Kind: String, CaseIterable, Hashable, Sendable {
        case sessions, worktrees, prs, questions, chats

        public var title: String {
            switch self {
            case .sessions: "Sessions"
            case .worktrees: "Worktrees"
            case .prs: "PRs"
            case .questions: "Questions"
            case .chats: "Chats"
            }
        }
    }

    public let id: String
    public let at: Date
    public let kind: Kind
    public let event: EventKind
    /// `Worktree removed:`, before the name.
    public let lead: String
    /// What it is about: a branch, a session's title, `#2841`. Struck through when its worktree is gone.
    public let name: String
    /// The line under it: repo, agent, what happened.
    public let detail: String
    /// One word or two for the chip: `created`, `removed`, `merged`, `parked`, `answered`.
    public let badge: String
    /// `org/name`.
    public let repo: String?
    public let host: String?
    public let session: String?
    /// The worktree it is about (its path), when it is about one.
    public let worktree: String?
    /// The worktree it is about no longer exists: drawn with a dashed ring and struck through.
    public var gone = false
    /// What was saved before its worktree was removed ("saved 3 unpushed commits as heed/archive/old-spike").
    public var saved: String?

    /// `local`, or `@devbox`.
    public var place: String { host.map { "@\($0)" } ?? "local" }

    /// The repo, from its `org/name`.
    public var repository: Repo? {
        let parts = repo?.split(separator: "/", maxSplits: 1) ?? []
        return parts.count == 2 ? Repo(org: String(parts[0]), name: String(parts[1])) : nil
    }
}

/// Which items the timeline shows.
public struct TimelineFilter: Equatable, Sendable {
    public var kinds: Set<TimelineItem.Kind> = Set(TimelineItem.Kind.allCases)
    /// `org/name`; nil is every repo.
    public var repo: String?
    /// `local` or a host's name; nil is everywhere.
    public var place: String?
    /// Lines about worktrees that no longer exist.
    public var showGone = true

    public init() {}

    public func matches(_ item: TimelineItem) -> Bool {
        kinds.contains(item.kind) && (repo == nil || item.repo == repo)
            && (place == nil || place == (item.host ?? "local")) && (showGone || !item.gone)
    }

    /// `t`: every kind, then each one alone, then every kind again; with a name, that kind alone (`all`: every kind).
    public mutating func cycleKind(_ named: String? = nil) {
        let all = TimelineItem.Kind.allCases
        if let named {
            kinds = TimelineItem.Kind(rawValue: named).map { [$0] } ?? Set(all)
            return
        }
        if kinds.count == all.count {
            kinds = [all[0]]
        } else if kinds.count == 1, let one = kinds.first, let index = all.firstIndex(of: one), index + 1 < all.count {
            kinds = [all[index + 1]]
        } else {
            kinds = Set(all)
        }
    }

    /// The next of `options` after the current one (nil, every one, first), or the one named.
    static func next(_ current: String?, in options: [String], named: String?) -> String? {
        if let named { return named == "all" ? nil : named }
        guard let current, let index = options.firstIndex(of: current) else { return options.first }
        return index + 1 < options.count ? options[index + 1] : nil
    }

    public mutating func cycleRepo(among repos: [String], named: String? = nil) {
        // A name may be the repo's own (`docs-builder`) or its slug.
        let slug = named.map { name in repos.first { $0 == name || $0.hasSuffix("/" + name) } ?? name }
        repo = Self.next(repo, in: repos, named: slug)
    }

    public mutating func cyclePlace(among places: [String], named: String? = nil) {
        place = Self.next(place, in: places, named: named.map { $0.hasPrefix("@") ? String($0.dropFirst()) : $0 })
    }
}

/// The facts the timeline's detail shows for an item.
public struct TimelineFacts: Equatable, Sendable {
    /// From the worktree's creation to its removal (nil: still there), when the log saw it made.
    public var lived: (from: Date, to: Date?)?
    /// Time its session's agent spent working; nil when no state was ever logged.
    public var agentTime: TimeInterval?
    /// Some of that time was read from the screen rather than reported: an estimate.
    public var estimated = false

    public init() {}

    public static func == (lhs: TimelineFacts, rhs: TimelineFacts) -> Bool {
        lhs.lived?.from == rhs.lived?.from && lhs.lived?.to == rhs.lived?.to && lhs.agentTime == rhs.agentTime
            && lhs.estimated == rhs.estimated
    }
}

public enum Timeline {
    /// The log's kinds the timeline is made of.
    public static let kinds: [EventKind] = [
        .sessionStarted, .sessionClosed, .sessionParked, .sessionReopened, .worktreeCreated, .worktreeRemoved,
        .worktreeArchived, .pullTracked, .pullMerged, .questionAnswered,
    ]

    /// The items for `events` (any order), newest first. Session titles and chats come from the domain where the
    /// event does not say; a worktree removed right after it was saved carries what was saved.
    public static func items(from events: [LoggedEvent], domain: Domain) -> [TimelineItem] {
        var sessions: [String: Session] = [:]
        for entry in domain.history {
            sessions[entry.id] = entry.session
        }
        for session in domain.sessions {
            sessions[session.id] = session
        }
        let live = Set(domain.worktrees.map { worktree in
            worktree.location.hostName.map { "\($0):\(worktree.path)" } ?? worktree.path
        })
        let archived = events.filter { $0.kind == .worktreeArchived }
        // A session no longer in the domain is still told by its start: its title, and whether it was a chat.
        var titles: [String: String] = [:]
        var chats: Set<String> = []
        var agents: [String: String] = [:]
        for event in events where event.kind == .sessionStarted || event.kind == .sessionReopened {
            guard let id = event.session else { continue }
            if !event.text.isEmpty { titles[id] = event.text }
            if event.payload["chat"] != nil { chats.insert(id) }
            if let agent = event.payload["agent"] { agents[id] = agent }
        }
        /// A worktree's events name no session: the one that worked there (by path, else by repo and branch).
        func owner(of event: LoggedEvent) -> String? {
            guard let path = event.worktree else { return nil }
            let place: Location = event.host.map(Location.host) ?? .local
            let branch = event.text
            return sessions.values.filter { session in
                session.location == place && session.repos.contains { $0.slug == event.repo }
                    && (session.worktreePaths.contains(path) || (!branch.isEmpty && session.branch == branch))
            }.map(\.id).sorted().first
        }
        var used: Set<Int> = []
        var items: [TimelineItem] = []
        for (index, event) in events.enumerated() {
            let session = event.session.flatMap { sessions[$0] }
            let title = session?.title ?? event.session.flatMap { titles[$0] } ?? "a session"
            let chat = session?.isChat ?? event.session.map(chats.contains) ?? false
            let repoName = event.repo.map { String($0.split(separator: "/").last ?? "") }
            let agent = session?.agent ?? event.payload["agent"] ?? event.session.flatMap { agents[$0] }
            func item(
                _ kind: TimelineItem.Kind, _ lead: String, _ name: String, _ detail: String, _ badge: String
            ) -> TimelineItem {
                TimelineItem(
                    id: "\(event.at.timeIntervalSince1970)-\(index)-\(event.kind.rawValue)", at: event.at,
                    kind: kind, event: event.kind, lead: lead, name: name, detail: detail, badge: badge,
                    repo: event.repo, host: event.host, session: event.session ?? owner(of: event),
                    worktree: event.worktree
                )
            }
            func joined(_ parts: String?...) -> String { parts.compactMap(\.self).filter { !$0.isEmpty }
                .joined(separator: " · ")
            }
            switch event.kind {
            case .sessionStarted:
                items.append(chat
                    ? item(.chats, "Chat started:", title, joined(agent), "chat")
                    : item(.sessions, "Session started:", title, joined(repoName, agent), "started"))
            case .sessionReopened:
                items.append(item(
                    chat ? .chats : .sessions,
                    chat ? "Chat reopened:" : "Session reopened:",
                    title,
                    joined(repoName, agent),
                    "reopened"
                ))
            case .sessionParked:
                items.append(item(
                    .sessions,
                    "Session parked:",
                    title,
                    joined(repoName, "the agent keeps running"),
                    "parked"
                ))
            case .sessionClosed:
                let outcome = event.text.isEmpty ? "closed" : event.text
                items.append(chat
                    ? item(.chats, "Chat closed:", title, joined(agent), outcome)
                    : item(.sessions, "Session ended:", title, joined(repoName, agent), outcome))
            case .worktreeCreated:
                var line = item(
                    .worktrees, "Worktree created:", event.text.isEmpty ? name(of: event.worktree) : event.text,
                    joined(repoName, event.worktree.map { Paths.tilde($0) }), "created"
                )
                line.gone = !live.contains(key(event))
                items.append(line)
            case .worktreeRemoved:
                var line = item(
                    .worktrees, "Worktree removed:", event.text.isEmpty ? name(of: event.worktree) : event.text,
                    joined(repoName, event.worktree.map { Paths.tilde($0) }), "removed"
                )
                line.gone = !live.contains(key(event))
                // The save comes just before the removal, in the same repo and place, under the branch's name.
                if let match = archived.firstIndex(where: { saved in
                    saved.repo == event.repo && saved.host == event.host
                        && saved.subject == "heed/archive/\(line.name)"
                        && abs(saved.at.timeIntervalSince(event.at)) < 600
                }) {
                    used.insert(match)
                    line.saved = archived[match].text
                }
                items.append(line)
            case .pullTracked, .pullMerged:
                let number = event.subject?.split(separator: "#").last.map { "#\($0)" } ?? "a PR"
                let merged = event.kind == .pullMerged
                items.append(item(
                    .prs, merged ? "PR merged:" : "PR tracked:", number, joined(repoName, session?.title),
                    merged ? "merged" : "PR open"
                ))
            case .questionAnswered:
                items.append(item(
                    .questions,
                    "You answered",
                    agent ?? "the agent",
                    joined(repoName, title),
                    "answered"
                ))
            default:
                break
            }
        }
        // A save whose removal the log did not see (heed quit in between) still says so.
        for (index, event) in archived.enumerated() where !used.contains(index) {
            let name = event.subject.map { $0.replacingOccurrences(of: "heed/archive/", with: "") } ?? ""
            var line = TimelineItem(
                id: "\(event.at.timeIntervalSince1970)-a\(index)", at: event.at, kind: .worktrees, event: event.kind,
                lead: "Work saved:", name: name, detail: event.text, badge: "saved", repo: event.repo,
                host: event.host, session: event.session, worktree: event.worktree
            )
            line.saved = event.text
            items.append(line)
        }
        return items.sorted { $0.at > $1.at }
    }

    private static func key(_ event: LoggedEvent) -> String {
        let path = event.worktree ?? ""
        return event.host.map { "\($0):\(path)" } ?? path
    }

    private static func name(of path: String?) -> String {
        path.map { ($0 as NSString).lastPathComponent } ?? "a worktree"
    }

    /// The repos and places the items are in, for the filters: repos by name, `local` first, then hosts.
    public static func choices(_ items: [TimelineItem]) -> (repos: [String], places: [String]) {
        let repos = Set(items.compactMap(\.repo)).sorted {
            $0.split(separator: "/").last.map(String.init) ?? $0 < $1.split(separator: "/").last.map(String.init) ?? $1
        }
        let hosts = Set(items.compactMap(\.host)).sorted()
        let local = items.contains { $0.host == nil } ? ["local"] : []
        return (repos, local + hosts)
    }

    /// A day of the timeline: its title (`Today`, `Yesterday`, `Monday 12 Oct`, as the away summary says it) and the
    /// indices of its items.
    public struct Day: Equatable, Sendable {
        public let title: String
        public let start: Date
        public let indices: [Int]
    }

    /// `items` (newest first) by day, newest first.
    public static func days(_ items: [TimelineItem], now: Date, calendar: Calendar = .current) -> [Day] {
        var days: [Day] = []
        for (index, item) in items.enumerated() {
            let start = calendar.startOfDay(for: item.at)
            if let last = days.last, last.start == start {
                days[days.count - 1] = Day(title: last.title, start: start, indices: last.indices + [index])
            } else {
                days.append(Day(
                    title: AwaySummary.dayTitle(start, now: now, calendar: calendar), start: start, indices: [index]
                ))
            }
        }
        return days
    }

    /// What the detail shows of `item`: how long its worktree lived (from the log's creation and removal of the same
    /// worktree) and how long its session's agent worked (`state` events of the session, oldest first or not).
    public static func facts(
        for item: TimelineItem, events: [LoggedEvent], states: [LoggedEvent], now: Date
    ) -> TimelineFacts {
        var facts = TimelineFacts()
        if let path = item.worktree {
            let same = events.filter { $0.worktree == path && $0.host == item.host }
            let created = same.filter { $0.kind == .worktreeCreated }.map(\.at).filter { $0 <= item.at }.max()
                ?? same.filter { $0.kind == .worktreeCreated }.map(\.at).min()
            if let created {
                let removed = same.filter { $0.kind == .worktreeRemoved && $0.at >= created }.map(\.at).min()
                facts.lived = (created, removed)
            }
        }
        if item.session != nil {
            let worked = agentTime(states.filter { $0.session == item.session }, now: now)
            facts.agentTime = worked.time
            facts.estimated = worked.estimated
        }
        return facts
    }

    /// The sum of the intervals a session's agent was `working`, from its `state` events: each lasts until the next
    /// state change, the last one until `now`. Nil when there are none. `estimated` when any working stretch was
    /// read from the screen (an agent whose hooks do not report it).
    public static func agentTime(_ states: [LoggedEvent], now: Date) -> (time: TimeInterval?, estimated: Bool) {
        let sorted = states.filter { $0.kind == .state }.sorted { $0.at < $1.at }
        guard !sorted.isEmpty else { return (nil, false) }
        var total: TimeInterval = 0
        var estimated = false
        for (index, event) in sorted.enumerated() where event.payload["state"] == AgentState.working.rawValue {
            let end = index + 1 < sorted.count ? sorted[index + 1].at : now
            total += max(0, end.timeIntervalSince(event.at))
            if event.guessed { estimated = true }
        }
        return (total, estimated)
    }
}
