import Foundation
@testable import HeedCore
import Testing

struct BrowseOriginsTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let docs = Repo(org: "acme", name: "docs")

    private func item(_ number: Int, kind: BrowseItem.Kind = .issue) -> BrowseItem {
        BrowseItem(
            repo: docs, number: number, kind: kind, title: ExternalText("t", source: .issueTitle, author: .unknown),
            state: .open, author: "mara", updatedAt: now
        )
    }

    private func goalItem(_ goal: String, _ kind: GoalItem.Link.Kind, _ target: String) -> GoalItem {
        GoalItem(
            id: "\(goal)/x", goal: goal, title: "x", source: .you, links: [.init(kind, target)], createdAt: now
        )
    }

    @Test func aSessionIsFoundByTheIssueItClosesAndThePullRequestItTracks() {
        let origins = BrowseOrigins.build(
            sessions: [
                .init(id: "s1", issues: [IssueRef(repo: docs, number: 7)], pulls: []),
                .init(id: "s2", issues: [], pulls: [PullRef(repo: docs, number: 9)]),
            ],
            goalItems: []
        )
        #expect(origins[item(7)].sessions == ["s1"])
        #expect(origins[item(9, kind: .pull)].sessions == ["s2"])
        #expect(origins[item(8)].isEmpty)
    }

    @Test func aGoalIsFoundByTheIssueOrPullRequestOneOfItsItemsLinksTo() {
        let origins = BrowseOrigins.build(
            sessions: [],
            goalItems: [
                goalItem("g1", .issue, "acme/docs#7"), goalItem("g1", .pr, "acme/docs#7"),
                goalItem("g2", .pr, "acme/docs#9"), goalItem("g3", .branch, "acme/docs#7"),
            ]
        )
        // g1 once, though two of its items link there; the branch link is not an item of Browse's.
        #expect(origins[item(7)].goals == ["g1"])
        #expect(origins[item(9, kind: .pull)].goals == ["g2"])
    }

    @Test func aSessionAndAGoalOnTheSameItemAreBothKept() {
        let origins = BrowseOrigins.build(
            sessions: [.init(id: "s1", issues: [IssueRef(repo: docs, number: 7)], pulls: [])],
            goalItems: [goalItem("g1", .issue, "acme/docs#7")]
        )
        #expect(origins[item(7)].sessions == ["s1"] && origins[item(7)].goals == ["g1"])
    }

    @Test func theQuickFiltersKeepWhatTheyNameAndNothingElse() {
        let origins = BrowseOrigins.build(
            sessions: [.init(id: "s1", issues: [IssueRef(repo: docs, number: 7)], pulls: [])],
            goalItems: [goalItem("g1", .issue, "acme/docs#8")]
        )
        let seven = item(7), eight = item(8), nine = item(9)
        #expect(BrowseWorkFilter.session.keeps(seven, hasRun: false, origins: origins))
        #expect(!BrowseWorkFilter.session.keeps(eight, hasRun: false, origins: origins))
        #expect(BrowseWorkFilter.goal.keeps(eight, hasRun: false, origins: origins))
        #expect(!BrowseWorkFilter.goal.keeps(seven, hasRun: false, origins: origins))
        #expect(BrowseWorkFilter.agent.keeps(nine, hasRun: true, origins: origins))
        #expect(!BrowseWorkFilter.agent.keeps(seven, hasRun: false, origins: origins))
    }
}
