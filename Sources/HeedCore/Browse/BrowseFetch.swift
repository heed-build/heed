import Foundation

/// Browse's fetch: one GitHub search over issues and pull requests, with what the list and the reader need. It runs
/// on demand (opening a scope, changing the query, "Show older"), never on the sync's poll, and the cache draws first.
public enum BrowseFetch {
    public static let caller = "browse.search"
    /// The most items one fetch brings in (GitHub's search holds 1000; a list that long is filtered, not read).
    public static let defaultCap = 300

    public struct Result: Equatable, Sendable {
        public var items: [BrowseItem] = []
        /// What GitHub says the search holds, of which `items` may be only the first part.
        public var total: Int = 0
        public var capped = false
        /// Items GitHub withheld (SAML).
        public var hidden = 0
        public var fetchedAt = Date.distantPast
    }

    static let fields = """
    number title url state createdAt updatedAt authorAssociation
    repository { nameWithOwner }
    author { login __typename }
    labels(first: 10) { nodes { name } }
    assignees(first: 5) { nodes { login } }
    milestone { title }
    comments { totalCount }
    projectItems(first: 5) { nodes { project { title } } }
    """

    static let query = """
    query($q: String!, $after: String) { search(query: $q, type: ISSUE, first: 100, after: $after) {
      issueCount pageInfo { hasNextPage endCursor } nodes {
        ... on Issue { \(fields) closedByPullRequestsReferences(first: 1) { totalCount } }
        ... on PullRequest { \(fields) isDraft reviewDecision
          reviewRequests(first: 10) { nodes { requestedReviewer { ... on User { login } } } }
          closingIssuesReferences(first: 1) { totalCount }
          commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } }
    } } }
    """

    /// The search text GitHub is asked: the query's string, newest update first.
    public static func searchText(_ query: BrowseQuery, maxAgeDays: Int, now: Date) -> String {
        query.rendered(maxAgeDays: maxAgeDays, now: now) + " sort:updated-desc"
    }

    /// Runs the search, following cursors until there are no more or `cap` items are in. A scope over many repos
    /// (an org view) is several searches (`BrowseQuery.renderedSearches`), whose answers are merged newest first.
    public static func search(
        _ query: BrowseQuery, maxAgeDays: Int, cap: Int = defaultCap, now: Date = Date()
    ) async throws -> Result {
        var result = Result(fetchedAt: now)
        for base in query.renderedSearches(maxAgeDays: maxAgeDays, now: now) {
            let text = base + " sort:updated-desc"
            var cursor: String?
            var fetched = 0
            repeat {
                var variables = ["q": text]
                if let cursor { variables["after"] = cursor }
                let data = try await GitHub.graphql(
                    self.query, operation: "browse search", variables: variables, caller: caller
                )
                let page = parse(data)
                result.items += page.items
                fetched += page.items.count
                result.hidden += page.hidden
                result.total += page.total ?? 0
                cursor = page.next
            } while cursor != nil && fetched < cap
            result.capped = result.capped || cursor != nil || fetched > cap
        }
        result.items.sort { ($0.updatedAt, $1.id) > ($1.updatedAt, $0.id) }
        result.capped = result.capped || result.items.count > cap
        result.items = Array(result.items.prefix(cap))
        return result
    }

    static let countQuery = """
    query($q: String!) { search(query: $q, type: ISSUE, first: 1) { issueCount } }
    """

    /// How many items the query holds on GitHub, without bringing them: one small call per search.
    public static func count(_ query: BrowseQuery, maxAgeDays: Int, now: Date = Date()) async throws -> Int {
        var total = 0
        for text in query.renderedSearches(maxAgeDays: maxAgeDays, now: now) {
            let data = try await GitHub.graphql(
                countQuery, operation: "browse count", variables: ["q": text], caller: "browse.count"
            )
            total += parse(data).total ?? 0
        }
        return total
    }

    // MARK: Org views

    /// The repos of an org with what the view's filters need (`gh repo list`); nil when gh cannot say.
    public static func orgRepos(owner: String) async -> [BrowseRepoInfo]? {
        guard let result = try? await GitHub.gh(
            BrowseRepoInfo.listArguments(owner: owner), operation: "repo list (org view)", timeout: .seconds(60),
            caller: "browse.orgview", items: { BrowseRepoInfo.parse(Data($0.utf8))?.count }
        ), result.succeeded else { return nil }
        return BrowseRepoInfo.parse(Data(result.stdout.utf8))
    }

    /// The org's team slugs (`gh api orgs/<org>/teams`); empty when you may not see them.
    public static func orgTeams(owner: String) async -> [String] {
        guard let result = try? await GitHub.gh(
            ["api", "orgs/\(owner)/teams", "--paginate", "--jq", ".[].slug"], operation: "org teams",
            timeout: .seconds(30), caller: "browse.orgview"
        ), result.succeeded else { return [] }
        return result.stdout.split(separator: "\n").map(String.init)
    }

    /// The repos a team has (`gh api orgs/<org>/teams/<team>/repos`), lowercased slugs; nil when gh cannot say.
    public static func teamRepos(owner: String, team: String) async -> Set<String>? {
        guard let result = try? await GitHub.gh(
            ["api", "orgs/\(owner)/teams/\(team)/repos", "--paginate", "--jq", ".[].full_name"],
            operation: "team repos", timeout: .seconds(30), caller: "browse.orgview"
        ), result.succeeded else { return nil }
        return BrowseRepoInfo.teamRepos(result.stdout)
    }

    struct Page {
        var items: [BrowseItem] = []
        var total: Int?
        var next: String?
        var hidden = 0
    }

    /// One answer's items (the ones that decode), the search's count, and the cursor of the next page.
    static func parse(_ data: Data) -> Page {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let search = (json["data"] as? [String: Any])?["search"] as? [String: Any]
        else { return Page() }
        var page = Page(hidden: GitHub.hiddenCount(json))
        page.total = search["issueCount"] as? Int
        let info = search["pageInfo"] as? [String: Any]
        page.next = info?["hasNextPage"] as? Bool == true ? info?["endCursor"] as? String : nil
        page.items = (search["nodes"] as? [Any] ?? []).compactMap { item($0 as? [String: Any]) }
        return page
    }

    static func item(_ node: [String: Any]?) -> BrowseItem? {
        guard let node, let number = node["number"] as? Int,
              let repo = GitHub.repo((node["repository"] as? [String: Any])?["nameWithOwner"] as? String),
              let title = node["title"] as? String
        else { return nil }
        let pull = node["isDraft"] != nil || node["closingIssuesReferences"] != nil
        let author = node["author"] as? [String: Any]
        let who = ExternalText.Author.github(author, association: node["authorAssociation"] as? String)
        func names(_ key: String, _ field: String) -> [String] {
            ((node[key] as? [String: Any])?["nodes"] as? [Any] ?? [])
                .compactMap { ($0 as? [String: Any])?[field] as? String }
        }
        let state: BrowseItem.State = switch (node["state"] as? String)?.uppercased() {
        case "MERGED": .merged
        case "CLOSED": .closed
        default: .open
        }
        let linked: Int = if pull {
            (node["closingIssuesReferences"] as? [String: Any])?["totalCount"] as? Int ?? 0
        } else {
            (node["closedByPullRequestsReferences"] as? [String: Any])?["totalCount"] as? Int ?? 0
        }
        let projects = ((node["projectItems"] as? [String: Any])?["nodes"] as? [Any] ?? []).compactMap {
            (($0 as? [String: Any])?["project"] as? [String: Any])?["title"] as? String
        }
        let rollup = ((((node["commits"] as? [String: Any])?["nodes"] as? [Any])?.first as? [String: Any])?["commit"]
            as? [String: Any])?["statusCheckRollup"] as? [String: Any]
        let checks: BrowseItem.Checks? = switch (rollup?["state"] as? String)?.uppercased() {
        case "SUCCESS": .passing
        case "FAILURE", "ERROR": .failing
        case "PENDING", "EXPECTED": .pending
        default: nil
        }
        return BrowseItem(
            repo: repo, number: number, kind: pull ? .pull : .issue,
            title: ExternalText(title, source: pull ? .pullTitle : .issueTitle, author: who),
            url: node["url"] as? String, state: state, author: who.login, authorIsBot: who.trust == .bot,
            labels: names("labels", "name"), assignees: names("assignees", "login"),
            milestone: (node["milestone"] as? [String: Any])?["title"] as? String, projects: projects,
            comments: (node["comments"] as? [String: Any])?["totalCount"] as? Int ?? 0,
            createdAt: GitHub.date(node["createdAt"] as? String), updatedAt: GitHub.date(node["updatedAt"] as? String),
            hasLinkedPull: linked > 0, isDraft: node["isDraft"] as? Bool ?? false, checks: checks,
            review: (node["reviewDecision"] as? String).flatMap(ReviewDecision.init(rawValue:)),
            requestedReviewers: pull ? ((node["reviewRequests"] as? [String: Any])?["nodes"] as? [Any] ?? [])
                .compactMap {
                    (($0 as? [String: Any])?["requestedReviewer"] as? [String: Any])?["login"] as? String
                } : nil
        )
    }

    // MARK: How many repos an owner has

    static let repoCountQuery = """
    query($login: String!) { repositoryOwner(login: $login) { repositories { totalCount } } }
    """

    /// How many repos `owner` has, for the guidance on big orgs; nil when GitHub does not say.
    public static func repoCount(owner: String) async -> Int? {
        guard let data = try? await GitHub.graphql(
            repoCountQuery, operation: "browse repo count", variables: ["login": owner], caller: caller
        ) else { return nil }
        return parseRepoCount(data)
    }

    static func parseRepoCount(_ data: Data) -> Int? {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let owner = (json?["data"] as? [String: Any])?["repositoryOwner"] as? [String: Any]
        return (owner?["repositories"] as? [String: Any])?["totalCount"] as? Int
    }
}
