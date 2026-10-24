import Foundation
@testable import HeedCore
import Testing

/// The setup wizard's reads, proposals, validation, readiness and config lines, over invented repos and PRs in the
/// shapes GitHub answers with.
struct RepoSetupTests {
    private let repo = Repo(org: "lumen", name: "tidepool")
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    private func data(_ text: String) -> Data { Data(text.utf8) }

    private func pull(
        _ number: Int, author: String = "ines", minutesBeforeMerge committed: Double = 30,
        reviews: [PullDetail.Review]? = nil, bots: Set<String> = [], labels: [String] = [], removed: [String] = [],
        passed: [String] = ["build"], failed: [String] = [], parents: Int? = 1, autoMerge: Bool = false
    ) -> SampledPull {
        let merged = now.addingTimeInterval(-Double(number) * 3600)
        let head = "head\(number)"
        return SampledPull(
            number: number, title: "PR \(number)", author: author, mergedBy: author,
            createdAt: merged.addingTimeInterval(-86400), mergedAt: merged, labels: labels, removedBeforeMerge: removed,
            parents: parents, autoMerge: autoMerge,
            reviews: reviews ?? [.init(author: "olek", state: "APPROVED", submittedAt: merged - 300, commit: head)],
            botReviewers: bots, headSHA: head, headCommittedAt: merged.addingTimeInterval(-committed * 60),
            passedChecks: passed, failedChecks: failed
        )
    }

    private func sample(
        _ pulls: [SampledPull], settings: RepoMergeSettings = RepoMergeSettings(), ci: CIHistory = CIHistory(),
        runs: [PilotRun] = [], tasks: [TaskSpec] = []
    ) -> RepoSetupSample {
        RepoSetupSample(repo: repo, settings: settings, pulls: pulls, ci: ci, runs: runs, tasks: tasks)
    }

    // MARK: Reading GitHub

    @Test func settingsComeFromGraphQLRestProtectionAndRulesets() throws {
        let graphql = """
        {"data":{"rateLimit":{"cost":1,"remaining":4990},"repository":{"autoMergeAllowed":true,
        "squashMergeAllowed":true,"mergeCommitAllowed":true,"rebaseMergeAllowed":true,"deleteBranchOnMerge":false,
        "viewerDefaultMergeMethod":"MERGE","viewerPermission":"READ",
        "defaultBranchRef":{"name":"trunk","branchProtectionRule":null},"mergeQueue":null,"codeowners":{"byteSize":40}}}}
        """
        let branch = """
        {"name":"trunk","protected":true,"protection":{"enabled":true,"required_status_checks":{
        "contexts":["unit (linux)","unit (mac)"],"enforcement_level":"non_admins"}}}
        """
        let rules = """
        [{"type":"deletion","parameters":null},
         {"type":"pull_request","parameters":{"allowed_merge_methods":["squash","merge"],
          "required_approving_review_count":2,"require_last_push_approval":true,"require_code_owner_review":false}},
         {"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"unit (mac)"},
          {"context":"lint"}],"strict_required_status_checks_policy":true}},
         {"type":"required_linear_history","parameters":null},
         {"type":"merge_queue","parameters":{"merge_method":"SQUASH"}},
         {"type":"copilot_code_review","parameters":{"review_on_push":false}}]
        """
        #expect(GitHub.parseDefaultBranch(data(graphql)) == "trunk")
        let settings = try #require(GitHub.parseRepoSettings(data(graphql), branch: data(branch), rules: data(rules)))
        #expect(settings.defaultBranch == "trunk")
        #expect(settings.repoMethods == ["squash", "merge", "rebase"])
        #expect(settings.rulesetMethods == ["squash", "merge"])
        // Linear history takes merge commits away too.
        #expect(settings.methods == ["squash"])
        #expect(settings.requiredChecks == ["unit (linux)", "unit (mac)", "lint"])
        #expect(settings.requiredApprovals == 2)
        #expect(settings.linearHistory && settings.strictChecks && settings.mergeQueue && settings.copilotReview)
        #expect(settings.lastPushApproval && !settings.codeOwnerReview)
        #expect(settings.autoMergeAllowed == true && settings.deleteBranchOnMerge == false)
        #expect(settings.isAdmin == false && settings.hasCodeowners)
    }

    @Test func anAdminSeesTheProtectionRuleItself() throws {
        let graphql = """
        {"data":{"repository":{"autoMergeAllowed":false,"squashMergeAllowed":null,"mergeCommitAllowed":null,
        "rebaseMergeAllowed":null,"viewerPermission":"ADMIN","defaultBranchRef":{"name":"main",
        "branchProtectionRule":{"requiredStatusCheckContexts":["build"],"requiredApprovingReviewCount":1,
        "requiresLinearHistory":false,"requiresStrictStatusChecks":true,"requireLastPushApproval":false,
        "requiresCodeOwnerReviews":true}},"mergeQueue":{"id":"MQ_1"},"codeowners":null}}}
        """
        let settings = try #require(GitHub.parseRepoSettings(data(graphql), branch: nil, rules: data("[]")))
        // Buttons GitHub would not tell: every method counts as allowed.
        #expect(settings.methods == ["squash", "merge", "rebase"])
        #expect(settings.requiredChecks == ["build"])
        #expect(settings.requiredApprovals == 1 && settings.strictChecks && settings.codeOwnerReview)
        #expect(settings.mergeQueue && settings.isAdmin == true && !settings.hasCodeowners)
        #expect(GitHub.parseRepoSettings(data("{\"data\":{\"repository\":null}}"), branch: nil, rules: nil) == nil)
    }

    @Test func mergedPullsKeepLabelsReviewsChecksAndHowTheyMerged() throws {
        let json = """
        {"data":{"repository":{"pullRequests":{"nodes":[{
          "number":77,"title":"Wave the flag","createdAt":"2030-01-01T10:00:00Z","mergedAt":"2030-01-02T10:00:00Z",
          "author":{"__typename":"User","login":"ines"},"mergedBy":{"login":"olek"},
          "labels":{"nodes":[{"name":"docs"},{"name":"released"}]},
          "mergeCommit":{"parents":{"totalCount":2}},
          "commits":{"totalCount":4,"nodes":[{"commit":{"oid":"abc123","committedDate":"2030-01-02T09:30:00Z",
            "statusCheckRollup":{"contexts":{"nodes":[
              {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2030-01-02T09:31:00Z"},
              {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2030-01-02T09:40:00Z"},
              {"__typename":"CheckRun","name":"draft","status":"COMPLETED","conclusion":"SKIPPED","startedAt":"2030-01-02T09:31:00Z"},
              {"__typename":"CheckRun","name":"e2e","status":"IN_PROGRESS","conclusion":null,"startedAt":"2030-01-02T09:31:00Z"},
              {"__typename":"StatusContext","context":"license/cla","state":"FAILURE"}]}}}}]},
          "timelineItems":{"nodes":[
            {"__typename":"LabeledEvent","createdAt":"2030-01-01T10:05:00Z","label":{"name":"wip"}},
            {"__typename":"LabeledEvent","createdAt":"2030-01-01T10:06:00Z","label":{"name":"docs"}},
            {"__typename":"UnlabeledEvent","createdAt":"2030-01-02T09:00:00Z","label":{"name":"wip"}},
            {"__typename":"AutoMergeEnabledEvent","createdAt":"2030-01-02T09:45:00Z"},
            {"__typename":"MergedEvent","createdAt":"2030-01-02T10:00:00Z"},
            {"__typename":"LabeledEvent","createdAt":"2030-01-03T10:00:00Z","label":{"name":"released"}}]},
          "reviews":{"nodes":[
            {"author":{"__typename":"Bot","login":"copilot-pull-request-reviewer"},"state":"COMMENTED",
             "submittedAt":"2030-01-02T09:35:00Z","commit":{"oid":"abc123"}},
            {"author":{"__typename":"User","login":"olek"},"state":"APPROVED","submittedAt":"2030-01-02T09:50:00Z",
             "commit":{"oid":"abc123"}},
            {"author":null,"state":"COMMENTED","submittedAt":"2030-01-02T09:51:00Z","commit":null}]},
          "reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"olek"},"path":"a.md"}]}}]}
        },{"number":78,"mergedAt":null}]}}}}
        """
        let pulls = GitHub.parseMergedPulls(data(json))
        #expect(pulls.count == 1)
        let pull = try #require(pulls.first)
        #expect(pull.number == 77 && pull.author == "ines" && !pull.authorIsBot && pull.mergedBy == "olek")
        #expect(pull.parents == 2 && pull.commits == 4 && pull.autoMerge && !pull.mergeQueue)
        #expect(pull.removedBeforeMerge == ["wip"])
        #expect(pull.labelsSeen == ["wip", "docs", "released"])
        // The newest run of a check counts; skipped passes; still running is pending.
        #expect(pull.passedChecks == ["build", "draft"])
        #expect(pull.failedChecks == ["license/cla"])
        #expect(pull.pendingChecks == ["e2e"])
        #expect(pull.reviews.map(\.author) == ["copilot-pull-request-reviewer", "olek"])
        #expect(pull.botReviewers == ["copilot-pull-request-reviewer"])
        #expect(pull.humanApproved)
        #expect(pull.threads.map(\.isResolved) == [false] && pull.threads.first?.author == "olek")
        #expect(pull.headSHA == "abc123")
        #expect(pull.lastActivity == GitHub.date("2030-01-02T09:50:00Z"))
    }

    @Test func botsAreAppsBotLoginsAndCopilot() {
        #expect(GitHub.isBot(["__typename": "Bot", "login": "renovate"]))
        #expect(GitHub.isBot(["__typename": "User", "login": "deps[bot]"]))
        #expect(GitHub.isBot(["__typename": "User", "login": "Copilot"]))
        #expect(!GitHub.isBot(["__typename": "User", "login": "ines"]))
        #expect(!GitHub.isBot(nil))
    }

    @Test func flakyWorkflowsPassedOnALaterAttempt() {
        let json = """
        {"total_count":5,"workflow_runs":[
          {"id":1,"name":"Tests","run_attempt":2,"conclusion":"success"},
          {"id":2,"name":"Tests","run_attempt":1,"conclusion":"success"},
          {"id":3,"name":"Tests","run_attempt":3,"conclusion":"success"},
          {"id":4,"name":"Lint","run_attempt":2,"conclusion":"failure"},
          {"id":5,"name":"Lint","run_attempt":1,"conclusion":"success"}]}
        """
        let runs = GitHub.parseWorkflowRuns(data(json))
        #expect(runs.count == 5)
        #expect(GitHub.flaky(runs) == [CIHistory.Flaky(workflow: "Tests", retried: 2, runs: 3)])
    }

    @Test func failedJobsNameTheirFirstFailedStep() {
        let json = """
        {"total_count":2,"jobs":[
          {"id":11,"name":"lint","conclusion":"failure","steps":[{"name":"Set up job","conclusion":"success"},
            {"name":"Check formatting","conclusion":"failure"},{"name":"Post","conclusion":"failure"}]},
          {"id":12,"name":"unit","conclusion":"success","steps":[]},
          {"id":13,"name":"e2e","conclusion":"failure"}]}
        """
        let jobs = GitHub.parseFailedJobs(data(json))
        #expect(jobs.map(\.id) == [11, 13])
        #expect(jobs.map(\.step) == ["Check formatting", nil])
    }

    @Test func failuresAreClassifiedByStepThenJobThenLog() {
        #expect(GitHub.classifyFailure(job: "ci", step: "Run swiftformat --lint", log: nil) == .lint)
        #expect(GitHub.classifyFailure(job: "unit tests", step: "Run it", log: nil) == .test)
        #expect(GitHub.classifyFailure(job: "release", step: "Compile", log: nil) == .build)
        #expect(GitHub.classifyFailure(job: "ci", step: "Set up Go", log: nil) == .infra)
        // The step decides before the job.
        #expect(GitHub.classifyFailure(job: "test", step: "Check formatting", log: nil) == .lint)
        #expect(GitHub.classifyFailure(job: "ci", step: "Run", log: nil) == .other)
        #expect(GitHub.classifyFailure(job: "ci", step: "Run", log: "2 files would reformat") == .lint)
        #expect(GitHub.classifyFailure(job: "ci", step: "Run", log: "--- FAIL: TestWave") == .test)
        #expect(GitHub.classifyFailure(job: "ci", step: "Run", log: "No space left on device") == .infra)
        #expect(GitHub.classifyFailure(job: "ci", step: "Run", log: "all good") == .other)
    }

    // MARK: Proposing: get it merged

    @Test func modeFollowsTheQueueAutoMergeUseAndWhatTheRepoAllows() {
        #expect(RepoSetupProposal.mergeMode(sample([])).value == .off)
        var queue = RepoMergeSettings()
        queue.mergeQueue = true
        #expect(RepoSetupProposal.mergeMode(sample([pull(1)], settings: queue)).value == .auto)
        var allowed = RepoMergeSettings()
        allowed.autoMergeAllowed = true
        let automatic = [pull(1, autoMerge: true), pull(2), pull(3)]
        let auto = RepoSetupProposal.mergeMode(sample(automatic, settings: allowed))
        #expect(auto.value == .auto)
        #expect(auto.why == "Auto-merge was turned on for 1 of 3 merged PRs.")
        let rarely = RepoSetupProposal.mergeMode(sample(automatic + [pull(4)], settings: allowed))
        #expect(rarely.value == .heed)
        #expect(rarely.why.contains("used on 1 of 4"))
        var refused = RepoMergeSettings()
        refused.autoMergeAllowed = false
        let heed = RepoSetupProposal.mergeMode(sample(automatic, settings: refused))
        #expect(heed.value == .heed)
        #expect(heed
            .why == "The repo does not allow auto-merge, so heed merges by its rules; a person approved 3 of 3.")
    }

    @Test func methodFollowsTheRepoThenWhatMergedPRsUsed() {
        var only = RepoMergeSettings()
        only.repoMethods = ["rebase"]
        #expect(RepoSetupProposal.mergeMethod(sample([pull(1)], settings: only))
            == .init("rebase", "The repo only allows rebase."))
        let commits = [pull(1, parents: 2), pull(2, parents: 2), pull(3, parents: 1)]
        #expect(RepoSetupProposal.mergeMethod(sample(commits))
            == .init("merge", "2 of 3 merged PRs were merge commits."))
        let squashed = [pull(1, parents: 1), pull(2, parents: 1), pull(3, parents: 2)]
        #expect(RepoSetupProposal.mergeMethod(sample(squashed))
            == .init("squash", "2 of 3 merged PRs landed without a merge commit."))
        var none = RepoMergeSettings()
        none.repoMethods = []
        #expect(RepoSetupProposal.mergeMethod(sample([pull(1)], settings: none)).value == "squash")
    }

    @Test func botsThatReviewOftenAreProposedAsTrusted() {
        let bot = "review-owl[bot]"
        let botReview = { (number: Int) in
            [PullDetail.Review(author: bot, state: number == 1 ? "APPROVED" : "COMMENTED", commit: "head\(number)")]
        }
        var pulls = (1 ... 3).map { pull($0, reviews: botReview($0), bots: [bot]) }
        pulls += (4 ... 10).map { pull($0) }
        pulls.append(pull(11, reviews: [.init(author: "rare[bot]", state: "COMMENTED")], bots: ["rare[bot]"]))
        let items = RepoSetupProposal.trustedReviewers(sample(pulls), current: ["kept-bot"])
        #expect(items.map(\.name) == ["kept-bot", bot])
        #expect(items[1].why == "Reviewed 3 of 11, approved 1.")
        var copilot = RepoMergeSettings()
        copilot.copilotReview = true
        let withRule = RepoSetupProposal.trustedReviewers(sample([pull(1)], settings: copilot), current: [])
        #expect(withRule.map(\.name) == ["copilot-pull-request-reviewer"])
    }

    @Test func gateChecksOnlyWithRequiredChecksAndOnlyThoseThatAlwaysPassed() {
        let pulls = (1 ... 10).map { number in
            pull(
                number,
                passed: ["build"] + (number <= 9 ? ["preview"] : []) + (number <= 8 ? ["docs"] : [])
                    + ["spell"],
                failed: number == 1 ? ["flaky-e2e"] : []
            )
        }
        #expect(RepoSetupProposal.gateChecks(sample(pulls), current: []).isEmpty)
        var required = RepoMergeSettings()
        required.requiredChecks = ["build"]
        let items = RepoSetupProposal.gateChecks(sample(pulls, settings: required), current: [])
        #expect(items.map(\.name) == ["spell", "preview", "docs"])
        // Ran on nine in ten or more: on; fewer: offered, off.
        #expect(items.map(\.on) == [true, true, false])
        #expect(items[0].why == "Passed on 10 of 10, never failed at merge; not required.")
        // A gate set now that never passed would hold every PR.
        let kept = RepoSetupProposal.gateChecks(sample(pulls), current: ["spell", "integration"])
        #expect(kept.map(\.on) == [true, false])
        #expect(kept[1].why == "A gate check now; passed on none of 10: it would hold every PR.")
    }

    @Test func holdLabelsDropWhatMergedPRsCarriedAndAddWhatWasTakenOff() {
        let pulls = [
            pull(1, labels: ["wip"]),
            pull(2, removed: ["do-not-merge"]),
            pull(3, removed: ["needs-design"]),
            pull(4, removed: ["needs-design"]),
            pull(5, removed: ["typo"]),
            pull(6, labels: ["blocked-upstream"]),
        ]
        let items = RepoSetupProposal.holdLabels(sample(pulls), current: ["hold", "wip"])
        #expect(items.map(\.name) == ["hold", "wip", "do-not-merge", "needs-design"])
        #expect(items.map(\.on) == [true, false, true, false])
        #expect(items[1].why == "On 1 merged PRs: it holds nothing here.")
        #expect(items[2].why == "Taken off before merging on 1 PRs.")
        #expect(items[3].why == "Taken off before merging on 2 PRs.")
    }

    @Test func quietMinutesFollowTheQuickestQuarterOfMerges() {
        // Last activity is the approval five minutes before the merge, or the commit when later.
        let quick = (1 ... 8).map { pull($0, minutesBeforeMerge: Double($0) * 10, reviews: []) }
        #expect(RepoSetupProposal.quietMinutes(sample(quick)).value == 30)
        let fast = (1 ... 4).map { pull($0, minutesBeforeMerge: 2, reviews: []) }
        let proposed = RepoSetupProposal.quietMinutes(sample(fast))
        #expect(proposed.value == 5)
        #expect(proposed.why == "A quarter of the merges came 2m after the last push or review.")
        let mid = (1 ... 4).map { pull($0, minutesBeforeMerge: 12, reviews: []) }
        #expect(RepoSetupProposal.quietMinutes(sample(mid)).value == 10)
        #expect(RepoSetupProposal.quietMinutes(sample([])).value == 5)
    }

    @Test func forceMergeIsOfferedToAdminsOnly() {
        var reader = RepoMergeSettings()
        reader.viewerPermission = "WRITE"
        reader.requiredApprovals = 1
        #expect(RepoSetupProposal.forceMerge(sample([pull(1, reviews: [])], settings: reader)) == nil)
        var admin = reader
        admin.viewerPermission = "ADMIN"
        let bypassed = RepoSetupProposal.forceMerge(sample([pull(1, reviews: []), pull(2)], settings: admin))
        #expect(bypassed == .init(.ask, "1 of 2 merged without the 1 required approval: an admin bypass."))
        #expect(RepoSetupProposal.forceMerge(sample([pull(1)], settings: admin))?.value == .off)
        admin.requiredApprovals = 0
        #expect(RepoSetupProposal.forceMerge(sample([pull(1, reviews: [])], settings: admin))?.value == .off)
    }

    @Test func mergeNowAsksUnlessGitHubDecides() {
        #expect(RepoSetupProposal.mergeNow(.auto).value == .auto)
        #expect(RepoSetupProposal.mergeNow(.heed).value == .ask)
    }

    // MARK: Proposing: get it green

    private func run(_ agent: String, _ model: String?, _ outcome: PilotRun.Outcome?, goal: RunGoal = .green)
        -> PilotRun
    {
        var run = PilotRun(
            ref: PullRef(repo: repo, number: 1), sessionID: "s", goal: goal, agent: agent, model: model,
            startedAt: now, items: 1, prBranch: "b", branch: "heed/b", worktree: "/tmp/b", startSHA: nil
        )
        run.outcome = outcome
        return run
    }

    @Test func greenGoesAutoOnceRunsPushMoreOftenThanNot() {
        #expect(RepoSetupProposal.green([]).value == .ask)
        let good = [
            run("claude", "haiku", .pushed(1)),
            run("claude", "haiku", .pushed(2)),
            run("codex", nil, .noChanges),
        ]
        #expect(RepoSetupProposal.green(good) == .init(.auto, "Runs pushed a fix on 2 of 3."))
        // Runs you stopped, that heed's quit interrupted, still running or for get it merged do not count.
        let noise = [
            run("claude", nil, .stopped),
            run("claude", nil, .interrupted),
            run("claude", nil, nil),
            run("claude", nil, .pushed(1), goal: .merged),
        ]
        #expect(RepoSetupProposal.green(good + noise).why == "Runs pushed a fix on 2 of 3.")
        let bad = [run("claude", nil, .pushed(1)), run("claude", nil, .timedOut), run("claude", nil, .failed("x"))]
        #expect(RepoSetupProposal.green(bad).value == .ask)
        #expect(RepoSetupProposal.maxRounds(bad) == .init(2, "2 of 3 runs changed nothing or failed: stop sooner."))
        #expect(RepoSetupProposal.maxRounds(good).value == 3)
    }

    @Test func theAgentWhoseRunsPushedMostIsProposed() throws {
        let runs = [
            run("claude", "haiku", .pushed(1)), run("claude", "haiku", .pushed(1)), run("claude", "haiku", .noChanges),
            run("codex", "gpt-5-codex", .pushed(1)), run("codex", "gpt-5-codex", .pushed(1)),
            run("pi", nil, .pushed(1)),
        ]
        let pick = try #require(RepoSetupProposal.agent(runs))
        #expect(pick.agent == "codex" && pick.model == "gpt-5-codex")
        #expect(pick.why == "codex gpt-5-codex pushed a fix on 2 of 2 runs.")
        #expect(RepoSetupProposal.agent([run("pi", nil, .pushed(1))]) == nil)
    }

    @Test func lintFailuresBecomeAnInstructionNamingTheRepoTasks() {
        let lint = CIHistory(failures: [
            .init(workflow: "CI", job: "lint", kind: .lint), .init(workflow: "CI", job: "lint", kind: .lint),
            .init(workflow: "CI", job: "unit", kind: .test),
        ])
        #expect(RepoSetupProposal.instructions(sample([], ci: CIHistory(failures: [
            .init(workflow: "CI", job: "unit", kind: .test),
        ]))) == nil)
        let tasks = [
            TaskSpec(name: "test", command: "make test"),
            TaskSpec(name: "lint", command: "make lint"),
            TaskSpec(name: "format", command: "make format"),
        ]
        let hint = RepoSetupProposal.instructions(sample([], ci: lint, tasks: tasks))
        #expect(hint == .init(
            "Before you push, run `make lint` and `make format` and fix what they report.",
            "2 of 3 failed CI jobs were lint or format."
        ))
        #expect(RepoSetupProposal.instructions(sample([], ci: lint))?.value
            == "Before you push, run the repo's linter and formatter and fix what they report.")
    }

    @Test func notesListFailuresAndFlakyWorkflows() {
        let ci = CIHistory(
            runs: 80, flaky: [.init(workflow: "Tests", retried: 1, runs: 40)],
            failures: [.init(workflow: "CI", job: "lint", kind: .lint), .init(workflow: "CI", job: "x", kind: .infra)]
        )
        #expect(RepoSetupProposal.notes(sample([], ci: ci)) == [
            "CI failures: 1 lint or format, 1 setup or infrastructure (of 2 failed jobs on PRs).",
            "Flaky: Tests passed on a re-run 1 time in 40 PR runs.",
            "Re-running a flaky check instead of sending it to the agent comes later; for now it is sent.",
        ])
        #expect(RepoSetupProposal.notes(sample([])).isEmpty)
    }

    @Test func fieldsAreTickedWhereTheyChangeSomething() throws {
        var settings = RepoMergeSettings()
        settings.autoMergeAllowed = false
        settings.repoMethods = ["squash"]
        var current = PilotSettings()
        current.quietMinutes = 5
        let fields = RepoSetupProposal.fields(
            sample([pull(1), pull(2)], settings: settings), current: current,
            agents: ["claude", "codex"]
        )
        let byKey = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0) })
        #expect(fields.map(\.id) == [
            "merge", "merge_method", "trusted_reviewers", "gate_checks", "hold_labels", "quiet_minutes", "merge_now",
            "green", "max_rounds", "agent", "model",
        ])
        let mode = try #require(byKey["merge"])
        #expect(mode.value == "heed" && mode.include && mode.current == "off")
        #expect(byKey["merge_method"]?.value == "squash" && byKey["merge_method"]?.include == true)
        // What is already so is shown, not written.
        #expect(byKey["merge_now"]?.include == false)
        #expect(byKey["max_rounds"]?.include == false)
        #expect(byKey["green"]?.include == false)
        #expect(byKey["agent"]?.choices == ["", "claude", "codex"])
        #expect(byKey["quiet_minutes"]?.choices == ["0", "5", "10", "15", "30", "60"])
    }

    @Test func fieldsCycleAndWriteTheirValues() {
        var field = SetupField(
            "max_rounds",
            .green,
            label: "",
            kind: .integer,
            choices: ["1", "3"],
            value: "2",
            why: "",
            current: "2"
        )
        #expect(field.choices == ["1", "2", "3"] && field.value == "2" && !field.include)
        field.cycle(by: 1)
        #expect(field.value == "3" && field.include && field.toml == .integer(3))
        field.cycle(by: 2)
        #expect(field.value == "2")
        var list = SetupField(
            "hold_labels",
            .merged,
            label: "",
            kind: .list,
            items: [.init("hold", why: ""), .init("wip", why: "", on: false)],
            why: "",
            current: "hold"
        )
        #expect(!list.include && list.display == "hold")
        list.cycle(by: 1)
        #expect(!list.include)
        #expect(list.toml == .array([.string("hold")]))
    }

    // MARK: Validating

    @Test func replayHoldsWhatHeedsRulesWouldHaveHeld() {
        var rules = PilotSettings()
        rules.merge = .heed
        rules.holdLabels = ["wip"]
        let pulls = [
            pull(1),
            pull(2, reviews: []),
            pull(3, labels: ["wip"]),
            pull(4, labels: ["wip"], removed: ["wip"]),
            pull(5, reviews: [.init(author: "olek", state: "APPROVED", commit: "older")]),
        ]
        let validation = RepoSetupValidation.validate(sample(pulls), settings: rules)
        #expect(validation.replayed == 5)
        #expect(validation.held.map(\.number) == [2, 3, 5])
        #expect(validation.held[1].reasons == ["a hold label (wip)"])
        #expect(validation.summary == "3 of 5 would be held: 2 no review of the last push, 1 a hold label.")
    }

    @Test func replayWaitsOutTheQuietWindowAndCountsTrustedReviewers() {
        var rules = PilotSettings()
        rules.merge = .heed
        rules.quietMinutes = 60
        let bot = "review-owl[bot]"
        // A comment review: only a trusted reviewer's counts.
        let botOnly = pull(1, reviews: [.init(author: bot, state: "COMMENTED", commit: "head1")], bots: [bot])
        // Merged a minute after its last commit: heed would have merged an hour later, not held it.
        let quick = pull(2, minutesBeforeMerge: 1, reviews: [.init(author: "olek", state: "APPROVED", commit: "head2")])
        #expect(RepoSetupValidation.validate(sample([botOnly, quick]), settings: rules).held.map(\.number) == [1])
        rules.trustedReviewers = [bot]
        let trusted = RepoSetupValidation.validate(sample([botOnly, quick]), settings: rules)
        #expect(trusted.held.isEmpty)
        #expect(trusted.summary == "All 2 merged PRs would have merged under these rules.")
    }

    @Test func replayHoldsOnFailedChecksOpenThreadsAndGates() {
        var rules = PilotSettings()
        rules.merge = .heed
        rules.gateChecks = ["preview"]
        var open = pull(2, passed: ["build", "preview"])
        open.threads = [ReviewThread(
            id: "t", isResolved: false, path: "", line: nil, author: "olek", body: "", diff: [], replies: 0, url: nil
        )]
        let pulls = [pull(1, passed: ["preview"], failed: ["build"]), open, pull(3)]
        let held = RepoSetupValidation.validate(sample(pulls), settings: rules).held
        #expect(held.map(\.number) == [1, 2, 3])
        #expect(held[0].reasons == ["checks failed"])
        #expect(held[1].reasons == ["review threads open"])
        #expect(held[2].reasons == ["gate checks not passed"])
    }

    @Test func otherModesAreNotReplayed() {
        var rules = PilotSettings()
        rules.merge = .auto
        let auto = RepoSetupValidation.validate(sample([pull(1, reviews: [])]), settings: rules)
        #expect(auto.replayed == 0 && auto.held.isEmpty)
        rules.merge = .off
        #expect(RepoSetupValidation.validate(sample([pull(1)]), settings: rules).summary
            == "Merging stays off: nothing to replay.")
    }

    @Test func checksSayWhatToChangeInGitHub() {
        var github = RepoMergeSettings()
        github.repoMethods = ["squash"]
        github.autoMergeAllowed = false
        var settings = PilotSettings()
        settings.merge = .auto
        settings.mergeMethod = "rebase"
        let checks = RepoSetupValidation.checks(github, repo: repo, settings: settings)
        #expect(checks.map(\.level) == [.fail, .fail])
        #expect(checks[0].text.hasPrefix("The repo does not allow rebase merges (allowed: squash)"))
        #expect(checks[0].url == "https://github.com/lumen/tidepool/settings")
        #expect(checks[1].text.contains("Allow auto-merge"))

        github.linearHistory = true
        github.repoMethods = ["merge", "squash"]
        github.autoMergeAllowed = true
        settings.mergeMethod = "merge"
        let linear = RepoSetupValidation.checks(github, repo: repo, settings: settings)
        #expect(linear.first?.level == .fail)
        #expect(linear.first?.url == "https://github.com/lumen/tidepool/settings/rules")
        #expect(linear.last?.text == "Auto-merge is allowed.")
    }

    @Test func checksWarnAboutQueuesApprovalsUpToDateAndAdminRights() {
        var github = RepoMergeSettings()
        github.mergeQueue = true
        github.requiredApprovals = 1
        github.strictChecks = true
        github.viewerPermission = "WRITE"
        var settings = PilotSettings()
        settings.merge = .heed
        settings.trustedReviewers = ["review-owl[bot]"]
        settings.updateBranches = false
        let checks = RepoSetupValidation.checks(github, repo: repo, settings: settings, forceMerge: .ask)
        #expect(checks.map(\.level) == [.ok, .warn, .warn, .warn, .fail])
        #expect(checks[1].text.contains("merge queue"))
        #expect(checks[2].text.contains("only an admin can bypass it"))
        #expect(checks[3].text.contains("update_branches"))
        #expect(checks[4].text == "force_merge needs admin rights on lumen/tidepool; you have write rights.")
        github.viewerPermission = "ADMIN"
        settings.updateBranches = true
        settings.trustedReviewers = []
        let admin = RepoSetupValidation.checks(github, repo: repo, settings: settings, forceMerge: .ask)
        #expect(admin.map(\.level) == [.ok, .warn, .ok, .ok, .ok])
        settings.adminMerge = true
        github.viewerPermission = "READ"
        #expect(RepoSetupValidation.checks(github, repo: repo, settings: settings).last?.text
            == "admin_merge is on but you are not an admin of lumen/tidepool.")
    }

    // MARK: Readiness

    @Test func statusSaysNotSetUpOffOkOrWhatIsWrong() {
        var rules = PilotRules()
        func status(_ readiness: RepoMergeReadiness? = nil) -> RepoSetupStatus {
            RepoSetupStatus.of(
                repo, rules: rules, readiness: readiness ?? RepoMergeReadiness.of(rules.resolve(repo), facts: nil)
            )
        }
        #expect(status().merging == .init(state: .notSetUp, text: "merging: not set up"))
        #expect(status().green == .init(state: .notSetUp, text: "green: not set up (ask)"))
        // Off for the whole org is decided too.
        rules.orgs[repo.org] = PilotOverrides(merge: .off)
        #expect(status().merging == .init(state: .off, text: "merging: off"))
        rules.orgs[repo.org] = nil
        rules.repos[repo.slug] = PilotOverrides(green: .auto, merge: .off)
        #expect(status().merging.state == .off)
        #expect(status().green == .init(state: .ok, text: "green: auto · 3 rounds"))
        rules.repos[repo.slug]?.merge = .heed
        rules.repos[repo.slug]?.mergeMethod = "rebase"
        rules.repos[repo.slug]?.agent = "claude"
        rules.repos[repo.slug]?.model = "haiku"
        #expect(status().merging == .init(state: .off, text: "merging: heed · not checked yet"))
        var github = RepoMergeSettings()
        github.repoMethods = ["rebase"]
        let ok = status(RepoMergeReadiness.of(rules.resolve(repo), facts: github.facts))
        #expect(ok.merging == .init(state: .ok, text: "merging: ok · heed · rebase"))
        #expect(ok.green.text == "green: auto · 3 rounds · claude haiku")
        github.repoMethods = ["squash"]
        let warn = status(RepoMergeReadiness.of(rules.resolve(repo), facts: github.facts))
        #expect(warn.merging.state == .warning)
        #expect(warn.merging.text.hasPrefix("merging: ⚠ the repo does not allow rebase merges"))
        rules.orgs[repo.org] = PilotOverrides(watch: false)
        #expect(status().green.state == .warning)
        rules.repos[repo.slug]?.green = .off
        #expect(status().green == .init(state: .off, text: "green: off"))
    }

    @Test func sampledSettingsGiveThePilotItsFacts() {
        var github = RepoMergeSettings(
            repoMethods: ["merge", "squash"],
            autoMergeAllowed: true,
            viewerPermission: "ADMIN"
        )
        github.linearHistory = true
        #expect(github.facts == RepoMergeFacts(
            allowsAutoMerge: true, methods: ["squash"], linearHistory: true, viewerPermission: "ADMIN"
        ))
    }

    // MARK: Config lines

    @Test func previewShowsTheExactLinesAndApplyKeepsTheRestOfTheFile() throws {
        let edits = [
            RepoSetupConfig.Edit("merge", .string("heed")),
            RepoSetupConfig.Edit("quiet_minutes", .integer(10)),
            RepoSetupConfig.Edit("trusted_reviewers", .array([.string("review-owl[bot]")])),
            RepoSetupConfig.Edit("green_instructions", .string("Run `make lint`.\nThen push.")),
        ]
        #expect(RepoSetupConfig.preview(repo, edits) == [
            "[repos.\"lumen/tidepool\"]",
            "merge = \"heed\"",
            "quiet_minutes = 10",
            "trusted_reviewers = [\"review-owl[bot]\"]",
            "green_instructions = \"Run `make lint`.\\nThen push.\"",
        ])
        #expect(RepoSetupConfig.preview(repo, []).isEmpty)
        let source = """
        # my heed config
        [pilot]
        merge = "off"   # nothing merges by default

        [repos."lumen/tidepool"]
        color = "teal"
        quiet_minutes = 5 # was five

        [repos."lumen/other"]
        merge = "auto"
        """
        let written = try RepoSetupConfig.apply(edits, repo: repo, to: source)
        #expect(written.hasPrefix("# my heed config\n[pilot]\nmerge = \"off\"   # nothing merges by default\n"))
        #expect(written.contains("quiet_minutes = 10 # was five"))
        #expect(written.contains("color = \"teal\""))
        #expect(written.contains("[repos.\"lumen/other\"]\nmerge = \"auto\""))
        let config = try #require(ConfigLoader.decode(written).config)
        let overrides = try #require(config.pilot.repos[repo.slug])
        #expect(overrides.merge == .heed && overrides.quietMinutes == 10)
        #expect(overrides.trustedReviewers == ["review-owl[bot]"])
        #expect(overrides.greenInstructions == "Run `make lint`.\nThen push.")
        #expect(config.pilot.defaults.merge == .off && config.pilot.repos["lumen/other"]?.merge == .auto)
        // A repo with no table yet gets one.
        let fresh = try RepoSetupConfig.apply([edits[0]], repo: repo, to: "[pilot]\nwatch = true\n")
        #expect(fresh == "[pilot]\nwatch = true\n\n[repos.\"lumen/tidepool\"]\nmerge = \"heed\"\n")
    }

    @Test func appliedFieldsChangeOnlyWhatIsTicked() throws {
        var fields = RepoSetupProposal.fields(
            RepoSetupFixtures.sample(for: repo, now: now), current: PilotSettings(), agents: ["claude"]
        )
        let applied = RepoSetupConfig.applied(fields, to: PilotSettings())
        #expect(applied.merge == .heed && applied.mergeMethod == "squash")
        #expect(applied.trustedReviewers == ["copilot-pull-request-reviewer"])
        // merge_now and force_merge land in the settings too once ticked.
        let force = try #require(fields.firstIndex { $0.id == "force_merge" })
        let now = try #require(fields.firstIndex { $0.id == "merge_now" })
        fields[force].cycle(by: -1)
        fields[now].cycle(by: 1)
        let forced = RepoSetupConfig.applied(fields, to: PilotSettings())
        #expect(forced.forceMerge == .off && forced.mergeNow == .auto)
        for index in fields.indices {
            fields[index].include = false
        }
        #expect(RepoSetupConfig.applied(fields, to: PilotSettings()) == PilotSettings())
    }

    // MARK: The wizard

    @Test func theWizardWalksSampleProposeValidateWrite() throws {
        var wizard = RepoSetupWizard(repo: repo, current: PilotSettings(), agents: ["claude"])
        // Nothing to go on before the sample arrives.
        #expect(wizard.handle(KeyStroke("CR")) == .handled && wizard.step == .sample)
        wizard.began(.settings)
        #expect(wizard.progress[.settings] == .running)
        wizard.finished(.settings)
        #expect(wizard.progress[.settings] == .done)
        wizard.go(to: .write)
        #expect(wizard.step == .sample)
        wizard.sampled(RepoSetupFixtures.sample(for: repo, now: now))
        #expect(GitHub.SampleStep.allCases.allSatisfy { wizard.progress[$0] == .done })
        _ = wizard.handle(KeyStroke("CR"))
        #expect(wizard.step == .propose && wizard.cursor == 0)
        #expect(wizard.rows.first == .field(0))
        // ← → change the mode; space leaves it out.
        _ = wizard.handle(KeyStroke("l"))
        #expect(wizard.fields[0].value == "off")
        _ = wizard.handle(KeyStroke("h"))
        #expect(wizard.fields[0].value == "heed")
        _ = wizard.handle(KeyStroke("Space"))
        #expect(!wizard.fields[0].include)
        _ = wizard.handle(KeyStroke("Space"))
        // Down to the first trusted reviewer, and off.
        let reviewerRow = try #require(wizard.rows.firstIndex(of: .item(2, 0)))
        for _ in 0 ..< reviewerRow {
            _ = wizard.handle(KeyStroke("j"))
        }
        _ = wizard.handle(KeyStroke("Space"))
        #expect(wizard.fields[2].items[0].on == false)
        _ = wizard.handle(KeyStroke("k"))
        #expect(wizard.cursor == reviewerRow - 1)
        _ = wizard.handle(KeyStroke("Tab"))
        #expect(wizard.step == .validate)
        let validation = try #require(wizard.validation)
        #expect(validation.replayed == 30)
        #expect(validation.summary
            == "5 of 30 would be held: 4 no review of the last push, 1 gate checks not passed.")
        _ = wizard.handle(KeyStroke("BS"))
        #expect(wizard.step == .propose)
        _ = wizard.handle(KeyStroke("CR"))
        _ = wizard.handle(KeyStroke("CR"))
        #expect(wizard.step == .write)
        #expect(wizard.preview.first == "[repos.\"lumen/tidepool\"]")
        #expect(wizard.preview.contains("merge = \"heed\""))
        #expect(wizard.preview.contains("trusted_reviewers = []"))
        guard case let .write(edits) = wizard.handle(KeyStroke("CR")) else {
            Issue.record("↩ on the last step writes")
            return
        }
        #expect(edits == wizard.edits && !edits.isEmpty)
        #expect(wizard.handle(.escape) == .close)
    }

    @Test func theValidationStepOpensTheSettingToChange() {
        var wizard = RepoSetupWizard(repo: repo, current: PilotSettings())
        var sample = RepoSetupFixtures.sample(for: repo, now: now)
        sample.settings.autoMergeAllowed = false
        wizard.sampled(sample)
        wizard.choose(field: 0, choice: MergeMode.allCases.firstIndex(of: .auto)!)
        wizard.go(to: .validate)
        #expect(wizard.fixes.map(\.url) == ["https://github.com/lumen/tidepool/settings"])
        #expect(wizard.handle(KeyStroke("o")) == .open("https://github.com/lumen/tidepool/settings"))
        wizard.move(by: 5)
        #expect(wizard.cursor == 0)
        wizard.choose(field: 99, choice: 0)
        wizard.toggle(row: 999)
        wizard.failed("gh is not signed in")
        #expect(wizard.failure == "gh is not signed in")
    }

    @Test func theFixtureSampleProposesFromItsInventedHistory() throws {
        let sample = RepoSetupFixtures.sample(for: repo, now: now)
        let fields = RepoSetupProposal.fields(sample, current: PilotSettings(), agents: ["claude"])
        let keys = fields.map(\.id)
        // An admin of the fixture repo is offered force_merge; lint failures bring instructions.
        #expect(keys.contains("force_merge") && keys.contains("green_instructions"))
        let instructions = try #require(fields.first { $0.id == "green_instructions" })
        #expect(instructions
            .value == "Before you push, run `mise run lint` and `mise run fmt` and fix what they report.")
        let holds = try #require(fields.first { $0.id == "hold_labels" })
        #expect(holds.items.map(\.name) == ["hold", "do-not-merge", "wip", "needs-design"])
    }
}
