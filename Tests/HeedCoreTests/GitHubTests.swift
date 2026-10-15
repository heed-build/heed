import Foundation
@testable import HeedCore
import Testing

struct GitHubParsingTests {
    @Test func notifications() {
        let json = """
        [{"id":"1","reason":"review_requested","unread":true,"updated_at":"2026-10-05T19:00:52Z",
          "subject":{"title":"Add link validation","type":"PullRequest","url":"https://api.github.com/repos/elastic/docs-builder/pulls/2845"},
          "repository":{"full_name":"elastic/docs-builder"}},
         {"id":"2","reason":"ci_activity","unread":false,"updated_at":"2026-10-05T18:00:00Z",
          "subject":{"title":"lint failed","type":"CheckSuite","url":null},
          "repository":{"full_name":"elastic/docs-builder"}}]
        """
        let items = GitHub.parseNotifications(Data(json.utf8))
        #expect(items.count == 2)
        #expect(items[0].kind == .pr)
        #expect(items[0].number == 2845)
        #expect(items[0].url == "https://github.com/elastic/docs-builder/pull/2845")
        #expect(items[0].reasonText == "review requested")
        #expect(items[1].kind == .ci)
        #expect(items[1].url == "https://github.com/elastic/docs-builder/actions")
    }

    @Test func pullSearchSkipsSAMLHiddenNodesAndCountsThem() {
        let json = """
        {"data":{"search":{"nodes":[null,{"number":170,"title":"Match converters","url":"https://github.com/xoofx/SharpYaml/pull/170",
          "isDraft":false,"state":"OPEN","headRefName":"fix/167","updatedAt":"2026-10-08T14:47:54Z",
          "repository":{"nameWithOwner":"xoofx/SharpYaml"},"reviewDecision":"CHANGES_REQUESTED",
          "reviewThreads":{"nodes":[{"isResolved":false},{"isResolved":true}]},
          "commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[
            {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"FAILURE"},
            {"__typename":"CheckRun","name":"lint","status":"IN_PROGRESS","conclusion":null},
            {"__typename":"CheckRun","name":"docs","status":"COMPLETED","conclusion":"SKIPPED"},
            {"__typename":"StatusContext","context":"ci/conventional","state":"SUCCESS"}]}}}}]}}]}},
         "errors":[{"type":"FORBIDDEN","extensions":{"saml_failure":true}}]}
        """
        let (pulls, hidden) = GitHub.parsePullSearch(Data(json.utf8))
        #expect(hidden == 1)
        #expect(pulls.count == 1)
        let pull = pulls[0]
        #expect(pull.ref == PullRef(repo: Repo(org: "xoofx", name: "SharpYaml"), number: 170))
        #expect(pull.review == .changesRequested)
        #expect(pull.unresolvedThreads == 1)
        #expect(pull.checks == CheckSummary(
            passed: 1, failed: 1, pending: 1, skipped: 1, failedNames: ["build"], pendingNames: ["lint"]
        ))
        #expect(pull.checks.text == "1/3 passed · build failed · 1 running · 1 skipped")
    }

    @Test func checkTexts() {
        #expect(CheckSummary().text == "no checks")
        #expect(CheckSummary(skipped: 2).text == "2 skipped")
        #expect(CheckSummary(passed: 2, pending: 3).text == "2/5 passed · 3 running")
        #expect(CheckSummary(passed: 4).text == "4/4 passed")
        #expect(CheckSummary(failed: 2, failedNames: ["a", "b"]).text == "0/2 passed · 2 failed")
        #expect(CheckSummary(passed: 52, failed: 2, pending: 3, skipped: 3, failedNames: ["lint", "e2e"]).parts == [
            .passed("52/57 passed"), .failed("2 failed"), .running("3 running"), .skipped("3 skipped"),
        ])
    }

    @Test func trackedPullsByAlias() {
        let json = """
        {"data":{"p0":{"pullRequest":{"number":5,"title":"T","url":"u","isDraft":true,"state":"MERGED",
          "headRefName":"b","updatedAt":"2026-10-01T00:00:00Z","repository":{"nameWithOwner":"o/r"},
          "reviewDecision":null,"reviewThreads":{"nodes":[]},"commits":{"nodes":[]}}},"p1":null}}
        """
        let refs = [
            PullRef(repo: Repo(org: "o", name: "r"), number: 5),
            PullRef(repo: Repo(org: "o", name: "x"), number: 1),
        ]
        let (pulls, _) = GitHub.parseTrackedPulls(Data(json.utf8), refs: refs)
        #expect(pulls.map(\.ref) == [refs[0]])
        #expect(pulls[0].state == .merged)
        #expect(pulls[0].isDraft)
        #expect(GitHub.trackedPullsQuery(refs)
            .contains("p1: repository(owner: \"o\", name: \"x\") { pullRequest(number: 1)"))
    }

    @Test func issues() {
        let json = """
        {"data":{"search":{"nodes":[{"number":94,"title":"Backpressure drops events","url":"https://github.com/o/r/issues/94",
          "bodyText":"Under burst load","updatedAt":"2026-10-01T00:00:00Z","repository":{"nameWithOwner":"o/r"},
          "author":{"login":"me"},"labels":{"nodes":[{"name":"bug"}]}}]}}}
        """
        let (issues, hidden) = GitHub.parseIssueSearch(Data(json.utf8))
        #expect(hidden == 0)
        #expect(issues.first?.labels == ["bug"])
        #expect(issues.first?.id == "o/r#94")
    }
}

struct WorkPromptTests {
    private func issue(_ number: Int, _ title: String) -> HeedCore.Issue {
        HeedCore.Issue(
            repo: Repo(org: "elastic", name: "docs-builder"),
            number: number,
            title: title,
            url: "",
            body: "Body \(number)",
            labels: [],
            author: nil,
            updatedAt: Date()
        )
    }

    @Test func severalIssuesBecomeOnePromptWithClosesLines() {
        let prompt = WorkPrompt.from(issues: [issue(2830, "Anchors lost"), issue(2833, "Redirect loop")])
        #expect(prompt.contains("- docs-builder#2830 Anchors lost"))
        #expect(prompt.contains("Closes elastic/docs-builder#2833"))
        #expect(!WorkPrompt.from(issues: [issue(1, "x")], closesLines: false).contains("Closes"))
    }

    @Test func startInstructionsGoBeforeTheClosesLines() {
        let one = WorkPrompt.from(issues: [issue(1, "x")], instructions: "Write a failing test first.")
        #expect(one.hasSuffix("Body 1\n\nWrite a failing test first.\n\nCloses elastic/docs-builder#1"))
        let two = WorkPrompt.from(issues: [issue(1, "x"), issue(2, "y")], instructions: "Keep it small.")
        #expect(two.contains("- docs-builder#2 y\n\nKeep it small.\n\nCloses"))
        #expect(!WorkPrompt.from(issues: [issue(1, "x")]).contains("\n\n\n"))
    }

    @Test func pullsAreTrackedByBranch() {
        let repo = Repo(org: "o", name: "r")
        let session = Session(
            id: "s",
            title: "t",
            repos: [repo],
            branch: "feature",
            agent: "claude",
            state: .init(.working)
        )
        let pull = PullRequest(
            ref: PullRef(repo: repo, number: 7), title: "", url: "", state: .open, isDraft: false,
            headBranch: "feature",
            review: nil, checks: CheckSummary(), unresolvedThreads: 0, updatedAt: Date()
        )
        let changes = PullTracking.changes(sessions: [session], pulls: [pull])
        guard case let .sessionUpserted(updated)? = changes.first else {
            Testing.Issue.record("expected an update")
            return
        }
        #expect(updated.trackedPRs == [pull.ref])
        #expect(PullTracking.changes(sessions: [updated], pulls: [pull]).isEmpty)
    }
}

struct FeedbackTests {
    private let ref = PullRef(repo: Repo(org: "elastic", name: "docs-builder"), number: 2841)

    private func detail(
        threads: [ReviewThread], failing: [String] = [], sha: String = "a1", approvals: Int = 0, pending: [String] = []
    ) -> PullDetail {
        PullDetail(
            ref: ref, title: "t", body: "", author: "you", baseBranch: "main", headBranch: "b", additions: 1,
            deletions: 1,
            commitCount: 1, headSHA: sha,
            reviews: (0 ..< approvals).map { PullDetail.Review(author: "r\($0)", state: "APPROVED") },
            threads: threads,
            failingChecks: failing.map { PullDetail.FailingCheck(name: $0, summary: "\($0) broke", url: nil) },
            checks: CheckSummary(
                failed: failing.count, pending: pending.count, failedNames: failing, pendingNames: pending
            ), closes: [],
            fetchedAt: Date()
        )
    }

    private func thread(_ id: String, resolved: Bool = false) -> ReviewThread {
        ReviewThread(
            id: id,
            isResolved: resolved,
            path: "src/RedirectFile.cs",
            line: 88,
            author: "reviewer",
            body: "Anchor lookup is case sensitive.",
            diff: [],
            replies: 0,
            url: nil
        )
    }

    @Test func newItemsArriveAndResolve() {
        var feedback = PullFeedback(ref: ref)
        feedback.merge(detail(threads: [thread("t1"), thread("t2")], failing: ["lint"]))
        #expect(feedback.items.map(\.status) == [.new, .new, .new])
        feedback.merge(detail(threads: [thread("t1", resolved: true), thread("t2")]))
        #expect(feedback.items.first { $0.id == "t1" }?.status == .resolved)
        #expect(feedback.items.first { $0.id == "check:lint" }?.status == .resolved)
        #expect(feedback.items.first { $0.id == "t2" }?.status == .new)
    }

    @Test func autoFeedQueuesAndPromptsListEachItem() {
        var feedback = PullFeedback(ref: ref, autoFeed: .auto)
        feedback.merge(detail(threads: [thread("t1")], failing: ["lint"]))
        #expect(feedback.queued.count == 2)
        let prompt = feedback.prompt() ?? ""
        #expect(prompt.hasPrefix("Review feedback on PR #2841"))
        #expect(prompt.contains("1) RedirectFile.cs:88 (@reviewer): Anchor lookup is case sensitive."))
        #expect(prompt.contains("2) check lint failed: lint broke"))
    }

    @Test func greenInstructionsFollowTheItems() {
        var feedback = PullFeedback(ref: ref, autoFeed: .auto)
        feedback.merge(detail(threads: [thread("t1")]))
        let prompt = feedback.prompt(instructions: "Resolve the threads you addressed.") ?? ""
        #expect(prompt.hasSuffix("case sensitive.\n\nResolve the threads you addressed."))
        #expect(feedback.prompt() == feedback.prompt(instructions: ""))
    }

    @Test func sentItemsBecomeAddressedOnANewPushAndRoundsReset() {
        var feedback = PullFeedback(ref: ref, autoFeed: .auto)
        feedback.merge(detail(threads: [thread("t1")]))
        feedback.markSent(at: "a1")
        #expect(feedback.rounds == 1)
        feedback.merge(detail(threads: [thread("t1")], sha: "a2"))
        #expect(feedback.items[0].status == .addressed)
        feedback.markSent(at: "a2")
        feedback.markSent(at: "a2")
        #expect(feedback.roundsExhausted)
        feedback.merge(detail(threads: [thread("t1")], sha: "a3", approvals: 1))
        #expect(feedback.rounds == 0)
    }

    @Test func aCheckRunningAgainIsNotResolvedYet() {
        var feedback = PullFeedback(ref: ref)
        feedback.merge(detail(threads: [], failing: ["build"]))
        feedback.merge(detail(threads: [], failing: [], pending: ["build"]))
        #expect(feedback.items[0].status == .new)
    }

    @Test func aCheckThatPassedResolvesWhileOthersStillRun() {
        var feedback = PullFeedback(ref: ref)
        feedback.merge(detail(threads: [], failing: ["check-labels", "validate"]))
        feedback.merge(detail(threads: [], failing: [], pending: ["build (windows-latest)"]))
        #expect(feedback.items.map(\.status) == [.resolved, .resolved])
    }

    @Test func onlyTheNewestRunOfACheckCounts() {
        // check-labels failed, then ran again on the same commit once the label was added.
        let contexts: [[String: Any]] = [
            [
                "__typename": "CheckRun",
                "name": "check-labels",
                "status": "COMPLETED",
                "conclusion": "FAILURE",
                "startedAt": "2026-10-13T08:20:00Z",
            ],
            [
                "__typename": "CheckRun",
                "name": "check-labels",
                "status": "COMPLETED",
                "conclusion": "SUCCESS",
                "startedAt": "2026-10-13T08:31:00Z",
            ],
            ["__typename": "CheckRun", "name": "build", "status": "IN_PROGRESS", "startedAt": "2026-10-13T08:20:00Z"],
            ["__typename": "StatusContext", "context": "ci/legacy", "state": "SUCCESS"],
        ]
        let summary = GitHub.checkSummary(GitHub.latest(contexts))
        #expect(summary.failed == 0)
        #expect(summary.passed == 2)
        #expect(summary.pendingNames == ["build"])
    }

    @Test func deliveryWaitsForIdleAndForYou() {
        #expect(Delivery.verdict(state: .idle, lastTyped: nil) == .deliver)
        #expect(Delivery.verdict(state: .done, lastTyped: Date(timeIntervalSinceNow: -60)) == .deliver)
        #expect(Delivery.verdict(state: .working, lastTyped: nil) == .wait("the agent is working"))
        #expect(Delivery.verdict(state: .blocked, lastTyped: nil) != .deliver)
        #expect(Delivery.verdict(state: .asking, lastTyped: nil) != .deliver)
        #expect(Delivery.verdict(state: .idle, lastTyped: Date()) == .wait("you typed in its pane just now"))
    }

    @Test func parsesPullDetail() {
        let json = """
        {"data":{"repository":{"pullRequest":{"number":2841,"title":"Fix","body":"Closes #2830","author":{"login":"you"},
          "baseRefName":"main","headRefName":"fix","additions":82,"deletions":4,
          "commits":{"totalCount":3,"nodes":[{"commit":{"oid":"abc","statusCheckRollup":{"contexts":{"nodes":[
            {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"FAILURE","title":"docs/redirects.md:41 line too long\\nmore","summary":null,"detailsUrl":"u"}]}}}}]},
          "reviews":{"nodes":[{"author":{"login":"rev"},"state":"CHANGES_REQUESTED"},{"author":{"login":"rev"},"state":"APPROVED"}]},
          "closingIssuesReferences":{"nodes":[{"number":2830,"repository":{"nameWithOwner":"elastic/docs-builder"}}]},
          "reviewThreads":{"nodes":[{"id":"T1","isResolved":false,"path":"src/RedirectFile.cs","line":88,
            "comments":{"totalCount":2,"nodes":[{"author":{"login":"rev"},"body":"Case sensitive","diffHunk":"@@ -80,8 +80,8 @@\\n a\\n b\\n c\\n d\\n e\\n f\\n-g\\n+h","url":"x"}]}}]}}}}}
        """
        let detail = GitHub.parsePullDetail(Data(json.utf8), ref: ref, now: Date())
        #expect(detail?.headSHA == "abc")
        #expect(detail?.failingChecks.first?.summary == "docs/redirects.md:41 line too long")
        #expect(detail?.threads.first?.diff.count == 6)
        #expect(detail?.threads.first?.replies == 1)
        #expect(detail?.threads.first?.location == "RedirectFile.cs:88")
        #expect(detail?.approvals == 1)
        #expect(detail?.closes.first?.number == 2830)
    }
}

struct AvatarCacheTests {
    @Test func cachesByLoginAndAgesOut() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heed-avatars-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AvatarCache(directory: directory, maxAge: 60)
        #expect(cache.cached("Elastic") == nil)
        #expect(cache.isStale("elastic"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: cache.file(for: "Elastic"))
        #expect(cache.cached("elastic") == Data([1, 2, 3]))
        #expect(!cache.isStale("elastic"))
        #expect(cache.isStale("elastic", now: Date().addingTimeInterval(120)))
        #expect(AvatarCache.url(for: "elastic")?.absoluteString == "https://github.com/elastic.png?size=64")
    }
}

struct SyncScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func theViewOnScreenRefreshesEveryMinuteTheRestEveryFive() {
        var schedule = SyncSchedule()
        #expect(schedule.due(now: now, front: [.pulls]) == Set(GitHubPart.allCases))
        schedule.fetched(Set(GitHubPart.allCases), at: now)
        #expect(schedule.due(now: now.addingTimeInterval(30), front: [.pulls]).isEmpty)
        #expect(schedule.due(now: now.addingTimeInterval(60), front: [.pulls]) == [.pulls])
        #expect(schedule.due(now: now.addingTimeInterval(300), front: [.pulls]) == Set(GitHubPart.allCases))
        #expect(schedule.due(now: now.addingTimeInterval(1), front: [], force: true) == Set(GitHubPart.allCases))
    }

    @Test func aDetailIsFetchedOnlyWhenItsSummaryMoved() {
        let ref = PullRef(repo: Repo(org: "elastic", name: "docs-builder"), number: 1)
        func pull(_ checks: CheckSummary) -> PullRequest {
            PullRequest(
                ref: ref, title: "t", url: ref.url, state: .open, isDraft: false, headBranch: "b", review: nil,
                checks: checks, unresolvedThreads: 0, updatedAt: now
            )
        }
        let running = CheckSummary(passed: 2, pending: 1, pendingNames: ["build"])
        let detail = PullDetail(
            ref: ref, title: "t", body: "", author: nil, baseBranch: "main", headBranch: "b", additions: 0,
            deletions: 0, commitCount: 1, headSHA: "a", reviews: [], threads: [], failingChecks: [], checks: running,
            closes: [], fetchedAt: now
        )
        #expect(SyncSchedule().needsDetail(pull: nil, detail: nil, now: now))
        #expect(!SyncSchedule().needsDetail(pull: pull(running), detail: detail, now: now.addingTimeInterval(60)))
        #expect(SyncSchedule().needsDetail(pull: pull(CheckSummary(passed: 3)), detail: detail, now: now))
        #expect(SyncSchedule().needsDetail(pull: pull(running), detail: detail, now: now.addingTimeInterval(300)))
    }
}

struct AgentEventTests {
    @Test func aFinishedTurnFoldsItsWorkingStepsAway() {
        let start = Date(timeIntervalSince1970: 0)
        var log: [AgentEvent] = []
        for (offset, state) in [AgentState.done, .working, .working, .working].enumerated() {
            log = AgentEvent.log(log, adding: AgentEvent(at: start + Double(offset), state: state, reason: nil))
        }
        #expect(log.map(\.state) == [.working, .working, .working, .done])
        log = AgentEvent.log(log, adding: AgentEvent(at: start + 9, state: .done, reason: nil))
        #expect(log.map(\.state) == [.done, .done])
        log = AgentEvent.log(log, adding: AgentEvent(at: start + 10, state: .working, reason: nil))
        log = AgentEvent.log(log, adding: AgentEvent(at: start + 11, state: .blocked, reason: "Bash"))
        #expect(log.map(\.state) == [.blocked, .done, .done])
    }
}
