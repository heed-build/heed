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
        refreshTeams: Bool = false,
        now: Date = Date(),
        caller: String
    ) async throws -> GitHubState {
        let full = parts == Set(GitHubPart.allCases)
        async let viewer = fetch(full || previous.viewer == nil) { try await viewer(caller: caller) }
        async let inbox = fetch(parts.contains(.inbox)) { try await notifications(caller: caller) }
        async let pulls = fetch(parts.contains(.pulls)) { try await pullRequests(tracked: tracked, caller: caller) }
        async let issues = fetch(parts.contains(.issues)) { try await self.issues(
            rules: issueRules,
            local: localRepos,
            caller: caller
        )
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
        var teams = previous.teams
        var mentions = previous.teamMentions
        var inboxItems = fetchedInbox ?? previous.inbox
        if let fetchedInbox {
            (teams, mentions) = await attributeTeams(
                inbox: fetchedInbox, teams: teams, cache: mentions, refresh: refreshTeams, now: now, caller: caller
            )
            inboxItems = mentions.applied(to: fetchedInbox)
        }
        return GitHubState(
            viewer: login, inbox: inboxItems, issues: fetchedIssues?.value ?? previous.issues,
            pulls: fetchedPulls?.value ?? previous.pulls, syncedAt: now, status: status, teams: teams,
            teamMentions: mentions
        )
    }

    private static func fetch<T: Sendable>(_ wanted: Bool, _ body: () async throws -> T) async throws -> T? {
        wanted ? try await body() : nil
    }

    public static func viewer(caller: String) async throws -> String {
        let result = try await gh(
            ["api", "user", "--jq", ".login"], operation: "GET user", timeout: .seconds(20), caller: caller
        )
        guard result.succeeded else { throw Failure(description: Self.explain(result)) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func notifications(caller: String) async throws -> [InboxItem] {
        let result = try await gh(
            ["api", "notifications?per_page=50"], operation: "GET notifications", timeout: .seconds(30),
            caller: caller, items: { ((try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [Any])?.count }
        )
        guard result.succeeded else { throw Failure(description: Self.explain(result)) }
        return parseNotifications(Data(result.stdout.utf8))
    }

    public static func pullRequests(tracked: [PullRef], caller: String) async throws -> Fetched<[PullRequest]> {
        let mine = try await graphql(
            pullSearchQuery, operation: "pullSearch",
            variables: ["q": "is:open is:pr author:@me archived:false"],
            caller: caller
        )
        var (pulls, hidden) = parsePullSearch(mine)
        let missing = tracked.filter { ref in !pulls.contains { $0.ref == ref } }
        if !missing.isEmpty {
            let data = try await graphql(
                trackedPullsQuery(missing),
                operation: "trackedPulls",
                variables: [:],
                caller: caller
            )
            let (extra, extraHidden) = parseTrackedPulls(data, refs: missing)
            pulls += extra
            hidden += extraHidden
        }
        return Fetched(value: pulls.sorted { $0.updatedAt > $1.updatedAt }, hidden: hidden)
    }

    /// Issues assigned to you or mentioning you, anywhere, plus every open issue in the repos `rules` shows all of.
    public static func issues(rules: IssueRules, local: [Repo], caller: String) async throws -> Fetched<[Issue]> {
        let base = "is:open is:issue archived:false"
        async let assigned = search("\(base) assignee:@me", caller: caller)
        async let mentioned = search("\(base) mentions:@me", caller: caller)
        var watched: [([Issue], Int)] = []
        for query in watchQueries(base: base, qualifiers: rules.watchQualifiers(local: local)) {
            try await watched.append(search(query, caller: caller))
        }
        let (mine, mineHidden) = try await assigned
        let (mentions, mentionsHidden) = try await mentioned
        let merged = mergeIssues(
            assigned: mine, mentioned: mentions,
            watched: watched.flatMap(\.0).filter { rules.visibility($0.repo) == .all }
        )
        return Fetched(value: merged, hidden: mineHidden + mentionsHidden + watched.map(\.1).reduce(0, +))
    }

    private static func search(_ query: String, caller: String) async throws -> ([Issue], Int) {
        try await parseIssueSearch(graphql(
            issueSearchQuery, operation: "issueSearch",
            variables: ["q": "\(query) sort:updated-desc"],
            caller: caller
        ))
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

    // MARK: Teams

    /// The teams you are on (`gh api user/teams`, every page: one call). Without the `read:org` scope GitHub refuses
    /// the call: no teams, and a note saying how to fix it. Throws when gh itself fails.
    public static func viewerTeams(now: Date = Date(), caller: String) async throws -> ViewerTeams {
        let result = try await gh(
            [
                "api",
                "user/teams",
                "--paginate",
                "--jq",
                #".[] | [.organization.login, .slug, (.parent.slug // "")] | @tsv"#,
            ],
            operation: "GET user/teams", timeout: .seconds(30), caller: caller,
            items: { $0.split(separator: "\n").count }
        )
        guard result.succeeded else {
            let text = result.stderr + result.stdout
            if text.contains("read:org") || text.contains("HTTP 403") {
                return ViewerTeams(fetchedAt: now, note: ViewerTeams.missingScopeNote)
            }
            throw Failure(description: Self.explain(result))
        }
        return ViewerTeams(teams: parseViewerTeams(result.stdout), fetchedAt: now)
    }

    /// How many team searches go in one GraphQL call: a dozen came back as HTTP 502.
    static let teamSearchBatch = 6
    /// How many threads are worked out per sync at most, so a first sync over a full inbox stays cheap.
    public static let teamAttributionLimit = 10

    /// Works out which of your teams each `team_mention` and `review_requested` thread in `inbox` came through, for
    /// the threads `cache` does not know yet: refreshes your teams first when they are stale (daily) or `refresh` asks
    /// and a thread needs them. Never throws: what fails is tried again next sync, or settled as unknown.
    ///
    /// A team mention is looked up with one search per team of the repo's org, `repo:o/r team:o/slug` (batched, and
    /// shared by every thread in that repo); the team is mentioned when the thread is in its results. Search finding
    /// nothing falls back to the thread's text. A review request asks the PR's requested reviewers.
    public static func attributeTeams(
        inbox: [InboxItem], teams: ViewerTeams, cache: TeamMentionCache, refresh: Bool = false,
        limit: Int = teamAttributionLimit, now: Date = Date(), caller: String
    ) async -> (ViewerTeams, TeamMentionCache) {
        var cache = cache
        var teams = teams
        cache.seen(inbox, now: now)
        let pending = Array(inbox.filter { cache.needs($0) }.prefix(limit))
        guard !pending.isEmpty else { return (teams, cache) }
        if refresh || teams.isStale(now: now), let fresh = try? await viewerTeams(now: now, caller: caller) {
            teams = fresh
        }
        guard teams.available else { return (teams, cache) }

        for item in pending where item.reason == "review_requested" {
            guard item.kind == .pr, let number = item.number else {
                cache.record(item, teams: [], source: .unknown, now: now)
                continue
            }
            let ours = Set(teams.teams(in: item.repo.org).map(\.id))
            do {
                let requested = try await requestedTeams(repo: item.repo, number: number, caller: caller)
                cache.record(item, teams: requested.intersection(ours), source: .reviewers, now: now)
            } catch {
                cache.failed(item, now: now)
            }
        }

        let mentions = pending.filter { $0.reason == "team_mention" }
        for repo in Array(Set(mentions.map(\.repo))).sorted(by: { $0.slug < $1.slug }) {
            let threads = mentions.filter { $0.repo == repo }
            let orgTeams = teams.teams(in: repo.org)
            guard !orgTeams.isEmpty else {
                for item in threads {
                    cache.record(item, teams: [], source: .unknown, now: now)
                }
                continue
            }
            let found = await searchTeams(repo: repo, teams: orgTeams, caller: caller)
            for item in threads {
                let url = item.url?.lowercased()
                let searched = Set(found.filter { url != nil && $0.value.contains(url!) }.keys)
                if !searched.isEmpty {
                    cache.record(item, teams: searched, source: .search, now: now)
                    continue
                }
                guard let number = item.number else {
                    cache.record(item, teams: [], source: .unknown, now: now)
                    continue
                }
                do {
                    let text = try await threadText(repo: repo, number: number, caller: caller)
                    let named = TeamMentions.parse(text).intersection(orgTeams.map(\.id))
                    cache.record(item, teams: named, source: named.isEmpty ? .unknown : .text, now: now)
                } catch {
                    cache.failed(item, now: now)
                }
            }
        }
        return (teams, cache)
    }

    /// Each of `teams` that answered, with the threads (web URLs, lowercased) in `repo` that mention it. A batch that
    /// fails (HTTP 502, a timeout) is tried again in pairs; what still fails is left out.
    static func searchTeams(repo: Repo, teams: [GitHubTeam], caller: String) async -> [String: Set<String>] {
        var found: [String: Set<String>] = [:]
        for batch in teams.chunked(teamSearchBatch) {
            if let answer = try? await teamSearch(repo: repo, teams: batch, caller: caller) {
                found.merge(answer) { $0.union($1) }
                continue
            }
            guard batch.count > 2 else { continue }
            for pair in batch.chunked(2) {
                if let answer = try? await teamSearch(repo: repo, teams: pair, caller: caller) {
                    found.merge(answer) { $0.union($1) }
                }
            }
        }
        return found
    }

    private static func teamSearch(repo: Repo, teams: [GitHubTeam], caller: String) async throws
        -> [String: Set<String>]
    {
        let data = try await graphql(
            teamSearchQuery(count: teams.count), operation: "teamSearch",
            variables: teamSearchVariables(repo: repo, teams: teams), caller: caller
        )
        return parseTeamSearch(data, teams: teams)
    }

    /// The thread's body, comments and (for a PR) reviews and review comments, as one text.
    static func threadText(repo: Repo, number: Int, caller: String) async throws -> String {
        let data = try await graphql(
            threadTextQuery, operation: "threadText",
            variables: ["owner": repo.org, "name": repo.name, "number": String(number)], caller: caller
        )
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let thread = ((json["data"] as? [String: Any])?["repository"] as? [String: Any])?["issueOrPullRequest"]
        else { throw Failure(description: "no thread \(repo.slug)#\(number)") }
        return bodies(in: thread).joined(separator: "\n")
    }

    /// The teams (`org/slug`, lowercased) asked to review a PR. REST, as GraphQL hides teams you cannot see.
    static func requestedTeams(repo: Repo, number: Int, caller: String) async throws -> Set<String> {
        let result = try await gh(
            ["api", "repos/\(repo.slug)/pulls/\(number)/requested_reviewers", "--jq", ".teams[].slug"],
            operation: "GET pulls/requested_reviewers", timeout: .seconds(20), caller: caller,
            items: { $0.split(separator: "\n").count }
        )
        guard result.succeeded else { throw Failure(description: Self.explain(result)) }
        return Set(result.stdout.split(separator: "\n").map {
            "\(repo.org)/\($0.trimmingCharacters(in: .whitespaces))".lowercased()
        })
    }

    // MARK: Thread details

    /// How many threads one details call asks for.
    static let detailsBatch = 20

    /// Author, labels, draft, size and the last comments of each thread (`urls`: issue and PR pages, with the update
    /// each is fetched for), in batches of 20 `resource(url:)` lookups. A batch that fails is left out (tried again
    /// next sync); a thread GitHub withholds (SAML) gets an empty detail.
    public static func threadDetails(
        _ urls: [(url: String, updatedAt: Date)], caller: String
    ) async -> [ThreadDetail] {
        var details: [ThreadDetail] = []
        for batch in urls.chunked(detailsBatch) {
            let variables = Dictionary(uniqueKeysWithValues: batch.enumerated()
                .map { ("u\($0.offset)", $0.element.url) })
            guard let data = try? await graphql(
                threadDetailsQuery(count: batch.count), operation: "threadDetails", variables: variables,
                caller: caller
            ) else { continue }
            details += parseThreadDetails(data, asked: batch)
        }
        return details
    }

    static func threadDetailsQuery(count: Int) -> String {
        let comments = "comments(last: 3) { nodes { author { login } bodyText createdAt } }"
        let common = "url updatedAt author { __typename login } labels(first: 10) { nodes { name } } bodyText \(comments)"
        let fields = "... on Issue { \(common) } ... on PullRequest { \(common) isDraft additions deletions headRefName "
            + "reviews(last: 3) { nodes { author { login } bodyText state submittedAt } } }"
        let variables = (0 ..< count).map { "$u\($0): URI!" }.joined(separator: ", ")
        let lookups = (0 ..< count).map { "r\($0): resource(url: $u\($0)) { \(fields) }" }.joined(separator: " ")
        return "query(\(variables)) { \(lookups) }"
    }

    static func parseThreadDetails(_ data: Data, asked: [(url: String, updatedAt: Date)]) -> [ThreadDetail] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answer = json["data"] as? [String: Any] else { return [] }
        return asked.enumerated().compactMap { index, wanted -> ThreadDetail? in
            // Withheld (SAML) or gone: an empty detail, so it is not asked for again until the thread changes.
            guard let node = answer["r\(index)"] as? [String: Any], node["url"] is String else {
                return ThreadDetail(url: wanted.url, updatedAt: wanted.updatedAt)
            }
            let author = node["author"] as? [String: Any]
            let labels = ((node["labels"] as? [String: Any])?["nodes"] as? [[String: Any]])?
                .compactMap { $0["name"] as? String } ?? []
            func entries(_ key: String, at dateKey: String) -> [ThreadDetail.Comment] {
                (((node[key] as? [String: Any])?["nodes"] as? [Any]) ?? []).compactMap { value in
                    guard let entry = value as? [String: Any] else { return nil }
                    let login = (entry["author"] as? [String: Any])?["login"] as? String ?? "ghost"
                    var text = (entry["bodyText"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty, let state = entry["state"] as? String {
                        text = state.lowercased().replacingOccurrences(of: "_", with: " ")
                    }
                    guard !text.isEmpty else { return nil }
                    return ThreadDetail.Comment(author: login, text: text, at: date(entry[dateKey] as? String))
                }
            }
            let comments = (entries("comments", at: "createdAt") + entries("reviews", at: "submittedAt"))
                .sorted { $0.at < $1.at }.suffix(3)
            let additions = node["additions"] as? Int, deletions = node["deletions"] as? Int
            let body = (node["bodyText"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return ThreadDetail(
                url: wanted.url, author: author?["login"] as? String,
                authorIsBot: author?["__typename"] as? String == "Bot", labels: labels,
                isDraft: node["isDraft"] as? Bool,
                size: additions.flatMap { added in deletions.map { added + $0 } },
                headBranch: node["headRefName"] as? String, body: String(body.prefix(600)), comments: Array(comments),
                updatedAt: max(wanted.updatedAt, date(node["updatedAt"] as? String))
            )
        }
    }

    /// Marks a notification thread read.
    public static func markRead(threadID: String, caller: String) async throws {
        let result = try await gh(
            ["api", "-X", "PATCH", "notifications/threads/\(threadID)"], operation: "PATCH notifications/threads",
            write: true, timeout: .seconds(20), caller: caller
        )
        guard result.succeeded else { throw Failure(description: Self.explain(result)) }
    }

    /// Mutes a notification thread: its subscription is set to ignored, so GitHub stops notifying about it (everywhere,
    /// not only in heed).
    public static func muteThread(threadID: String, caller: String) async throws {
        let result = try await gh(
            ["api", "-X", "PUT", "notifications/threads/\(threadID)/subscription", "-F", "ignored=true"],
            operation: "PUT notifications/threads/subscription", write: true, timeout: .seconds(20), caller: caller
        )
        guard result.succeeded else { throw Failure(description: Self.explain(result)) }
    }

    /// Comments on an issue or PR (they share the issue comments API).
    public static func comment(repo: Repo, number: Int, body: String, caller: String) async throws {
        let result = try await gh(
            ["api", "-X", "POST", "repos/\(repo.slug)/issues/\(number)/comments", "-f", "body=\(body)"],
            operation: "POST issues/comments", write: true, shown: [
                "api", "-X", "POST", "repos/\(repo.slug)/issues/\(number)/comments", "-f", "body=…",
            ], timeout: .seconds(30), caller: caller
        )
        guard result.succeeded else { throw Failure(description: Self.explain(result)) }
    }

    /// Runs a GraphQL query. gh exits non-zero when the answer carries errors, even with data; the data is returned
    /// as long as there is some.
    ///
    /// Every query also asks for its `rateLimit` (cost and what remains), which the call log keeps; `operation` names
    /// it there, in place of the query text.
    static func graphql(
        _ query: String, operation: String, variables: [String: String], caller: String
    ) async throws -> Data {
        var fields: [String] = []
        for (key, value) in variables.sorted(by: { $0.key < $1.key }) {
            // -F sends a typed field, so `number` reaches GraphQL as an Int; -f keeps strings strings.
            fields += [key == "number" ? "-F" : "-f", "\(key)=\(value)"]
        }
        let result = try await gh(
            ["api", "graphql", "-f", "query=\(withRateLimit(query))"] + fields, operation: "graphql \(operation)",
            shown: ["api", "graphql", "-f", "query=@\(operation)"] + fields, variables: variables,
            timeout: .seconds(45), caller: caller, counts: graphqlCounts
        )
        let data = Data(result.stdout.utf8)
        if !result.succeeded, (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] == nil {
            throw Failure(description: Self.explain(result))
        }
        return data
    }

    /// The query with `rateLimit { cost remaining }` added to its top-level selection (the first `{`: variable
    /// definitions are in parentheses).
    static func withRateLimit(_ query: String) -> String {
        guard let brace = query.firstIndex(of: "{") else { return query }
        return query.replacingCharacters(in: brace ... brace, with: "{ rateLimit { cost remaining }")
    }

    /// What a GraphQL answer says for the call log: items (the nodes of a search, else each aliased field that
    /// answered), SAML-withheld entries, and the rate limit.
    static func graphqlCounts(_ stdout: String) -> GitHubCounts {
        guard let json = try? JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any] else {
            return GitHubCounts()
        }
        let data = json["data"] as? [String: Any] ?? [:]
        let rate = data["rateLimit"] as? [String: Any]
        let items = data.filter { $0.key != "rateLimit" }.values.reduce(0) { total, value in
            guard let field = value as? [String: Any] else { return total }
            return total + ((field["nodes"] as? [Any])?.count ?? 1)
        }
        return GitHubCounts(
            items: items, hidden: hiddenCount(json), rateCost: rate?["cost"] as? Int,
            rateRemaining: rate?["remaining"] as? Int, answered: json["data"] is [String: Any]
        )
    }

    /// Runs gh, and records it in the call log as a GitHub call (not as a shell call: one row per call). `shown` is
    /// the command as the log keeps it, when the real one is too long to keep (a GraphQL query's text).
    static func gh(
        _ arguments: [String], operation: String, write: Bool = false, shown: [String]? = nil,
        variables: [String: String] = [:], timeout: Duration, caller: String,
        items: @escaping @Sendable (String) -> Int? = { _ in nil },
        counts: (@Sendable (String) -> GitHubCounts)? = nil
    ) async throws -> ProcessResult {
        let started = Date()
        func record(_ result: ProcessResult?, _ error: String?) {
            let found = result.map { counts?($0.stdout) ?? GitHubCounts(items: items($0.stdout)) } ?? GitHubCounts()
            // gh exits non-zero when a GraphQL answer carries errors (SAML-withheld items), even with data: answered.
            let failed = result.map { !$0.succeeded && !found.answered } ?? true
            CallLog.record(LoggedCall(
                at: started, kind: .github, caller: caller,
                command: (["gh"] + (shown ?? arguments)).map(ShellQuote.quote).joined(separator: " "),
                duration: Date().timeIntervalSince(started), exitCode: result.map { Int($0.status) }, failed: failed,
                stdout: failed ? LoggedCall.truncated(result?.stdout) : nil,
                stderr: LoggedCall.truncated(error ?? result?.stderr), operation: operation, write: write,
                items: found.items, hidden: found.hidden, rateCost: found.rateCost, rateRemaining: found.rateRemaining,
                detail: variables
            ))
        }
        do {
            let result = try await ProcessRunner.execute(executable, arguments, timeout: timeout)
            record(result, nil)
            return result
        } catch let error as ProcessError {
            record(error.result, error.reason)
            throw error
        } catch {
            record(nil, "\(error)")
            throw error
        }
    }

    /// The gh to run: `gh`, found as every tool is; tests point it at a stand-in.
    @TaskLocal static var executable = "gh"

    static func explain(_ result: ProcessResult) -> String {
        let text = (result.stderr.isEmpty ? result.stdout : result.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("gh auth login") || text
            .contains("not logged") { return "gh is not signed in (gh auth login)" }
        if text.contains("could not start") { return "gh is not installed" }
        return text.split(separator: "\n").first.map(String.init) ?? "gh failed (exit \(result.status))"
    }

    /// The reader's view of one PR.
    public static func pullDetail(_ ref: PullRef, now: Date = Date(), caller: String) async throws -> PullDetail {
        let data = try await graphql(
            pullDetailQuery, operation: "pullDetail",
            variables: ["owner": ref.repo.org, "name": ref.repo.name, "number": String(ref.number)], caller: caller
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
    public static func failedLog(repo: Repo, job: String, lines: Int = 80, caller: String) async throws -> String {
        let result = try await gh(
            ["run", "view", "--job", job, "--log-failed", "-R", repo.slug], operation: "run view --log-failed",
            timeout: .seconds(60), caller: caller
        )
        guard result.succeeded else { throw Failure(description: Self.explain(result)) }
        return result.stdout.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines)
            .map { cleanLogLine(String($0)) }.joined(separator: "\n")
    }

    /// `gh pr merge --auto --<method>`: auto-merge on, or a merge right away when GitHub has nothing left to wait for.
    public static func enableAutoMerge(_ ref: PullRef, method: String, caller: String) async throws {
        try await pr(["merge", "\(ref.number)", "--auto", "--\(method)", "-R", ref.repo.slug], caller: caller)
    }

    public static func disableAutoMerge(_ ref: PullRef, caller: String) async throws {
        try await pr(["merge", "\(ref.number)", "--disable-auto", "-R", ref.repo.slug], caller: caller)
    }

    /// `gh pr update-branch`: merges the base into a PR that fell behind.
    public static func updateBranch(_ ref: PullRef, caller: String) async throws {
        try await pr(["update-branch", "\(ref.number)", "-R", ref.repo.slug], caller: caller)
    }

    /// Whether GitHub's Copilot coding agent can be assigned in a repo: it is among the repo's suggested actors.
    public static func copilotAvailable(_ repo: Repo, caller: String) async throws -> Bool {
        let query = """
        query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) {
          suggestedActors(capabilities: [CAN_BE_ASSIGNED], first: 100) { nodes { login } } } }
        """
        let data = try await graphql(
            query, operation: "suggestedActors", variables: ["owner": repo.org, "name": repo.name], caller: caller
        )
        return parseCopilotAvailable(data)
    }

    static func parseCopilotAvailable(_ data: Data) -> Bool {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let actors = (((json?["data"] as? [String: Any])?["repository"] as? [String: Any])?["suggestedActors"]
            as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        return actors.contains { $0["login"] as? String == CopilotAsk.login }
    }

    /// `gh pr edit --add-reviewer`: logins, `org/team`, or `@copilot`.
    public static func requestReviews(_ ref: PullRef, from reviewers: [String], caller: String) async throws {
        try await pr(
            ["edit", "\(ref.number)", "--add-reviewer", reviewers.joined(separator: ","), "-R", ref.repo.slug],
            caller: caller
        )
    }

    /// `gh pr merge --<method> --match-head-commit <sha>`: merges only the commit the rules were checked on.
    public static func merge(
        _ ref: PullRef, method: String, head: String, admin: Bool = false, caller: String
    ) async throws {
        try await pr(
            ["merge", "\(ref.number)", "--\(method)", "--match-head-commit", head, "-R", ref.repo.slug]
                + (admin ? ["--admin"] : []),
            caller: caller
        )
    }

    /// `gh pr diff`.
    public static func diff(_ ref: PullRef, caller: String) async throws -> String {
        let result = try await gh(
            ["pr", "diff", "\(ref.number)", "-R", ref.repo.slug], operation: "pr diff", timeout: .seconds(60),
            caller: caller
        )
        guard result.succeeded else { throw Failure(description: Self.explain(result)) }
        return result.stdout
    }

    /// `gh pr comment`.
    public static func comment(_ ref: PullRef, body: String, caller: String) async throws {
        try await pr(["comment", "\(ref.number)", "--body", body, "-R", ref.repo.slug], caller: caller)
    }

    private static func pr(_ arguments: [String], caller: String) async throws {
        // Every `gh pr` heed runs changes the PR (merge, edit, comment, update-branch).
        let result = try await gh(
            ["pr"] + arguments, operation: "pr \(arguments.first ?? "")", write: true, timeout: .seconds(60),
            caller: caller
        )
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
      autoMergeAllowed squashMergeAllowed mergeCommitAllowed rebaseMergeAllowed viewerPermission
      pullRequest(number: $number) {
      number title body author { login } baseRefName headRefName additions deletions
      baseRef { refUpdateRule { requiresLinearHistory } }
      state isDraft mergeable mergeStateStatus reviewDecision
      autoMergeRequest { enabledAt mergeMethod } labels(first: 20) { nodes { name } }
      commits(last: 1) { totalCount nodes { commit { oid committedDate statusCheckRollup { contexts(first: 100) { nodes {
        __typename ... on CheckRun { name status conclusion startedAt title summary detailsUrl
          isRequired(pullRequestNumber: $number) }
        ... on StatusContext { context state description targetUrl isRequired(pullRequestNumber: $number) }
      } } } } } }
      reviews(last: 30) { nodes { author { login } state submittedAt commit { oid } } }
      timelineItems(itemTypes: [CROSS_REFERENCED_EVENT], last: 20) { nodes { ... on CrossReferencedEvent {
        source { ... on PullRequest { number title state createdAt author { login } repository { nameWithOwner } } }
      } } }
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

    /// Titles and states of the issues sessions link to, at most 50 a call. A number that turns out to be a PR is left
    /// out.
    public static func issueInfo(_ refs: [IssueRef], caller: String) async throws -> [IssueRef: IssueInfo] {
        guard !refs.isEmpty else { return [:] }
        let batch = Array(refs.prefix(50))
        let data = try await graphql(
            linkedIssuesQuery(batch),
            operation: "linkedIssues",
            variables: [:],
            caller: caller
        )
        return parseLinkedIssues(data, refs: batch)
    }

    static func linkedIssuesQuery(_ refs: [IssueRef]) -> String {
        let parts = refs.enumerated().map { index, ref in
            "i\(index): repository(owner: \"\(ref.repo.org)\", name: \"\(ref.repo.name)\") { issueOrPullRequest(number: \(ref.number)) { __typename ... on Issue { title state bodyText updatedAt author { login } labels(first: 10) { nodes { name } } } } }"
        }
        return "query { \(parts.joined(separator: "\n")) }"
    }

    static func parseLinkedIssues(_ data: Data, refs: [IssueRef]) -> [IssueRef: IssueInfo] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = json["data"] as? [String: Any]
        else { return [:] }
        var result: [IssueRef: IssueInfo] = [:]
        for (index, ref) in refs.enumerated() {
            guard let node = (root["i\(index)"] as? [String: Any])?["issueOrPullRequest"] as? [String: Any],
                  node["__typename"] as? String == "Issue"
            else { continue }
            let labels = ((node["labels"] as? [String: Any])?["nodes"] as? [[String: Any]])?
                .compactMap { $0["name"] as? String } ?? []
            result[ref] = IssueInfo(
                title: node["title"] as? String ?? "", closed: node["state"] as? String == "CLOSED",
                body: node["bodyText"] as? String ?? "", labels: labels,
                author: (node["author"] as? [String: Any])?["login"] as? String,
                updatedAt: date(node["updatedAt"] as? String)
            )
        }
        return result
    }

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

    /// One aliased search per team (`t0`…), each over the thread's repo: `$qN` is `repo:o/r team:o/slug`.
    static func teamSearchQuery(count: Int) -> String {
        let variables = (0 ..< count).map { "$q\($0): String!" }.joined(separator: ", ")
        let searches = (0 ..< count).map {
            "t\($0): search(type: ISSUE, first: 100, query: $q\($0)) { issueCount nodes { ... on Issue { url } ... on PullRequest { url } } }"
        }.joined(separator: " ")
        return "query(\(variables)) { \(searches) }"
    }

    static func teamSearchVariables(repo: Repo, teams: [GitHubTeam]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: teams.enumerated().map { index, team in
            ("q\(index)", "repo:\(repo.slug) team:\(team.org)/\(team.slug)")
        })
    }

    static let threadTextQuery = """
    query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) {
      issueOrPullRequest(number: $number) {
        ... on Issue { body comments(last: 100) { nodes { body } } }
        ... on PullRequest { body comments(last: 100) { nodes { body } }
          reviews(last: 50) { nodes { body comments(first: 50) { nodes { body } } } } }
    } } }
    """

    // MARK: Parsing (pure, tested)

    /// `org\tslug\tparent` lines (parent empty for a top-level team).
    static func parseViewerTeams(_ text: String) -> [GitHubTeam] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard fields.count >= 2, !fields[0].isEmpty, !fields[1].isEmpty else { return nil }
            let parent = fields.count > 2 && !fields[2].isEmpty ? fields[2] : nil
            return GitHubTeam(org: fields[0], slug: fields[1], parent: parent)
        }
    }

    /// For each team whose search answered, the URLs (lowercased) it returned. A search GitHub withheld or failed
    /// (null, SAML) is left out, so it neither confirms nor rules out a mention.
    static func parseTeamSearch(_ data: Data, teams: [GitHubTeam]) -> [String: Set<String>] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answer = json["data"] as? [String: Any] else { return [:] }
        var found: [String: Set<String>] = [:]
        for (index, team) in teams.enumerated() {
            guard let search = answer["t\(index)"] as? [String: Any],
                  let nodes = search["nodes"] as? [Any] else { continue }
            let urls = nodes.compactMap { (($0 as? [String: Any])?["url"] as? String)?.lowercased() }
            found[team.id, default: []].formUnion(urls)
        }
        return found
    }

    /// Every `body` string anywhere in a JSON value, in document order.
    static func bodies(in value: Any) -> [String] {
        if let object = value as? [String: Any] {
            return object.keys.sorted().flatMap { key -> [String] in
                if key == "body", let body = object[key] as? String { return [body] }
                return bodies(in: object[key] as Any)
            }
        }
        if let list = value as? [Any] { return list.flatMap(bodies(in:)) }
        return []
    }

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
                url: web?.url ?? (kind == .ci ? "https://github.com/\(repo.slug)/actions" : nil),
                subjectAPI: subject["url"] as? String
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
            return PullDetail.Review(
                author: author, state: state, submittedAt: date(review["submittedAt"] as? String),
                commit: (review["commit"] as? [String: Any])?["oid"] as? String
            )
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
        detail.viewerPermission = repository["viewerPermission"] as? String
        detail.repoRequiresLinearHistory = ((node["baseRef"] as? [String: Any])?["refUpdateRule"] as? [String: Any])?[
            "requiresLinearHistory"
        ] as? Bool
        detail.headCommittedAt = date(commit?["committedDate"] as? String)
        let crossReferences = ((node["timelineItems"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        detail.references = crossReferences.compactMap { event -> PullDetail.Reference? in
            guard let source = event["source"] as? [String: Any], let number = source["number"] as? Int,
                  let repo = repo((source["repository"] as? [String: Any])?["nameWithOwner"] as? String)
            else { return nil }
            let ref = PullRef(repo: repo, number: number)
            guard ref != detail.ref else { return nil }
            return PullDetail.Reference(
                ref: ref, title: source["title"] as? String ?? "",
                author: (source["author"] as? [String: Any])?["login"] as? String,
                state: source["state"] as? String ?? "OPEN",
                createdAt: (source["createdAt"] as? String).map { date($0) }
            )
        }
        detail.passedChecks = contexts.filter { context in
            context["__typename"] as? String == "StatusContext" ? context["state"] as? String == "SUCCESS"
                : context["status"] as? String == "COMPLETED"
                && ["SUCCESS", "NEUTRAL", "SKIPPED"].contains(context["conclusion"] as? String ?? "")
        }.compactMap { ($0["name"] ?? $0["context"]) as? String }
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

/// What the call log keeps of a GitHub answer.
public struct GitHubCounts: Equatable, Sendable {
    public var items: Int?
    public var hidden: Int?
    public var rateCost: Int?
    public var rateRemaining: Int?
    /// A GraphQL answer with data, whatever gh's exit code.
    public var answered: Bool

    public init(
        items: Int? = nil, hidden: Int? = nil, rateCost: Int? = nil, rateRemaining: Int? = nil, answered: Bool = false
    ) {
        self.items = items
        self.hidden = hidden
        self.rateCost = rateCost
        self.rateRemaining = rateRemaining
        self.answered = answered
    }
}
