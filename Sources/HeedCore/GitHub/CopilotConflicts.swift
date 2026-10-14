import Foundation

/// Asking GitHub's Copilot coding agent to resolve a watched PR's merge conflicts, instead of your session's agent.
public enum CopilotConflicts {
    /// The login GitHub lists among a repo's assignable actors when its Copilot coding agent can work there.
    public static let login = "copilot-swe-agent"

    /// The comment that asks it, in the words GitHub documents.
    public static func comment(base: String) -> String {
        "@copilot Merge in \(base) and resolve the conflicts, then make sure the build and tests still pass."
    }

    /// The open conflict item Copilot should be asked about now, if any: the PR conflicts (not merely behind), the
    /// settings say copilot, the PR is watched and not paused, Copilot can work in the repo, and it was not asked
    /// about this conflict yet.
    public static func itemToAsk(
        _ pipeline: PullFeedback, settings: PilotSettings, watching: Bool, paused: Bool, copilotAvailable: Bool
    ) -> FeedbackItem? {
        guard settings.conflicts == .copilot, watching, !paused, copilotAvailable else { return nil }
        return pipeline.items.first { item in
            guard case let .conflict(_, behind) = item.kind else { return false }
            return !behind && item.status != .resolved && item.copilotAskedAt == nil
        }
    }

    /// The conflict item after asking: sent (so it is not fed to the agent as well), with when.
    public static func asked(_ pipeline: inout PullFeedback, item id: String, at now: Date) {
        guard let index = pipeline.items.firstIndex(where: { $0.id == id }) else { return }
        pipeline.items[index].copilotAskedAt = now
        pipeline.items[index].status = .sent
        pipeline.items[index].sentAt = now
    }
}
