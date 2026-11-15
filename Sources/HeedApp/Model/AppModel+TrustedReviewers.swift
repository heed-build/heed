import Foundation
import HeedCore

/// Bots that review a repo's PRs, suggested for its `trusted_reviewers` (`ReviewerSuggestion`): accepting writes the
/// repo's list to config.toml, dismissing remembers not to ask again. Never added without you.
extension AppModel {
    /// The bots heed suggests trusting in a PR's repo, from the reviews it fetched there.
    func reviewerSuggestions(for repo: Repo) -> [ReviewerSuggestion] {
        ReviewerSuggestion.suggest(
            repo: repo, details: Array(pullDetails.values), trusted: config.pilot.resolve(repo).trustedReviewers,
            dismissed: dismissedReviewerSuggestions
        )
    }

    private func suggestedReviewer(_ login: String?) -> ReviewerSuggestion? {
        guard let repo = pilotTargets.first?.repo else {
            flash = noOpenPR
            return nil
        }
        let suggestions = reviewerSuggestions(for: repo)
        let found = login.map { name in
            suggestions.first { GateCheck.normalize($0.login) == GateCheck.normalize(name) }
        } ?? suggestions.first
        if found == nil { flash = "no reviewer to suggest for \(repo.slug)" }
        return found
    }

    /// `:pilot.reviewers.trust [login]`: the repo's `trusted_reviewers` with the bot added.
    func trustSuggestedReviewer(_ login: String?) {
        guard let suggestion = suggestedReviewer(login) else { return }
        let repo = suggestion.repo
        let list = suggestion.accepted(config.pilot.resolve(repo).trustedReviewers)
        writeAutopilot([AutopilotSwitch.Write(
            ["repos", repo.slug, "trusted_reviewers"], .array(list.map(TOMLValue.string))
        )])
        flash = "\(suggestion.entry) trusted in \(repo.slug): its approvals count for heed's merges"
    }

    /// `:pilot.reviewers.dismiss [login]`: not suggested again for the repo.
    func dismissSuggestedReviewer(_ login: String?) {
        guard let suggestion = suggestedReviewer(login) else { return }
        dismissedReviewerSuggestions.insert(suggestion.id)
        flash = "\(suggestion.login) won't be suggested for \(suggestion.repo.slug) again"
    }
}
