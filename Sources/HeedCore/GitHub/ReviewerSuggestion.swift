import Foundation

/// A bot that reviews a repo's PRs but is not among its `trusted_reviewers`, so its approvals do not count for heed's
/// merges: heed asks whether to trust it, and never adds it by itself. Found in the reviews heed already fetched.
public struct ReviewerSuggestion: Hashable, Sendable, Identifiable {
    public let repo: Repo
    /// As GitHub names it in a review.
    public let login: String
    /// GitHub says it is a bot (an app, or a `[bot]` account), rather than only going by its name.
    public let isBot: Bool

    public init(repo: Repo, login: String, isBot: Bool) {
        self.repo = repo
        self.login = login
        self.isBot = isBot
    }

    /// `org/name|login`: what dismissing remembers.
    public var id: String { "\(repo.slug)|\(GateCheck.normalize(login))" }

    public var text: String { "\(login) reviews here: trust its approvals?" }

    /// The entry accepting writes: `name[bot]` for a bot, which matches only a bot of that name.
    public var entry: String {
        isBot && !login.lowercased().hasSuffix("[bot]") ? login + "[bot]" : login
    }

    /// Copilot code review's reviewer.
    public static let copilot = "copilot-pull-request-reviewer"

    /// The repo's `trusted_reviewers` with this one added.
    public func accepted(_ current: [String]) -> [String] {
        current.contains { HeedMerge.listed($0, login: login, isBot: isBot) } ? current : current + [entry]
    }

    /// Bots (by GitHub's author type, a `[bot]` login, or Copilot's reviewer) that reviewed one of `details`' PRs in
    /// `repo`, are not trusted yet and were not dismissed, by login.
    public static func suggest(
        repo: Repo, details: [PullDetail], trusted: [String], dismissed: Set<String>
    ) -> [ReviewerSuggestion] {
        var found: [String: ReviewerSuggestion] = [:]
        for detail in details where detail.ref.repo == repo {
            for review in detail.reviews {
                let isBot = review.trust == .bot
                guard isBot || GateCheck.normalize(review.author) == copilot else { continue }
                guard !trusted.contains(where: { HeedMerge.listed($0, login: review.author, isBot: isBot) })
                else { continue }
                let suggestion = ReviewerSuggestion(repo: repo, login: review.author, isBot: isBot)
                guard !dismissed.contains(suggestion.id) else { continue }
                found[suggestion.id] = found[suggestion.id] ?? suggestion
            }
        }
        return found.values.sorted { $0.login.lowercased() < $1.login.lowercased() }
    }
}
