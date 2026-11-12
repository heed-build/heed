import Foundation
@testable import HeedCore
import Testing

/// Can close: a session is done with only when closing it loses nothing.
struct CloseReadinessTests {
    private let repo = Repo(org: "o", name: "r")

    private func pull(_ number: Int, _ state: PullRequest.State) -> PullRequest {
        PullRequest(
            ref: PullRef(repo: repo, number: number), title: "t", url: "", state: state, isDraft: false,
            headBranch: "b", review: nil, checks: CheckSummary(), unresolvedThreads: 0, updatedAt: Date()
        )
    }

    private func session(_ state: AgentState = .done, prs: [Int] = [1], chat: Bool = false) -> Session {
        var session = Session(
            title: "t", repos: [repo], branch: "b", agent: "claude", state: ObservedState(state),
            trackedPRs: prs.map { PullRef(repo: repo, number: $0) }
        )
        if chat { session.workspace = .chat(ChatFolder(.scratch, path: "/tmp/c")) }
        return session
    }

    private func check(
        _ session: Session, _ pulls: [PullRequest], pending: PendingChanges = PendingChanges(),
        followUps: [String]? = nil, group: SessionGroup = .parked
    ) -> CloseReadiness.Ready? {
        var github = GitHubState()
        github.pulls = pulls
        return CloseReadiness.check(session, pulls: github, pending: pending, followUps: followUps, group: group)
    }

    @Test func mergedAndCleanCanCloseAsMerged() {
        let ready = check(session(prs: [1, 2]), [pull(1, .merged), pull(2, .merged)])
        #expect(ready?.reason == "merged · nothing open")
        #expect(ready?.outcome == .merged)
        #expect(check(session(prs: [1, 2]), [pull(1, .merged), pull(2, .closed)])?.outcome == .closed)
    }

    @Test func anOpenOrUnknownPRKeepsItOpen() {
        #expect(check(session(prs: [1, 2]), [pull(1, .merged), pull(2, .open)]) == nil)
        #expect(check(session(prs: [1, 2]), [pull(1, .merged)]) == nil)
        #expect(check(session(prs: []), []) == nil)
    }

    @Test func workNotSharedOrLeftOpenKeepsItOpen() {
        let merged = [pull(1, .merged)]
        #expect(check(session(), merged, pending: PendingChanges(ahead: 1)) == nil)
        #expect(check(session(), merged, pending: PendingChanges(dirty: 2)) == nil)
        #expect(check(session(), merged, followUps: ["port the docs"]) == nil)
        #expect(check(session(), merged, followUps: []) != nil)
    }

    @Test func busyWaitingPinnedOrAChatIsNeverDone() {
        let merged = [pull(1, .merged)]
        #expect(check(session(.working), merged) == nil)
        #expect(check(session(.asking), merged) == nil)
        #expect(check(session(), merged, group: .pinned) == nil)
        #expect(check(session(chat: true), merged) == nil)
    }

    @Test func theBandSitsLastAndTakesItsSessionsOutOfTheirGroups() {
        let done = Session(id: "done", title: "d", repos: [repo], branch: "b", agent: "", state: ObservedState(.done))
        let live = Session(
            id: "live",
            title: "l",
            repos: [repo],
            branch: "b",
            agent: "",
            state: ObservedState(.working)
        )
        let pinned = Session(
            id: "pin", title: "p", repos: [repo], branch: "b", agent: "", state: ObservedState(.done), pinned: true
        )
        for view in [SessionsView.standard, SessionsView(grouping: .repo)] {
            let list = SessionList([done, live, pinned], view: view, closable: { $0.id != "live" })
            #expect(list.sections.last?.header == .canClose)
            #expect(list.sections.last?.sessions.map(\.id) == ["done"])
            #expect(list.sections.first?.sessions.map(\.id) == ["pin"])
            #expect(list.ordered.count == 3)
        }
    }
}
