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

    /// A sync of `parts` (all of them by default): notifications, your open PRs (plus `tracked` ones), and issues
    /// (those involving you, plus every open one in repos `rules` shows all of), fetched concurrently. The parts not
    /// asked for keep their `previous` data; the login is fetched once, and again on a full sync. Throws only when gh
    /// itself is unusable (missing, signed out, offline).
    public static func sync(
        parts: Set<GitHubPart> = Set(GitHubPart.allCases),
        tracked: [PullRef],
        previous: GitHubState,
        issueRules: IssueRules = IssueRules(),
        localRepos: [Repo] = [],
        now: Date = Date()
    ) async throws -> GitHubState {
        let full = parts == Set(GitHubPart.allCases)
        async let viewer = fetch(full || previous.viewer == nil) { try await viewer() }
        async let inbox = fetch(parts.contains(.inbox)) { try await notifications() }
        async let pulls = fetch(parts.contains(.pulls)) { try await pullRequests(tracked: tracked) }
        async let issues = fetch(parts.contains(.issues)) { try await self.issues(rules: issueRules, local: localRepos)
        }
        let login = try await viewer ?? previous.viewer
        let fetchedInbox = try await inbox
        let fetchedPulls = try await pulls
        let fetchedIssues = try await issues
        let hidden = (fetchedPulls?.hidden ?? 0) + (fetchedIssues?.hidden ?? 0)
        // A partial sync that saw nothing hidden says nothing about the parts it skipped.
        let status: SyncStatus = if hidden > 0 {
            .partial(
                hidden: hidden,
                note: "\(hidden) item\(hidden == 1 ? "" : "s") hidden by SAML: authorize the GitHub CLI for that org (gh auth refresh, or github.com/settings/applications)"
            )
        } else if !full, case .partial = previous.status {
            previous.status
        } else {
            .ok
        }
        return GitHubState(
            viewer: login, inbox: fetchedInbox ?? previous.inbox, issues: fetchedIssues?.value ?? previous.issues,
            pulls: fetchedPulls?.value ?? previous.pulls, syncedAt: now, status: status
        )
    }

    private static func fetch<T: Sendable>(_ wanted: Bool, _ body: () async throws -> T) async throws -> T? {
        wanted ? try await body() : nil
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

    /// Issues assigned to you or mentioning you, anywhere, plus every open issue in the repos `rules` shows all of.
    public static func issues(rules: IssueRules, local: [Repo]) async throws -> Fetched<[Issue]> {
        let base = "is:open is:issue archived:false"
        async let assigned = search("\(base) assignee:@me")
        async let mentioned = search("\(base) mentions:@me")
        var watched: [([Issue], Int)] = []
        for query in watchQueries(base: base, qualifiers: rules.watchQualifiers(local: local)) {
            try await watched.append(search(query))
        }
        let (mine, mineHidden) = try await assigned
        let (mentions, mentionsHidden) = try await mentioned
        let merged = mergeIssues(
            assigned: mine, mentioned: mentions,
            watched: watched.flatMap(\.0).filter { rules.visibility($0.repo) == .all }
        )
        return Fetched(value: merged, hidden: mineHidden + mentionsHidden + watched.map(\.1).reduce(0, +))
    }

    private static func search(_ query: String) async throws -> ([Issue], Int) {
        try await parseIssueSearch(graphql(issueSearchQuery, variables: ["q": "\(query) sort:updated-desc"]))
    }

    /// GitHub caps a search query at 256 characters, so qualifiers are split over several queries (at most 8).
    static func watchQueries(base: String, qualifiers: [String], limit: Int = 230) -> [String] {
        var queries: [String] = []
        var current: [String] = []
        for qualifier in qualifiers {
            let candidate = ([base] + current + [qualifier]).joined(separator: " ")
            if candidate.count > limit, !current.isEmpty {
                queries.append(([base] + current).joined(separator: " "))
                current = []
            }
            current.append(qualifier)
        }
        if !current.isEmpty { queries.append(([base] + current).joined(separator: " ")) }
        return Array(queries.prefix(8))
    }

    /// One entry per issue, flagged with how it involves you; newest first.
    static func mergeIssues(assigned: [Issue], mentioned: [Issue], watched: [Issue]) -> [Issue] {
        var byID: [String: Issue] = [:]
        for var issue in watched {
            issue.assigned = false
            issue.mentioned = false
            byID[issue.id] = issue
        }
        for issue in mentioned {
            var merged = byID[issue.id] ?? issue
            merged.mentioned = true
            byID[issue.id] = merged
        }
        for issue in assigned {
            var merged = byID[issue.id] ?? issue
            merged.assigned = true
            byID[issue.id] = merged
        }
        return byID.values.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
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
            // -F sends a typed field, so `number` reaches GraphQL as an Int; -f keeps strings strings.
            args += [key == "number" ? "-F" : "-f", "\(key)=\(value)"]
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

    /// The reader's view of one PR.
    public static func pullDetail(_ ref: PullRef, now: Date = Date()) async throws -> PullDetail {
        let data = try await graphql(
            pullDetailQuery, variables: ["owner": ref.repo.org, "name": ref.repo.name, "number": String(ref.number)]
        )
        guard let detail = parsePullDetail(data, ref: ref, now: now) else {
            throw Failure(description: "\(ref) is not visible to gh")
        }
        return detail
    }

    /// The Actions job behind a check's details URL (`…/actions/runs/123/job/456` → `456`); nil for other checks.
    public static func jobID(fromDetailsURL url: String?) -> String? {
        guard let url, let range = url.range(of: #"/actions/runs/\d+/job/(\d+)"#, options: .regularExpression)
        else { return nil }
        return url[range].split(separator: "/").last.map(String.init)
    }

    /// The last `lines` of an Actions job's failed steps (`gh run view --job <id> --log-failed`).
    public static func failedLog(repo: Repo, job: String, lines: Int = 80) async throws -> String {
        let result = try await ProcessRunner.run(
            "gh", ["run", "view", "--job", job, "--log-failed", "-R", repo.slug], timeout: .seconds(60)
        )
        guard result.succeeded else { throw Failure(description: Self.explain(result)) }
        return result.stdout.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines)
            .map { cleanLogLine(String($0)) }.joined(separator: "\n")
    }

    /// `gh pr merge --auto --<method>`: auto-merge on, or a merge right away when GitHub has nothing left to wait for.
    public static func enableAutoMerge(_ ref: PullRef, method: String) async throws {
        try await pr(["merge", "\(ref.number)", "--auto", "--\(method)", "-R", ref.repo.slug])
    }

    public static func disableAutoMerge(_ ref: PullRef) async throws {
        try await pr(["merge", "\(ref.number)", "--disable-auto", "-R", ref.repo.slug])
    }

    /// `gh pr update-branch`: merges the base into a PR that fell behind.
    public static func updateBranch(_ ref: PullRef) async throws {
        try await pr(["update-branch", "\(ref.number)", "-R", ref.repo.slug])
    }

    private static func pr(_ arguments: [String]) async throws {
        let result = try await ProcessRunner.run("gh", ["pr"] + arguments, timeout: .seconds(60))
        guard result.succeeded else { throw Failure(description: Self.explain(result)) }
    }

    /// `build<TAB>Run tests<TAB>2026-10-13T18:44:48.5Z text` → `Run tests: text`.
    static func cleanLogLine(_ line: String) -> String {
        let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3 else { return line }
        let text = fields[2].split(separator: " ", maxSplits: 1).last.map(String.init) ?? ""
        return "\(fields[1]): \(text)"
    }

    // MARK: Queries

    static let pullDetailQuery = """
    query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) {
      autoMergeAllowed squashMergeAllowed mergeCommitAllowed rebaseMergeAllowed
      pullRequest(number: $number) {
      number title body author { login } baseRefName headRefName additions deletions
      state isDraft mergeable mergeStateStatus reviewDecision
      autoMergeRequest { enabledAt mergeMethod } labels(first: 20) { nodes { name } }
      commits(last: 1) { totalCount nodes { commit { oid statusCheckRollup { contexts(first: 100) { nodes {
        __typename ... on CheckRun { name status conclusion startedAt title summary detailsUrl
          isRequired(pullRequestNumber: $number) }
        ... on StatusContext { context state description targetUrl isRequired(pullRequestNumber: $number) }
      } } } } } }
      reviews(last: 30) { nodes { author { login } state } }
      closingIssuesReferences(first: 10) { nodes { number repository { nameWithOwner } } }
      reviewThreads(first: 100) { nodes { id isResolved path line
        comments(first: 30) { totalCount nodes { author { login } body diffHunk url } } } }
    } } }
    """

    static let pullFields = """
    number title url isDraft state headRefName updatedAt
    repository { nameWithOwner }
    reviewDecision
    reviewThreads(first: 100) { nodes { isResolved } }
    commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
      __typename ... on CheckRun { name status conclusion startedAt } ... on StatusContext { context state }
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
        let contexts = latest((((commit?["statusCheckRollup"] as? [String: Any])?["contexts"] as? [String: Any])?[
            "nodes"
        ] as? [[String: Any]]) ?? [])
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

    /// One run per check: a re-run, or a check that runs again on the same commit (a label added), leaves the earlier
    /// run in the rollup, and GitHub itself shows only the newest.
    static func latest(_ contexts: [[String: Any]]) -> [[String: Any]] {
        var newest: [String: Int] = [:]
        for (index, context) in contexts.enumerated() where context["__typename"] as? String == "CheckRun" {
            let name = context["name"] as? String ?? ""
            if let seen = newest[name],
               (contexts[seen]["startedAt"] as? String ?? "") > (context["startedAt"] as? String ?? "")
            {
                continue
            }
            newest[name] = index
        }
        let kept = Set(newest.values)
        return contexts.enumerated().filter { index, context in
            context["__typename"] as? String != "CheckRun" || kept.contains(index)
        }.map(\.element)
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
                default:
                    summary.pending += 1
                    summary.pendingNames.append(context["context"] as? String ?? "status")
                }
                continue
            }
            guard context["status"] as? String == "COMPLETED" else {
                summary.pending += 1
                summary.pendingNames.append(context["name"] as? String ?? "check")
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

    static func parsePullDetail(_ data: Data, ref: PullRef, now: Date) -> PullDetail? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let repository = (json["data"] as? [String: Any])?["repository"] as? [String: Any],
              let node = repository["pullRequest"] as? [String: Any]
        else { return nil }
        let commits = node["commits"] as? [String: Any]
        let commit = ((commits?["nodes"] as? [[String: Any]])?.first?["commit"] as? [String: Any])
        let contexts = latest((((commit?["statusCheckRollup"] as? [String: Any])?["contexts"] as? [String: Any])?[
            "nodes"
        ] as? [[String: Any]]) ?? [])
        let failing = contexts.compactMap { context -> PullDetail.FailingCheck? in
            if context["__typename"] as? String == "StatusContext" {
                guard ["FAILURE", "ERROR"].contains(context["state"] as? String ?? "") else { return nil }
                return PullDetail.FailingCheck(
                    name: context["context"] as? String ?? "status", summary: context["description"] as? String ?? "",
                    url: context["targetUrl"] as? String
                )
            }
            guard context["status"] as? String == "COMPLETED",
                  ["FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "CANCELLED"]
                  .contains(context["conclusion"] as? String ?? "")
            else { return nil }
            let summary = (context["title"] as? String) ?? (context["summary"] as? String) ?? ""
            return PullDetail.FailingCheck(
                name: context["name"] as? String ?? "check",
                summary: summary.split(separator: "\n").first.map(String.init) ?? "",
                url: context["detailsUrl"] as? String
            )
        }
        let threadNodes = ((node["reviewThreads"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let threads = threadNodes.compactMap { thread -> ReviewThread? in
            guard let id = thread["id"] as? String else { return nil }
            let comments = thread["comments"] as? [String: Any]
            let first = (comments?["nodes"] as? [[String: Any]])?.first
            let hunk = (first?["diffHunk"] as? String ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            return ReviewThread(
                id: id, isResolved: thread["isResolved"] as? Bool ?? false, path: thread["path"] as? String ?? "",
                line: thread["line"] as? Int,
                author: (first?["author"] as? [String: Any])?["login"] as? String ?? "ghost",
                body: first?["body"] as? String ?? "", diff: hunk.suffix(6).map(String.init),
                replies: max((comments?["totalCount"] as? Int ?? 1) - 1, 0), url: first?["url"] as? String
            )
        }
        let reviewNodes = ((node["reviews"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let reviews = reviewNodes.compactMap { review -> PullDetail.Review? in
            guard let author = (review["author"] as? [String: Any])?["login"] as? String,
                  let state = review["state"] as? String
            else { return nil }
            return PullDetail.Review(author: author, state: state)
        }
        let closes = (((node["closingIssuesReferences"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [])
            .compactMap { issue -> PullRef? in
                guard let number = issue["number"] as? Int,
                      let repo = repo((issue["repository"] as? [String: Any])?["nameWithOwner"] as? String)
                else { return nil }
                return PullRef(repo: repo, number: number)
            }
        var detail = PullDetail(
            ref: ref, title: node["title"] as? String ?? "", body: node["body"] as? String ?? "",
            author: (node["author"] as? [String: Any])?["login"] as? String,
            baseBranch: node["baseRefName"] as? String ?? "", headBranch: node["headRefName"] as? String ?? "",
            additions: node["additions"] as? Int ?? 0, deletions: node["deletions"] as? Int ?? 0,
            commitCount: commits?["totalCount"] as? Int ?? 0, headSHA: commit?["oid"] as? String ?? "",
            reviews: reviews, threads: threads, failingChecks: failing, checks: checkSummary(contexts), closes: closes,
            fetchedAt: now
        )
        detail.state = node["state"] as? String
        detail.isDraft = node["isDraft"] as? Bool
        detail.mergeable = node["mergeable"] as? String
        detail.mergeState = node["mergeStateStatus"] as? String
        detail.reviewDecision = node["reviewDecision"] as? String
        detail.requiredChecks = contexts.filter { $0["isRequired"] as? Bool == true }
            .compactMap { ($0["name"] ?? $0["context"]) as? String }
        let autoMerge = node["autoMergeRequest"] as? [String: Any]
        detail.autoMergeEnabled = autoMerge != nil
        detail.autoMergeMethod = (autoMerge?["mergeMethod"] as? String)?.lowercased()
        detail.labels = ((node["labels"] as? [String: Any])?["nodes"] as? [[String: Any]])?
            .compactMap { $0["name"] as? String }
        detail.repoAllowsAutoMerge = repository["autoMergeAllowed"] as? Bool
        let methods: [(String, String)] = [
            ("squash", "squashMergeAllowed"), ("merge", "mergeCommitAllowed"), ("rebase", "rebaseMergeAllowed"),
        ]
        detail.repoMergeMethods = methods.filter { repository[$0.1] as? Bool == true }.map(\.0)
        return detail
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
