import Foundation
@testable import HeedCore
import Testing

/// A session's links: its PRs and issues, in order, and what gB does with them.
struct LinksTests {
    private let repo = Repo(org: "o", name: "r")
    private let other = Repo(org: "a", name: "b")

    @Test func closingKeywordsInEveryForm() {
        let text = """
        Fixes #12. Closes a/b#3, resolved: https://github.com/o/r/issues/4
        fixed #12 again; mentions #99 without a keyword. Close #7
        """
        #expect(IssueLinks.referenced(in: text, defaultRepo: repo) == [
            IssueRef(repo: repo, number: 12), IssueRef(repo: other, number: 3), IssueRef(repo: repo, number: 4),
            IssueRef(repo: repo, number: 7),
        ])
        // Without a repo to resolve it in, a bare #N is left out.
        #expect(IssueLinks.referenced(in: "Fixes #12", defaultRepo: nil).isEmpty)
        #expect(IssueRef(url: "https://github.com/o/r/issues/5/") == IssueRef(repo: repo, number: 5))
        #expect(IssueRef(url: "https://github.com/o/r/pull/5") == nil)
    }

    @Test func issuesComeFromHandThePromptAndThePRsWithoutDuplicates() {
        let issues = IssueLinks.issues(
            added: [IssueRef(repo: other, number: 1)], prompt: "Fixes #2", defaultRepo: repo,
            closedByPulls: [IssueRef(repo: repo, number: 2), IssueRef(repo: repo, number: 3)],
            hidden: [IssueRef(repo: repo, number: 3)]
        )
        #expect(issues == [IssueRef(repo: other, number: 1), IssueRef(repo: repo, number: 2)])
    }

    @Test func openPRsThenMergedThenClosedThenIssues() {
        let pulls = [1, 2, 3].map { PullRef(repo: repo, number: $0) }
        let states: [Int: PullRequest.State] = [1: .merged, 2: .closed, 3: .open]
        let issues = [IssueRef(repo: repo, number: 10), IssueRef(repo: repo, number: 11)]
        let links = IssueLinks.ordered(
            pulls: pulls, state: { states[$0.number] }, issues: issues, closed: { $0.number == 10 }
        )
        #expect(links == [
            .pull(pulls[2]), .pull(pulls[0]), .pull(pulls[1]), .issue(issues[1]), .issue(issues[0]),
        ])
        #expect(SessionLink.repo(repo).url == "https://github.com/o/r")
        #expect(IssueLinks
            .compareURL(repo: repo, branch: "fix/a b") == "https://github.com/o/r/compare/fix/a%20b?expand=1")
    }

    @Test func thePickerOpensOneByNumberOrAll() {
        let links: [SessionLink] = [.pull(PullRef(repo: repo, number: 1)), .issue(IssueRef(repo: repo, number: 2))]
        var picker = LinkPicker(title: "t", links: links)
        #expect(picker.handle(KeyStroke("2")) == .open([links[1]]))
        #expect(picker.handle(KeyStroke("5")) == .handled)
        #expect(picker.handle(KeyStroke("j")) == .handled)
        #expect(picker.cursor == 1)
        #expect(picker.handle(KeyStroke("j")) == .handled)
        #expect(picker.cursor == 1)
        #expect(picker.handle(KeyStroke("CR")) == .open([links[1]]))
        #expect(picker.handle(KeyStroke("a")) == .open(links))
        #expect(picker.handle(.escape) == .cancel)
    }

    @Test func heedIssueAddAndOldSessionsStillLoad() throws {
        #expect(try HookCommandLine.parse(["issue", "add", "https://github.com/o/r/issues/3"])
            == [.issueAdd(url: "https://github.com/o/r/issues/3")])
        #expect(throws: HookCommandLine.UsageError.self) {
            try HookCommandLine.parse(["issue", "add", "https://github.com/o/r/pull/3"])
        }
        let session = Session(title: "t", repos: [repo], branch: "b", agent: "claude", state: ObservedState(.idle))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        json["issues"] = nil
        json["hiddenIssues"] = nil
        let old = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.issues.isEmpty && old.hiddenIssues.isEmpty)
    }
}
