import Foundation

/// Why a Browse fetch did not run. Browse works inside what is checked out and never searches all of GitHub.
public enum BrowseFetchError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The query names no place and nothing is checked out to search inside.
    case unbounded
    /// The query names an org or repo with no checkout.
    case notCheckedOut(String)

    public var description: String {
        switch self {
        case .unbounded: "Check out a repo first. Browse searches the orgs and repos you have checked out."
        case let .notCheckedOut(name):
            "\(name) isn't checked out. Browse searches orgs and repos you have checked out. "
                + "Clone it (Add or clone), then it shows up here."
        }
    }
}

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
        /// "All my orgs" took several searches: how many ran, and how many its owners needed.
        public var groups = 1
        public var groupsTotal = 1
    }

    /// Why `query` would not be asked, or nil: a place that is not checked out, or no place with nothing checked out.
    public static func refusal(for query: BrowseQuery, checkouts: BrowseCheckouts) -> BrowseFetchError? {
        let places = query.places
        if let missing = places.first(where: { !checkouts.allows($0) }) { return .notCheckedOut(missing.name) }
        return places.isEmpty && checkouts.isEmpty ? .unbounded : nil
    }

    /// The one gate every search passes, and what it asks. A query that names places (a scope, `org:`, `repo:`…) is one
    /// search as it stands, and only when each place's org has a checkout. A query that names none runs inside the
    /// checked-out orgs, in as many searches as their qualifiers need (a scope of its own is never widened by that).
    /// With nothing checked out, or a place that is not, nothing is sent.
    static func searches(
        for query: BrowseQuery, checkouts: BrowseCheckouts, maxAgeDays: Int, now: Date, sorted: Bool
    ) throws -> (texts: [String], total: Int) {
        if let refusal = refusal(for: query, checkouts: checkouts) { throw refusal }
        // An org's own repos: its checked-out repos in as many searches as they need, exactly as the default scope
        // splits the orgs. Read from the checkouts now, so it is never a snapshot.
        if case let .ownRepos(org)? = query.scope {
            var rest = query
            rest.scope = nil
            let text = rest.rendered(maxAgeDays: maxAgeDays, now: now) + (sorted ? " sort:updated-desc" : "")
            let plan = BrowseDefaultScope.plan(checkouts.repoQualifiers(of: org), rest: text)
            return (plan.groups.map { BrowseDefaultScope.text($0, rest: text) }, plan.totalGroups)
        }
        let text = query.rendered(maxAgeDays: maxAgeDays, now: now) + (sorted ? " sort:updated-desc" : "")
        if query.hasOwnPlace { return ([text], 1) }
        let plan = BrowseDefaultScope.plan(checkouts.qualifiers, rest: text)
        return (plan.groups.map { BrowseDefaultScope.text($0, rest: text) }, plan.totalGroups)
    }

    /// The groups' answers as one: items newest update first (the single search's order), the counts summed, the cap on
    /// the whole.
    static func merge(_ results: [Result], cap: Int, now: Date) -> Result {
        var merged = Result(fetchedAt: now)
        var seen = Set<String>()
        for result in results {
            merged.items += result.items.filter { seen.insert($0.id).inserted }
            merged.total += result.total
            merged.hidden += result.hidden
            merged.capped = merged.capped || result.capped
        }
        merged.items.sort { ($0.updatedAt, $1.id) > ($1.updatedAt, $0.id) }
        merged.capped = merged.capped || merged.items.count > cap
        merged.items = Array(merged.items.prefix(cap))
        return merged
    }

    static let fields = """
    number title url state createdAt updatedAt authorAssociation
    repository { nameWithOwner }
    author { login __typename }
    labels(first: 10) { nodes { name } }
    assignees(first: 5) { nodes { login } }
    milestone { title }
    comments { totalCount }
    """

    /// The search, `size` nodes a page. `light` leaves out what costs GitHub the most on a pull request (checks,
    /// requested reviewers, closing references): the last rung of the ladder, see `BrowseFetchPolicy`.
    static func searchQuery(size: Int = 100, light: Bool = false) -> String {
        let heavy = """
        reviewRequests(first: 10) { nodes { requestedReviewer { ... on User { login } } } }
          closingIssuesReferences(first: 1) { totalCount }
          commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
        """
        return """
        query($q: String!, $after: String) { search(query: $q, type: ISSUE, first: \(size), after: $after) {
          issueCount pageInfo { hasNextPage endCursor } nodes {
            ... on Issue { \(fields) closedByPullRequestsReferences(first: 1) { totalCount } }
            ... on PullRequest { \(fields) isDraft reviewDecision
              \(light ? "" : heavy) }
        } } }
        """
    }

    static let query = searchQuery()

    /// The search text GitHub is asked: the query's string, newest update first.
    public static func searchText(_ query: BrowseQuery, maxAgeDays: Int, now: Date) -> String {
        query.rendered(maxAgeDays: maxAgeDays, now: now) + " sort:updated-desc"
    }

    /// Runs the search, following cursors until there are no more or `cap` items are in; with no scope, once per group
    /// of the checked-out orgs.
    ///
    /// A page GitHub fails to answer (HTTP 502/504, a timeout) is asked again from the same cursor at the next
    /// smaller size, after a short wait; the page that answers continues from its own end cursor, so nothing is
    /// dropped or doubled. Each group is its own search text with its own remembered size (`memory`), which never
    /// climbs back. When a group's ladder is spent, or the failure is one asking again cannot fix, the whole fetch
    /// throws a message a person can act on: never a partial list.
    public static func search(
        _ query: BrowseQuery, maxAgeDays: Int, cap: Int = defaultCap, now: Date = Date(), checkouts: BrowseCheckouts,
        memory: BrowseFetchMemory = .shared, sleep: BrowseFetchPolicy.Sleeper = BrowseFetchPolicy.realSleep
    ) async throws -> Result {
        let asked = try searches(for: query, checkouts: checkouts, maxAgeDays: maxAgeDays, now: now, sorted: true)
        var results: [Result] = []
        for text in asked.texts {
            try Task.checkCancellation()
            try await results.append(pages(text, cap: cap, now: now, memory: memory, sleep: sleep))
        }
        var merged = merge(results, cap: cap, now: now)
        merged.groups = asked.texts.count
        merged.groupsTotal = asked.total
        return merged
    }

    /// One search string's pages.
    private static func pages(
        _ text: String, cap: Int, now: Date, memory: BrowseFetchMemory, sleep: BrowseFetchPolicy.Sleeper
    ) async throws -> Result {
        var result = Result(fetchedAt: now)
        var cursor: String?
        var fetched = 0
        var rung = memory.rung(for: text)
        var rateLimitWaited = false
        repeat {
            var variables = ["q": text]
            if let cursor { variables["after"] = cursor }
            let data: Data
            while true {
                let step = BrowseFetchPolicy.rungs[rung]
                do {
                    data = try await GitHub.graphql(
                        searchQuery(size: step.size, light: step.light), operation: "browse search",
                        variables: variables, caller: caller
                    )
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    switch BrowseFetchPolicy.next(
                        after: BrowseFetchPolicy.text(of: error), rung: rung, rateLimitWaited: rateLimitWaited
                    ) {
                    case let .retry(next, wait):
                        try await sleep(wait)
                        rung = next
                        memory.settle(rung, for: text)
                    case let .waitThenRetry(wait):
                        rateLimitWaited = true
                        try await sleep(wait)
                    case let .fail(message):
                        throw GitHub.Failure(description: message)
                    }
                }
            }
            let page = parse(data)
            result.items += page.items
            fetched += page.items.count
            result.hidden += page.hidden
            // GitHub's count is the same on every page: the last one said is the total, not a sum.
            result.total = page.total ?? result.total
            cursor = page.next
        } while cursor != nil && fetched < cap
        result.capped = cursor != nil || fetched > cap
        return result
    }

    static let countQuery = """
    query($q: String!) { search(query: $q, type: ISSUE, first: 1) { issueCount } }
    """

    /// How many items the query holds on GitHub, without bringing them: one small call per search (the groups' counts
    /// add up: they are disjoint). Each call is asked again after a transient failure; a caller that cannot wait for
    /// it keeps the count it had.
    public static func count(
        _ query: BrowseQuery, maxAgeDays: Int, now: Date = Date(), checkouts: BrowseCheckouts,
        sleep: BrowseFetchPolicy.Sleeper = BrowseFetchPolicy.realSleep
    ) async throws -> Int {
        let asked = try searches(for: query, checkouts: checkouts, maxAgeDays: maxAgeDays, now: now, sorted: false)
        var total = 0
        for text in asked.texts {
            try Task.checkCancellation()
            let data = try await BrowseFetchPolicy.retrying(sleep: sleep) {
                try await GitHub.graphql(
                    countQuery, operation: "browse count", variables: ["q": text], caller: "browse.count"
                )
            }
            total += parse(data).total ?? 0
        }
        return total
    }

    // MARK: Org views

    /// The repos of an org with their language and archived state (`gh repo list`), for the builder's live count; nil
    /// when gh cannot say.
    public static func orgRepos(
        owner: String, sleep: BrowseFetchPolicy.Sleeper = BrowseFetchPolicy.realSleep
    ) async -> [BrowseRepoInfo]? {
        let result = try? await BrowseFetchPolicy.retrying(sleep: sleep) {
            let result = try await GitHub.gh(
                BrowseRepoInfo.listArguments(owner: owner), operation: "repo list (org view)", timeout: .seconds(60),
                caller: "browse.orgview", items: { BrowseRepoInfo.parse(Data($0.utf8))?.count }
            )
            guard result.succeeded else { throw GitHub.Failure(description: GitHub.explain(result)) }
            return result
        }
        guard let result else { return nil }
        return BrowseRepoInfo.parse(Data(result.stdout.utf8))
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
            // A light page did not ask: no answer is not "nobody was asked".
            requestedReviewers: pull && node["reviewRequests"] != nil
                ? ((node["reviewRequests"] as? [String: Any])?["nodes"] as? [Any] ?? [])
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
    public static func repoCount(
        owner: String,
        sleep: BrowseFetchPolicy.Sleeper = BrowseFetchPolicy.realSleep
    ) async -> Int? {
        guard let data = try? await BrowseFetchPolicy.retrying(sleep: sleep, {
            try await GitHub.graphql(
                repoCountQuery, operation: "browse repo count", variables: ["login": owner], caller: caller
            )
        }) else { return nil }
        return parseRepoCount(data)
    }

    static func parseRepoCount(_ data: Data) -> Int? {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let owner = (json?["data"] as? [String: Any])?["repositoryOwner"] as? [String: Any]
        return (owner?["repositories"] as? [String: Any])?["totalCount"] as? Int
    }
}
