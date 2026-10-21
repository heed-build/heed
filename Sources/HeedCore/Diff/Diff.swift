import Foundation

/// A parsed unified diff, the domain the diff overlay draws. design/screens/Diff.png.
public struct FileDiff: Identifiable, Hashable, Sendable {
    public enum Status: String, Hashable, Sendable {
        case modified = "M", added = "A", deleted = "D", renamed = "R"
    }

    public var id: String { "\(repo?.slug ?? "")/\(path)" }
    public var repo: Repo?
    public var path: String
    public var oldPath: String?
    public var status: Status
    public var hunks: [Hunk]
    public var binary: Bool
    /// Has staged changes (marked with a filled dot).
    public var staged: Bool

    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .added } } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .deleted } } }
}

public struct Hunk: Hashable, Sendable {
    public var header: String
    public var oldStart: Int
    public var newStart: Int
    public var lines: [DiffLine]
}

public struct DiffLine: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case context, added, deleted }

    public var kind: Kind
    public var oldNumber: Int?
    public var newNumber: Int?
    public var text: String
    /// The changed part of a line paired with its counterpart (character offsets), for word-level highlights.
    public var changed: Range<Int>?
}

/// What the overlay compares.
public enum DiffScope: Hashable, Sendable {
    /// Everything since the merge-base with the base branch: commits plus uncommitted work.
    case all
    /// Commits on the branch, vs the merge-base.
    case committed
    case staged
    case unstaged
    case commit(String)

    public static let cycle: [DiffScope] = [.all, .committed, .staged, .unstaged]

    public var title: String {
        switch self {
        case .all: "All"
        case .committed: "Committed"
        case .staged: "Staged"
        case .unstaged: "Unstaged"
        case let .commit(sha): sha
        }
    }
}

public struct CommitSummary: Hashable, Sendable, Identifiable {
    public var id: String { sha }
    public var sha: String
    public var subject: String
}

public enum DiffParser {
    /// Parses `git diff` output (no color, default context).
    public static func parse(_ text: String, repo: Repo? = nil, staged: Set<String> = []) -> [FileDiff] {
        var files: [FileDiff] = []
        var current: FileDiff?
        var hunk: Hunk?
        var oldLine = 0
        var newLine = 0

        func flushHunk() {
            if let finished = hunk { current?.hunks.append(withWordHighlights(finished)) }
            hunk = nil
        }
        func flushFile() {
            flushHunk()
            if let file = current { files.append(file) }
            current = nil
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                flushFile()
                let path = line.components(separatedBy: " b/").last ?? ""
                current = FileDiff(
                    repo: repo, path: path, oldPath: nil, status: .modified, hunks: [], binary: false,
                    staged: staged.contains(path)
                )
            } else if line.hasPrefix("new file mode") {
                current?.status = .added
            } else if line.hasPrefix("deleted file mode") {
                current?.status = .deleted
            } else if line.hasPrefix("rename from ") {
                current?.status = .renamed
                current?.oldPath = String(line.dropFirst(12))
            } else if line.hasPrefix("Binary files") {
                current?.binary = true
            } else if line.hasPrefix("@@") {
                flushHunk()
                let (old, new) = parseHeader(line)
                oldLine = old
                newLine = new
                hunk = Hunk(header: line, oldStart: old, newStart: new, lines: [])
            } else if hunk != nil {
                if line.hasPrefix("+") {
                    hunk?.lines.append(DiffLine(
                        kind: .added,
                        oldNumber: nil,
                        newNumber: newLine,
                        text: String(line.dropFirst())
                    ))
                    newLine += 1
                } else if line.hasPrefix("-") {
                    hunk?.lines.append(DiffLine(
                        kind: .deleted,
                        oldNumber: oldLine,
                        newNumber: nil,
                        text: String(line.dropFirst())
                    ))
                    oldLine += 1
                } else if line.hasPrefix(" ") {
                    hunk?.lines.append(DiffLine(
                        kind: .context, oldNumber: oldLine, newNumber: newLine, text: String(line.dropFirst())
                    ))
                    oldLine += 1
                    newLine += 1
                }
            }
        }
        flushFile()
        return files
    }

    /// `@@ -76,9 +76,16 @@ …` → (76, 76).
    static func parseHeader(_ line: String) -> (Int, Int) {
        let parts = line.split(separator: " ")
        func start(_ part: Substring?) -> Int {
            guard let part else { return 0 }
            return Int(part.dropFirst().split(separator: ",").first ?? "0") ?? 0
        }
        return (start(parts.count > 1 ? parts[1] : nil), start(parts.count > 2 ? parts[2] : nil))
    }

    /// Pairs each run of deleted lines with the added run after it, line by line, and marks what differs between
    /// the pair: everything between their common prefix and suffix.
    static func withWordHighlights(_ hunk: Hunk) -> Hunk {
        var hunk = hunk
        var index = 0
        while index < hunk.lines.count {
            guard hunk.lines[index].kind == .deleted else {
                index += 1
                continue
            }
            let deletedStart = index
            while index < hunk.lines.count, hunk.lines[index].kind == .deleted {
                index += 1
            }
            let addedStart = index
            while index < hunk.lines.count, hunk.lines[index].kind == .added {
                index += 1
            }
            let pairs = min(addedStart - deletedStart, index - addedStart)
            for offset in 0 ..< pairs {
                let (old, new) = changedRanges(
                    hunk.lines[deletedStart + offset].text,
                    hunk.lines[addedStart + offset].text
                )
                hunk.lines[deletedStart + offset].changed = old
                hunk.lines[addedStart + offset].changed = new
            }
        }
        return hunk
    }

    static func changedRanges(_ old: String, _ new: String) -> (Range<Int>?, Range<Int>?) {
        let a = Array(old)
        let b = Array(new)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        let oldRange = prefix < a.count - suffix ? prefix ..< a.count - suffix : nil
        let newRange = prefix < b.count - suffix ? prefix ..< b.count - suffix : nil
        // A pair that shares almost nothing is a rewrite, not an edit: no word highlight.
        let shared = prefix + suffix
        guard shared * 3 >= min(a.count, b.count) else { return (nil, nil) }
        return (oldRange, newRange)
    }

    /// Splits a hunk into side-by-side rows: context on both sides, deleted on the left, added on the right.
    public static func splitRows(_ hunk: Hunk) -> [(left: DiffLine?, right: DiffLine?)] {
        var rows: [(DiffLine?, DiffLine?)] = []
        var deleted: [DiffLine] = []
        var added: [DiffLine] = []
        func flush() {
            for index in 0 ..< max(deleted.count, added.count) {
                rows.append((index < deleted.count ? deleted[index] : nil, index < added.count ? added[index] : nil))
            }
            deleted = []
            added = []
        }
        for line in hunk.lines {
            switch line.kind {
            case .deleted: deleted.append(line)
            case .added: added.append(line)
            case .context:
                flush()
                rows.append((line, line))
            }
        }
        flush()
        return rows
    }
}

public extension Git {
    /// The diff of a worktree for `scope`, against the merge-base with `origin/<base>` (or `<base>`).
    static func diff(at path: String, scope: DiffScope, base: String, repo: Repo?) async throws -> [FileDiff] {
        let args: [String] = switch scope {
        case .all: try await ["diff", "--no-color", "-M", mergeBase(at: path, base: base)]
        case .committed: try await ["diff", "--no-color", "-M", "\(mergeBase(at: path, base: base))..HEAD"]
        case .staged: ["diff", "--no-color", "-M", "--cached"]
        case .unstaged: ["diff", "--no-color", "-M"]
        case let .commit(sha): ["show", "--no-color", "-M", "--format=", sha]
        }
        async let text = ProcessRunner.output("git", ["-C", path] + args, timeout: .seconds(30), caller: "diff.changes")
        async let stagedNames = ProcessRunner.output(
            "git",
            ["-C", path, "diff", "--cached", "--name-only"],
            timeout: .seconds(10), caller: "diff.changes"
        )
        let staged = await Set(((try? stagedNames) ?? "").split(separator: "\n").map(String.init))
        return try await DiffParser.parse(text, repo: repo, staged: staged)
    }

    /// Commits on the branch since it left `base`, newest first.
    static func commits(at path: String, base: String) async throws -> [CommitSummary] {
        let since = try await mergeBase(at: path, base: base)
        let log = try await ProcessRunner.output(
            "git", ["-C", path, "log", "--format=%h%x09%s", "\(since)..HEAD"], timeout: .seconds(15),
            caller: "diff.commits"
        )
        return log.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return CommitSummary(sha: String(parts[0]), subject: String(parts[1]))
        }
    }

    internal static func mergeBase(at path: String, base: String) async throws -> String {
        for candidate in ["origin/\(base)", base] {
            if let sha = try? await ProcessRunner.output(
                "git",
                ["-C", path, "merge-base", "HEAD", candidate],
                timeout: .seconds(10), caller: "diff.mergeBase"
            ) {
                return sha.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return "HEAD"
    }
}
