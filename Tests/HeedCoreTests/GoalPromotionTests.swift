import Foundation
@testable import HeedCore
import Testing

private let toolkit = Repo(org: "acme", name: "docs-toolkit")
private let website = Repo(org: "acme", name: "docs-website")

private func pull(_ number: Int, in repo: Repo = toolkit) -> PullRef {
    PullRef(repo: repo, number: number)
}

private func session(pulls: [PullRef] = [], repos: [Repo] = [toolkit], last: String? = nil, chat: Bool = false)
    -> Session
{
    var session = Session(
        id: "s1", title: "Fix broken anchors in redirects", prompt: "Fix broken anchors in redirects.\n\nAnd more.",
        repos: repos, branch: "fix/anchors", agent: "claude", state: ObservedState(.idle),
        workspace: chat ? .chat(ChatFolder(.scratch, path: "/tmp/c")) : .worktrees
    )
    session.trackedPRs = pulls
    session.lastMessage = last
    return session
}

private let found = "The redirects are fixed, but the website vendors its own slug code, so its old links still break. "
    + "That's a change in docs-website, and the sample site should prove both."

struct GoalGrowthTests {
    private func growth(_ session: Session, onGoal: Bool = false, setAside: Bool = false) -> GoalGrowth? {
        GoalGrowth.of(session, pullState: { $0.number == 3 ? .open : .merged }, onGoal: onGoal, setAside: setAside)
    }

    @Test func oneRepoOnePrAndNothingFoundIsNotGrowing() {
        #expect(growth(session(pulls: [pull(1)], last: "Done: the redirects resolve.")) == nil)
    }

    @Test func twoPullsASecondRepoOrFoundWorkEachGrow() throws {
        let pulls = try #require(growth(session(pulls: [pull(1), pull(2), pull(3)])))
        #expect(pulls.pulls == 3)
        #expect(pulls.merged == 2)
        #expect(pulls.signs == ["3 PRs"])
        // Two is enough.
        #expect(growth(session(pulls: [pull(1), pull(2)]))?.signs == ["2 PRs"])
        // A PR in another repo makes the second repo.
        let repos = try #require(growth(session(pulls: [pull(1, in: website)])))
        #expect(repos.signs == ["2nd repo"])
        let foundWork = try #require(growth(session(last: found)))
        #expect(foundWork.signs == ["found work it didn't start"])
        // Both sentences name work left, each as the clause that says it.
        #expect(foundWork.found == ["its old links still break", "a change in docs-website"])
    }

    @Test func chatsSessionsOnAGoalAndOnesSetAsideNeverGrow() {
        let big = session(pulls: [pull(1), pull(2)])
        #expect(growth(big, onGoal: true) == nil)
        #expect(growth(big, setAside: true) == nil)
        #expect(growth(session(pulls: [pull(1), pull(2)], repos: [], chat: true)) == nil)
    }

    @Test func foundWorkIsTheClauseThatSaysItAtMostThree() {
        #expect(GoalGrowth.found(in: nil).isEmpty)
        #expect(GoalGrowth.found(in: "All green. Merged.").isEmpty)
        let many = "A follow-up: the slugs. Out of scope: the theme. Not started: search. Another PR for tests. Done."
        #expect(GoalGrowth.foundSentences(in: many).count == 3)
        #expect(GoalGrowth.found(in: many) == ["the slugs", "the theme", "search"])
        let long = "This still needs " + String(repeating: "x", count: 100)
        #expect(GoalGrowth.found(in: long).first?.count == 48)
    }

    @Test func aModelNamesFoundWorkAndAFailureLeavesTheClauses() async {
        let json = #"{"items": ["the website's vendored slug copy.", " a sample-site proof ", ""]}"#
        let named = await FoundWork.summarise(["x"]) { request in
            #expect(request.call.schema != nil)
            return LLMResponse(text: json, json: Data(json.utf8), agent: "claude")
        }
        #expect(named == ["the website's vendored slug copy", "a sample-site proof"])
        #expect(await FoundWork.summarise([]) { _ in throw LLMError.disabled } == nil)
        #expect(await FoundWork.summarise(["x"]) { _ in throw LLMError.disabled } == nil)
        #expect(FoundWork.read(Data(#"{"items": []}"#.utf8)) == nil)
    }
}

struct GoalPromotionTests {
    @Test func theDraftCountsMergedPullsAsDoneAndSaysNothingRestarts() {
        let s = session(pulls: [pull(1), pull(2), pull(3)], last: found)
        let draft = GoalPromotion.draft(s, growth: nil) { ref in
            ref.number == 3 ? (.open, "Slug copy") : (.merged, ref.number == 1 ? "Redirects resolve" : "")
        }
        #expect(draft.statement == "Fix broken anchors in redirects.")
        #expect(draft.done.map(\.title) == ["Redirects resolve", "#2"])
        #expect(draft.found.count == 2)
        #expect(draft.lines.map(\.glyph) == [.goal, .done, .found, .stays])
        #expect(draft.lines[1].text == "its 2 merged PRs count as the first parts, done")
        #expect(draft.lines.last?.text == "this session stays as part 1; nothing restarts")
        let bare = GoalPromotion.draft(session(), growth: nil) { _ in nil }
        #expect(bare.lines.map(\.glyph) == [.goal, .stays])
    }

    @Test func promotingMakesTheGoalWithTheSessionOnItDonePartsAndPlannedOnes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heed-promote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ops = try GoalOps(
            path: dir.appendingPathComponent("goals.sqlite").path,
            files: GoalFiles(root: dir.appendingPathComponent("goals"))
        )
        let promotion = GoalPromotion(
            session: "s1", title: "Anchors survive moves", statement: "Every inbound anchor keeps working.",
            done: [.init(pull: pull(1), title: "Redirects resolve")], found: ["Vendored slug copy"]
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let goal = try await ops.promote(promotion, now: now)
        let snapshot = try await ops.snapshot()
        #expect(snapshot.links.contains { $0.goal == goal.id && $0.target == "s1" })
        let items = snapshot.items.filter { $0.goal == goal.id }
        let done = try #require(items.first { $0.title == "Redirects resolve" })
        #expect(done.placement?.column == .done)
        #expect(done.links.contains(GoalItem.Link(.pr, "acme/docs-toolkit#1")))
        #expect(items.first { $0.title == "Vendored slug copy" }?.placement?.column == .planned)
    }
}
