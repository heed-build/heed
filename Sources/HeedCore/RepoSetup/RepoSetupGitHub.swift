import Foundation

/// The setup wizard's reads: a repo's merge settings, its last merged PRs, and its CI history. GETs only, each a row
/// in the call log under the caller given (`repo.setup`); raw JSON stays in this file.
public extension GitHub {
    /// One step of a sample, for the wizard's progress list.
    enum SampleStep: String, CaseIterable, Sendable {
        case settings = "Repo settings and branch rules"
        case pulls = "Last merged PRs"
        case runs = "CI runs on PRs"
        case failures = "Why CI failed"
    }

    /// The most failed runs the sample opens, and the failed-step logs it reads when a step's name says too little.
    static let sampledFailures = 20
    static let sampledLogs = 5
    static let sampledPulls = 30

    /// Samples a repo: its settings (GraphQL, then REST protection and rulesets, which readers can see too), its last
    /// merged PRs into the default branch, and its PR runs. `progress` hears each step start and end.
    static func sampleRepo(
        _ repo: Repo, runs: [PilotRun] = [], tasks: [TaskSpec] = [], caller: String,
        progress: @escaping @Sendable (SampleStep, Bool) async -> Void = { _, _ in }
    ) async throws -> RepoSetupSample {
        var calls = 0
        var cost = 0
        func counted(_ data: Data) -> Data {
            calls += 1
            cost += graphqlCounts(String(decoding: data, as: UTF8.self)).rateCost ?? 0
            return data
        }
        await progress(.settings, false)
        let variables = ["owner": repo.org, "name": repo.name]
        let settingsData = try await counted(graphql(
            repoSettingsQuery, operation: "repoSettings", variables: variables, caller: caller
        ))
        let branch = parseDefaultBranch(settingsData) ?? "main"
        let path = "repos/\(repo.slug)"
        async let protection = rest("\(path)/branches/\(branch)", operation: "GET branches/{branch}", caller: caller)
        async let rules = rest("\(path)/rules/branches/\(branch)", operation: "GET rules/branches", caller: caller)
        let (protectionData, rulesData) = await (protection, rules)
        calls += 2
        guard let settings = parseRepoSettings(settingsData, branch: protectionData, rules: rulesData) else {
            throw Failure(description: "\(repo.slug) is not visible to gh")
        }
        await progress(.settings, true)
        await progress(.pulls, false)
        let pullsData = try await counted(graphql(
            mergedPullsQuery, operation: "mergedPulls",
            variables: variables.merging(["base": settings.defaultBranch]) { $1 }, caller: caller
        ))
        let pulls = parseMergedPulls(pullsData)
        await progress(.pulls, true)
        await progress(.runs, false)
        let runsData = await rest(
            "\(path)/actions/runs?event=pull_request&per_page=100", operation: "GET actions/runs", caller: caller
        )
        let failedData = await rest(
            "\(path)/actions/runs?event=pull_request&status=failure&per_page=\(sampledFailures)",
            operation: "GET actions/runs (failed)", caller: caller
        )
        calls += 2
        let prRuns = runsData.map(parseWorkflowRuns) ?? []
        let failedRuns = Array((failedData.map(parseWorkflowRuns) ?? []).prefix(sampledFailures))
        await progress(.runs, true)
        await progress(.failures, false)
        var failures: [CIHistory.Failure] = []
        var logsRead = 0
        for run in failedRuns {
            let jobsData = await rest(
                "\(path)/actions/runs/\(run.id)/jobs", operation: "GET actions/runs/{id}/jobs", caller: caller
            )
            calls += 1
            let jobs = jobsData.map(parseFailedJobs) ?? []
            if jobs.isEmpty {
                failures.append(CIHistory.Failure(workflow: run.name, job: run.name, kind: .infra))
                continue
            }
            for job in jobs {
                var kind = classifyFailure(job: job.name, step: job.step, log: nil)
                if kind == .other, logsRead < sampledLogs {
                    logsRead += 1
                    calls += 1
                    let log = try? await failedLog(repo: repo, job: String(job.id), lines: 200, caller: caller)
                    kind = classifyFailure(job: job.name, step: job.step, log: log)
                }
                failures.append(CIHistory.Failure(workflow: run.name, job: job.name, step: job.step, kind: kind))
            }
        }
        await progress(.failures, true)
        return RepoSetupSample(
            repo: repo, settings: settings, pulls: pulls,
            ci: CIHistory(runs: prRuns.count, flaky: flaky(prRuns), failures: failures),
            runs: runs.filter { $0.ref.repo == repo }, tasks: tasks, calls: calls, cost: cost
        )
    }

    /// A REST GET; nil when it failed (a repo without Actions, rules a token cannot read): the sample goes on without.
    private static func rest(_ path: String, operation: String, caller: String) async -> Data? {
        guard let result = try? await gh(["api", path], operation: operation, timeout: .seconds(30), caller: caller),
              result.succeeded
        else { return nil }
        return Data(result.stdout.utf8)
    }

    // MARK: Settings

    static let repoSettingsQuery = """
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        autoMergeAllowed squashMergeAllowed mergeCommitAllowed rebaseMergeAllowed deleteBranchOnMerge
        viewerDefaultMergeMethod viewerPermission
        defaultBranchRef { name branchProtectionRule { requiredStatusCheckContexts requiredApprovingReviewCount
          requiresLinearHistory requiresStrictStatusChecks requireLastPushApproval requiresCodeOwnerReviews } }
        mergeQueue { id }
        codeowners: object(expression: "HEAD:.github/CODEOWNERS") { ... on Blob { byteSize } }
      }
    }
    """

    static func parseDefaultBranch(_ data: Data) -> String? {
        let repository = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"]
            as? [String: Any])?["repository"] as? [String: Any]
        return (repository?["defaultBranchRef"] as? [String: Any])?["name"] as? String
    }

    /// The GraphQL answer, with REST's branch (its protection, which readers see when GraphQL hides the rule) and
    /// the rules that apply to the branch (rulesets).
    static func parseRepoSettings(_ data: Data, branch: Data?, rules: Data?) -> RepoMergeSettings? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let repository = (json["data"] as? [String: Any])?["repository"] as? [String: Any]
        else { return nil }
        var settings = RepoMergeSettings()
        let defaultBranch = repository["defaultBranchRef"] as? [String: Any]
        settings.defaultBranch = defaultBranch?["name"] as? String ?? "main"
        let buttons: [(String, String)] = [
            ("squash", "squashMergeAllowed"), ("merge", "mergeCommitAllowed"), ("rebase", "rebaseMergeAllowed"),
        ]
        // Readers of some repos get nulls: then every method counts as allowed, as GitHub's merge would tell.
        let known = buttons.filter { repository[$0.1] is Bool }
        settings.repoMethods = known.isEmpty ? MergeQueue.methods
            : buttons.filter { repository[$0.1] as? Bool == true }.map(\.0)
        settings.autoMergeAllowed = repository["autoMergeAllowed"] as? Bool
        settings.deleteBranchOnMerge = repository["deleteBranchOnMerge"] as? Bool
        settings.viewerPermission = repository["viewerPermission"] as? String
        settings.mergeQueue = repository["mergeQueue"] is [String: Any]
        settings.hasCodeowners = repository["codeowners"] is [String: Any]
        var required: [String] = []
        if let rule = defaultBranch?["branchProtectionRule"] as? [String: Any] {
            required += rule["requiredStatusCheckContexts"] as? [String] ?? []
            settings.requiredApprovals = rule["requiredApprovingReviewCount"] as? Int ?? 0
            settings.linearHistory = rule["requiresLinearHistory"] as? Bool ?? false
            settings.strictChecks = rule["requiresStrictStatusChecks"] as? Bool ?? false
            settings.lastPushApproval = rule["requireLastPushApproval"] as? Bool ?? false
            settings.codeOwnerReview = rule["requiresCodeOwnerReviews"] as? Bool ?? false
        }
        if let branch, let object = try? JSONSerialization.jsonObject(with: branch) as? [String: Any] {
            let checks = (object["protection"] as? [String: Any])?["required_status_checks"] as? [String: Any]
            required += checks?["contexts"] as? [String] ?? []
        }
        if let rules, let list = try? JSONSerialization.jsonObject(with: rules) as? [[String: Any]] {
            for rule in list {
                let parameters = rule["parameters"] as? [String: Any] ?? [:]
                switch rule["type"] as? String {
                case "pull_request":
                    settings.requiredApprovals = max(
                        settings.requiredApprovals, parameters["required_approving_review_count"] as? Int ?? 0
                    )
                    if let methods = parameters["allowed_merge_methods"] as? [String] {
                        settings.rulesetMethods = (settings.rulesetMethods ?? MergeQueue.methods)
                            .filter(methods.contains)
                    }
                    if parameters["require_last_push_approval"] as? Bool == true { settings.lastPushApproval = true }
                    if parameters["require_code_owner_review"] as? Bool == true { settings.codeOwnerReview = true }
                case "required_status_checks":
                    let checks = parameters["required_status_checks"] as? [[String: Any]] ?? []
                    required += checks.compactMap { $0["context"] as? String }
                    if parameters["strict_required_status_checks_policy"] as? Bool == true {
                        settings.strictChecks = true
                    }
                case "required_linear_history": settings.linearHistory = true
                case "merge_queue": settings.mergeQueue = true
                case "copilot_code_review": settings.copilotReview = true
                default: break
                }
            }
        }
        var seen = Set<String>()
        settings.requiredChecks = required.filter { seen.insert($0).inserted }
        return settings
    }

    // MARK: Merged PRs

    /// The last merged PRs into the base, with what decided each merge. Costs about 17 points for 30.
    static let mergedPullsQuery = """
    query($owner: String!, $name: String!, $base: String!) {
      repository(owner: $owner, name: $name) {
        pullRequests(states: MERGED, baseRefName: $base, first: \(sampledPulls),
                     orderBy: { field: UPDATED_AT, direction: DESC }) {
          nodes {
            number title createdAt mergedAt
            author { __typename login }
            mergedBy { login }
            labels(first: 20) { nodes { name } }
            mergeCommit { parents { totalCount } }
            commits(last: 1) { totalCount nodes { commit { oid committedDate statusCheckRollup { contexts(first: 50) {
              nodes { __typename ... on CheckRun { name status conclusion startedAt }
                      ... on StatusContext { context state } } } } } } }
            timelineItems(first: 50, itemTypes: [LABELED_EVENT, UNLABELED_EVENT, AUTO_MERGE_ENABLED_EVENT,
                                                 ADDED_TO_MERGE_QUEUE_EVENT, MERGED_EVENT]) {
              nodes { __typename ... on LabeledEvent { createdAt label { name } }
                      ... on UnlabeledEvent { createdAt label { name } }
                      ... on AutoMergeEnabledEvent { createdAt } ... on AddedToMergeQueueEvent { createdAt }
                      ... on MergedEvent { createdAt } }
            }
            reviews(last: 20) { nodes { author { __typename login } state submittedAt commit { oid } } }
            reviewThreads(first: 50) { nodes { isResolved comments(first: 1) { nodes { author { login } path } } } }
          }
        }
      }
    }
    """

    /// Bots by how GitHub names them: an app (`Bot`), a `…[bot]` login, Copilot's reviewer.
    static func isBot(_ author: [String: Any]?) -> Bool {
        guard let author else { return false }
        let login = (author["login"] as? String ?? "").lowercased()
        return author["__typename"] as? String == "Bot" || login.hasSuffix("[bot]") || login.contains("copilot")
    }

    static func parseMergedPulls(_ data: Data) -> [SampledPull] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let repository = (json["data"] as? [String: Any])?["repository"] as? [String: Any],
              let nodes = (repository["pullRequests"] as? [String: Any])?["nodes"] as? [[String: Any]]
        else { return [] }
        return nodes.compactMap(parseMergedPull)
    }

    static func parseMergedPull(_ node: [String: Any]) -> SampledPull? {
        guard let number = node["number"] as? Int, let merged = node["mergedAt"] as? String else { return nil }
        let mergedAt = date(merged)
        let author = node["author"] as? [String: Any]
        let commits = node["commits"] as? [String: Any]
        let commit = (commits?["nodes"] as? [[String: Any]])?.first?["commit"] as? [String: Any]
        let contexts = latest((((commit?["statusCheckRollup"] as? [String: Any])?["contexts"] as? [String: Any])?[
            "nodes"
        ] as? [[String: Any]]) ?? [])
        var passed: [String] = []
        var failed: [String] = []
        var pending: [String] = []
        for context in contexts {
            let name = (context["name"] ?? context["context"]) as? String ?? "check"
            if context["__typename"] as? String == "StatusContext" {
                switch context["state"] as? String {
                case "SUCCESS": passed.append(name)
                case "FAILURE", "ERROR": failed.append(name)
                default: pending.append(name)
                }
            } else if context["status"] as? String != "COMPLETED" {
                pending.append(name)
            } else if ["SUCCESS", "NEUTRAL", "SKIPPED"].contains(context["conclusion"] as? String ?? "") {
                passed.append(name)
            } else {
                failed.append(name)
            }
        }
        // Count the timeline's nodes: its totalCount includes events of every type.
        let events = (((node["timelineItems"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [])
            .map { (
                kind: $0["__typename"] as? String ?? "",
                at: date($0["createdAt"] as? String),
                label: ($0["label"] as? [String: Any])?["name"] as? String
            ) }
            .sorted { $0.at < $1.at }
        let mergeEvent = events.first { $0.kind == "MergedEvent" }?.at ?? mergedAt
        var onPull: Set<String> = []
        var seen: [String] = []
        var removed: [String] = []
        for event in events where event.at <= mergeEvent {
            guard let label = event.label else { continue }
            if event.kind == "LabeledEvent" {
                onPull.insert(label)
                removed.removeAll { $0 == label }
                if !seen.contains(label) { seen.append(label) }
            } else if event.kind == "UnlabeledEvent" {
                onPull.remove(label)
                if !removed.contains(label) { removed.append(label) }
                if !seen.contains(label) { seen.append(label) }
            }
        }
        let labels = (((node["labels"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [])
            .compactMap { $0["name"] as? String }
        for label in labels where !seen.contains(label) {
            seen.append(label)
        }
        var bots: Set<String> = []
        let reviews = (((node["reviews"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [])
            .compactMap { review -> PullDetail.Review? in
                let reviewer = review["author"] as? [String: Any]
                guard let login = reviewer?["login"] as? String, let state = review["state"] as? String else {
                    return nil
                }
                if isBot(reviewer) { bots.insert(login) }
                return PullDetail.Review(
                    author: login, state: state, submittedAt: date(review["submittedAt"] as? String),
                    commit: (review["commit"] as? [String: Any])?["oid"] as? String
                )
            }
        let threads = (((node["reviewThreads"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [])
            .enumerated().map { index, thread in
                let first = ((thread["comments"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first
                return ReviewThread(
                    id: "\(number)-\(index)", isResolved: thread["isResolved"] as? Bool ?? false,
                    path: first?["path"] as? String ?? "", line: nil,
                    author: (first?["author"] as? [String: Any])?["login"] as? String ?? "ghost", body: "", diff: [],
                    replies: 0, url: nil
                )
            }
        let parents = ((node["mergeCommit"] as? [String: Any])?["parents"] as? [String: Any])?["totalCount"] as? Int
        return SampledPull(
            number: number, title: node["title"] as? String ?? "", author: author?["login"] as? String ?? "ghost",
            authorIsBot: isBot(author), mergedBy: (node["mergedBy"] as? [String: Any])?["login"] as? String,
            createdAt: date(node["createdAt"] as? String), mergedAt: mergedAt, labels: labels,
            removedBeforeMerge: removed, labelsSeen: seen, parents: parents,
            commits: commits?["totalCount"] as? Int ?? 1,
            autoMerge: events.contains { $0.kind == "AutoMergeEnabledEvent" },
            mergeQueue: events.contains { $0.kind == "AddedToMergeQueueEvent" }, reviews: reviews, botReviewers: bots,
            threads: threads, headSHA: commit?["oid"] as? String ?? "",
            headCommittedAt: (commit?["committedDate"] as? String).map { date($0) }, passedChecks: passed,
            failedChecks: failed, pendingChecks: pending
        )
    }

    // MARK: CI

    struct WorkflowRun: Hashable, Sendable {
        let id: Int
        let name: String
        let attempt: Int
        let conclusion: String?
    }

    struct FailedJob: Hashable, Sendable {
        let id: Int
        let name: String
        /// The first step that failed.
        let step: String?
    }

    static func parseWorkflowRuns(_ data: Data) -> [WorkflowRun] {
        let runs = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["workflow_runs"]
            as? [[String: Any]]) ?? []
        return runs.compactMap { run in
            guard let id = run["id"] as? Int else { return nil }
            return WorkflowRun(
                id: id, name: run["name"] as? String ?? "workflow", attempt: run["run_attempt"] as? Int ?? 1,
                conclusion: run["conclusion"] as? String
            )
        }
    }

    static func parseFailedJobs(_ data: Data) -> [FailedJob] {
        let jobs = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["jobs"] as? [[String: Any]])
            ?? []
        return jobs.filter { $0["conclusion"] as? String == "failure" }.compactMap { job in
            guard let id = job["id"] as? Int else { return nil }
            let steps = job["steps"] as? [[String: Any]] ?? []
            return FailedJob(
                id: id, name: job["name"] as? String ?? "job",
                step: steps.first { $0["conclusion"] as? String == "failure" }?["name"] as? String
            )
        }
    }

    /// Workflows that passed on a later attempt, most retried first.
    static func flaky(_ runs: [WorkflowRun]) -> [CIHistory.Flaky] {
        var total: [String: Int] = [:]
        var retried: [String: Int] = [:]
        for run in runs {
            total[run.name, default: 0] += 1
            if run.attempt > 1, run.conclusion == "success" { retried[run.name, default: 0] += 1 }
        }
        return retried.map { CIHistory.Flaky(workflow: $0.key, retried: $0.value, runs: total[$0.key] ?? $0.value) }
            .sorted { ($0.retried, $1.workflow) > ($1.retried, $0.workflow) }
    }

    /// What kind of failure a failed job was, from its failed step's name, then its own, then its log.
    static func classifyFailure(job: String, step: String?, log: String?) -> CIHistory.Kind {
        let kinds: [(CIHistory.Kind, [String])] = [
            (.lint, [
                "lint", "format", "fmt", "prettier", "eslint", "swiftlint", "rubocop", "clippy", "ruff", "black",
                "style", "vet", "spell",
            ]),
            (.test, ["test", "spec", "e2e", "pytest", "jest", "vitest"]),
            (.build, ["build", "compile", "bundle", "package", "docs"]),
            (.infra, [
                "set up", "setup", "checkout", "install", "cache", "dependencies", "download", "docker", "runner",
            ]),
        ]
        for text in [step, job].compactMap({ $0?.lowercased() }) {
            if let kind = kinds.first(where: { $0.1.contains { text.contains($0) } })?.0 { return kind }
        }
        guard let log = log?.lowercased() else { return .other }
        let signs: [(CIHistory.Kind, [String])] = [
            (.lint, ["would reformat", "not formatted", "lint", "formatting", "style violation"]),
            (.test, ["--- fail", "tests failed", "test failed", "assertion", "expected"]),
            (.build, ["error: compil", "build failed", "cannot find", "undefined reference", "error[e"]),
            (.infra, ["no space left", "rate limit", "timed out", "connection reset", "could not resolve host"]),
        ]
        return signs.first { $0.1.contains { log.contains($0) } }?.0 ?? .other
    }
}
