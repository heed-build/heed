import Foundation

/// A repository, always under an org or a personal account.
public struct Repo: Hashable, Sendable, Codable {
    public var org: String
    public var name: String

    public init(org: String, name: String) {
        self.org = org
        self.name = name
    }

    public var slug: String { "\(org)/\(name)" }
}

/// A pull request, identified across repos.
public struct PullRef: Hashable, Sendable, Codable, CustomStringConvertible {
    public var repo: Repo
    public var number: Int

    public init(repo: Repo, number: Int) {
        self.repo = repo
        self.number = number
    }

    /// `https://github.com/org/name/pull/123` (with or without a trailing path).
    public init?(url: String) {
        let parts = url.split(separator: "/").map(String.init)
        guard let pull = parts.firstIndex(of: "pull"), pull >= 2, pull + 1 < parts.count,
              let number = Int(parts[pull + 1].prefix { $0.isNumber })
        else { return nil }
        self.init(repo: Repo(org: parts[pull - 2], name: parts[pull - 1]), number: number)
    }

    public var description: String { "\(repo.slug)#\(number)" }
    public var url: String { "https://github.com/\(repo.slug)/pull/\(number)" }
}

/// One task: a prompt, its worktrees (possibly across repos), terminals, the agent's own session id, tracked PRs.
/// Heed keeps only this record; the agent owns its transcript.
public struct Session: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var title: String
    public var prompt: String
    public var repos: [Repo]
    public var branch: String
    public var agent: String
    /// The agent's own session id, captured from its start hook.
    public var agentSessionID: String?
    public var state: ObservedState
    /// What the agent is up to, in a few words ("running tests", "wants to run dotnet publish").
    public var activity: String
    public var trackedPRs: [PullRef]
    public var pinned: Bool
    public var parked: Bool
    public var lastActivity: Date
    public var createdAt: Date
    /// What happened, coarsely: started, PRs, resumed, ended. Kept with the session and in history; capped.
    public var timeline: [TimelineEvent]

    /// The repos it works in (its worktrees), then those of PRs it opened elsewhere.
    public var involvedRepos: [Repo] {
        var result = repos
        for ref in trackedPRs where !result.contains(ref.repo) {
            result.append(ref.repo)
        }
        return result
    }

    public init(
        id: String = UUID().uuidString.lowercased(), title: String, prompt: String = "", repos: [Repo], branch: String,
        agent: String, agentSessionID: String? = nil, state: ObservedState, activity: String = "",
        trackedPRs: [PullRef] = [], pinned: Bool = false, parked: Bool = false, lastActivity: Date = Date(),
        createdAt: Date? = nil, timeline: [TimelineEvent] = []
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.repos = repos
        self.branch = branch
        self.agent = agent
        self.agentSessionID = agentSessionID
        self.state = state
        self.activity = activity
        self.trackedPRs = trackedPRs
        self.pinned = pinned
        self.parked = parked
        self.lastActivity = lastActivity
        self.createdAt = createdAt ?? lastActivity
        self.timeline = timeline
    }

    public static let timelineLimit = 50

    public mutating func record(_ text: String, at date: Date = Date()) {
        timeline.append(TimelineEvent(at: date, text: text))
        if timeline.count > Self.timelineLimit { timeline.removeFirst(timeline.count - Self.timelineLimit) }
    }
}

/// The sidebar's groups, in order. A session sits in exactly one.
public enum SessionGroup: String, CaseIterable, Sendable {
    case pinned = "Pinned"
    case needsYou = "Needs you"
    case working = "Working"
    case parked = "Parked"

    public static let maxPins = 9

    public static func of(_ session: Session) -> SessionGroup {
        if session.pinned { return .pinned }
        if session.state.state.needsYou { return .needsYou }
        if session.parked || session.state.state == .done || session.state.state == .idle
            || session.state.state == .exited { return .parked }
        return .working
    }
}

/// The sessions as the sidebar lists them: grouped, in a stable order, so `j`/`k` and counts walk the list you see.
public struct SessionList: Sendable {
    public struct Section: Sendable {
        public let group: SessionGroup
        public let sessions: [Session]
    }

    public let sections: [Section]
    /// Every session in display order.
    public let ordered: [Session]

    public init(_ sessions: [Session]) {
        let grouped = Dictionary(grouping: sessions, by: SessionGroup.of)
        sections = SessionGroup.allCases.compactMap { group in
            guard let members = grouped[group], !members.isEmpty else { return nil }
            return Section(group: group, sessions: members)
        }
        ordered = sections.flatMap(\.sessions)
    }

    /// The pinned sessions in pin order, for `'1`..`'9`.
    public var pins: [Session] { ordered.filter(\.pinned) }

    /// Vim-style relative numbers: the cursor row shows its absolute position (1-based), the others their distance.
    public func lineNumber(of index: Int, cursor: Int) -> Int {
        index == cursor ? index + 1 : abs(index - cursor)
    }

    /// The next session after `cursor` that needs you (blocked or asking), wrapping around. For `ga`.
    public func nextNeedingYou(after cursor: Int) -> Int? {
        guard !ordered.isEmpty else { return nil }
        for step in 1 ... ordered.count {
            let index = (cursor + step) % ordered.count
            if ordered[index].state.state.needsYou { return index }
        }
        return nil
    }
}

public struct TimelineEvent: Hashable, Sendable, Codable {
    public var at: Date
    public var text: String

    public init(at: Date, text: String) {
        self.at = at
        self.text = text
    }
}

/// How a session ended, for history.
public enum Outcome: String, Hashable, Sendable, Codable, CaseIterable {
    case merged, closed, abandoned
    case cleanedUp = "cleaned up"
}

/// A session that is no longer active: kept for search, reopening and starting again from its prompt.
public struct HistoryEntry: Identifiable, Hashable, Sendable, Codable {
    public var id: String { session.id }
    public var session: Session
    public var closedAt: Date
    public var outcome: Outcome

    public init(session: Session, closedAt: Date, outcome: Outcome) {
        self.session = session
        self.closedAt = closedAt
        self.outcome = outcome
    }

    public var duration: TimeInterval { closedAt.timeIntervalSince(session.createdAt) }

    /// The outcome when a session is closed by hand, before GitHub knows better (step 6 refines it from PR state).
    public static func outcome(closing session: Session) -> Outcome {
        session.trackedPRs.isEmpty ? .abandoned : .closed
    }
}
