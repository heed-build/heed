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
            timeout: .seconds(5)
        )
        return url.flatMap { parseRemote($0) } ?? Repo(org: "local", name: URL(fileURLWithPath: path).lastPathComponent)
    }

    /// `main` from `origin/HEAD`, falling back to `main`.
    public static func defaultBranch(at path: String, on location: Location = .local) async -> String {
        let ref = try? await ProcessRunner.output(
            on: location, "git", ["-C", path, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
            timeout: .seconds(5)
        )
        let name = ref?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "main" : String(name.split(separator: "/", maxSplits: 1).last ?? "main")
    }

    /// A record for the checkout at `path`, or nil when it is not a git repository's main checkout.
    public static func record(at path: String, on location: Location = .local) async -> RepoRecord? {
        guard let top = try? await ProcessRunner.output(
            on: location, "git", ["-C", path, "rev-parse", "--show-toplevel"], timeout: .seconds(5)
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
            "git", ["-C", path, "rev-parse", "--show-toplevel"], timeout: .seconds(5)
        ), let common = try? await ProcessRunner.output(
            "git", ["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"], timeout: .seconds(5)
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
            on: record.location, "git", ["-C", record.path, "worktree", "list", "--porcelain"]
        )
        return parseWorktrees(output, repo: record.repo).map { worktree in
            var worktree = worktree
            worktree.location = record.location
            return worktree
        }
    }

    public static func status(at path: String, on location: Location = .local) async throws -> WorktreeStatus {
        let output = try await ProcessRunner.output(
            on: location, "git", ["-C", path, "status", "--porcelain=v2", "--branch"], timeout: .seconds(10)
        )
        return parseStatus(output)
    }

    // MARK: Changing

    /// Adds a worktree on a new branch `branch` from `origin/<base>` (fetched first, best effort, so the branch starts
    /// from what is on GitHub rather than a stale local ref).
    public static func addWorktree(
        _ record: RepoRecord, path: String, branch: String, base: String
    ) async throws -> Worktree {
        _ = try? await ProcessRunner.run("git", ["-C", record.path, "fetch", "origin", base], timeout: .seconds(30))
        let hasRemote = await (try? ProcessRunner.run(
            "git", ["-C", record.path, "rev-parse", "--verify", "--quiet", "origin/\(base)"], timeout: .seconds(5)
        ))?.succeeded ?? false
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        _ = try await ProcessRunner.output(
            "git", ["-C", record.path, "worktree", "add", "-b", branch, path, hasRemote ? "origin/\(base)" : base]
        )
        let head = try await ProcessRunner.output("git", ["-C", path, "rev-parse", "--short", "HEAD"])
        return Worktree(
            repo: record.repo, path: path, branch: branch, head: head.trimmingCharacters(in: .whitespacesAndNewlines),
            isMain: false, status: WorktreeStatus()
        )
    }

    /// Re-adds a worktree for an existing local `branch` (a reopened session whose worktree was cleaned up).
    public static func restoreWorktree(_ record: RepoRecord, path: String, branch: String) async throws -> Worktree {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        _ = try await ProcessRunner.output("git", ["-C", record.path, "worktree", "add", path, branch])
        let head = try await ProcessRunner.output("git", ["-C", path, "rev-parse", "--short", "HEAD"])
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
