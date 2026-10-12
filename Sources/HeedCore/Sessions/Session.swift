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
    public var trackedPRs: [Int]
    public var pinned: Bool
    public var parked: Bool
    public var lastActivity: Date

    public init(
        id: String = UUID().uuidString, title: String, prompt: String = "", repos: [Repo], branch: String,
        agent: String, agentSessionID: String? = nil, state: ObservedState, activity: String = "",
        trackedPRs: [Int] = [], pinned: Bool = false, parked: Bool = false, lastActivity: Date = Date()
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
