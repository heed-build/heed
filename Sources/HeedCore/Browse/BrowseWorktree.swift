import Foundation

/// The temporary worktree a Browse run works in: how it is named, where it goes, how it is made and removed, what
/// the startup sweep (`RunCleanup`, at launch) takes of the ones a crash left, and what a run becomes when you keep it as a session.
///
/// A run's worktree is `issue-<number>-<6 hex>` or `pr-<number>-<6 hex>`, under the runs root helpers use
/// (`<root>/heed/<repo>/<name>`), on the branch `heed/browse/<name>`. Closing the run removes both; whatever the run
/// pushed stays on its remote.
public enum BrowseWorktree {
    public static let branchPrefix = Runs.prefix + "browse/"

    // MARK: Naming

    /// Six lowercase hex digits from a number: the short guid in a name.
    public static func suffix(_ value: UInt32) -> String {
        let digits = String(value & 0xFFFFFF, radix: 16)
        return String(repeating: "0", count: 6 - digits.count) + digits
    }

    public static func randomSuffix() -> String { suffix(UInt32.random(in: 0 ... 0xFFFFFF)) }

    /// `issue-2830-4f9c2e`, `pr-412-a01b2c`.
    public static func name(_ kind: BrowseItem.Kind, number: Int, suffix: String) -> String {
        "\(kind == .pull ? "pr" : "issue")-\(number)-\(suffix)"
    }

    public static func branch(named name: String) -> String { branchPrefix + name }

    /// `<root>/heed/<repo>/<name>`: beside the helpers' worktrees.
    public static func path(root: String, repo: Repo, name: String) -> String { "\(root)/heed/\(repo.name)/\(name)" }

    /// What a name or a branch says about its run, or nil when it is not a Browse run's.
    public static func parse(_ text: String) -> (kind: BrowseItem.Kind, number: Int, suffix: String)? {
        let name = text.hasPrefix(branchPrefix) ? String(text.dropFirst(branchPrefix.count)) : text
        let parts = name.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let number = Int(parts[1]), number > 0, parts[2].count == 6,
              parts[2].allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { return nil }
        switch parts[0] {
        case "issue": return (.issue, number, parts[2])
        case "pr": return (.pull, number, parts[2])
        default: return nil
        }
    }

    /// Whether a branch is one a Browse run made (`heed/browse/issue-2830-4f9c2e`): only those, never a person's
    /// branch that happens to sit under `heed/`.
    public static func isBranch(_ branch: String) -> Bool {
        branch.hasPrefix(branchPrefix) && parse(branch) != nil
    }

    // MARK: Making one

    /// What is made for a run: the names, where, and what it starts from.
    public struct Plan: Equatable, Sendable {
        public enum Start: Equatable, Sendable {
            /// A new branch from the repo's default branch (Fix, Implement, Chat on an issue).
            case defaultBranch(String)
            /// The pull request's head as GitHub has it, a fork's included (anything on a pull request).
            case pullHead(Int)
        }

        public var name: String
        public var branch: String
        public var path: String
        public var start: Start
    }

    public static func plan(
        for item: BrowseItem, defaultBranch: String, root: String, suffix: String = randomSuffix()
    ) -> Plan {
        let name = name(item.kind, number: item.number, suffix: suffix)
        return Plan(
            name: name, branch: branch(named: name), path: path(root: root, repo: item.repo, name: name),
            start: item.kind == .pull ? .pullHead(item.number) : .defaultBranch(defaultBranch)
        )
    }

    /// Makes the worktree with git: its real path.
    public static func create(_ plan: Plan, in record: RepoRecord) async throws -> String {
        switch plan.start {
        case let .defaultBranch(base):
            try await Git.addWorktree(record, path: plan.path, branch: plan.branch, base: base).path
        case let .pullHead(number):
            try await Git.addPullWorktree(record, path: plan.path, number: number, runBranch: plan.branch)
        }
    }

    /// Removes the worktree and its local branch; a branch the run pushed stays on its remote.
    public static func remove(path: String, branch: String, in record: RepoRecord) async {
        await Git.removeWorktree(record, path: path, branch: branch)
    }

    // MARK: Keeping one

    /// What a kept run becomes: its branch and worktree under heed's usual naming (`fix/anchors-lost-page-moved`),
    /// unique among the branches there are.
    public static func promoted(
        verb: BrowseVerb, title: String, taken: Set<String>, prefixes: BranchPrefixes = .default
    ) -> String {
        let word = switch verb {
        case .fix: "fix"
        case .implement: "add"
        case .chat: "look"
        case .review: "review"
        }
        let base = StartWork.branchName(for: "\(word) \(title)", prefixes: prefixes)
        return StartWork.unique(base, taken: taken)
    }

    /// Moves the worktree and renames its branch to `branch`, in `record`'s repo: where the run's session works.
    /// The new path goes where Start work puts worktrees. Throws what git said.
    public static func promote(
        _ record: RepoRecord, from path: String, branch old: String, to branch: String, at newPath: String
    ) async throws -> String {
        let parent = (newPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        _ = try await ProcessRunner.output(
            "git", ["-C", record.path, "worktree", "move", path, newPath], caller: "browse.promote"
        )
        _ = try await ProcessRunner.output(
            "git", ["-C", newPath, "branch", "-m", old, branch], caller: "browse.promote"
        )
        return newPath
    }
}
