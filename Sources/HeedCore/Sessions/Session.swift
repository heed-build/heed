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

/// A chat's folder: an empty one heed made for it (scratch), or one you picked (folder).
public struct ChatFolder: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        /// A new empty folder per chat, under the chats root; heed may remove it once the chat is long closed.
        case scratch
        /// A folder you picked; heed never removes it.
        case folder
    }

    public var kind: Kind
    /// Where the agent runs: on this Mac, or on the session's host.
    public var path: String

    public init(_ kind: Kind, path: String) {
        self.kind = kind
        self.path = path
    }
}

/// Where a session works: in worktrees of its repos, or, for a chat, in a folder with no repo or branch.
public enum Workspace: Hashable, Sendable {
    case worktrees
    case chat(ChatFolder)
}

/// One task: a prompt, its worktrees (possibly across repos), terminals, the agent's own session id, tracked PRs.
/// Heed keeps only this record; the agent owns its transcript. A chat is a session without repos: it runs in a folder.
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
    /// Every branch its worktrees have been on, `branch` first: work that goes on after a merge, on a new branch in
    /// the same worktree, still belongs to the session (its PRs are matched against all of them).
    public var branches: [String]
    /// Its worktrees, by path, so they stay its own when their branch changes.
    public var worktreePaths: [String]
    /// PRs taken off it by hand (`pr.untrack`), so no rule adds them back.
    public var untrackedPRs: [PullRef]
    /// The host it runs on (`[hosts.<name>]`); nil for this Mac.
    public var host: String?
    /// Issues linked by hand (`heed issue add`, `:issue.add`); its prompt's and its PRs' closing references are added
    /// when shown (`IssueLinks.issues`).
    public var issues: [IssueRef]
    /// Issues taken off by hand (`:issue.remove`), so no reference shows them again.
    public var hiddenIssues: [IssueRef]
    /// Your notes on its diff while it has no PR to put them on (`SessionNotes`).
    public var notes: [FeedbackItem]
    /// The agent's latest model and what it used, as its hooks report; nil until they report any.
    public var usage: AgentUsage?
    /// Worktrees of `repos`, or a chat's folder.
    public var workspace: Workspace = .worktrees

    /// The chat's folder; nil for a session in worktrees.
    public var chat: ChatFolder? {
        if case let .chat(folder) = workspace { folder } else { nil }
    }

    public var isChat: Bool { chat != nil }

    /// Where its agent starts: a chat's folder, else its first worktree (nil before it has one).
    public var directory: String? { chat?.path ?? worktreePaths.first }

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
        createdAt: Date? = nil, timeline: [TimelineEvent] = [], workspace: Workspace = .worktrees
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
        self.workspace = workspace
        branches = workspace == .worktrees ? [branch] : []
        worktreePaths = []
        untrackedPRs = []
        issues = []
        hiddenIssues = []
        notes = []
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, prompt, repos, branch, agent, agentSessionID, state, activity, trackedPRs, pinned, parked,
             lastActivity, createdAt, timeline, branches, worktreePaths, untrackedPRs, host, issues, hiddenIssues,
             notes, usage, chat
    }

    /// Sessions cached before branches were followed still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        prompt = try container.decode(String.self, forKey: .prompt)
        repos = try container.decode([Repo].self, forKey: .repos)
        branch = try container.decode(String.self, forKey: .branch)
        agent = try container.decode(String.self, forKey: .agent)
        agentSessionID = try container.decodeIfPresent(String.self, forKey: .agentSessionID)
        state = try container.decode(ObservedState.self, forKey: .state)
        activity = try container.decode(String.self, forKey: .activity)
        trackedPRs = try container.decode([PullRef].self, forKey: .trackedPRs)
        pinned = try container.decode(Bool.self, forKey: .pinned)
        parked = try container.decode(Bool.self, forKey: .parked)
        lastActivity = try container.decode(Date.self, forKey: .lastActivity)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        // Kept in the event log now (`EventLog`); read from caches that still have it, to move it there.
        timeline = try container.decodeIfPresent([TimelineEvent].self, forKey: .timeline) ?? []
        branches = try container.decodeIfPresent([String].self, forKey: .branches) ?? [branch]
        worktreePaths = try container.decodeIfPresent([String].self, forKey: .worktreePaths) ?? []
        untrackedPRs = try container.decodeIfPresent([PullRef].self, forKey: .untrackedPRs) ?? []
        host = try container.decodeIfPresent(String.self, forKey: .host)
        issues = try container.decodeIfPresent([IssueRef].self, forKey: .issues) ?? []
        hiddenIssues = try container.decodeIfPresent([IssueRef].self, forKey: .hiddenIssues) ?? []
        notes = try container.decodeIfPresent([FeedbackItem].self, forKey: .notes) ?? []
        usage = try container.decodeIfPresent(AgentUsage.self, forKey: .usage)
        workspace = try container.decodeIfPresent(ChatFolder.self, forKey: .chat).map(Workspace.chat) ?? .worktrees
    }

    /// A chat keeps its folder under `chat`; a session in worktrees writes nothing for it, as before chats.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(repos, forKey: .repos)
        try container.encode(branch, forKey: .branch)
        try container.encode(agent, forKey: .agent)
        try container.encodeIfPresent(agentSessionID, forKey: .agentSessionID)
        try container.encode(state, forKey: .state)
        try container.encode(activity, forKey: .activity)
        try container.encode(trackedPRs, forKey: .trackedPRs)
        try container.encode(pinned, forKey: .pinned)
        try container.encode(parked, forKey: .parked)
        try container.encode(lastActivity, forKey: .lastActivity)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(timeline, forKey: .timeline)
        try container.encode(branches, forKey: .branches)
        try container.encode(worktreePaths, forKey: .worktreePaths)
        try container.encode(untrackedPRs, forKey: .untrackedPRs)
        try container.encodeIfPresent(host, forKey: .host)
        try container.encode(issues, forKey: .issues)
        try container.encode(hiddenIssues, forKey: .hiddenIssues)
        try container.encode(notes, forKey: .notes)
        try container.encodeIfPresent(usage, forKey: .usage)
        try container.encodeIfPresent(chat, forKey: .chat)
    }

    /// What the sidebar calls the session: its worktree's folder name (Start work names it after the task, the same
    /// as the branch), else its branch. The prompt-derived `title` stays for the title bar and the inspector. A chat
    /// has neither, so it goes by its title.
    public var worktreeName: String {
        if isChat { return title }
        return worktreePaths.first.map { ($0 as NSString).lastPathComponent } ?? branch
    }

    /// Whether a worktree is this session's: one it has by path, or (for sessions that predate paths) one on its
    /// first branch, in one of its repos.
    public func owns(_ worktree: Worktree) -> Bool {
        !isChat && worktree.location == location && repos.contains(worktree.repo)
            && (worktreePaths.contains(worktree.path) || worktree.branch == branch)
    }

    /// Where it runs.
    public var location: Location { host.map(Location.host) ?? .local }

    /// Tracks a PR unless it is already tracked or was untracked by hand; says why on the timeline. True when added.
    /// A chat tracks none: it has no branch for a PR to come from, and `:promote` is how one becomes work.
    @discardableResult
    public mutating func track(_ pull: PullRef, because reason: String, at date: Date = Date()) -> Bool {
        guard !isChat, !trackedPRs.contains(pull), !untrackedPRs.contains(pull) else { return false }
        trackedPRs.append(pull)
        record("tracking PR \(pull.repo.name)#\(pull.number) (\(reason))", at: date)
        return true
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
    /// A PR of the session used its get-it-green rounds without a new approval.
    case stalled = "Stalled"
    case working = "Working"
    /// Heed is getting a PR of the session green or merged, and you have not typed in it since heed last acted.
    case watching = "Watching"
    /// Chats: no repo, no worktree. One that is asking or blocked is in Needs you instead, like any session.
    case chats = "Chats"
    case parked = "Parked"

    public static let maxPins = 9

    /// Pinned, then what needs you, then what you parked; then chats, which have no PRs for the pilot; then stalled,
    /// then watching (heed is driving, the session is not yours); then the agent's state decides, working or parked.
    public static func of(_ session: Session, pilot: SessionPilot = SessionPilot()) -> SessionGroup {
        if session.pinned { return .pinned }
        if session.state.state.needsYou || pilot.status?.needsYou == true || pilot.helperNeedsYou { return .needsYou }
        if session.parked { return .parked }
        if session.isChat { return .chats }
        if case .stalled = pilot.status { return .stalled }
        if pilot.acting, !pilot.yours { return .watching }
        if session.parked || session.state.state == .done || session.state.state == .idle
            || session.state.state == .exited { return .parked }
        return .working
    }
}

/// The session under the cursor, as the list last showed it: its group, and whether you had pinned or parked it.
public struct SessionHold: Equatable, Sendable {
    public let id: String
    public let group: SessionGroup
    public let pinned: Bool
    public let parked: Bool

    public init(id: String, group: SessionGroup, pinned: Bool = false, parked: Bool = false) {
        self.id = id
        self.group = group
        self.pinned = pinned
        self.parked = parked
    }
}

extension SessionGroup {
    /// The group of the session under the cursor: a move the pilot causes (into or out of Watching or Stalled) waits
    /// until the cursor leaves it; what you do yourself (pin, park) and what needs you show at once.
    static func held(_ held: SessionGroup, natural: SessionGroup) -> SessionGroup {
        let pilot: Set<SessionGroup> = [.watching, .stalled]
        guard held != natural, pilot.contains(held) || pilot.contains(natural),
              ![held, natural].contains(.pinned), natural != .needsYou
        else { return natural }
        return held
    }
}

/// What the pilot says about a session, for its group: its most urgent PR state, whether heed is acting on any of its
/// PRs, and whether you typed in it since heed last did something there.
public struct SessionPilot: Equatable, Sendable {
    public var status: PilotStatus?
    public var acting: Bool
    public var yours: Bool
    /// A helper tab of the session (`send_to = "tab"`) is asking or blocked: waiting on you.
    public var helperNeedsYou: Bool

    public init(status: PilotStatus? = nil, acting: Bool = false, yours: Bool = false, helperNeedsYou: Bool = false) {
        self.status = status
        self.acting = acting
        self.yours = yours
        self.helperNeedsYou = helperNeedsYou
    }

    /// Yours: you typed in the session after heed's last action on any of its PRs.
    public static func yours(lastTyped: Date?, lastAction: Date?) -> Bool {
        guard let lastTyped else { return false }
        guard let lastAction else { return true }
        return lastTyped > lastAction
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

    /// `pilot` says what the pilot knows of each session. `hold` keeps one session (the one under the cursor) in the
    /// group it had while the pilot would move it; pinning or parking it moves it at once.
    public init(
        _ sessions: [Session], pilot: (Session) -> SessionPilot = { _ in SessionPilot() }, hold: SessionHold? = nil
    ) {
        let grouped = Dictionary(grouping: sessions) { session in
            let natural = SessionGroup.of(session, pilot: pilot(session))
            guard let hold, hold.id == session.id, hold.pinned == session.pinned, hold.parked == session.parked
            else { return natural }
            return SessionGroup.held(hold.group, natural: natural)
        }
        sections = SessionGroup.allCases.compactMap { group in
            guard let members = grouped[group], !members.isEmpty else { return nil }
            return Section(group: group, sessions: members)
        }
        ordered = sections.flatMap(\.sessions)
    }

    /// The group a session is shown in.
    public func group(of id: String) -> SessionGroup? {
        sections.first { $0.sessions.contains { $0.id == id } }?.group
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
    /// A chat that became work (`chat.promote`): its timeline names the session it became.
    case promoted
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

    /// The outcome when a session is closed by hand, before GitHub knows better (step 6 refines it from PR state). A
    /// chat had no work to abandon: it is closed.
    public static func outcome(closing session: Session) -> Outcome {
        session.trackedPRs.isEmpty && !session.isChat ? .abandoned : .closed
    }
}
