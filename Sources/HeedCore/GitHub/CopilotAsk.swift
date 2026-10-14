import Foundation

/// Asking GitHub's Copilot coding agent, in one PR comment, to resolve a watched PR's merge conflicts and to address
/// its review comments, instead of your session's agent.
public enum CopilotAsk {
    /// The login GitHub lists among a repo's assignable actors when its Copilot coding agent can work there.
    public static let login = "copilot-swe-agent"

    /// The items Copilot should be asked about now. A conflict (not merely behind) when `copilotConflicts`, review
    /// threads that are new or queued when `copilotComments`; none asked about before. `everything` is `C`: both kinds,
    /// whatever the settings say.
    public static func items(
        _ pipeline: PullFeedback,
        settings: PilotSettings,
        everything: Bool = false
    ) -> [FeedbackItem] {
        pipeline.items.filter { item in
            guard item.copilotAskedAt == nil else { return false }
            switch item.kind {
            case let .conflict(_, behind):
                return (everything || settings.copilotConflicts) && !behind && item.status != .resolved
            case .review:
                return (everything || settings.copilotComments) && (item.status == .new || item.status == .queued)
            case .check:
                return false
            }
        }
    }

    /// One comment for all of them: the merge first, then the comments, numbered.
    public static func comment(base: String, items: [FeedbackItem]) -> String {
        let conflict = items.contains { if case .conflict = $0.kind { true } else { false } }
        let reviews = items.filter { if case .review = $0.kind { true } else { false } }
        var asks: [String] = []
        if conflict { asks.append("merge in \(base) and resolve the conflicts") }
        if !reviews.isEmpty {
            asks.append("address \(reviews.count == 1 ? "this review comment" : "these review comments")")
        }
        guard !asks.isEmpty else { return "" }
        var text = "@copilot Please " + asks.joined(separator: ", then ")
        if !reviews.isEmpty {
            text += ":\n\n" + reviews.enumerated().map { index, item in
                guard case let .review(location, author) = item.kind else { return "" }
                let first = item.text.split(separator: "\n").first.map(String.init) ?? item.text
                return "\(index + 1). `\(location)` (@\(author)): \(first)"
            }.joined(separator: "\n") + "\n\n"
        } else {
            text += ". "
        }
        return text + "Make sure the build and tests still pass."
    }

    /// After asking: sent (so the agent does not get them as well), with when.
    public static func asked(_ pipeline: inout PullFeedback, items ids: [String], at now: Date) {
        for index in pipeline.items.indices where ids.contains(pipeline.items[index].id) {
            pipeline.items[index].copilotAskedAt = now
            pipeline.items[index].status = .sent
            pipeline.items[index].sentAt = now
        }
    }
}

/// Asking for reviews: the reviewers the settings name, once per PR, when it is open and not a draft.
public enum ReviewRequests {
    /// Who to ask now: the configured reviewers not asked before, not the author. `copilot` becomes `@copilot`, as gh
    /// spells it.
    public static func wanted(_ settings: PilotSettings, detail: PullDetail, asked: [String]) -> [String] {
        guard detail.state == "OPEN" || detail.state == nil, detail.isDraft != true else { return [] }
        let author = detail.author?.lowercased()
        let done = Set(asked.map { $0.lowercased() })
        return settings.reviewers.map { $0.lowercased() == "copilot" ? "@copilot" : $0 }
            .filter { !done.contains($0.lowercased()) && $0.lowercased() != author }
    }
}
