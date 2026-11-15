import Foundation
@testable import HeedCore
import Testing

struct HeedMergeTests {
    private let ref = PullRef(repo: Repo(org: "globex", name: "heed"), number: 7)
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private let head = "abc1234def"

    /// Green, approved by a human on the head commit an hour ago.
    private func detail(
        reviews: [PullDetail.Review]? = nil, committed: TimeInterval = -3600, passed: [String] = ["build"],
        labels: [String] = [], threads: [ReviewThread] = [], state: String = "CLEAN", autoMerge: Bool = false,
        authorTrust: ExternalText.Trust = .owner, app: String? = "github-actions"
    ) -> PullDetail {
        var detail = PullDetail(
            ref: ref, title: "t", body: "b", author: "me", baseBranch: "main", headBranch: "b", additions: 1,
            deletions: 1, commitCount: 1, headSHA: head,
            reviews: reviews ?? [approval("alice")],
            threads: threads, failingChecks: [], checks: CheckSummary(passed: passed.count), closes: [], fetchedAt: now,
            authorTrust: authorTrust
        )
        detail.state = "OPEN"
        detail.isDraft = false
        detail.mergeable = "MERGEABLE"
        detail.mergeState = state
        detail.requiredChecks = []
        detail.labels = labels
        detail.headCommittedAt = now + committed
        detail.passedChecks = passed
        detail.passedRuns = passed.map { PullDetail.CheckOrigin(name: $0, app: app) }
        detail.baseChecks = []
        detail.repoMergeMethods = ["squash"]
        detail.autoMergeEnabled = autoMerge
        return detail
    }

    /// An approval of the head commit an hour ago, by a collaborator unless said.
    private func approval(
        _ author: String, trust: ExternalText.Trust = .collaborator, commit: String? = nil
    ) -> PullDetail.Review {
        .init(author: author, state: "APPROVED", submittedAt: now - 3600, commit: commit ?? head, trust: trust)
    }

    private func blocker(_ detail: PullDetail, _ settings: PilotSettings = PilotSettings(), review: SelfReview? = nil)
        -> String?
    {
        HeedMerge.verdict(detail, settings: settings, selfReview: review, now: now).blocker.map(\.name)
    }

    private func action(_ detail: PullDetail, _ settings: PilotSettings = PilotSettings(), review: SelfReview? = nil)
        -> MergeQueue.Action
    {
        MergeQueue.action(for: MergeQueue.Entry(
            ref: ref, detail: detail, settings: settings, paused: false, mode: .heed, selfReview: review, now: now
        ))
    }

    @Test func mergesWhenEveryRuleHolds() {
        #expect(blocker(detail()) == nil)
        #expect(action(detail()) == .merge(method: "squash", admin: false))
        var admin = PilotSettings()
        admin.adminMerge = true
        #expect(action(detail(), admin) == .merge(method: "squash", admin: true))
    }

    @Test func anApprovalBeforeTheLastPushDoesNotCount() {
        let old = detail(reviews: [approval("alice", commit: "old")])
        #expect(blocker(old) == "Reviewed after push")
        #expect(action(old) ==
            .hold("Reviewed after push: approved before the last push; waiting for a review of abc1234"))
    }

    @Test func trustedAIReviews() {
        var settings = PilotSettings()
        settings.trustedReviewers = ["copilot-pull-request-reviewer"]
        let bot = "copilot-pull-request-reviewer"
        // A comment review with none of its threads open counts.
        let commented = detail(reviews: [.init(
            author: bot, state: "COMMENTED", submittedAt: now - 3600, commit: head, trust: .bot
        )])
        #expect(blocker(commented, settings) == nil)
        let open = ReviewThread(
            id: "T", isResolved: false, path: "f", line: 1, author: bot, body: "x", diff: [], replies: 0, url: nil,
            trust: .bot
        )
        let withThread = detail(
            reviews: [.init(author: bot, state: "COMMENTED", submittedAt: now - 3600, commit: head, trust: .bot)],
            threads: [open]
        )
        #expect(blocker(withThread, settings) != nil)
        // No review at all counts once its review check passed on the head commit.
        settings.gateChecks = ["copilot-review"]
        #expect(blocker(detail(reviews: [], passed: ["build"]), settings) == "Reviewed after push")
        #expect(blocker(detail(reviews: [], passed: ["build", "copilot-review"]), settings) == nil)
        // An untrusted bot's comment does not.
        #expect(blocker(detail(reviews: [.init(author: "other", state: "COMMENTED", commit: head)])) != nil)
    }

    @Test func quietGateLabelsAndGreen() {
        #expect(blocker(detail(committed: -120)) == "Quiet")
        var gate = PilotSettings()
        gate.gateChecks = ["e2e"]
        #expect(blocker(detail(), gate) == "Gate checks")
        #expect(blocker(detail(labels: ["Do-Not-Merge"])) == "No hold label")
        #expect(blocker(detail(state: "UNSTABLE")) == nil)
        var red = detail()
        red.failingChecks = [PullDetail.FailingCheck(name: "lint", summary: "x", url: nil)]
        #expect(blocker(red) == "Green")
    }

    @Test func selfReviewRunsLastAndGates() {
        var settings = PilotSettings()
        settings.selfReview = "claude -p"
        #expect(action(detail(), settings) == .selfReview)
        // Not before the other rules hold.
        #expect(action(detail(committed: -60), settings) == .hold("Quiet: quiet for 4m more"))
        let approved = SelfReview(sha: head, approved: true, summary: "approved", at: now)
        #expect(action(detail(), settings, review: approved) == .merge(method: "squash", admin: false))
        let refused = SelfReview(sha: head, approved: false, summary: "no tests", at: now)
        #expect(action(detail(), settings, review: refused) == .hold("Self-review: no tests"))
        // A review of an older commit is not this one's.
        let stale = SelfReview(sha: "old", approved: true, summary: "approved", at: now)
        #expect(action(detail(), settings, review: stale) == .selfReview)
    }

    @Test func autoMergeIsTurnedOffAndBehindIsUpdated() {
        #expect(action(detail(autoMerge: true)) == .disableAutoMerge(reason: "heed merges this PR itself"))
        #expect(action(detail(state: "BEHIND")) == .updateBranch)
    }

    @Test func parsingTheSelfReview() {
        #expect(SelfReview.parse("APPROVE\nLooks good.", sha: head, at: now).approved)
        #expect(SelfReview.parse("**APPROVE**", sha: head, at: now).approved)
        let refused = SelfReview.parse("REQUEST_CHANGES: the migration has no rollback", sha: head, at: now)
        #expect(!refused.approved)
        #expect(refused.summary == "the migration has no rollback")
        #expect(!SelfReview.parse("", sha: head, at: now).approved)
        #expect(SelfReview.prompt(detail(), diff: "+x").display.contains("APPROVE"))
        let extra = SelfReview.prompt(detail(), diff: "+x", instructions: "Flag API changes without a changelog entry.")
        #expect(extra.display.contains("not do.\n\nFlag API changes without a changelog entry.\n\nPR #"))
    }

    @Test func onlyApprovalsFromCollaboratorsAndTrustedReviewersCount() {
        func review(_ detail: PullDetail, _ settings: PilotSettings = PilotSettings()) -> String {
            let rule = HeedMerge.verdict(detail, settings: settings, selfReview: nil, now: now).rules
                .first { $0.name == "Reviewed after push" }
            return "\(rule?.state == .pass ? "pass" : "wait"): \(rule?.detail ?? "")"
        }
        #expect(review(detail(reviews: [approval("olek", trust: .owner)])) == "pass: approved by @olek on abc1234")
        #expect(review(detail(reviews: [approval("eve", trust: .stranger)]))
            == "wait: @eve approved abc1234, but isn't a collaborator")
        #expect(review(detail(reviews: [approval("helper", trust: .bot)]))
            == "wait: @helper approved abc1234, but isn't in trusted_reviewers")
        // A stranger's approval beside a collaborator's does not get in the way.
        #expect(review(detail(reviews: [approval("eve", trust: .stranger), approval("alice")]))
            == "pass: approved by @alice on abc1234")
        // A stranger's approval before the last push is no review either.
        #expect(review(detail(reviews: [approval("eve", trust: .stranger, commit: "old")]))
            == "wait: waiting for a review of abc1234")
        var settings = PilotSettings()
        settings.trustedReviewers = ["helper[bot]"]
        #expect(review(detail(reviews: [approval("helper", trust: .bot)]), settings)
            == "pass: approved by @helper on abc1234")
        // `name[bot]` is only ever the bot: a person with that login does not count.
        #expect(review(detail(reviews: [approval("helper", trust: .stranger)]), settings)
            == "wait: @helper approved abc1234, but isn't a collaborator")
        settings.trustedReviewers = ["Helper"]
        #expect(review(detail(reviews: [approval("helper", trust: .stranger)]), settings)
            == "pass: approved by @helper on abc1234")
    }

    @Test func gateChecksCountOnlyFromTheirApp() {
        var settings = PilotSettings()
        func gate(_ detail: PullDetail) -> String {
            let rule = HeedMerge.verdict(detail, settings: settings, selfReview: nil, now: now).rules
                .first { $0.name == "Gate checks" }
            return rule.map { "\($0.state): \($0.detail)" } ?? ""
        }
        settings.gateChecks = ["github-actions:build"]
        #expect(gate(detail()) == "pass: build (github-actions) passed")
        #expect(gate(detail(app: "someone-else")) == "wait: build (from github-actions) not passed on abc1234 yet")
        // A bare name: the app that reports it on the base branch, else GitHub Actions.
        settings.gateChecks = ["build"]
        #expect(gate(detail()) == "pass: build (github-actions) passed")
        #expect(gate(detail(app: "someone-else")) == "wait: build (from github-actions) not passed on abc1234 yet")
        var onBase = detail(app: "circleci")
        onBase.baseChecks = [.init(name: "build", app: "circleci"), .init(name: "lint", app: "github-actions")]
        #expect(gate(onBase) == "pass: build (circleci) passed")
        onBase.passedRuns = [.init(name: "build", app: "github-actions")]
        #expect(gate(onBase) == "wait: build (from circleci) not passed on abc1234 yet")
        // A failure counts only from the gate's app, too.
        var red = detail()
        red.failingChecks = [PullDetail.FailingCheck(
            name: "build", summary: ExternalText(
                "x",
                source: .checkSummary,
                author: .init(login: "other", trust: .bot)
            ),
            url: nil
        )]
        #expect(gate(red) == "pass: build (github-actions) passed")
        red.failingChecks = [PullDetail.FailingCheck(
            name: "build",
            summary: ExternalText("x", source: .checkSummary, author: .init(login: "github-actions", trust: .bot)),
            url: nil
        )]
        #expect(gate(red) == "fail: build failed")
        // Details cached before the apps were fetched: nothing counts until the next fetch.
        var cached = detail()
        cached.passedRuns = nil
        #expect(gate(cached) == "wait: build (from github-actions) not passed on abc1234 yet")
    }

    @Test func aGateCheckNamesItsAppBeforeAColon() {
        let named = GateCheck("github-actions:ci/test")
        #expect(named.app == "github-actions" && named.name == "ci/test")
        let bare = GateCheck("ci/test")
        #expect(bare.app == nil && bare.name == "ci/test")
        // Not an app's slug before the colon: all of it is the name.
        #expect(GateCheck("CI: test").app == nil)
        #expect(GateCheck("CI: test").name == "CI: test")
        #expect(GateCheck("lint:").app == nil)
        #expect(GateCheck.normalize("Dependabot[bot]") == "dependabot")
    }

    @Test func prsFromOutsideAreNotMergedOnTheirOwn() {
        let outside = detail(authorTrust: .stranger)
        #expect(blocker(outside) == "Author")
        let author = HeedMerge.verdict(outside, settings: PilotSettings(), selfReview: nil, now: now).rules[1]
        #expect(author.detail == "@me isn't a collaborator: heed doesn't merge it on its own; merge it by hand (zM)")
        #expect(action(outside) == .hold("Author: \(author.detail)"))
        // Not with GitHub's auto-merge either, and not with --admin.
        let auto = MergeQueue.Entry(ref: ref, detail: outside, settings: PilotSettings(), paused: false, mode: .auto)
        #expect(MergeQueue.action(for: auto) == .hold("Author: \(author.detail)"))
        var admin = PilotSettings()
        admin.adminMerge = true
        #expect(action(outside, admin) == .hold("Author: \(author.detail)"))
        // Behind or not, it is not touched.
        #expect(action(detail(state: "BEHIND", authorTrust: .stranger)) == .hold("Author: \(author.detail)"))
        // Nor does its self-review run.
        var reviewing = PilotSettings()
        reviewing.selfReview = "claude -p"
        #expect(action(outside, reviewing) == .hold("Author: \(author.detail)"))
        // Its gate checks run what the PR changes: none counts.
        var gated = PilotSettings()
        gated.gateChecks = ["build"]
        let gate = HeedMerge.verdict(outside, settings: gated, selfReview: nil, now: now).rules
            .first { $0.name == "Gate checks" }
        #expect(gate?.state == .fail)
        // Nor does a trusted reviewer's review check.
        gated.trustedReviewers = ["copilot-pull-request-reviewer"]
        #expect(HeedMerge.reviewed(detail(reviews: [], authorTrust: .stranger), settings: gated).state == .wait)
        #expect(HeedMerge.reviewed(detail(reviews: []), settings: gated).state == .pass)
        // A collaborator's PR merges.
        #expect(blocker(detail(authorTrust: .collaborator)) == nil)
    }

    @Test func theMergeItselfChecksTheRulesAgainAndRetriesWithAdminOnlyWhenTheyHeld() {
        func attempt(_ detail: PullDetail, admin: Bool) -> HeedMerge.Attempt {
            HeedMerge.attempt(
                HeedMerge.verdict(detail, settings: PilotSettings(), selfReview: nil, now: now), adminMerge: admin
            )
        }
        #expect(attempt(detail(), admin: true) == .merge(adminRetry: true))
        #expect(attempt(detail(), admin: false) == .merge(adminRetry: false))
        let outside = attempt(detail(authorTrust: .stranger), admin: true)
        #expect(outside == .hold(
            "Author: @me isn't a collaborator: heed doesn't merge it on its own; merge it by hand (zM)"
        ))
        #expect(attempt(detail(reviews: [approval("eve", trust: .stranger)]), admin: true)
            == .hold("Reviewed after push: @eve approved abc1234, but isn't a collaborator"))
    }

    @Test func trustedAuthorsAreMergedToo() {
        var settings = PilotSettings()
        settings.trustedAuthors = ["dependabot[bot]"]
        var bot = detail(authorTrust: .bot)
        bot.author = "dependabot"
        #expect(blocker(bot) == "Author")
        #expect(blocker(bot, settings) == nil)
        #expect(action(bot, settings) == .merge(method: "squash", admin: false))
        // A person called dependabot is not the bot.
        var person = detail(authorTrust: .stranger)
        person.author = "dependabot"
        #expect(blocker(person, settings) == "Author")
    }

    @Test func theSelfReviewRunsWithoutTools() {
        #expect(SelfReview.noTools("claude -p") == "claude --tools '' --strict-mcp-config -p")
        #expect(SelfReview.noTools("/opt/homebrew/bin/claude -p --model haiku")
            == "/opt/homebrew/bin/claude --tools '' --strict-mcp-config -p --model haiku")
        #expect(SelfReview.noTools("claude") == "claude --tools '' --strict-mcp-config")
        #expect(SelfReview.noTools("pi -p") == "pi --no-tools --no-extensions --no-mcp -p")
        // Tools named by you, and agents heed has no flags for, run as written.
        #expect(SelfReview.noTools("claude -p --tools Read") == "claude -p --tools Read")
        #expect(SelfReview.noTools("my-review.sh") == "my-review.sh")
    }

    @Test func theSelfReviewRunsInAnEmptyFolderWithThePromptOnStdin() async throws {
        let echoed = try await SelfReview.run("cat", prompt: "APPROVE")
        #expect(echoed == "APPROVE")
        let folder = try await SelfReview.run("pwd; ls -A", prompt: "x")
        let lines = folder.split(separator: "\n")
        #expect(lines.first?.hasSuffix("/work") == true)
        #expect(lines.count == 1)
    }

    @Test func onlyAnExactVerdictLineCounts() {
        func approved(_ output: String) -> Bool { SelfReview.parse(output, sha: head, at: now).approved }
        #expect(approved("APPROVE"))
        #expect(approved("## APPROVE\nfine"))
        #expect(approved("`APPROVE`"))
        #expect(!approved("APPROVED"))
        #expect(!approved("APPROVE."))
        #expect(!approved("Approve"))
        #expect(!approved("I APPROVE of this"))
        #expect(!approved("APPROVE: but"))
        #expect(!approved("Looks fine.\nAPPROVE"))
        let other = SelfReview.parse("Looks fine.\nAPPROVE", sha: head, at: now)
        #expect(other.summary == "the answer did not start with APPROVE or REQUEST_CHANGES: Looks fine.")
        #expect(SelfReview.parse("**REQUEST_CHANGES**: no tests", sha: head, at: now).summary == "no tests")
        #expect(SelfReview.parse("REQUEST_CHANGES", sha: head, at: now).summary
            == "changes requested, no reason given")
    }

    @Test func botsThatReviewHereAreSuggested() {
        let repo = ref.repo
        func reviewed(_ reviews: [PullDetail.Review], in other: Repo? = nil) -> PullDetail {
            var detail = detail(reviews: reviews)
            if let other { detail.ref = PullRef(repo: other, number: 1) }
            return detail
        }
        let details = [
            reviewed([
                .init(author: "copilot-pull-request-reviewer", state: "COMMENTED", trust: .bot),
                .init(author: "alice", state: "APPROVED", trust: .collaborator),
                .init(author: "eve", state: "APPROVED", trust: .stranger),
            ]),
            reviewed([.init(author: "review-owl", state: "APPROVED", trust: .bot)]),
            reviewed([.init(author: "elsewhere", state: "APPROVED", trust: .bot)], in: Repo(org: "o", name: "x")),
        ]
        let all = ReviewerSuggestion.suggest(repo: repo, details: details, trusted: [], dismissed: [])
        #expect(all.map(\.login) == ["copilot-pull-request-reviewer", "review-owl"])
        #expect(all[0].text == "copilot-pull-request-reviewer reviews here: trust its approvals?")
        #expect(all[0].accepted(["alice"]) == ["alice", "copilot-pull-request-reviewer[bot]"])
        // Trusted already, or dismissed: not asked.
        let trusted = ReviewerSuggestion.suggest(
            repo: repo, details: details, trusted: ["copilot-pull-request-reviewer"], dismissed: [all[1].id]
        )
        #expect(trusted.isEmpty)
        #expect(all[1].id == "globex/heed|review-owl")
        // The entry it writes makes its approval count.
        var settings = PilotSettings()
        settings.trustedReviewers = all[1].accepted([])
        #expect(blocker(detail(reviews: [approval("review-owl", trust: .bot)]), settings) == nil)
        // Accepting writes the repo's list, which the fake world applies as reading config.toml back would.
        var config = HeedConfig.default
        AutopilotSwitch.apply(
            [.init(["repos", repo.slug, "trusted_reviewers"], .array(all[1].accepted([]).map(TOMLValue.string)))],
            to: &config
        )
        #expect(config.pilot.resolve(repo).trustedReviewers == ["review-owl[bot]"])
    }

    @Test func theCommentSaysWhy() {
        let verdict = HeedMerge.verdict(detail(), settings: PilotSettings(), selfReview: nil, now: now)
        let comment = HeedMerge.comment(verdict, method: "squash")
        #expect(comment.contains("- **Reviewed after push**: approved by @alice on abc1234"))
    }

    @Test func configReadsTheRulesAndAdminOnlyPerRepo() throws {
        let (decoded, problems) = ConfigLoader.decode("""
        [pilot]
        merge = "heed"
        quiet_minutes = 10
        trusted_reviewers = ["copilot-pull-request-reviewer"]
        trusted_authors = ["dependabot[bot]"]
        gate_checks = ["copilot-review"]
        hold_labels = ["blocked"]
        self_review = "claude -p"
        admin_merge = true
        [orgs.employer]
        admin_merge = true
        quiet_minutes = 0
        [repos."employer/tools"]
        admin_merge = true
        trusted_authors = []
        """)
        let config = try #require(decoded)
        #expect(config.pilot.defaults.merge == .heed)
        #expect(config.pilot.defaults.quietMinutes == 10)
        #expect(config.pilot.defaults.selfReview == "claude -p")
        #expect(config.pilot.defaults.holdLabels == ["blocked"])
        #expect(!config.pilot.resolve(Repo(org: "employer", name: "other")).adminMerge)
        #expect(config.pilot.resolve(Repo(org: "employer", name: "other")).quietMinutes == 0)
        #expect(config.pilot.resolve(Repo(org: "employer", name: "tools")).adminMerge)
        #expect(config.pilot.defaults.trustedAuthors == ["dependabot[bot]"])
        #expect(config.pilot.resolve(Repo(org: "employer", name: "tools")).trustedAuthors.isEmpty)
        #expect(problems.map(\.path) == ["pilot.admin_merge"])
    }

    @Test func theQueryReadsReviewCommitsAndPassedChecks() throws {
        let json = """
        {"data":{"repository":{"pullRequest":{"number":7,"title":"t","body":"","baseRefName":"main","headRefName":"b",
          "additions":1,"deletions":1,"state":"OPEN",
          "commits":{"totalCount":1,"nodes":[{"commit":{"oid":"abc","committedDate":"2026-10-14T08:00:00Z",
            "statusCheckRollup":{"contexts":{"nodes":[
              {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS",
               "startedAt":"2026-10-14T08:01:00Z","checkSuite":{"app":{"slug":"github-actions"}}},
              {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"FAILURE",
               "startedAt":"2026-10-14T08:02:00Z","checkSuite":{"app":{"slug":"elsewhere"}}},
              {"__typename":"StatusContext","context":"deploy","state":"SUCCESS","creator":{"login":"vercel"}},
              {"__typename":"CheckRun","name":"e2e","status":"IN_PROGRESS","conclusion":null}]}}}}]},
          "baseRef":{"target":{"statusCheckRollup":{"contexts":{"nodes":[
            {"__typename":"CheckRun","name":"build","checkSuite":{"app":{"slug":"github-actions"}}}]}}}},
          "reviews":{"nodes":[{"author":{"login":"alice"},"state":"APPROVED","submittedAt":"2026-10-14T09:00:00Z",
            "commit":{"oid":"abc"}}]},
          "closingIssuesReferences":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
        """
        let detail = try #require(GitHub.parsePullDetail(Data(json.utf8), ref: ref, now: now))
        #expect(detail.reviews.first?.commit == "abc")
        #expect(detail.reviews.first?.submittedAt != nil)
        #expect(detail.passedChecks == ["build", "deploy"])
        // The same name from another app is a check of its own: the later failure does not hide the pass.
        #expect(detail.passedRuns == [
            .init(name: "build", app: "github-actions"),
            .init(name: "deploy", app: "vercel"),
        ])
        #expect(detail.failingChecks.map(\.summary.author.login) == ["elsewhere"])
        #expect(detail.baseChecks == [.init(name: "build", app: "github-actions")])
        #expect(detail.headCommittedAt == ISO8601DateFormatter().date(from: "2026-10-14T08:00:00Z"))
    }
}
