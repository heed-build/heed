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
        #expect(pull.checks == CheckSummary(passed: 1, failed: 1, pending: 1, skipped: 1, failedNames: ["build"]))
        #expect(pull.checks.text == "build failed")
    }

    @Test func checkTexts() {
        #expect(CheckSummary().text == "no checks")
        #expect(CheckSummary(passed: 2, pending: 3).text == "2/5 running")
        #expect(CheckSummary(passed: 4).text == "4/4 passed")
        #expect(CheckSummary(failed: 2, failedNames: ["a", "b"]).text == "2 failed")
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
