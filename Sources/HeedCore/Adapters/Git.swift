import Foundation

/// git, projected into the domain. Every call runs `git` off the main actor and returns domain values; raw output
/// never leaves this file.
public enum Git {
    // MARK: Reading

    /// The repo behind a checkout: `org/name` from the `origin` remote, else `local/<directory>`.
    public static func repo(at path: String, on location: Location = .local) async -> Repo {
        let url = try? await ProcessRunner.output(
            on: location, "git",
            ["-C", path, "remote", "get-url", "origin"],
            timeout: .seconds(5), caller: "git.repo"
        )
        return url.flatMap { parseRemote($0) } ?? Repo(org: "local", name: URL(fileURLWithPath: path).lastPathComponent)
    }

    /// `main` from `origin/HEAD`, falling back to `main`.
    public static func defaultBranch(at path: String, on location: Location = .local) async -> String {
        let ref = try? await ProcessRunner.output(
            on: location, "git", ["-C", path, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
            timeout: .seconds(5), caller: "git.defaultBranch"
        )
        let name = ref?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "main" : String(name.split(separator: "/", maxSplits: 1).last ?? "main")
    }

    /// A record for the checkout at `path`, or nil when it is not a git repository's main checkout.
    public static func record(at path: String, on location: Location = .local) async -> RepoRecord? {
        guard let top = try? await ProcessRunner.output(
            on: location, "git", ["-C", path, "rev-parse", "--show-toplevel"], timeout: .seconds(5),
            caller: "git.record"
        ) else { return nil }
        let root = top.trimmingCharacters(in: .whitespacesAndNewlines)
        async let repo = repo(at: root, on: location)
        async let branch = defaultBranch(at: root, on: location)
        return await RepoRecord(repo: repo, path: root, defaultBranch: branch, location: location)
    }

    /// The repo and worktree a path is in, whichever worktree that is (a linked one resolves to its repo's main
    /// checkout through the shared git dir). Nil when the path is not inside a git worktree.
    public static func locate(_ path: String) async -> (record: RepoRecord, worktree: Worktree, all: [Worktree])? {
        guard let top = try? await ProcessRunner.output(
            "git", ["-C", path, "rev-parse", "--show-toplevel"], timeout: .seconds(5), caller: "git.locate"
        ), let common = try? await ProcessRunner.output(
            "git", ["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"], timeout: .seconds(5),
            caller: "git.locate"
        ) else { return nil }
        let root = URL(fileURLWithPath: top.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL.path
        let shared = URL(fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL
        let main = shared.lastPathComponent == ".git" ? shared.deletingLastPathComponent().path : shared.path
        guard let record = await record(at: main), let all = try? await worktrees(of: record),
              let worktree = all.first(where: {
                  URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().path
                      == URL(fileURLWithPath: root).resolvingSymlinksInPath().path
              })
        else { return nil }
        return (record, worktree, all)
    }

    public static func worktrees(of record: RepoRecord) async throws -> [Worktree] {
        let output = try await ProcessRunner.output(
            on: record.location, "git", ["-C", record.path, "worktree", "list", "--porcelain"], caller: "git.worktrees"
        )
        return parseWorktrees(output, repo: record.repo).map { worktree in
            var worktree = worktree
            worktree.location = record.location
            return worktree
        }
    }

    public static func status(at path: String, on location: Location = .local) async throws -> WorktreeStatus {
        let output = try await ProcessRunner.output(
            on: location, "git", ["-C", path, "status", "--porcelain=v2", "--branch"], timeout: .seconds(10),
            caller: "git.status"
        )
        return parseStatus(output)
    }

    // MARK: Changing

    /// Adds a worktree on a new branch `branch` from `origin/<base>` (fetched first, best effort, so the branch starts
    /// from what is on GitHub rather than a stale local ref).
    public static func addWorktree(
        _ record: RepoRecord, path: String, branch: String, base: String
    ) async throws -> Worktree {
        let location = record.location
        _ = try? await ProcessRunner.run(
            on: location,
            "git",
            ["-C", record.path, "fetch", "origin", base],
            timeout: .seconds(30), caller: "git.addWorktree"
        )
        let hasRemote = await (try? ProcessRunner.run(
            on: location, "git", ["-C", record.path, "rev-parse", "--verify", "--quiet", "origin/\(base)"],
            timeout: .seconds(5), caller: "git.addWorktree"
        ))?.succeeded ?? false
        let parent = (path as NSString).deletingLastPathComponent
        if location.isLocal {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        } else {
            _ = try await ProcessRunner.output(on: location, "mkdir", ["-p", parent], caller: "git.addWorktree")
        }
        _ = try await ProcessRunner.output(
            on: location, "git",
            ["-C", record.path, "worktree", "add", "-b", branch, path, hasRemote ? "origin/\(base)" : base],
            caller: "git.addWorktree"
        )
        // On a host `path` may start with ~: keep the worktree's real path.
        let top = try await ProcessRunner.output(
            on: location,
            "git",
            ["-C", path, "rev-parse", "--show-toplevel"],
            caller: "git.addWorktree"
        )
        let head = try await ProcessRunner.output(
            on: location,
            "git",
            ["-C", path, "rev-parse", "--short", "HEAD"],
            caller: "git.addWorktree"
        )
        return Worktree(
            repo: record.repo, path: top.trimmingCharacters(in: .whitespacesAndNewlines), branch: branch,
            head: head.trimmingCharacters(in: .whitespacesAndNewlines), isMain: false, status: WorktreeStatus(),
            location: location
        )
    }

    /// A run's worktree, on its own branch `runBranch` (`heed/get-it-green/<branch>`: git checks a branch out once,
    /// and the PR's is in the session's worktree), started at the remote's tip of `branch` and tracking it. The run
    /// pushes to the PR's branch with `git push origin HEAD:<branch>`. Returns its real path.
    public static func addRunWorktree(
        _ record: RepoRecord, path: String, branch: String, runBranch: String
    ) async throws -> String {
        let location = record.location
        _ = try? await ProcessRunner.run(
            on: location, "git", ["-C", record.path, "fetch", "origin", branch], timeout: .seconds(30),
            caller: "git.addRunWorktree"
        )
        let hasRemote = await (try? ProcessRunner.run(
            on: location, "git", ["-C", record.path, "rev-parse", "--verify", "--quiet", "origin/\(branch)"],
            timeout: .seconds(5), caller: "git.addRunWorktree"
        ))?.succeeded ?? false
        let parent = (path as NSString).deletingLastPathComponent
        if location.isLocal {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        } else {
            _ = try await ProcessRunner.output(on: location, "mkdir", ["-p", parent], caller: "git.addRunWorktree")
        }
        _ = try await ProcessRunner.output(
            on: location, "git",
            // -B: a branch left behind by an earlier helper starts over.
            ["-C", record.path, "worktree", "add", "-B", runBranch, path, hasRemote ? "origin/\(branch)" : branch],
            caller: "git.addRunWorktree"
        )
        if hasRemote {
            _ = try? await ProcessRunner.run(
                on: location, "git", ["-C", path, "branch", "--set-upstream-to", "origin/\(branch)"],
                timeout: .seconds(5), caller: "git.addRunWorktree"
            )
        }
        let top = try await ProcessRunner.output(
            on: location,
            "git",
            ["-C", path, "rev-parse", "--show-toplevel"],
            caller: "git.addRunWorktree"
        )
        return top.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes a worktree heed made for itself (a run's), changes and all, and its branch.
    public static func removeWorktree(_ record: RepoRecord, path: String, branch: String? = nil) async {
        _ = try? await ProcessRunner.run(
            on: record.location, "git", ["-C", record.path, "worktree", "remove", "--force", path],
            timeout: .seconds(30), caller: "git.removeWorktree"
        )
        if let branch {
            _ = try? await ProcessRunner.run(
                on: record.location, "git", ["-C", record.path, "branch", "-D", branch], timeout: .seconds(10),
                caller: "git.removeWorktree"
            )
        }
    }

    /// The remote's commit for `branch`, fetched fresh; nil when it has none.
    public static func remoteSHA(_ record: RepoRecord, branch: String) async -> String? {
        _ = try? await ProcessRunner.run(
            on: record.location, "git", ["-C", record.path, "fetch", "origin", branch], timeout: .seconds(30),
            caller: "git.remoteSHA"
        )
        let sha = try? await ProcessRunner.output(
            on: record.location, "git", ["-C", record.path, "rev-parse", "--verify", "--quiet", "origin/\(branch)"],
            caller: "git.remoteSHA"
        )
        return sha?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// Commits in `to` that are not in `from`.
    public static func commitCount(_ record: RepoRecord, from: String, to: String) async -> Int {
        let text = try? await ProcessRunner.output(
            on: record.location, "git", ["-C", record.path, "rev-list", "--count", "\(from)..\(to)"],
            caller: "git.commitCount"
        )
        return Int(text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    /// Branches a run made (`heed/get-it-green/*`, `heed/get-it-merged/*`), with the worktree each is checked out in.
    public static func runBranches(_ record: RepoRecord) async -> [(branch: String, worktree: String?)] {
        let refs = await (try? ProcessRunner.output(
            on: record.location, "git",
            ["-C", record.path, "for-each-ref", "--format=%(refname:short)", "refs/heads/heed/"],
            caller: "git.runBranches"
        )) ?? ""
        let porcelain = await (try? ProcessRunner.output(
            on: record.location, "git", ["-C", record.path, "worktree", "list", "--porcelain"],
            caller: "git.runBranches"
        )) ?? ""
        var checkedOut: [String: String] = [:]
        var path: String?
        for line in porcelain.split(separator: "\n").map(String.init) {
            if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
            if line.hasPrefix("branch refs/heads/"),
               let path { checkedOut[String(line.dropFirst("branch refs/heads/".count))] = path }
        }
        return refs.split(separator: "\n").map(String.init).filter(Runs.isRunBranch).map { ($0, checkedOut[$0]) }
    }

    /// Brings a worktree up to its upstream when it has no changes of its own and can fast-forward (after a helper
    /// pushed to its branch). True when it moved.
    @discardableResult
    public static func fastForwardIfClean(at path: String, on location: Location = .local) async -> Bool {
        guard let status = try? await self.status(at: path, on: location),
              status.changedFiles == 0, status.untrackedFiles == 0, status.ahead == 0
        else { return false }
        _ = try? await ProcessRunner.run(
            on: location,
            "git",
            ["-C", path, "fetch"],
            timeout: .seconds(30),
            caller: "git.fastForward"
        )
        let result = try? await ProcessRunner.run(
            on: location, "git", ["-C", path, "merge", "--ff-only", "@{u}"], timeout: .seconds(30),
            caller: "git.fastForward"
        )
        return result?.succeeded ?? false
    }

    /// Re-adds a worktree for an existing local `branch` (a reopened session whose worktree was cleaned up).
    public static func restoreWorktree(_ record: RepoRecord, path: String, branch: String) async throws -> Worktree {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        _ = try await ProcessRunner.output(
            "git",
            ["-C", record.path, "worktree", "add", path, branch],
            caller: "git.restoreWorktree"
        )
        let head = try await ProcessRunner.output(
            "git",
            ["-C", path, "rev-parse", "--short", "HEAD"],
            caller: "git.restoreWorktree"
        )
        return Worktree(
            repo: record.repo, path: path, branch: branch, head: head.trimmingCharacters(in: .whitespacesAndNewlines),
            isMain: false, status: WorktreeStatus()
        )
    }

    // MARK: Parsing (pure, tested)

    /// `git@github.com:org/name.git`, `https://github.com/org/name(.git)`, `ssh://git@host/org/name`.
    public static func parseRemote(_ url: String) -> Repo? {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".git") { text.removeLast(4) }
        if text.hasSuffix("/") { text.removeLast() }
        let path: Substring
        if let range = text.range(of: "://") {
            let afterScheme = text[range.upperBound...]
            guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
            path = afterScheme[afterScheme.index(after: slash)...]
        } else if let colon = text.firstIndex(of: ":") {
            path = text[text.index(after: colon)...]
        } else {
            return nil
        }
        let parts = path.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return Repo(org: String(parts[parts.count - 2]), name: String(parts[parts.count - 1]))
    }

    public static func parseWorktrees(_ porcelain: String, repo: Repo) -> [Worktree] {
        var result: [Worktree] = []
        // git lists the main worktree first; a bare repo has none, and its first linked worktree is not it.
        for (index, block) in porcelain.components(separatedBy: "\n\n").enumerated() {
            var path: String?
            var head = ""
            var branch: String?
            var bare = false
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") {
                    path = String(line.dropFirst(9))
                } else if line.hasPrefix("HEAD ") {
                    head = String(line.dropFirst(5).prefix(7))
                } else if line.hasPrefix("branch ") {
                    branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "")
                } else if line == "bare" {
                    bare = true
                }
            }
            guard let path, !bare else { continue }
            result.append(Worktree(repo: repo, path: path, branch: branch, head: head, isMain: index == 0))
        }
        return result
    }

    public static func parseStatus(_ porcelain: String) -> WorktreeStatus {
        var status = WorktreeStatus()
        for line in porcelain.split(separator: "\n") {
            if line.hasPrefix("# branch.upstream ") {
                status.upstream = String(line.dropFirst(18))
            } else if line.hasPrefix("# branch.ab ") {
                for part in line.dropFirst(12).split(separator: " ") {
                    if part.hasPrefix("+") { status.ahead = Int(part.dropFirst()) ?? 0 }
                    if part.hasPrefix("-") { status.behind = Int(part.dropFirst()) ?? 0 }
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") || line.hasPrefix("u ") {
                status.changedFiles += 1
            } else if line.hasPrefix("? ") {
                status.untrackedFiles += 1
            }
        }
        return status
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
