import Foundation

public extension OriginBook {
    /// The book from what heed already holds: your login, the local checkouts and worktrees, the PRs it has details
    /// of (their author, reviewers and threads, the runs of their checks, and from `authorship` whether they are from
    /// a fork), the issues it lists, and what it asked GitHub for (`fetched`, which wins). At most `limit` PRs and
    /// issues: the ones fetched or seen last, and at most `checkoutLimit` checkouts: the first ones listed.
    static func project(
        viewer: String?, checkouts: [(path: String, repo: Repo)], details: [PullDetail], issues: [Issue],
        authorship: (PullRef) -> PullAuthorship? = { _ in nil }, fetched: [String: Item] = [:]
    ) -> OriginBook {
        var book = OriginBook(viewer: viewer)
        for checkout in checkouts where book.checkouts[checkout.path] != nil || book.checkouts.count < checkoutLimit {
            book.checkouts[checkout.path] = checkout.repo.slug
        }
        var seen: [String: Date] = [:]
        for detail in details {
            let key = OriginBook.key(detail.ref.repo.slug, detail.ref.number)
            let who = authorship(detail.ref)
            let author = detail.body.author.login.map { _ in Person(detail.body.author) }
                ?? who?.author.map { Person(login: $0, trust: who?.by.trust ?? .stranger) }
            let others = detail.reviews.map { Person(login: $0.author, trust: $0.trust) }
                + detail.threads.map { Person($0.body.author) }
            book.pulls[key] = Item(
                author: author, fork: who?.crossRepository, headBranch: detail.headBranch, participants: others
            )
            seen[key] = detail.fetchedAt
            for check in detail.failingChecks {
                if let run = runID(fromDetailsURL: check.url) { book.runs[run] = key }
                if let job = GitHub.jobID(fromDetailsURL: check.url) { book.runs["job/" + job] = key }
            }
        }
        for issue in issues {
            guard let login = issue.author, let trust = issue.authorTrust else { continue }
            let key = OriginBook.key(issue.repo.slug, issue.number)
            book.issues[key] = Item(author: Person(login: login, trust: trust))
            seen[key] = issue.updatedAt
        }
        for (key, item) in fetched {
            if item.headBranch != nil || item.fork != nil || book.pulls[key] != nil {
                book.pulls[key] = book.pulls[key].map { $0.merging(item) } ?? item
            } else {
                book.issues[key] = book.issues[key].map { $0.merging(item) } ?? item
            }
            seen[key] = item.fetchedAt ?? seen[key]
        }
        let kept = Set(seen.sorted { $0.value > $1.value }.prefix(limit).map(\.key))
        book.pulls = book.pulls.filter { kept.contains($0.key) }
        book.issues = book.issues.filter { kept.contains($0.key) }
        book.runs = book.runs.filter { kept.contains($0.value) }
        return book
    }

    /// The Actions run behind a check's details URL (`…/actions/runs/123/job/456` → `123`).
    static func runID(fromDetailsURL url: String?) -> String? {
        guard let url, let range = url.range(of: #"/actions/runs/\d+"#, options: .regularExpression) else { return nil }
        return url[range].split(separator: "/").last.map(String.init)
    }
}

// MARK: Asking GitHub

public extension GitHub {
    /// Who opened a PR or an issue, who else wrote on it (comments, reviews, review threads) and who each is to the
    /// repo, and for a PR whether it is from a fork: one GraphQL call, read only.
    static func origin(repo: Repo, number: Int, at: Date = Date(), caller: String) async throws -> OriginBook.Item {
        let data = try await graphql(
            originQuery, operation: "origin", variables: [
                "owner": repo.org, "name": repo.name, "number": "\(number)",
            ], caller: caller
        )
        guard let item = OriginBook.parseOrigin(data, at: at) else {
            throw Failure(description: "no PR or issue \(repo.slug)#\(number)")
        }
        return item
    }

    internal static let originQuery = """
    query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) {
      issueOrPullRequest(number: $number) { __typename
        ... on Issue { author { login __typename } authorAssociation
          comments(last: 100) { nodes { author { login __typename } authorAssociation } } }
        ... on PullRequest { author { login __typename } authorAssociation isCrossRepository headRefName
          comments(last: 100) { nodes { author { login __typename } authorAssociation } }
          reviews(last: 100) { nodes { author { login __typename } authorAssociation } }
          reviewThreads(last: 50) { nodes { comments(first: 20) { nodes { author { login __typename }
            authorAssociation } } } } }
      } } }
    """
}

extension OriginBook {
    /// `GitHub.originQuery`'s answer; nil when it names no PR or issue.
    static func parseOrigin(_ data: Data, at: Date) -> Item? {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let node = ((json?["data"] as? [String: Any])?["repository"] as? [String: Any])?["issueOrPullRequest"]
            as? [String: Any]
        else { return nil }
        func person(_ node: [String: Any]) -> Person? {
            let author = ExternalText.Author.github(
                node["author"] as? [String: Any], association: node["authorAssociation"] as? String
            )
            return author.login.map { Person(login: $0, trust: author.trust) }
        }
        func nodes(_ field: String, in node: [String: Any]) -> [[String: Any]] {
            GraphQLNodes.objects((node[field] as? [String: Any])?["nodes"]) ?? []
        }
        var others = nodes("comments", in: node).compactMap(person) + nodes("reviews", in: node).compactMap(person)
        for thread in nodes("reviewThreads", in: node) {
            others += nodes("comments", in: thread).compactMap(person)
        }
        let pull = node["__typename"] as? String == "PullRequest"
        return Item(
            author: person(node), fork: pull ? node["isCrossRepository"] as? Bool ?? true : nil,
            headBranch: pull ? node["headRefName"] as? String : nil, participants: others, fetchedAt: at
        )
    }
}
