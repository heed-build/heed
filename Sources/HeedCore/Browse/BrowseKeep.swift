import Foundation

/// What a kept run's session is told: where the run got to, so its agent picks up from the worktree.
public enum BrowseKeep {
    public static func prompt(_ run: BrowseRun, item: BrowseItem) -> String {
        var text = BrowseWorkPrompts.prompt(run.verb, item: item).text
        text += "\n\nAn agent already worked on this in this worktree: read `git log` and `git status` to see where it got to, and carry on from there."
        if let branch = run
            .prBranch { text += " Push to the pull request's branch with `git push origin HEAD:\(branch)`." }
        return text
    }
}

extension BrowseKeep {
    /// Why a run is not kept as a session, when it is not.
    public static func refusal(_ run: BrowseRun) -> String? { nil }
}
