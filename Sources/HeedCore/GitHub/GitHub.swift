import Foundation

/// GitHub, only through `gh`, projected into the domain. Every call runs off the main actor; raw JSON never leaves
/// this file. GraphQL answers can be partial (SAML-protected orgs the token is not authorized for): those items are
/// skipped and counted, never fatal.
public enum GitHub {
    public struct Fetched<Value: Sendable>: Sendable {
        public var value: Value
        /// Items GitHub withheld (SAML).
        public var hidden: Int
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    // MARK: Sync

    /// One full sync: viewer, notifications, your open PRs (plus `tracked` ones), and issues assigned to you, fetched
    /// concurrently. Throws only when gh itself is unusable (missing, signed out, offline).
    public static func sync(
        tracked: [PullRef],
        previous _: GitHubState,
        now: Date = Date()
    ) async throws -> GitHubState {
        async let viewer = viewer()
        async let inbox = notifications()
        async let pulls = pullRequests(tracked: tracked)
        async let issues = assignedIssues()
        let login = try await viewer
        let fetchedInbox = try await inbox
        let fetchedPulls = try await pulls
        let fetchedIssues = try await issues
        let hidden = fetchedPulls.hidden + fetchedIssues.hidden
        return GitHubState(
            viewer: login, inbox: fetchedInbox, issues: fetchedIssues.value, pulls: fetchedPulls.value,
            syncedAt: now,
            status: hidden > 0 ? .partial(
                hidden: hidden,
                note: "\(hidden) item\(hidden == 1 ? "" : "s") hidden by SAML: authorize the GitHub CLI for that org (gh auth refresh, or github.com/settings/applications)"
            ) : .ok
        )
    }

    public static func viewer() async throws -> String {
        let result = try await ProcessRunner.run("gh", ["api", "user", "--jq", ".login"], timeout: .seconds(20))
        guard result.succeeded else { throw Failure(description: Self.explain(result)) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func notifications() async throws -> [InboxItem] {
        let result = try await ProcessRunner.run("gh", ["api", "notifications?per_page=50"], timeout: .seconds(30))
        guard result.succeeded else { throw Failure(description: Self.explain(result)) }
        return parseNotifications(Data(result.stdout.utf8))
    }

    public static func pullRequests(tracked: [PullRef]) async throws -> Fetched<[PullRequest]> {
        let mine = try await graphql(pullSearchQuery, variables: ["q": "is:open is:pr author:@me archived:false"])
        var (pulls, hidden) = parsePullSearch(mine)
        let missing = tracked.filter { ref in !pulls.contains { $0.ref == ref } }
        if !missing.isEmpty {
            let data = try await graphql(trackedPullsQuery(missing), variables: [:])
            let (extra, extraHidden) = parseTrackedPulls(data, refs: missing)
            pulls += extra
            hidden += extraHidden
        }
        return Fetched(value: pulls.sorted { $0.updatedAt > $1.updatedAt }, hidden: hidden)
    }

    public static func assignedIssues() async throws -> Fetched<[Issue]> {
        let data = try await graphql(issueSearchQuery, variables: ["q": "is:open is:issue assignee:@me archived:false"])
        let (issues, hidden) = parseIssueSearch(data)
        return Fetched(value: issues, hidden: hidden)
    }

    /// Marks a notification thread read.
    public static func markRead(threadID: String) async throws {
        let result = try await ProcessRunner.run(
            "gh", ["api", "-X", "PATCH", "notifications/threads/\(threadID)"], timeout: .seconds(20)
        )
        guard result.succeeded else { throw Failure(description: Self.explain(result)) }
    }

    /// Runs a GraphQL query. gh exits non-zero when the answer carries errors, even with data; the data is returned
    /// as long as there is some.
    static func graphql(_ query: String, variables: [String: String]) async throws -> Data {
        var args = ["api", "graphql", "-f", "query=\(query)"]
        for (key, value) in variables.sorted(by: { $0.key < $1.key }) {
            args += ["-f", "\(key)=\(value)"]
        }
        let result = try await ProcessRunner.run("gh", args, timeout: .seconds(45))
        let data = Data(result.stdout.utf8)
        if !result.succeeded, (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] == nil {
            throw Failure(description: Self.explain(result))
        }
        return data
    }

    static func explain(_ result: ProcessResult) -> String {
        let text = (result.stderr.isEmpty ? result.stdout : result.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("gh auth login") || text
            .contains("not logged") { return "gh is not signed in (gh auth login)" }
        if text.contains("could not start") { return "gh is not installed" }
        return text.split(separator: "\n").first.map(String.init) ?? "gh failed (exit \(result.status))"
    }

    // MARK: Queries

    static let pullFields = """
    number title url isDraft state headRefName updatedAt
    repository { nameWithOwner }
    reviewDecision
    reviewThreads(first: 100) { nodes { isResolved } }
    commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
      __typename ... on CheckRun { name status conclusion } ... on StatusContext { context state }
    } } } } } }
    """

    static let pullSearchQuery = """
    query($q: String!) { search(query: $q, type: ISSUE, first: 50) { nodes { ... on PullRequest { \(pullFields) } } } }
    """

    static func trackedPullsQuery(_ refs: [PullRef]) -> String {
        let parts = refs.enumerated().map { index, ref in
            "p\(index): repository(owner: \"\(ref.repo.org)\", name: \"\(ref.repo.name)\") { pullRequest(number: \(ref.number)) { \(pullFields) } }"
        }
        return "query { \(parts.joined(separator: "\n")) }"
    }

    static let issueSearchQuery = """
    query($q: String!) { search(query: $q, type: ISSUE, first: 50) { nodes { ... on Issue {
      number title url bodyText updatedAt repository { nameWithOwner } author { login } labels(first: 10) { nodes { name } }
    } } } }
    """

    // MARK: Parsing (pure, tested)

    static func date(_ text: String?) -> Date {
        text.flatMap { try? Date($0, strategy: .iso8601) } ?? .distantPast
    }

    static func repo(_ nameWithOwner: String?) -> Repo? {
        guard let parts = nameWithOwner?.split(separator: "/"), parts.count == 2 else { return nil }
        return Repo(org: String(parts[0]), name: String(parts[1]))
    }

    /// `https://api.github.com/repos/o/r/pulls/12` → (`https://github.com/o/r/pull/12`, 12).
    static func webURL(api: String?) -> (url: String, number: Int)? {
        guard let api, let range = api.range(of: "/repos/") else { return nil }
        let parts = api[range.upperBound...].split(separator: "/")
        guard parts.count >= 4, let number = Int(parts[3]) else { return nil }
        let kind = parts[2] == "pulls" ? "pull" : String(parts[2])
        return ("https://github.com/\(parts[0])/\(parts[1])/\(kind)/\(number)", number)
    }

    public static func parseNotifications(_ data: Data) -> [InboxItem] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { item -> InboxItem? in
            guard let id = item["id"] as? String,
                  let subject = item["subject"] as? [String: Any],
                  let repo = repo((item["repository"] as? [String: Any])?["full_name"] as? String)
            else { return nil }
            let type = subject["type"] as? String
            let kind: InboxItem.Kind = switch type {
            case "PullRequest": .pr
            case "Issue": .issue
            case "CheckSuite": .ci
            case "Release": .release
            case "Discussion": .discussion
            default: .other
            }
            let web = webURL(api: subject["url"] as? String)
            return InboxItem(
                id: id, kind: kind, repo: repo, number: web?.number, title: subject["title"] as? String ?? "",
                reason: item["reason"] as? String ?? "", unread: item["unread"] as? Bool ?? false,
                updatedAt: date(item["updated_at"] as? String),
                url: web?.url ?? (kind == .ci ? "https://github.com/\(repo.slug)/actions" : nil)
            )
        }
    }

    /// Counts the SAML-withheld entries in a GraphQL answer.
    static func hiddenCount(_ json: [String: Any]) -> Int {
        (json["errors"] as? [[String: Any]])?.count {
            (($0["extensions"] as? [String: Any])?["saml_failure"] as? Bool) == true
        } ?? 0
    }

    static func parsePullSearch(_ data: Data) -> ([PullRequest], Int) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], 0) }
        let nodes = (((json["data"] as? [String: Any])?["search"] as? [String: Any])?["nodes"] as? [Any]) ?? []
        return (nodes.compactMap { ($0 as? [String: Any]).flatMap(parsePull) }, hiddenCount(json))
    }

    static func parseTrackedPulls(_ data: Data, refs: [PullRef]) -> ([PullRequest], Int) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = json["data"] as? [String: Any]
        else { return ([], 0) }
        let pulls = refs.indices.compactMap { index in
            ((root["p\(index)"] as? [String: Any])?["pullRequest"] as? [String: Any]).flatMap(parsePull)
        }
        return (pulls, hiddenCount(json))
    }

    static func parsePull(_ node: [String: Any]) -> PullRequest? {
        guard let number = node["number"] as? Int,
              let repo = repo((node["repository"] as? [String: Any])?["nameWithOwner"] as? String)
        else { return nil }
        let threads = ((node["reviewThreads"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let commit = (((node["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first?["commit"]
            as? [String: Any])
        let contexts = (((commit?["statusCheckRollup"] as? [String: Any])?["contexts"] as? [String: Any])?["nodes"]
            as? [[String: Any]]) ?? []
        return PullRequest(
            ref: PullRef(repo: repo, number: number), title: node["title"] as? String ?? "",
            url: node["url"] as? String ?? PullRef(repo: repo, number: number).url,
            state: PullRequest.State(rawValue: node["state"] as? String ?? "") ?? .open,
            isDraft: node["isDraft"] as? Bool ?? false, headBranch: node["headRefName"] as? String ?? "",
            review: (node["reviewDecision"] as? String).flatMap(ReviewDecision.init(rawValue:)),
            checks: checkSummary(contexts), unresolvedThreads: threads.count { ($0["isResolved"] as? Bool) == false },
            updatedAt: date(node["updatedAt"] as? String)
        )
    }

    static func checkSummary(_ contexts: [[String: Any]]) -> CheckSummary {
        var summary = CheckSummary()
        for context in contexts {
            if context["__typename"] as? String == "StatusContext" {
                switch context["state"] as? String {
                case "SUCCESS": summary.passed += 1
                case "FAILURE", "ERROR":
                    summary.failed += 1
                    summary.failedNames.append(context["context"] as? String ?? "status")
                default: summary.pending += 1
                }
                continue
            }
            guard context["status"] as? String == "COMPLETED" else {
                summary.pending += 1
                continue
            }
            switch context["conclusion"] as? String {
            case "SUCCESS", "NEUTRAL": summary.passed += 1
            case "SKIPPED": summary.skipped += 1
            case "FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "CANCELLED":
                summary.failed += 1
                summary.failedNames.append(context["name"] as? String ?? "check")
            default: summary.passed += 1
            }
        }
        return summary
    }

    static func parseIssueSearch(_ data: Data) -> ([Issue], Int) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], 0) }
        let nodes = (((json["data"] as? [String: Any])?["search"] as? [String: Any])?["nodes"] as? [Any]) ?? []
        let issues = nodes.compactMap { raw -> Issue? in
            guard let node = raw as? [String: Any], let number = node["number"] as? Int,
                  let repo = repo((node["repository"] as? [String: Any])?["nameWithOwner"] as? String)
            else { return nil }
            let labels = ((node["labels"] as? [String: Any])?["nodes"] as? [[String: Any]])?.compactMap {
                $0["name"] as? String
            } ?? []
            return Issue(
                repo: repo, number: number, title: node["title"] as? String ?? "", url: node["url"] as? String ?? "",
                body: String((node["bodyText"] as? String ?? "").prefix(4000)), labels: labels,
                author: (node["author"] as? [String: Any])?["login"] as? String,
                updatedAt: date(node["updatedAt"] as? String)
            )
        }
        return (issues, hiddenCount(json))
    }
}
