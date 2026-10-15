import Foundation

/// A repository Heed knows about: where its main checkout lives and what it is on GitHub.
public struct RepoRecord: Identifiable, Hashable, Sendable, Codable {
    /// `org/name` for a repo on this Mac (the identity in chips, config and PRs); `org/name@host` for one on a host, so
    /// the same repo on several machines are several records.
    public var id: String { location.hostName.map { "\(repo.slug)@\($0)" } ?? repo.slug }
    public var repo: Repo
    /// The main checkout, where `git worktree` commands run.
    public var path: String
    /// `main`, `master`, ... from `origin/HEAD`; nil until known.
    public var defaultBranch: String?
    public var location: Location

    public init(repo: Repo, path: String, defaultBranch: String? = nil, location: Location = .local) {
        self.repo = repo
        self.path = path
        self.defaultBranch = defaultBranch
        self.location = location
    }

    private enum CodingKeys: String, CodingKey { case repo, path, defaultBranch, location }

    /// Records cached before hosts are local ones.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repo = try container.decode(Repo.self, forKey: .repo)
        path = try container.decode(String.self, forKey: .path)
        defaultBranch = try container.decodeIfPresent(String.self, forKey: .defaultBranch)
        location = try container.decodeIfPresent(Location.self, forKey: .location) ?? .local
    }
}

/// A git worktree of a known repo, as git reports it plus what Heed tracks about it.
public struct Worktree: Identifiable, Hashable, Sendable, Codable {
    /// The worktree's path (with its host for one on a host): unique, so it is the identity.
    public var id: String { location.hostName.map { "\($0):\(path)" } ?? path }
    public var repo: Repo
    public var path: String
    /// Nil for a detached HEAD.
    public var branch: String?
    public var head: String
    /// The repo's main checkout rather than an added worktree.
    public var isMain: Bool
    public var status: WorktreeStatus?
    public var location: Location

    public init(
        repo: Repo, path: String, branch: String?, head: String, isMain: Bool, status: WorktreeStatus? = nil,
        location: Location = .local
    ) {
        self.repo = repo
        self.path = path
        self.branch = branch
        self.head = head
        self.isMain = isMain
        self.status = status
        self.location = location
    }

    private enum CodingKeys: String, CodingKey { case repo, path, branch, head, isMain, status, location }

    /// Worktrees cached before hosts are local ones.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repo = try container.decode(Repo.self, forKey: .repo)
        path = try container.decode(String.self, forKey: .path)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        head = try container.decode(String.self, forKey: .head)
        isMain = try container.decode(Bool.self, forKey: .isMain)
        status = try container.decodeIfPresent(WorktreeStatus.self, forKey: .status)
        location = try container.decodeIfPresent(Location.self, forKey: .location) ?? .local
    }
}

/// What makes a worktree unsafe to remove, and how it relates to its upstream.
public struct WorktreeStatus: Hashable, Sendable, Codable {
    public var changedFiles: Int
    public var untrackedFiles: Int
    public var ahead: Int
    public var behind: Int
    public var upstream: String?

    public init(
        changedFiles: Int = 0,
        untrackedFiles: Int = 0,
        ahead: Int = 0,
        behind: Int = 0,
        upstream: String? = nil
    ) {
        self.changedFiles = changedFiles
        self.untrackedFiles = untrackedFiles
        self.ahead = ahead
        self.behind = behind
        self.upstream = upstream
    }

    public var isDirty: Bool { changedFiles > 0 || untrackedFiles > 0 }
    /// Commits that exist nowhere else: ahead of upstream, or any commits at all without one.
    public var hasUnpushedWork: Bool { ahead > 0 || upstream == nil }
}

/// The order repos are listed and suggested in: the ones you work in most (most added worktrees) first, then by name.
public enum RepoOrder {
    /// Added worktrees (not main checkouts) per repo slug.
    public static func worktreeCounts(_ worktrees: [Worktree]) -> [String: Int] {
        worktrees.filter { !$0.isMain }
            .reduce(into: [:]) { counts, worktree in counts[worktree.repo.slug, default: 0] += 1 }
    }

    /// Most recently worked in first (`StartWork.lastWorked`), then by name.
    public static func recent(_ repos: [RepoRecord], lastWorked: [String: Date]) -> [RepoRecord] {
        repos.sorted { lhs, rhs in
            let left = lastWorked[lhs.id] ?? .distantPast
            let right = lastWorked[rhs.id] ?? .distantPast
            if left != right { return left > right }
            let order = lhs.repo.name.localizedCaseInsensitiveCompare(rhs.repo.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    public static func sorted(_ repos: [RepoRecord], counts: [String: Int]) -> [RepoRecord] {
        repos.sorted { lhs, rhs in
            let left = counts[lhs.id] ?? 0
            let right = counts[rhs.id] ?? 0
            if left != right { return left > right }
            let order = lhs.repo.name.localizedCaseInsensitiveCompare(rhs.repo.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }
}

/// What a session has not shared yet, summed over its worktrees: commits ahead of their upstream and files changed
/// or untracked. A worktree listed twice (under two repos, e.g. a fork's clone) counts once.
public struct PendingChanges: Hashable, Sendable {
    public var ahead = 0
    public var dirty = 0

    public init(ahead: Int = 0, dirty: Int = 0) {
        self.ahead = ahead
        self.dirty = dirty
    }

    public init(_ worktrees: [Worktree]) {
        var seen: Set<String> = []
        for worktree in worktrees where seen.insert("\(worktree.location.label)\u{0}\(worktree.path)").inserted {
            guard let status = worktree.status else { continue }
            ahead += status.ahead
            dirty += status.changedFiles + status.untrackedFiles
        }
    }

    public var isEmpty: Bool { ahead == 0 && dirty == 0 }
}
