import Foundation

/// Work saved from a worktree before it was removed: `refs/heed/archive/<branch>` in its repo, pointing at what the
/// worktree had checked out, and `refs/heed/archive/<branch>-wip` with its uncommitted changes when it had any.
public struct ArchiveRef: Identifiable, Hashable, Sendable, Codable {
    public var id: String { location.hostName.map { "\(repo.slug)@\($0):\(branch)" } ?? "\(repo.slug):\(branch)" }
    public var repo: Repo
    public var location: Location
    /// The name under `refs/heed/archive/`: the branch, or the worktree's directory for a detached HEAD.
    public var branch: String
    /// The commit saved (abbreviated).
    public var commit: String
    /// The commit holding the uncommitted changes (on top of `commit`), when there were any.
    public var wip: String?
    public var archivedAt: Date
    /// Commits that were on no remote when it was saved.
    public var unpushed: Int

    public init(
        repo: Repo, location: Location = .local, branch: String, commit: String, wip: String? = nil,
        archivedAt: Date, unpushed: Int = 0
    ) {
        self.repo = repo
        self.location = location
        self.branch = branch
        self.commit = commit
        self.wip = wip
        self.archivedAt = archivedAt
        self.unpushed = unpushed
    }

    /// `heed/archive/old-spike`: what git accepts for it (`git log heed/archive/old-spike`).
    public var name: String { "heed/archive/\(branch)" }

    /// "saved 3 unpushed commits as heed/archive/old-spike"; nil when nothing was at risk (everything was pushed).
    public var said: String? {
        var parts: [String] = []
        if unpushed > 0 { parts.append("\(unpushed) unpushed commit\(unpushed == 1 ? "" : "s")") }
        if wip != nil { parts.append("uncommitted changes") }
        return parts.isEmpty ? nil : "saved \(parts.joined(separator: " and ")) as \(name)"
    }
}

/// Saving, listing, restoring and pruning archive refs. Every removal of a worktree heed made for you saves one first
/// (manual `dd` in Repos and Sessions, and the sweep), wherever the worktree lives. Not for get it green / get it
/// merged runs: their worktrees are heed's own and their work is on the pull request's branch (`RunCleanup`).
///
/// The archive ref points at an annotated tag object heed writes, so one `for-each-ref` reads when it was saved and how
/// many commits were unpushed; git peels it to the commit everywhere a commit is wanted. The changes are a commit on
/// top of it whose tree is the worktree as it was, untracked files included, made with a throwaway index so neither
/// the worktree nor your stash is touched.
public enum Archive {
    public static let prefix = "refs/heed/archive/"
    static let wipSuffix = "-wip"
    static let wipSubject = "heed-archive wip of "

    public static func refName(for branch: String) -> String { prefix + branch }

    /// The name a worktree is saved under: its branch, or its directory when detached.
    public static func name(of worktree: Worktree) -> String {
        worktree.branch ?? URL(fileURLWithPath: worktree.path).lastPathComponent
    }

    /// Saves `worktree` in `record`'s repo, replacing an older archive of the same name. Throws when it cannot (the
    /// worktree is then not removed).
    public static func save(
        _ worktree: Worktree,
        in record: RepoRecord,
        now: Date = Date()
    ) async throws -> ArchiveRef {
        let location = record.location
        let path = worktree.path
        func git(_ directory: String, _ arguments: [String]) async throws -> String {
            try await ProcessRunner.output(
                on: location, "git", ["-C", directory] + arguments, timeout: .seconds(30), caller: "archive.save"
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let branch = name(of: worktree)
        let head = try await git(path, ["rev-parse", "HEAD"])
        let unpushed = try await Int(git(path, ["rev-list", "--count", "HEAD", "--not", "--remotes"])) ?? 0
        let clean = try await git(path, ["status", "--porcelain"]).isEmpty
        let wip = clean ? nil : try await snapshot(path, branch: branch, on: location)

        let tag = try await writeTag(record, head: head, branch: branch, unpushed: unpushed, now: now)
        _ = try await git(record.path, ["update-ref", refName(for: branch), tag])
        if let wip {
            _ = try await git(record.path, ["update-ref", refName(for: branch) + wipSuffix, wip])
        } else {
            // Changes saved by an earlier removal belong to that commit, not this one.
            _ = try? await git(record.path, ["update-ref", "-d", refName(for: branch) + wipSuffix])
        }
        return ArchiveRef(
            repo: record.repo, location: location, branch: branch, commit: String(head.prefix(7)),
            wip: wip.map { String($0.prefix(7)) }, archivedAt: now, unpushed: unpushed
        )
    }

    /// A commit on top of HEAD with the worktree's tree as it is (tracked changes, deletions and untracked files but
    /// not ignored ones), built in a throwaway index.
    private static func snapshot(_ path: String, branch: String, on location: Location) async throws -> String {
        func git(_ arguments: [String], index: String? = nil) async throws -> String {
            // `env` sets the index for this git alone, the same way here and over ssh.
            let command = (index.map { ["GIT_INDEX_FILE=\($0)"] } ?? []) + ["git", "-C", path] + arguments
            return try await ProcessRunner.output(
                on: location, "/usr/bin/env", command, timeout: .seconds(120), caller: "archive.save"
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let index = try await git(["rev-parse", "--path-format=absolute", "--git-path", "heed-archive-index"])
        defer {
            if location.isLocal {
                try? FileManager.default.removeItem(atPath: index)
            } else {
                Task { _ = try? await ProcessRunner.run(on: location, "rm", ["-f", index], caller: "archive.save") }
            }
        }
        _ = try await git(["read-tree", "HEAD"], index: index)
        _ = try await git(["add", "-A"], index: index)
        let tree = try await git(["write-tree"], index: index)
        // heed is the author of the snapshot; the repo may have no identity of its own configured.
        return try await git([
            "-c", "user.name=heed", "-c", "user.email=heed@localhost", "commit-tree", tree, "-p", "HEAD",
            "-m", wipSubject + branch,
        ])
    }

    private static func writeTag(
        _ record: RepoRecord, head: String, branch: String, unpushed: Int, now: Date
    ) async throws -> String {
        let seconds = Int(now.timeIntervalSince1970)
        let text = """
        object \(head)
        type commit
        tag heed-archive/\(branch)
        tagger heed <heed@localhost> \(seconds) +0000

        heed-archive unpushed=\(unpushed)

        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("heed-archive-\(UUID().uuidString)")
        try Data(text.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await ProcessRunner.run(
            on: record.location, "git", ["-C", record.path, "mktag"], input: file, caller: "archive.save"
        )
        guard result.succeeded else {
            throw ProcessError(command: "git mktag", result: result, reason: "exit \(result.status)")
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The repo's archives; nil when git could not be asked (the cached list stays).
    public static func list(_ record: RepoRecord) async -> [ArchiveRef]? {
        guard let output = try? await ProcessRunner.output(
            on: record.location, "git",
            [
                "-C", record.path, "for-each-ref",
                "--format=%(refname)%09%(objecttype)%09%(*objectname:short)%(if:equals=commit)%(objecttype)%(then)"
                    + "%(objectname:short)%(end)%09%(creatordate:unix)%09%(contents:subject)",
                prefix,
            ],
            timeout: .seconds(15), caller: "archive.list"
        ) else { return nil }
        return parse(output, repo: record.repo, location: record.location)
    }

    /// `for-each-ref` lines: `refname TAB type TAB commit TAB unix-date TAB subject`.
    static func parse(_ output: String, repo: Repo, location: Location) -> [ArchiveRef] {
        var refs: [ArchiveRef] = []
        var wips: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5, fields[0].hasPrefix(prefix) else { continue }
            let name = String(fields[0].dropFirst(prefix.count))
            let subject = fields[4]
            if fields[1] == "commit", subject.hasPrefix(wipSubject) {
                wips[String(subject.dropFirst(wipSubject.count))] = fields[2]
                continue
            }
            guard fields[1] == "tag", subject.hasPrefix("heed-archive") else { continue }
            let unpushed = subject.split(separator: " ").first { $0.hasPrefix("unpushed=") }
                .flatMap { Int($0.dropFirst("unpushed=".count)) } ?? 0
            refs.append(ArchiveRef(
                repo: repo, location: location, branch: name, commit: fields[2],
                archivedAt: Date(timeIntervalSince1970: TimeInterval(fields[3]) ?? 0), unpushed: unpushed
            ))
        }
        return refs.map { ref in
            var ref = ref
            ref.wip = wips[ref.branch]
            return ref
        }
    }

    /// Archives older than `keepDays` (0 keeps them all).
    public static func expired(_ refs: [ArchiveRef], keepDays: Int, now: Date = Date()) -> [ArchiveRef] {
        guard keepDays > 0 else { return [] }
        return refs.filter { now.timeIntervalSince($0.archivedAt) > TimeInterval(keepDays) * 86400 }
    }

    /// Deletes an archive and its changes.
    public static func drop(_ ref: ArchiveRef, in record: RepoRecord) async throws {
        _ = try await ProcessRunner.output(
            on: record.location, "git", ["-C", record.path, "update-ref", "-d", refName(for: ref.branch)],
            caller: "archive.drop"
        )
        _ = try? await ProcessRunner.output(
            on: record.location, "git",
            ["-C", record.path, "update-ref", "-d", refName(for: ref.branch) + wipSuffix], caller: "archive.drop"
        )
    }
}
