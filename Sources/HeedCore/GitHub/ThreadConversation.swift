import Foundation

/// An issue or PR as the reader shows it: its opening post and its conversation, each as GitHub's own rendered HTML
/// (`bodyHTML`), with who wrote it, when, and the reactions it got. Fetched when a reader opens the thread
/// (`GitHub.conversation`), never as part of a sync.
public struct ThreadConversation: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case issue, pr
    }

    public var repo: Repo
    public var number: Int
    public var kind: Kind
    public var title: String
    public var url: String
    /// `OPEN`, `CLOSED`, or for a PR `MERGED`.
    public var state: String
    /// Why an issue closed: `COMPLETED`, `NOT_PLANNED`, `DUPLICATE`; nil when open or unknown.
    public var stateReason: String?
    public var isDraft: Bool
    public var author: ThreadAuthor?
    public var createdAt: Date
    /// GitHub's rendered HTML of the opening post (empty when there is no description).
    public var bodyHTML: String
    public var reactions: [ThreadReaction]
    public var labels: [String]
    /// Comments (and, on a PR, reviews that say something), oldest first: the newest `GitHub.conversationCap`.
    public var comments: [ThreadComment]
    /// How many comments GitHub has, so the reader can say how many older ones it did not load.
    public var totalComments: Int
    public var fetchedAt: Date

    public init(
        repo: Repo, number: Int, kind: Kind, title: String, url: String, state: String, stateReason: String? = nil,
        isDraft: Bool = false, author: ThreadAuthor?, createdAt: Date, bodyHTML: String,
        reactions: [ThreadReaction] = [], labels: [String] = [], comments: [ThreadComment] = [],
        totalComments: Int? = nil, fetchedAt: Date
    ) {
        self.repo = repo
        self.number = number
        self.kind = kind
        self.title = title
        self.url = url
        self.state = state
        self.stateReason = stateReason
        self.isDraft = isDraft
        self.author = author
        self.createdAt = createdAt
        self.bodyHTML = bodyHTML
        self.reactions = reactions
        self.labels = labels
        self.comments = comments
        self.totalComments = totalComments ?? comments.count(where: { $0.review == nil })
        self.fetchedAt = fetchedAt
    }

    /// `acme/docs-toolkit#2845`, lowercased: how the app keys conversations.
    public static func key(repo: Repo, number: Int) -> String { "\(repo.slug)#\(number)".lowercased() }
    public var key: String { Self.key(repo: repo, number: number) }

    /// Issue comments GitHub has that were not loaded (older than the cap).
    public var olderNotLoaded: Int { max(totalComments - comments.count(where: { $0.review == nil }), 0) }

    /// The state as a chip says it: `open`, `draft`, `merged`, `closed`, `closed as not planned`.
    public var stateText: String {
        switch state {
        case "OPEN": isDraft ? "draft" : "open"
        case "MERGED": "merged"
        default:
            switch stateReason {
            case "NOT_PLANNED": "closed as not planned"
            case "DUPLICATE": "closed as duplicate"
            default: "closed"
            }
        }
    }
}

public struct ThreadAuthor: Hashable, Sendable, Codable {
    public var login: String
    /// GitHub's avatar for the account (bots and apps included), when the API gave one.
    public var avatarURL: String?
    public var isBot: Bool

    public init(login: String, avatarURL: String? = nil, isBot: Bool = false) {
        self.login = login
        self.avatarURL = avatarURL
        self.isBot = isBot
    }
}

/// One reaction and how many gave it.
public struct ThreadReaction: Hashable, Sendable, Codable {
    /// GitHub's name: `THUMBS_UP`, `HOORAY`, `EYES`, ...
    public var content: String
    public var count: Int

    public init(content: String, count: Int) {
        self.content = content
        self.count = count
    }

    /// The emoji GitHub shows for it.
    public var emoji: String {
        switch content {
        case "THUMBS_UP": "👍"
        case "THUMBS_DOWN": "👎"
        case "LAUGH": "😄"
        case "HOORAY": "🎉"
        case "CONFUSED": "😕"
        case "HEART": "❤️"
        case "ROCKET": "🚀"
        case "EYES": "👀"
        default: content.lowercased()
        }
    }
}

/// A comment on an issue or PR, or a PR review with a verdict or something to say.
public struct ThreadComment: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var author: ThreadAuthor?
    public var createdAt: Date
    public var bodyHTML: String
    public var reactions: [ThreadReaction]
    public var url: String?
    /// A review's state (`APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, `DISMISSED`); nil for a comment.
    public var review: String?
    /// Hidden on GitHub (spam, off topic, outdated, resolved): the reader shows the reason and no body.
    public var minimizedReason: String?

    public init(
        id: String, author: ThreadAuthor?, createdAt: Date, bodyHTML: String, reactions: [ThreadReaction] = [],
        url: String? = nil, review: String? = nil, minimizedReason: String? = nil
    ) {
        self.id = id
        self.author = author
        self.createdAt = createdAt
        self.bodyHTML = bodyHTML
        self.reactions = reactions
        self.url = url
        self.review = review
        self.minimizedReason = minimizedReason
    }

    /// The verb in the card's header: `commented`, `approved`, `requested changes`, `reviewed`.
    public var verb: String {
        switch review {
        case nil: "commented"
        case "APPROVED": "approved"
        case "CHANGES_REQUESTED": "requested changes"
        case "DISMISSED": "reviewed (dismissed)"
        default: "reviewed"
        }
    }
}

/// Which comments the reader folds, and where "new · N" goes, given when you last looked at the thread.
public struct ThreadFold: Equatable, Sendable {
    /// Leading comments folded into "N earlier comments, read".
    public var folded: Int
    /// The index of the first new comment, where the divider goes; nil for no divider.
    public var divider: Int?
    /// Comments after the divider.
    public var newCount: Int

    public init(folded: Int, divider: Int?, newCount: Int) {
        self.folded = folded
        self.divider = divider
        self.newCount = newCount
    }

    /// Without `seenAt` nothing folds and there is no divider. With it, comments written up to then are read: they
    /// fold, and the divider sits at the first one after. When nothing is new, the last read one stays out as
    /// context. `unfolded` (a click on the fold) shows them all and keeps the divider.
    public static func compute(_ comments: [ThreadComment], seenAt: Date?, unfolded: Bool = false) -> ThreadFold {
        guard let seenAt, !comments.isEmpty else { return ThreadFold(folded: 0, divider: nil, newCount: 0) }
        let firstNew = comments.firstIndex { $0.createdAt > seenAt } ?? comments.count
        let newCount = comments.count - firstNew
        let folded = unfolded ? 0 : newCount > 0 ? firstNew : comments.count - 1
        return ThreadFold(folded: folded, divider: newCount > 0 ? firstNew : nil, newCount: newCount)
    }

    /// `6 earlier comments, read`.
    public var foldText: String { "\(folded) earlier comment\(folded == 1 ? "" : "s"), read" }
    /// `new · 3`.
    public var dividerText: String { "new · \(newCount)" }
}

public extension GitHub {
    /// The newest comments a reader loads; older ones are counted, and GitHub has them.
    static let conversationCap = 300

    /// An issue or PR with its rendered body and its newest comments (pages of 100, back from the newest, up to
    /// `conversationCap`).
    static func conversation(
        repo: Repo, number: Int, now: Date = Date(), caller: String
    ) async throws -> ThreadConversation {
        var variables = ["owner": repo.org, "name": repo.name, "number": String(number)]
        var conversation: ThreadConversation?
        var older: [ThreadComment] = []
        while true {
            let data = try await graphql(
                conversationQuery, operation: "conversation", variables: variables, caller: caller
            )
            guard let page = parseConversation(data, repo: repo, number: number, now: now) else {
                throw Failure(description: "\(repo.slug)#\(number) is not visible to gh")
            }
            if conversation == nil {
                conversation = page.conversation
            } else {
                // Later pages are older comments only: the reviews came with the first.
                older = page.conversation.comments.filter { $0.review == nil } + older
            }
            let loaded = (conversation?.comments.count ?? 0) + older.count
            guard let cursor = page.before, loaded < conversationCap else { break }
            variables["before"] = cursor
        }
        guard var conversation else { throw Failure(description: "\(repo.slug)#\(number) is not visible to gh") }
        conversation.comments = (older + conversation.comments).sorted { $0.createdAt < $1.createdAt }
        if conversation.comments.count > conversationCap {
            conversation.comments = Array(conversation.comments.suffix(conversationCap))
        }
        return conversation
    }

    internal static let conversationQuery = """
    query($owner: String!, $name: String!, $number: Int!, $before: String) {
      repository(owner: $owner, name: $name) { issueOrPullRequest(number: $number) {
        __typename
        ... on Issue { number title url state stateReason createdAt bodyHTML
          author { __typename login avatarUrl } labels(first: 20) { nodes { name } }
          reactionGroups { content reactors { totalCount } }
          comments(last: 100, before: $before) { totalCount pageInfo { hasPreviousPage startCursor }
            nodes { ...heedComment } } }
        ... on PullRequest { number title url state isDraft createdAt bodyHTML
          author { __typename login avatarUrl } labels(first: 20) { nodes { name } }
          reactionGroups { content reactors { totalCount } }
          comments(last: 100, before: $before) { totalCount pageInfo { hasPreviousPage startCursor }
            nodes { ...heedComment } }
          reviews(last: 50) { nodes { id url state submittedAt bodyHTML author { __typename login avatarUrl }
            reactionGroups { content reactors { totalCount } } } } }
      } }
    }
    fragment heedComment on IssueComment { id url createdAt bodyHTML isMinimized minimizedReason
      author { __typename login avatarUrl } reactionGroups { content reactors { totalCount } } }
    """

    /// One page of `conversationQuery`: the thread with this page's comments, and the cursor for the page before it
    /// (nil on the first page).
    internal static func parseConversation(
        _ data: Data, repo: Repo, number: Int, now: Date
    ) -> (conversation: ThreadConversation, before: String?)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let repository = (json["data"] as? [String: Any])?["repository"] as? [String: Any],
              let node = repository["issueOrPullRequest"] as? [String: Any]
        else { return nil }
        let isPull = node["__typename"] as? String == "PullRequest"
        let commentsNode = node["comments"] as? [String: Any]
        var comments = ((commentsNode?["nodes"] as? [Any]) ?? []).compactMap { raw -> ThreadComment? in
            guard let comment = raw as? [String: Any], let id = comment["id"] as? String else { return nil }
            return ThreadComment(
                id: id, author: author(comment["author"]), createdAt: date(comment["createdAt"] as? String),
                bodyHTML: comment["bodyHTML"] as? String ?? "", reactions: reactions(comment["reactionGroups"]),
                url: comment["url"] as? String,
                minimizedReason: comment["isMinimized"] as? Bool == true
                    ? (comment["minimizedReason"] as? String ?? "hidden").lowercased().replacingOccurrences(
                        of: "_", with: " "
                    ) : nil
            )
        }
        // Reviews join the conversation when they have a verdict or say something; a review that only carries
        // inline comments is in the review threads instead, and a pending one is the viewer's unsent draft.
        let reviews = (((node["reviews"] as? [String: Any])?["nodes"] as? [Any]) ?? []).compactMap { raw in
            raw as? [String: Any]
        }
        comments += reviews.compactMap { review -> ThreadComment? in
            guard let id = review["id"] as? String, let state = review["state"] as? String, state != "PENDING"
            else { return nil }
            let body = review["bodyHTML"] as? String ?? ""
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || ["APPROVED", "CHANGES_REQUESTED"].contains(state)
            else { return nil }
            return ThreadComment(
                id: id, author: author(review["author"]), createdAt: date(review["submittedAt"] as? String),
                bodyHTML: body, reactions: reactions(review["reactionGroups"]), url: review["url"] as? String,
                review: state
            )
        }
        comments.sort { $0.createdAt < $1.createdAt }
        let pageInfo = commentsNode?["pageInfo"] as? [String: Any]
        let before = pageInfo?["hasPreviousPage"] as? Bool == true ? pageInfo?["startCursor"] as? String : nil
        let labels = ((node["labels"] as? [String: Any])?["nodes"] as? [[String: Any]])?
            .compactMap { $0["name"] as? String } ?? []
        let conversation = ThreadConversation(
            repo: repo, number: node["number"] as? Int ?? number, kind: isPull ? .pr : .issue,
            title: node["title"] as? String ?? "", url: node["url"] as? String ?? "",
            state: node["state"] as? String ?? "OPEN", stateReason: node["stateReason"] as? String,
            isDraft: node["isDraft"] as? Bool ?? false, author: author(node["author"]),
            createdAt: date(node["createdAt"] as? String), bodyHTML: node["bodyHTML"] as? String ?? "",
            reactions: reactions(node["reactionGroups"]), labels: labels, comments: comments,
            totalComments: commentsNode?["totalCount"] as? Int, fetchedAt: now
        )
        return (conversation, before)
    }

    private static func author(_ value: Any?) -> ThreadAuthor? {
        guard let author = value as? [String: Any], let login = author["login"] as? String else { return nil }
        return ThreadAuthor(
            login: login, avatarURL: author["avatarUrl"] as? String, isBot: author["__typename"] as? String == "Bot"
        )
    }

    /// Reactions someone gave, in GitHub's order.
    private static func reactions(_ value: Any?) -> [ThreadReaction] {
        ((value as? [Any]) ?? []).compactMap { raw in
            guard let group = raw as? [String: Any], let content = group["content"] as? String,
                  let count = (group["reactors"] as? [String: Any])?["totalCount"] as? Int, count > 0
            else { return nil }
            return ThreadReaction(content: content, count: count)
        }
    }
}
