import Foundation

/// A session's tabs and splits: restored on launch, so it is part of the domain rather than view state.
public struct SessionLayout: Hashable, Sendable, Codable {
    public var tabs: [PaneTab]
    public var activeTab: Int

    public init(tabs: [PaneTab], activeTab: Int = 0) {
        self.tabs = tabs
        self.activeTab = activeTab
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

    public init(
        repos: [RepoRecord] = [], worktrees: [Worktree] = [], sessions: [Session] = [],
        layouts: [String: SessionLayout] = [:], history: [HistoryEntry] = [], github: GitHubState = GitHubState()
    ) {
        self.history = history
        self.github = github
        self.repos = repos
        self.worktrees = worktrees
        self.sessions = sessions
        self.layouts = layouts
    }

    public static let empty = Domain()

    public func repo(_ slug: String) -> RepoRecord? { repos.first { $0.id == slug } }
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
    /// A GitHub sync finished (or failed: the status says so and the data is the previous data).
    case githubSynced(GitHubState)
    /// Notification threads marked read.
    case inboxRead([String])
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
            worktrees.removeAll { $0.repo == repo }
            worktrees.append(contentsOf: merged)
        case let .sessionUpserted(session):
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
        case let .githubSynced(state):
            github = state
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
