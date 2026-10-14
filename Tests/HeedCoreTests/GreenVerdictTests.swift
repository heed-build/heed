import Foundation
@testable import HeedCore
import Testing

struct GreenVerdictTests {
    private let ref = PullRef(repo: Repo(org: "nullean", name: "heed"), number: 7)

    private func detail(
        mergeable: String? = "MERGEABLE", state: String? = "CLEAN", failing: [String] = [], pending: [String] = [],
        required: [String] = [], threads: Int = 0, review: String? = nil, draft: Bool = false, prState: String = "OPEN"
    ) -> PullDetail {
        var detail = PullDetail(
            ref: ref, title: "t", body: "", author: nil, baseBranch: "main", headBranch: "b", additions: 0,
            deletions: 0, commitCount: 1, headSHA: "a1", reviews: [],
            threads: (0 ..< threads).map {
                ReviewThread(
                    id: "T\($0)",
                    isResolved: false,
                    path: "f",
                    line: 1,
                    author: "r",
                    body: "x",
                    diff: [],
                    replies: 0,
                    url: nil
                )
            },
            failingChecks: failing.map { PullDetail.FailingCheck(name: $0, summary: "\($0) broke", url: nil) },
            checks: CheckSummary(
                passed: 2,
                failed: failing.count,
                pending: pending.count,
                failedNames: failing,
                pendingNames: pending
            ),
            closes: [], fetchedAt: Date()
        )
        detail.state = prState
        detail.isDraft = draft
        detail.mergeable = mergeable
        detail.mergeState = state
        detail.reviewDecision = review
        detail.requiredChecks = required
        return detail
    }

    private func status(_ detail: PullDetail) -> PilotStatus {
        PilotStatus.of(pull: nil, pipeline: nil, settings: PilotSettings(), hasSession: true, detail: detail)
    }

    @Test func greenWhenEveryRuleHolds() {
        let verdict = GreenVerdict.of(detail())
        #expect(verdict.isGreen)
        #expect(verdict.blocker == nil)
        #expect(status(detail()) == .green)
    }

    @Test func eachRuleHoldsItBack() {
        #expect(status(detail(mergeable: "CONFLICTING", state: "DIRTY")) == .conflicted("conflicts with main"))
        #expect(status(detail(state: "BEHIND")) == .conflicted("behind main, which this repo requires to be current"))
        #expect(status(detail(failing: ["lint"])) == .failing(1))
        #expect(status(detail(pending: ["build"])) == .pending)
        #expect(status(detail(threads: 2)) == .changes(2))
        #expect(status(detail(review: "CHANGES_REQUESTED")) == .changes(1))
        #expect(status(detail(draft: true)) == .draft)
        #expect(status(detail(prState: "MERGED")) == .closed(merged: true))
        // GitHub still working out mergeability: not green yet, but nothing failed either.
        #expect(status(detail(mergeable: "UNKNOWN", state: "UNKNOWN")) == .pending)
    }

    @Test func onlyRequiredChecksCountWhenThereAreAny() {
        let optional = detail(failing: ["label"], required: ["build"])
        #expect(GreenVerdict.of(optional).isGreen)
        #expect(status(detail(failing: ["build"], required: ["build"])) == .failing(1))
        #expect(GreenVerdict.of(detail(failing: ["label"])).blocker?.detail == "label failed")
    }

    @Test func aConflictBecomesAnItemAndResolves() {
        var pipeline = PullFeedback(ref: ref)
        pipeline.merge(detail(mergeable: "CONFLICTING", state: "DIRTY"))
        let item = pipeline.items.first { $0.id == "conflict" }
        #expect(item?.status == .new)
        #expect(item?.promptLine.contains("rebase on main, resolve the conflicts") == true)
        // Unknown keeps it; merging cleanly resolves it.
        pipeline.merge(detail(mergeable: "UNKNOWN", state: "UNKNOWN"))
        #expect(pipeline.items.first { $0.id == "conflict" }?.status == .new)
        pipeline.merge(detail())
        #expect(pipeline.items.first { $0.id == "conflict" }?.status == .resolved)

        var behind = PullFeedback(ref: ref)
        behind.merge(detail(state: "BEHIND"))
        #expect(behind.items.first?.promptLine.contains("behind main") == true)
    }

    @Test func aFailedCheckPointsAtItsLog() {
        var item = FeedbackItem(id: "check:lint", kind: .check(name: "lint"), text: "line too long")
        #expect(item.promptLine == "check lint failed: line too long")
        item.logPath = "/tmp/heed/logs/x.log"
        #expect(item.promptLine == "check lint failed: line too long (the failed log is in /tmp/heed/logs/x.log)")
    }

    @Test func jobsAndLogLines() {
        #expect(GitHub.jobID(fromDetailsURL: "https://github.com/o/r/actions/runs/123/job/456") == "456")
        #expect(GitHub.jobID(fromDetailsURL: "https://ci.example.com/build/9") == nil)
        #expect(GitHub.jobID(fromDetailsURL: nil) == nil)
        #expect(GitHub.cleanLogLine("build\tRun tests\t2026-10-13T18:44:48.5Z 3 failed") == "Run tests: 3 failed")
        #expect(GitHub.cleanLogLine("plain line") == "plain line")
    }

    @Test func theDetailQueryFieldsAreRead() throws {
        let json = """
        {"data":{"repository":{"pullRequest":{"number":7,"title":"t","body":"","baseRefName":"main","headRefName":"b",
          "additions":1,"deletions":1,"state":"OPEN","isDraft":false,"mergeable":"CONFLICTING",
          "mergeStateStatus":"DIRTY","reviewDecision":"APPROVED",
          "commits":{"totalCount":1,"nodes":[{"commit":{"oid":"a1","statusCheckRollup":{"contexts":{"nodes":[
            {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true},
            {"__typename":"CheckRun","name":"label","status":"COMPLETED","conclusion":"FAILURE","isRequired":false},
            {"__typename":"StatusContext","context":"ci/legacy","state":"SUCCESS","isRequired":true}]}}}}]},
          "reviews":{"nodes":[]},"closingIssuesReferences":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
        """
        let detail = try #require(GitHub.parsePullDetail(Data(json.utf8), ref: ref, now: Date()))
        #expect(detail.mergeable == "CONFLICTING")
        #expect(detail.mergeState == "DIRTY")
        #expect(detail.reviewDecision == "APPROVED")
        #expect(detail.requiredChecks == ["build", "ci/legacy"])
        #expect(GreenVerdict.of(detail).blocker?.name == "No conflicts")
    }
}
