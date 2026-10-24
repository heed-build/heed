import Foundation

/// A session's tabs and splits: restored on launch, so it is part of the domain rather than view state.
public struct SessionLayout: Hashable, Sendable, Codable {
    public var tabs: [PaneTab]
    public var activeTab: Int

    public init(tabs: [PaneTab], activeTab: Int = 0) {
        self.tabs = tabs
        self.activeTab = activeTab
    }

    /// Removes a pane from whichever tab has it; a tab left without panes goes too. False when no tab has it.
    @discardableResult
    public mutating func removePane(_ id: String) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.tree.panes.contains { $0.id == id } }) else { return false }
        var tab = tabs[index]
        let focused = tab.focused
        tab.focused = id
        if tab.closeFocused() {
            if focused != id, tab.tree.panes.contains(where: { $0.id == focused }) { tab.focused = focused }
            tabs[index] = tab
        } else {
            removeTab(at: index)
        }
        return true
    }

    /// Removes a tab, keeping the active one active (or its neighbour, when it was the one removed).
    public mutating func removeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs.remove(at: index)
        if index < activeTab { activeTab -= 1 }
        activeTab = max(0, min(activeTab, tabs.count - 1))
    }

    /// Moves a tab to `destination` (a tab dragged along the strip); the tab that was active stays active.
    public mutating func moveTab(from index: Int, to destination: Int) {
        guard tabs.indices.contains(index), tabs.indices.contains(destination), index != destination else { return }
        let active = tabs.indices.contains(activeTab) ? tabs[activeTab].id : nil
        tabs.insert(tabs.remove(at: index), at: destination)
        if let active, let moved = tabs.firstIndex(where: { $0.id == active }) { activeTab = moved }
    }

    /// Moves the active tab `offset` places (`g>`, `g<`), stopping at either end. False when it is already there.
    @discardableResult
    public mutating func moveActiveTab(by offset: Int) -> Bool {
        guard tabs.indices.contains(activeTab) else { return false }
        let destination = min(max(activeTab + offset, 0), tabs.count - 1)
        guard destination != activeTab else { return false }
        moveTab(from: activeTab, to: destination)
        return true
    }
}

/// Everything Heed knows, as one value. The window is drawn from this (plus input state), it is what the cache
/// stores, and fixtures are just instances of it, so the UI can start in any state without IO.
public struct Domain: Hashable, Sendable, Codable {
    public var repos: [RepoRecord]
    public var worktrees: [Worktree]
    public var sessions: [Session]
    public var layouts: [String: SessionLayout]
    /// Closed sessions, newest first.
    public var history: [HistoryEntry]
    public var github: GitHubState
    /// PR details by `org/name#n`, for the reader (cached, so it opens offline).
    public var pullDetails: [String: PullDetail]
    /// Feedback pipelines by `org/name#n`.
    public var feedback: [String: PullFeedback]
    /// What the pilot noticed and did, newest first, capped (`PilotEvent.logLimit`).
    public var pilotLog: [PilotEvent]
    /// Each repo's merge queue runs by `org/name`, newest first, capped (`MergeRun.keep`).
    public var mergeRuns: [String: [MergeRun]]
    /// Get it green / get it merged runs, newest first, capped (`PilotRun.keep`).
    public var runs: [PilotRun]
    /// Worktrees on hosts that heed manages (made by heed, or registered with ↩), by worktree id. Ones a scan found
    /// and nobody registered are left alone.
    public var registeredWorktrees: Set<String>
    /// Work saved from removed worktrees (`refs/heed/archive/…`), as last listed in each repo, wherever it lives.
    public var archives: [ArchiveRef]

    public init(
        repos: [RepoRecord] = [], worktrees: [Worktree] = [], sessions: [Session] = [],
        layouts: [String: SessionLayout] = [:], history: [HistoryEntry] = [], github: GitHubState = GitHubState(),
        pullDetails: [String: PullDetail] = [:], feedback: [String: PullFeedback] = [:], pilotLog: [PilotEvent] = [],
        mergeRuns: [String: [MergeRun]] = [:], registeredWorktrees: Set<String> = [], runs: [PilotRun] = [],
        archives: [ArchiveRef] = []
    ) {
        self.archives = archives
        self.runs = runs
        self.registeredWorktrees = registeredWorktrees
        self.mergeRuns = mergeRuns
        self.pullDetails = pullDetails
        self.feedback = feedback
        self.pilotLog = pilotLog
        self.history = history
        self.github = github
        self.repos = repos
        self.worktrees = worktrees
        self.sessions = sessions
        self.layouts = layouts
    }

    public static let empty = Domain()

    private enum CodingKeys: String, CodingKey {
        case repos, worktrees, sessions, layouts, history, github, pullDetails, feedback, pilotLog, mergeRuns,
             registeredWorktrees, runs, archives
    }

    /// Caches from before the pilot log still load (no version bump, which would drop sessions).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repos = try container.decode([RepoRecord].self, forKey: .repos)
        worktrees = try container.decode([Worktree].self, forKey: .worktrees)
        sessions = try container.decode([Session].self, forKey: .sessions)
        layouts = try container.decode([String: SessionLayout].self, forKey: .layouts)
        // Kept in the event log now (`EventLog`); read from caches that still have it, to move it there.
        history = try container.decodeIfPresent([HistoryEntry].self, forKey: .history) ?? []
        github = try container.decode(GitHubState.self, forKey: .github)
        pullDetails = try container.decode([String: PullDetail].self, forKey: .pullDetails)
        feedback = try container.decode([String: PullFeedback].self, forKey: .feedback)
        pilotLog = try container.decodeIfPresent([PilotEvent].self, forKey: .pilotLog) ?? []
        mergeRuns = try container.decodeIfPresent([String: [MergeRun]].self, forKey: .mergeRuns) ?? [:]
        registeredWorktrees = try container.decodeIfPresent(Set<String>.self, forKey: .registeredWorktrees) ?? []
        runs = try container.decodeIfPresent([PilotRun].self, forKey: .runs) ?? []
        archives = try container.decodeIfPresent([ArchiveRef].self, forKey: .archives) ?? []
    }

    public func repo(_ slug: String) -> RepoRecord? { repos.first { $0.id == slug } }

    /// Whether heed manages a worktree, and how it stands (`reachable`: whether its host answers now).
    public func registration(of worktree: Worktree, reachable: Bool = true) -> WorktreeRegistration {
        guard !worktree.location.isLocal else { return .registered }
        guard reachable else { return .stale }
        return registeredWorktrees.contains(worktree.id) ? .registered : .discovered
    }

    public func worktrees(of repo: Repo) -> [Worktree] { worktrees.filter { $0.repo == repo } }
    public func session(_ id: String) -> Session? { sessions.first { $0.id == id } }
}

/// One edit to the domain. Adapters (git, gh, hooks) and the UI both speak in these, so every change takes the same
/// path: applied to the store (and persisted), and applied to the main-actor model, which redraws only what changed.
public enum DomainChange: Hashable, Sendable, Codable {
    case repoUpserted(RepoRecord)
    case repoRemoved(String)
    /// The complete worktree list of one repo, as git reported it.
    case worktreesListed(repo: Repo, [Worktree])
    case sessionUpserted(Session)
    case sessionRemoved(String)
    case layoutChanged(session: String, SessionLayout)
    /// A session closes into history (its layout is dropped).
    case sessionClosed(HistoryEntry)
    /// A history entry comes back as an active session (`R` reopen).
    case historyRemoved(String)
    /// A history entry changed in place (a closed chat's scratch folder removed).
    case historyUpdated(HistoryEntry)
    /// A GitHub sync finished (or failed: the status says so and the data is the previous data).
    case githubSynced(GitHubState)
    /// Notification threads marked read.
    case inboxRead([String])
    /// A PR's detail arrived; it is merged into the PR's feedback pipeline.
    case pullDetailFetched(PullDetail)
    case feedbackChanged(PullFeedback)
    /// Something the pilot did that the domain cannot see happen (sent, waiting, a mode or pause changed).
    case pilotLogged([PilotEvent])
    /// A repo's merge queue ran.
    case mergeRan(MergeRun)
    /// A worktree on a host is heed's to manage from now on.
    case worktreeRegistered(String)
    /// A get it green / get it merged run started or ended (by id: a later one replaces it).
    case runUpdated(PilotRun)
    /// A repo's archive refs on one machine, as git listed them (after a scan, or a sweep that dropped some).
    case archivesListed(repo: Repo, location: Location, [ArchiveRef])
    /// A worktree's work was saved before it was removed.
    case worktreeArchived(ArchiveRef)
}

public extension Domain {
    mutating func apply(_ change: DomainChange) {
        switch change {
        case let .repoUpserted(record):
            if let index = repos.firstIndex(where: { $0.id == record.id }) {
                repos[index] = record
            } else {
                repos.append(record)
                repos.sort { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            }
        case let .repoRemoved(slug):
            repos.removeAll { $0.id == slug }
            worktrees.removeAll { $0.repo.slug == slug }
        case let .worktreesListed(repo, listed):
            // Keep known status for worktrees git still lists; status refreshes arrive separately.
            let known = Dictionary(worktrees.filter { $0.repo == repo }.map { ($0.path, $0.status) }) { first, _ in
                first
            }
            let merged = listed.map { worktree in
                var worktree = worktree
                if worktree.status == nil, let status = known[worktree.path] { worktree.status = status }
                return worktree
            }
            // A listing replaces what was known on the machines it covers: listing a repo's worktrees on @devbox leaves
            // its worktrees on this Mac (and other hosts) alone.
            let places = Set(merged.map(\.location))
            worktrees.removeAll { $0.repo == repo && places.contains($0.location) }
            worktrees.append(contentsOf: merged)
            sessions = sessions.map { BranchFollowing.follow($0, worktrees: merged) }
        case var .sessionUpserted(session):
            // Notes queued before the session had a PR join that PR's feedback once it tracks one.
            let pulls = github
            for pipeline in SessionNotes.adopt(&session, into: feedback, isOpen: {
                (pulls.pull($0)?.state ?? .open) == .open
            }) {
                feedback[pipeline.ref.description] = pipeline
            }
            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[index] = session
            } else {
                sessions.append(session)
            }
        case let .sessionRemoved(id):
            sessions.removeAll { $0.id == id }
            layouts[id] = nil
        case let .layoutChanged(session, layout):
            layouts[session] = layout
        case let .sessionClosed(entry):
            sessions.removeAll { $0.id == entry.id }
            layouts[entry.id] = nil
            history.removeAll { $0.id == entry.id }
            history.insert(entry, at: 0)
        case let .historyRemoved(id):
            history.removeAll { $0.id == id }
        case let .historyUpdated(entry):
            if let index = history.firstIndex(where: { $0.id == entry.id }) { history[index] = entry }
        case let .githubSynced(state):
            github = state
        case let .pullDetailFetched(detail):
            let merged = detail.state == "MERGED" && pullDetails[detail.ref.description]
                .map { $0.state != "MERGED" } == true
            pullDetails[detail.ref.description] = detail
            if merged {
                pilotLog = PilotEvent.log(pilotLog, adding: [PilotEvent(
                    at: detail.fetchedAt, ref: detail.ref, kind: .merged, text: "merged into \(detail.baseBranch)"
                )])
            }
            let before = feedback[detail.ref.description]
            var pipeline = before ?? PullFeedback(ref: detail.ref)
            pipeline.merge(detail)
            feedback[detail.ref.description] = pipeline
            pilotLog = PilotEvent.log(
                pilotLog,
                adding: PilotEvent.changes(from: before, to: pipeline, at: detail.fetchedAt)
            )
        case let .pilotLogged(events):
            pilotLog = PilotEvent.log(pilotLog, adding: events)
        case let .worktreeRegistered(id):
            registeredWorktrees.insert(id)
        case let .runUpdated(run):
            runs.removeAll { $0.id == run.id }
            runs = Array(([run] + runs).sorted { $0.startedAt > $1.startedAt }.prefix(PilotRun.keep))
        case let .mergeRan(run):
            mergeRuns[run.repo] = Array(([run] + (mergeRuns[run.repo] ?? [])).prefix(MergeRun.keep))
        case let .feedbackChanged(pipeline):
            feedback[pipeline.ref.description] = pipeline
        case let .archivesListed(repo, location, listed):
            archives.removeAll { $0.repo == repo && $0.location == location }
            archives.append(contentsOf: listed)
        case let .worktreeArchived(ref):
            archives.removeAll { $0.id == ref.id }
            archives.append(ref)
        case let .inboxRead(ids):
            for index in github.inbox.indices where ids.contains(github.inbox[index].id) {
                github.inbox[index].unread = false
            }
        }
    }

    func applying(_ changes: [DomainChange]) -> Domain {
        var copy = self
        for change in changes {
            copy.apply(change)
        }
        return copy
    }
}
