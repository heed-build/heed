import Foundation

/// What a kept run's session is told: where the run got to, so its agent picks up from the worktree. A kept run is
/// a normal session, with the agent's own tools and no heed policy, so a run that was held to Chat (an author heed
/// does not trust) is not kept at all.
public enum BrowseKeep {
    /// Why a run is not kept as a session, when it is not.
    public static func refusal(_ run: BrowseRun) -> String? {
        if case let .chatOnly(reason) = run.mode {
            return "this run was held to Chat because \(reason): a session would run its agent with no such limits, "
                + "so the worktree is not kept"
        }
        return nil
    }

    /// The prompt of what the run was held to (`effectiveVerb`), not of what was asked for.
    public static func prompt(_ run: BrowseRun, item: BrowseItem, thread: Prompt? = nil) -> String {
        var text = BrowseWorkPrompts.prompt(run.effectiveVerb, item: item, thread: thread).text
        text += "\n\nAn agent already worked on this in this worktree: read `git log` and `git status` to see where it got to, and carry on from there."
        if run.mode == .full, let branch = run.prBranch {
            text += " Push to the pull request's branch with `git push origin HEAD:\(branch)`."
        }
        return text
    }
}
