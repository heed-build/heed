import Foundation
@testable import HeedCore
import Testing

/// What keeps a hook's message cheap: the sidebar rebuilt once per commit, the next tool of a working turn told apart
/// from a change that moves something, rows and PRs found by key, rules parsed once, presence written only on change.
struct HookPathTests {
    private let repo = Repo(org: "acme", name: "docs")
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func session(_ id: String, pinned: Bool = false, state: AgentState = .working) -> Session {
        Session(
            id: id, title: id, repos: [repo], branch: id, agent: "claude", state: ObservedState(state),
            pinned: pinned, lastActivity: base, createdAt: base
        )
    }

    private func pull(_ number: Int, title: String = "t") -> PullRequest {
        PullRequest(
            ref: PullRef(repo: repo, number: number), title: title, url: "", state: .open, isDraft: false,
            headBranch: "b", review: nil, checks: CheckSummary(), unresolvedThreads: 0, updatedAt: base
        )
    }

    // MARK: One rebuild per commit

    @Test func requestsInABatchRunTheWorkOnceAtItsEnd() {
        var order: [String] = []
        let work = Coalesced { order.append("work") }
        work.batch {
            work.request()
            order.append("body")
            work.request()
            work.request()
            work.request()
        }
        #expect(work.runs == 1)
        #expect(order == ["body", "work"])
    }

    @Test func outsideABatchEachRequestRunsAtOnce() {
        let work = Coalesced {}
        work.request()
        work.request()
        #expect(work.runs == 2)
        #expect(!work.batching)
    }

    @Test func nestedBatchesRunOnceWhenTheOutermostEnds() {
        let work = Coalesced {}
        work.batch {
            work.request()
            work.batch { work.request() }
            #expect(work.runs == 0)
            #expect(work.batching)
        }
        #expect(work.runs == 1)
    }

    @Test func aBatchWithoutRequestsRunsNothing() {
        let work = Coalesced {}
        work.batch {}
        #expect(work.runs == 0)
    }

    // MARK: The next tool of a working turn

    @Test func whatAnAgentIsDoingIsAnActivityOnlyChange() {
        let old = session("a")
        var next = old
        next.activity = "working · Bash"
        next.lastActivity = base.addingTimeInterval(5)
        next.state = ObservedState(.working, reason: "Bash")
        #expect(next.changedOnlyActivity(from: old))
        #expect(old.changedOnlyActivity(from: old))
    }

    @Test func aChangeThatMovesSomethingIsNot() {
        let old = session("a")
        var changes: [Session] = []
        var state = old
        state.state = ObservedState(.asking)
        changes.append(state)
        var title = old
        title.title = "renamed"
        changes.append(title)
        var pulls = old
        pulls.trackedPRs = [PullRef(repo: repo, number: 1)]
        changes.append(pulls)
        var turn = old
        turn.lastMessage = "done"
        changes.append(turn)
        var both = old
        both.activity = "working · Bash"
        both.parked = true
        changes.append(both)
        #expect(changes.count == 5)
        for change in changes {
            #expect(!change.changedOnlyActivity(from: old))
        }
        #expect(!session("b").changedOnlyActivity(from: old))
    }

    // MARK: Rows by id

    @Test func rowsAndPinsAreFoundByIDAsByScanning() {
        let sessions = [
            session("a"), session("b", pinned: true), session("c", state: .asking), session("d", pinned: true),
            session("e", state: .idle),
        ]
        let list = SessionList(sessions, closable: { $0.id == "e" })
        #expect(list.ordered.count == 5)
        for (index, session) in list.ordered.enumerated() {
            #expect(list.index(of: session.id) == index)
            #expect(list.pinIndex(of: session.id) == list.pins.firstIndex(of: session))
        }
        #expect(list.pins.count == 2)
        #expect(list.index(of: "missing") == nil)
        #expect(list.sections.last?.header == .canClose)
    }

    @Test func sortingBySizeAsksEachSessionsSizeOnce() {
        let sessions = (0 ..< 40).map { session("s\($0)") }
        var asked: [String: Int] = [:]
        let list = SessionList(sessions, view: SessionsView(sort: .size), size: { session in
            asked[session.id, default: 0] += 1
            return Int(session.id.dropFirst())!
        })
        #expect(asked.count == 40)
        #expect(asked.values.allSatisfy { $0 == 1 })
        #expect(list.ordered.first?.id == "s39")
        #expect(list.ordered.last?.id == "s0")
    }

    // MARK: PRs by ref

    @Test func aPullIsFoundByRefAndFollowsItsList() {
        var state = GitHubState(pulls: [pull(1), pull(2, title: "first"), pull(2, title: "second")])
        #expect(state.pull(PullRef(repo: repo, number: 2))?.title == "first")
        #expect(state.pull(PullRef(repo: repo, number: 3)) == nil)
        state.pulls.append(pull(3))
        #expect(state.pull(PullRef(repo: repo, number: 3)) != nil)
        state.pulls.removeAll { $0.ref.number == 1 }
        #expect(state.pull(PullRef(repo: repo, number: 1)) == nil)
        #expect(state.pull(PullRef(repo: repo, number: 3))?.ref.number == 3)
        state.pulls[0].title = "changed"
        #expect(state.pull(PullRef(repo: repo, number: 2))?.title == "changed")
    }

    @Test func theIndexTakesNoPartInEqualityOrTheCache() throws {
        let state = GitHubState(pulls: [pull(1), pull(2)])
        var same = GitHubState()
        same.pulls = [pull(1), pull(2)]
        #expect(state == same)
        #expect(state.hashValue == same.hashValue)
        let data = try JSONEncoder().encode(state)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("pullIndex") && !json.contains("positions"))
        let decoded = try JSONDecoder().decode(GitHubState.self, from: data)
        #expect(decoded == state)
        #expect(decoded.pull(PullRef(repo: repo, number: 2))?.ref.number == 2)
    }

    // MARK: Rules parsed once

    @Test func parsedRulesFollowTheirLines() {
        var settings = AttentionSettings(rules: ["mention boost 3"])
        #expect(settings.parsedRules == AttentionRules(lines: ["mention boost 3"]))
        #expect(settings.parsedRules.rules.count == 1)
        settings.rules = ["mention boost 3", "assigned ignore"]
        #expect(settings.parsedRules == AttentionRules(lines: ["mention boost 3", "assigned ignore"]))
        #expect(settings.parsedRules.rules.count == 2)
        settings.rules.removeAll()
        #expect(settings.parsedRules.rules.isEmpty)
        #expect(settings == AttentionSettings())
    }

    // MARK: Presence written on change only

    @Test func presenceChangesOnlyWhenItWouldMoveAPane() {
        var presence = AgentPresence()
        for (state, pane) in [
            (AgentState.working, "p1"),
            (.working, "p1"),
            (.idle, "p1"),
            (.exited, "p1"),
            (.exited, "p1"),
            (.exited, "p2"),
            (.asking, "p2"),
        ] {
            let before = presence
            let changes = presence.changes(observing: state, in: pane)
            presence.observed(state, in: pane)
            #expect(changes == (presence != before), "\(state) in \(pane)")
        }
        #expect(presence.isRunning("p2"))
        #expect(!presence.isRunning("p1"))
    }
}
