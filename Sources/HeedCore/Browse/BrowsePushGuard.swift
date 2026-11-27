import Foundation

/// What a push would publish, asked of the app (which runs git) by the policy (which only reads text). The policy
/// refuses a push whose commits touch a file that runs code later (`BrowsePolicy.protectedWrite`), so an injected
/// agent cannot add a workflow and push it. A guard that cannot tell answers nil, and the push is refused.
public protocol BrowsePushGuard: Sendable {
    /// The files this run's commits changed since it began, relative to the worktree; nil when git could not say.
    func changedFiles(in worktree: String) -> [String]?
}
