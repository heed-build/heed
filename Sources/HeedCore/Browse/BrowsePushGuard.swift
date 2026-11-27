import Foundation

/// What a push would publish, asked of the app (which runs git) by the policy (which only reads text). The policy
/// refuses a push whose commits touch a file that runs code later (`BrowsePolicy.protectedWrite`), so an injected
/// agent cannot add a workflow and push it. A guard that cannot tell answers nil, and the push is refused.
public protocol BrowsePushGuard: Sendable {
    /// The files this run's commits changed since it began, relative to the worktree; nil when git could not say.
    func changedFiles(in worktree: String) -> [String]?
    /// The branch HEAD is on; nil on a detached HEAD or when git could not say.
    func currentBranch(in worktree: String) -> String?
}

/// The real guard: asks git. `start` is the commit the run began at, so a pull request's own earlier changes to a
/// workflow are not blamed on the run, and only what the run added is looked at.
public struct GitPushGuard: BrowsePushGuard {
    public var start: String?

    public init(start: String?) { self.start = start }

    public func changedFiles(in worktree: String) -> [String]? {
        guard let start, !start.isEmpty else { return nil }
        guard let out = Self.git(
            worktree,
            ["diff", "--name-only", "--no-renames", "--no-ext-diff", "-z", start, "HEAD"]
        )
        else { return nil }
        return out.split(separator: "\0").map(String.init)
    }

    public func currentBranch(in worktree: String) -> String? {
        guard let out = Self.git(worktree, ["symbolic-ref", "--quiet", "--short", "HEAD"]) else { return nil }
        let name = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The commit HEAD is at, to start a run's push guard from.
    public static func head(of worktree: String) -> String? {
        git(worktree, ["rev-parse", "HEAD"])?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs git in `worktree` with no hook, no pager and a scrubbed environment; nil when it fails. Called off the
    /// main actor, where the policy runs.
    private static func git(_ worktree: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "git",
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "core.fsmonitor=false",
            "--no-pager",
            "-C",
            worktree,
        ]
            + arguments
        process.environment = GitEnvironment.scrubbed(ProcessInfo.processInfo.environment)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
