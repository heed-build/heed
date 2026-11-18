import Foundation

/// One issue or pull request in Browse: what a GitHub search answers, cached as it was fetched. Whether its repo is
/// cloned on this Mac is not kept here: that is a fact about the Mac (`RepoPlace`), derived when a row is drawn.
public struct BrowseItem: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable { case issue, pull }
    public enum State: String, Hashable, Sendable, Codable { case open, closed, merged }
    public enum Checks: String, Hashable, Sendable, Codable { case passing, failing, pending }

    /// `org/repo#12`, lowercased: the same id Attention gives the thread.
    public var id: String
    public var kind: Kind
    public var repo: Repo
    public var number: Int
    public var title: ExternalText
    public var url: String
    public var state: State
    public var author: String?
    public var authorIsBot: Bool
    public var labels: [String]
    public var assignees: [String]
    public var milestone: String?
    /// The titles of the Projects (boards) it is on.
    public var projects: [String]
    public var comments: Int
    public var createdAt: Date
    public var updatedAt: Date
    /// An issue a pull request closes, or a pull request that closes an issue.
    public var hasLinkedPull: Bool
    public var isDraft: Bool
    public var checks: Checks?
    public var review: ReviewDecision?

    public init(
        repo: Repo, number: Int, kind: Kind = .issue, title: ExternalText, url: String? = nil, state: State = .open,
        author: String? = nil, authorIsBot: Bool = false, labels: [String] = [], assignees: [String] = [],
        milestone: String? = nil, projects: [String] = [], comments: Int = 0, createdAt: Date = .distantPast,
        updatedAt: Date = .distantPast, hasLinkedPull: Bool = false, isDraft: Bool = false, checks: Checks? = nil,
        review: ReviewDecision? = nil
    ) {
        id = AttentionItem.threadID(repo, number)
        self.kind = kind
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url ?? "https://github.com/\(repo.slug)/\(kind == .pull ? "pull" : "issues")/\(number)"
        self.state = state
        self.author = author
        self.authorIsBot = authorIsBot
        self.labels = labels
        self.assignees = assignees
        self.milestone = milestone
        self.projects = projects
        self.comments = comments
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.hasLinkedPull = hasLinkedPull
        self.isDraft = isDraft
        self.checks = checks
        self.review = review
    }

    /// `acme/docs#12`.
    public var place: String { "\(repo.slug)#\(number)" }
}
