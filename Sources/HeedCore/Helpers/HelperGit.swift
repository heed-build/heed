import Foundation

/// What a helper's close-out needs from git and gh, run off the main actor: what it changed in its worktree, the push
/// to the PR's branch (only once you approved), and the replies and review it drafted.
public enum HelperGit {
    /// Commits ahead of where it started, uncommitted changes, and the files changed since `base` (its start).
    public static func changes(worktree: String, base: String) async -> (
        commits: Int, dirty: Bool, files: [HelperFile]
    ) {
        let count = await (try? ProcessRunner.output(
            "git", ["-C", worktree, "rev-list", "--count", "\(base)..HEAD"], caller: "helper.changes"
        )).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        let status = await (try? ProcessRunner.output(
            "git", ["-C", worktree, "status", "--porcelain"], caller: "helper.changes"
        )) ?? ""
        // Against the start, uncommitted work included; new files show once they are added.
        _ = try? await ProcessRunner.run(
            "git", ["-C", worktree, "add", "--intent-to-add", "--all"], timeout: .seconds(10), caller: "helper.changes"
        )
        let numstat = await (try? ProcessRunner.output(
            "git", ["-C", worktree, "diff", "--numstat", base], caller: "helper.changes"
        )) ?? ""
        return (count, !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, files(numstat))
    }

    /// `12\t3\tsrc/a.cs` lines; a binary file (`-\t-`) counts as nothing.
    public static func files(_ numstat: String) -> [HelperFile] {
        numstat.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2)
            guard fields.count == 3 else { return nil }
            return HelperFile(path: String(fields[2]), added: Int(fields[0]) ?? 0, removed: Int(fields[1]) ?? 0)
        }
    }

    /// Where it started: the worktree's first commit, its HEAD when it was made.
    public static func head(_ worktree: String) async -> String? {
        await (try? ProcessRunner.output("git", ["-C", worktree, "rev-parse", "HEAD"], caller: "helper.head"))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Commits what is left uncommitted (with `message`), then pushes to the PR's branch: the new head.
    public static func push(worktree: String, prBranch: String, message: String) async throws -> String {
        let status = try await ProcessRunner.output(
            "git", ["-C", worktree, "status", "--porcelain"], caller: "helper.push"
        )
        if !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try await ProcessRunner.output("git", ["-C", worktree, "add", "--all"], caller: "helper.push")
            _ = try await ProcessRunner.output(
                "git", ["-C", worktree, "commit", "-m", message], caller: "helper.push"
            )
        }
        let result = try await ProcessRunner.run(
            "git", ["-C", worktree, "push", "origin", "HEAD:\(prBranch)"], timeout: .seconds(120), caller: "helper.push"
        )
        guard result.succeeded else {
            throw ProcessError(
                command: "git push", result: result,
                reason: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return try await ProcessRunner.output("git", ["-C", worktree, "rev-parse", "HEAD"], caller: "helper.push")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The diff of everything it changed since `base`, for the close-out's diff.
    public static func diff(worktree: String, base: String, repo: Repo) async -> [FileDiff] {
        let text = await (try? ProcessRunner.output(
            "git", ["-C", worktree, "diff", base], caller: "helper.diff"
        )) ?? ""
        return DiffParser.parse(text, repo: repo)
    }
}

public extension GitHub {
    /// A PR's branches, title and description, for a review helper: `gh pr view`.
    static func pullForReview(_ ref: PullRef, caller: String) async throws -> (
        head: String, base: String, title: String, body: String
    ) {
        let result = try await gh(
            ["pr", "view", "\(ref.number)", "-R", ref.repo.slug, "--json", "headRefName,baseRefName,title,body"],
            operation: "pr view", timeout: .seconds(30), caller: caller
        )
        guard result.succeeded, let json = JSONValue.parse(result.stdout), let head = json["headRefName"]?.string else {
            throw Failure(description: explain(result))
        }
        return (
            head, json["baseRefName"]?.string ?? "main", json["title"]?.string ?? "",
            json["body"]?.string ?? ""
        )
    }

    /// A reply on a review thread, by the thread's node id.
    static func replyToThread(_ threadID: String, body: String, caller: String) async throws {
        let query = """
        mutation($thread: ID!, $body: String!) {
          addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $thread, body: $body}) { comment { id } }
        }
        """
        let result = try await gh(
            ["api", "graphql", "-f", "query=\(query)", "-f", "thread=\(threadID)", "-f", "body=\(body)"],
            operation: "graphql addPullRequestReviewThreadReply", write: true, timeout: .seconds(45), caller: caller
        )
        guard result.succeeded else { throw Failure(description: explain(result)) }
    }

    /// A review on someone else's PR: `comment`, `approve` or `request changes`, with its body.
    static func review(_ ref: PullRef, verdict: String?, body: String, caller: String) async throws {
        let flag = switch verdict {
        case "approve": "--approve"
        case "request changes", "request_changes", "request-changes": "--request-changes"
        default: "--comment"
        }
        let result = try await gh(
            ["pr", "review", "\(ref.number)", flag, "-b", body, "-R", ref.repo.slug], operation: "pr review",
            write: true, timeout: .seconds(60), caller: caller
        )
        guard result.succeeded else { throw Failure(description: explain(result)) }
    }
}
