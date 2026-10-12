import Foundation

/// A repository Heed knows about: where its main checkout lives and what it is on GitHub.
public struct RepoRecord: Identifiable, Hashable, Sendable, Codable {
    /// `org/name`, the stable identity everywhere (chips, config, PRs).
    public var id: String { repo.slug }
    public var repo: Repo
    /// The main checkout, where `git worktree` commands run.
    public var path: String
    /// `main`, `master`, ... from `origin/HEAD`; nil until known.
    public var defaultBranch: String?

    public init(repo: Repo, path: String, defaultBranch: String? = nil) {
        self.repo = repo
        self.path = path
        self.defaultBranch = defaultBranch
    }
}

/// A git worktree of a known repo, as git reports it plus what Heed tracks about it.
public struct Worktree: Identifiable, Hashable, Sendable, Codable {
    /// The worktree's path: unique on disk, so it is the identity.
    public var id: String { path }
    public var repo: Repo
    public var path: String
    /// Nil for a detached HEAD.
    public var branch: String?
    public var head: String
    /// The repo's main checkout rather than an added worktree.
    public var isMain: Bool
    public var status: WorktreeStatus?

    public init(
        repo: Repo, path: String, branch: String?, head: String, isMain: Bool, status: WorktreeStatus? = nil
    ) {
        self.repo = repo
        self.path = path
        self.branch = branch
        self.head = head
        self.isMain = isMain
        self.status = status
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
