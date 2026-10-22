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
        labels: [String] = [], threads: [ReviewThread] = [], state: String = "CLEAN", autoMerge: Bool = false
    ) -> PullDetail {
        var detail = PullDetail(
            ref: ref, title: "t", body: "b", author: "me", baseBranch: "main", headBranch: "b", additions: 1,
            deletions: 1, commitCount: 1, headSHA: head,
            reviews: reviews ?? [.init(author: "alice", state: "APPROVED", submittedAt: now - 3600, commit: head)],
            threads: threads, failingChecks: [], checks: CheckSummary(passed: passed.count), closes: [], fetchedAt: now
        )
        detail.state = "OPEN"
        detail.isDraft = false
        detail.mergeable = "MERGEABLE"
        detail.mergeState = state
        detail.requiredChecks = []
        detail.labels = labels
        detail.headCommittedAt = now + committed
        detail.passedChecks = passed
        detail.repoMergeMethods = ["squash"]
        detail.autoMergeEnabled = autoMerge
        return detail
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
        let old = detail(reviews: [.init(author: "alice", state: "APPROVED", submittedAt: now - 7200, commit: "old")])
        #expect(blocker(old) == "Reviewed after push")
        #expect(action(old) ==
            .hold("Reviewed after push: approved before the last push; waiting for a review of abc1234"))
    }

    @Test func trustedAIReviews() {
        var settings = PilotSettings()
        settings.trustedReviewers = ["copilot-pull-request-reviewer"]
        let bot = "copilot-pull-request-reviewer"
        // A comment review with none of its threads open counts.
        let commented = detail(reviews: [.init(author: bot, state: "COMMENTED", submittedAt: now - 3600, commit: head)])
        #expect(blocker(commented, settings) == nil)
        let open = ReviewThread(
            id: "T", isResolved: false, path: "f", line: 1, author: bot, body: "x", diff: [], replies: 0, url: nil
        )
        let withThread = detail(
            reviews: [.init(author: bot, state: "COMMENTED", submittedAt: now - 3600, commit: head)], threads: [open]
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
        #expect(SelfReview.prompt(detail(), diff: "+x").contains("APPROVE"))
        let extra = SelfReview.prompt(detail(), diff: "+x", instructions: "Flag API changes without a changelog entry.")
        #expect(extra.contains("not do.\n\nFlag API changes without a changelog entry.\n\nPR #"))
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
        gate_checks = ["copilot-review"]
        hold_labels = ["blocked"]
        self_review = "claude -p"
        admin_merge = true
        [orgs.employer]
        admin_merge = true
        quiet_minutes = 0
        [repos."employer/tools"]
        admin_merge = true
        """)
        let config = try #require(decoded)
        #expect(config.pilot.defaults.merge == .heed)
        #expect(config.pilot.defaults.quietMinutes == 10)
        #expect(config.pilot.defaults.selfReview == "claude -p")
        #expect(config.pilot.defaults.holdLabels == ["blocked"])
        #expect(!config.pilot.resolve(Repo(org: "employer", name: "other")).adminMerge)
        #expect(config.pilot.resolve(Repo(org: "employer", name: "other")).quietMinutes == 0)
        #expect(config.pilot.resolve(Repo(org: "employer", name: "tools")).adminMerge)
        #expect(problems.map(\.path) == ["pilot.admin_merge"])
    }

    @Test func theQueryReadsReviewCommitsAndPassedChecks() throws {
        let json = """
        {"data":{"repository":{"pullRequest":{"number":7,"title":"t","body":"","baseRefName":"main","headRefName":"b",
          "additions":1,"deletions":1,"state":"OPEN",
          "commits":{"totalCount":1,"nodes":[{"commit":{"oid":"abc","committedDate":"2026-10-14T08:00:00Z",
            "statusCheckRollup":{"contexts":{"nodes":[
              {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"},
              {"__typename":"CheckRun","name":"e2e","status":"IN_PROGRESS","conclusion":null}]}}}}]},
          "reviews":{"nodes":[{"author":{"login":"alice"},"state":"APPROVED","submittedAt":"2026-10-14T09:00:00Z",
            "commit":{"oid":"abc"}}]},
          "closingIssuesReferences":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
        """
        let detail = try #require(GitHub.parsePullDetail(Data(json.utf8), ref: ref, now: now))
        #expect(detail.reviews.first?.commit == "abc")
        #expect(detail.reviews.first?.submittedAt != nil)
        #expect(detail.passedChecks == ["build"])
        #expect(detail.headCommittedAt == ISO8601DateFormatter().date(from: "2026-10-14T08:00:00Z"))
    }
}
