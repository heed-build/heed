import Foundation
@testable import HeedCore
import Testing

/// An open PR's card: reviewers and their verdicts, the agent's part, heed's runs and switches, what waits for you.
struct PullCardTests {
    private let repo = Repo(org: "o", name: "r")
    private var ref: PullRef { PullRef(repo: repo, number: 7) }
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func pull(review: ReviewDecision? = nil, threads: Int = 0) -> PullRequest {
        PullRequest(
            ref: ref, title: "t", url: "", state: .open, isDraft: false, headBranch: "b", review: review,
            checks: CheckSummary(), unresolvedThreads: threads, updatedAt: t0
        )
    }

    private func detail(_ reviews: [(String, String, Double)]) -> PullDetail {
        PullDetail(
            ref: ref, title: "t", body: "", author: "me", baseBranch: "main", headBranch: "b", additions: 0,
            deletions: 0, commitCount: 1, headSHA: "0",
            reviews: reviews.map { .init(author: $0.0, state: $0.1, submittedAt: t0.addingTimeInterval($0.2)) },
            threads: [], failingChecks: [], checks: CheckSummary(), closes: [], fetchedAt: t0
        )
    }

    private func session(_ state: AgentState = .idle) -> Session {
        Session(title: "s", repos: [repo], branch: "b", agent: "claude", state: ObservedState(state))
    }

    private func card(
        _ pull: PullRequest, detail: PullDetail? = nil, items: [FeedbackItem.Status] = [], green: AutoFeed = .ask,
        state: AgentState = .idle, runs: [PilotRun] = [], ready: Bool = false
    ) -> PullCard {
        var settings = PilotSettings()
        settings.green = green
        let pipeline = PullFeedback(
            ref: ref, items: items.enumerated().map {
                FeedbackItem(id: "i\($0.offset)", kind: .check(name: "lint"), text: "x", status: $0.element)
            }
        )
        return PullCard.make(
            pull: pull, detail: detail, pipeline: pipeline, settings: settings, runs: runs, session: session(state),
            readyToMerge: ready
        )
    }

    @Test func eachReviewerShowsTheirLatestVerdictAndACommentDoesNotUndoIt() {
        let made = card(pull(review: .changesRequested, threads: 2), detail: detail([
            ("al", "CHANGES_REQUESTED", 1), ("jk", "APPROVED", 2), ("al", "COMMENTED", 3), ("me", "COMMENTED", 4),
            ("bo", "COMMENTED", 5),
        ]))
        #expect(made.reviewers.map(\.login) == ["al", "jk", "bo"])
        #expect(made.reviewers.map(\.verdict) == [.changes, .approved, .commented])
        #expect(made.review == "changes requested · 2 threads")
        #expect(card(pull(review: .approved)).review == "approved")
        #expect(card(pull(), items: [.new, .queued]).review == "2 new comments")
        #expect(card(pull()).review == "no review")
    }

    @Test func theAgentRowIsOnlyThereWhileSomethingWasSentToIt() {
        #expect(card(pull()).agent == nil)
        let working = card(pull(), items: [.sent, .sent, .resolved], state: .working)
        #expect(working.agent == "claude working on 2 sent items")
        #expect(working.agentWorking)
        #expect(card(pull(), items: [.sent]).agent == "1 item sent to claude")
    }

    @Test func whatWaitsForYouIsItemsToSendOrAMerge() {
        #expect(card(pull(), items: [.new, .queued, .sent]).call == .send(count: 2))
        // With green on auto heed sends them itself: nothing waits for you.
        #expect(card(pull(), items: [.new], green: .auto).call == nil)
        #expect(card(pull(), ready: true).call == .merge)
        #expect(card(pull()).call == nil)
    }

    @Test func heedsRunsAreItsOwnOldestFirstAtMostFive() {
        func run(_ minutes: Double, on other: Bool = false) -> PilotRun {
            PilotRun(
                ref: other ? PullRef(repo: repo, number: 8) : ref, sessionID: "s", goal: .green, agent: "codex",
                model: nil, startedAt: t0.addingTimeInterval(minutes * 60), items: 1, prBranch: "b", branch: "r",
                worktree: "/w", startSHA: nil
            )
        }
        let runs = (0 ..< 7).map { run(Double($0)) } + [run(99, on: true)]
        let made = card(pull(), runs: runs.reversed())
        #expect(made.runs.count == 5)
        #expect(made.runs.map(\.startedAt) == (2 ..< 7).map { t0.addingTimeInterval(Double($0) * 60) })
    }

    @Test func roundsShowOnceGreenIsOnOrUsed() {
        #expect(card(pull(), green: .off).rounds == nil)
        #expect(card(pull(), green: .ask).rounds == PullCard.Rounds(used: 0, of: PilotSettings().maxRounds))
    }
}
