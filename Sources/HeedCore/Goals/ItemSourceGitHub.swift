import Foundation

/// What item sources ask of GitHub: a search, and PRs or issues by number. `GitHubSources` runs gh; tests use an
/// in-memory one.
public protocol SourceGitHub: Sendable {
    /// The first page (100) of what `query` finds, and how many GitHub says there are.
    func search(_ query: String) async throws -> (matches: [SourceMatch], total: Int)
    /// The PRs or issues `refs` (`org/repo#n`) name, as they are now; one GitHub cannot find is left out.
    func lookup(_ refs: [String]) async throws -> [SourceMatch]
}

/// Item sources through gh's GraphQL: one search a source, and the items that stopped matching looked up 50 at a
/// time. Each call is a `github` row in the call log (caller `goals.sources`), with its rate-limit cost.
public struct GitHubSources: SourceGitHub {
    public var caller: String

    public init(caller: String = "goals.sources") {
        self.caller = caller
    }

    static let fields = """
    __typename
    ... on PullRequest { number title url state isDraft repository { nameWithOwner } author { login }
      viewerLatestReview { state }
      commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
        __typename ... on CheckRun { name status conclusion startedAt } ... on StatusContext { context state }
      } } } } } } }
    ... on Issue { number title url state repository { nameWithOwner } author { login } }
    """

    static let searchQuery = """
    query($q: String!) { search(query: $q, type: ISSUE, first: 100) { issueCount nodes { \(fields) } } }
    """

    /// One aliased lookup per ref (`r0`…).
    static func lookupQuery(_ refs: [PullRef]) -> String {
        let parts = refs.enumerated().map { index, ref in
            "r\(index): repository(owner: \"\(ref.repo.org)\", name: \"\(ref.repo.name)\") { issueOrPullRequest(number: \(ref.number)) { \(fields) } }"
        }
        return "query { \(parts.joined(separator: "\n")) }"
    }

    public func search(_ query: String) async throws -> (matches: [SourceMatch], total: Int) {
        let data = try await GitHub.graphql(
            Self.searchQuery, operation: "sourceSearch", variables: ["q": query], caller: caller
        )
        return try Self.parseSearch(data)
    }

    public func lookup(_ refs: [String]) async throws -> [SourceMatch] {
        let parsed = refs.compactMap { PullRef(slug: $0) }
        var found: [SourceMatch] = []
        var start = 0
        while start < parsed.count {
            let batch = Array(parsed[start ..< min(start + 50, parsed.count)])
            let data = try await GitHub.graphql(
                Self.lookupQuery(batch), operation: "sourceLookup", variables: [:], caller: caller
            )
            found += Self.parseLookup(data, count: batch.count)
            start += 50
        }
        return found
    }

    // MARK: Parsing

    static func parseSearch(_ data: Data) throws -> (matches: [SourceMatch], total: Int) {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let search = (json?["data"] as? [String: Any])?["search"] as? [String: Any] else {
            let message = ((json?["errors"] as? [[String: Any]])?.first?["message"] as? String)
                ?? "GitHub did not answer the search"
            throw GitHub.Failure(description: message)
        }
        let nodes = search["nodes"] as? [[String: Any]] ?? []
        let matches = nodes.compactMap(match)
        return (matches, search["issueCount"] as? Int ?? matches.count)
    }

    static func parseLookup(_ data: Data, count: Int) -> [SourceMatch] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let root = json?["data"] as? [String: Any] ?? [:]
        return (0 ..< count).compactMap { index in
            ((root["r\(index)"] as? [String: Any])?["issueOrPullRequest"] as? [String: Any]).flatMap(match)
        }
    }

    /// A PR or issue node; nil for anything else a search can find.
    static func match(_ node: [String: Any]) -> SourceMatch? {
        guard let number = node["number"] as? Int,
              let repo = GitHub.repo((node["repository"] as? [String: Any])?["nameWithOwner"] as? String)
        else { return nil }
        let ref = "\(repo.slug)#\(number)"
        let author = (node["author"] as? [String: Any])?["login"] as? String
        let title = node["title"] as? String ?? ref
        let state = node["state"] as? String ?? "OPEN"
        if node["__typename"] as? String == "Issue" {
            return SourceMatch(
                ref: ref, kind: .issue, title: title,
                url: node["url"] as? String ?? "https://github.com/\(repo.slug)/issues/\(number)", author: author,
                state: state == "CLOSED" ? .closed : .open
            )
        }
        let commit = ((node["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first?["commit"]
            as? [String: Any]
        let contexts = GitHub.latest(((commit?["statusCheckRollup"] as? [String: Any])?["contexts"]
                as? [String: Any])?["nodes"] as? [[String: Any]] ?? [])
        let review: SourceMatch.Review? = switch (node["viewerLatestReview"] as? [String: Any])?["state"] as? String {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        case "COMMENTED": .commented
        default: nil
        }
        return SourceMatch(
            ref: ref, kind: .pr, title: title,
            url: node["url"] as? String ?? PullRef(repo: repo, number: number).url, author: author,
            state: state == "MERGED" ? .merged : state == "CLOSED" ? .closed : .open,
            isDraft: node["isDraft"] as? Bool ?? false, checks: GitHub.checkSummary(contexts), review: review
        )
    }
}

/// Syncs a goal's sources: a search each, a lookup of the items that stopped matching, written in one step by
/// `GoalOps.applySources`. A source whose search fails keeps its items as they are, and says why.
public struct ItemSourceSyncRun: Sendable {
    public let ops: GoalOps
    public let github: any SourceGitHub

    public init(ops: GoalOps, github: any SourceGitHub) {
        self.ops = ops
        self.github = github
    }

    @discardableResult
    public func sync(goal: String, now: Date) async throws -> GoalOps.SourceSyncSummary {
        let state = try await ops.sourceState(of: goal)
        guard !state.sources.isEmpty else { return GoalOps.SourceSyncSummary() }
        let snapshot = try await ops.snapshot()
        let items = snapshot.items(of: goal)
        let evidence = snapshot.evidence(of: goal)
        var results: [String: SourceResult] = [:]
        var problems: [String] = []
        for source in state.sources {
            do {
                let (matches, total) = try await github.search(source.query)
                let matched = Set(matches.map(\.ref))
                let missing = ItemSourceSync.lookups(source: source, items: items, evidence: evidence)
                    .filter { !matched.contains($0) }
                let looked = try await missing.isEmpty ? [] : github.lookup(missing)
                results[source.id] = SourceResult(
                    matches: matches, looked: Dictionary(looked.map { ($0.ref, $0) }) { first, _ in first },
                    total: total > matches.count ? total : nil
                )
                if total > matches.count {
                    problems.append("\(source.id) finds \(total): heed follows the first \(matches.count)")
                }
            } catch {
                problems.append("\(source.id): \(error)")
            }
        }
        return try await ops.applySources(
            goal: goal, results: results, error: problems.isEmpty ? nil : problems.joined(separator: "; "), now: now
        )
    }
}
