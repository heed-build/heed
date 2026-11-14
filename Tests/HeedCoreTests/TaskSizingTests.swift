import Foundation
@testable import HeedCore
import Testing

/// Answers the size question with fixed probabilities, and counts what it was asked.
private final class SizeDecider: Decider, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let probabilities: [String: Double]?

    init(_ probabilities: [String: Double]?) {
        self.probabilities = probabilities
    }

    var asked: Int { lock.withLock { count } }

    func decide(subject _: String, state _: String, questions: [String: Question]) async throws -> [String: Answer] {
        lock.withLock { count += 1 }
        guard let probabilities else { throw DeciderError.off }
        let best = probabilities.max { $0.value < $1.value }?.key
        return questions.mapValues { _ in Answer(choice: best, probabilities: probabilities, confidence: 0.8) }
    }
}

private let records = ["docs-toolkit", "docs-website"].map {
    RepoRecord(repo: Repo(org: "acme", name: $0), path: "/code/\($0)")
}

private let big = "Make anchors survive page moves everywhere: redirects resolve to the right heading, the build fails on "
    + "a broken anchor, the docs site keeps old links working, and the sample site proves it."

private func facts(_ json: String) -> TaskSizer.Run {
    { _ in LLMResponse(
        text: json,
        json: Data(json.utf8),
        agent: "claude",
        model: "claude-haiku-4-5",
        cost: 0.0012,
        duration: 1.8
    ) }
}

private let goalFacts = facts(#"{"parts": 4, "repos": 2, "at_once": 3, "hours": 10, "title": "Anchors survive moves"}"#)

private func goalSizing(_ prompt: String = big) -> TaskSizing {
    TaskSizing(
        prompt: TaskSizer.key(prompt), kind: .goal, goal: 0.8,
        facts: TaskSizeFacts(parts: 4, repos: 2, atOnce: 3, hours: 10, title: "Anchors survive moves"),
        model: "claude-haiku-4-5", seconds: 1.8, cost: 0.0012
    )
}

private func sizingForm(_ prompt: String = big) -> StartWorkForm {
    var form = StartWorkForm(repos: records, settings: .default, prompt: prompt)
    form.sizeCheck = true
    return form
}

struct TaskSizerTests {
    @Test func shortPromptsAreNeverSized() async {
        let decider = SizeDecider(["goal": 1])
        #expect(!TaskSizer.worthSizing("fix the flaky link checker in docs-toolkit"))
        let sizing = await TaskSizer.size(
            prompt: "fix the flaky link checker", repos: [], decider: decider, run: goalFacts
        )
        #expect(sizing == nil)
        #expect(decider.asked == 0)
    }

    @Test func aLikelyGoalGetsItsFactsAndTheCallsCost() async throws {
        let sizing = try #require(await TaskSizer.size(
            prompt: big, repos: ["acme/docs-toolkit"], decider: SizeDecider(["goal": 0.7, "session": 0.3]),
            run: goalFacts
        ))
        #expect(sizing.kind == .goal)
        #expect(sizing.facts == TaskSizeFacts(parts: 4, repos: 2, atOnce: 3, hours: 10, title: "Anchors survive moves"))
        #expect(sizing.callLabel == "haiku · 2 s · $0.001")
        #expect(sizing.facts?.time.value == "1")
        #expect(sizing.facts?.time.unit == "day+")
    }

    @Test func aSessionAskNoFactsAndOnePartIsASessionAfterAll() async throws {
        actor Calls {
            var count = 0
            func add() { count += 1 }
        }
        let calls = Calls()
        let session = try #require(await TaskSizer.size(
            prompt: big, repos: [], decider: SizeDecider(["session": 0.9, "goal": 0.1]),
            run: { _ in
                await calls.add()
                return LLMResponse(text: "", agent: "claude")
            }
        ))
        #expect(session.kind == .session)
        #expect(session.facts == nil)
        #expect(await calls.count == 0)
        let small = try #require(await TaskSizer.size(
            prompt: big, repos: [], decider: SizeDecider(["goal": 0.6, "session": 0.4]),
            run: facts(#"{"parts": 1, "repos": 1, "at_once": 1, "hours": 3, "title": "x"}"#)
        ))
        #expect(small.kind == .session)
    }

    @Test func noDeciderMeansNoSizingAndBadFactsKeepTheVerdict() async throws {
        #expect(await TaskSizer.size(prompt: big, repos: [], decider: SizeDecider(nil), run: goalFacts) == nil)
        let sizing = try #require(await TaskSizer.size(
            prompt: big, repos: [], decider: SizeDecider(["goal": 0.9]), run: facts("not json")
        ))
        #expect(sizing.kind == .goal)
        #expect(sizing.facts == nil)
        #expect(sizing.callLabel == nil)
    }

    @Test func classifyNeedsHalfForAGoalAndReadsAChat() {
        #expect(TaskSizer.classify(nil).kind == .session)
        let chat = Answer(choice: "chat", probabilities: ["chat": 0.6, "session": 0.2, "goal": 0.2], confidence: 1)
        #expect(TaskSizer.classify(chat).kind == .chat)
        let close = Answer(choice: "session", probabilities: ["session": 0.55, "goal": 0.45], confidence: 1)
        #expect(TaskSizer.classify(close).kind == .session)
        let goal = Answer(choice: "goal", probabilities: ["session": 0.5, "goal": 0.5], confidence: 1)
        #expect(TaskSizer.classify(goal).kind == .goal)
    }

    @Test func factsAreKeptInRange() throws {
        let read = try #require(TaskSizer.facts(from: Data(
            #"{"parts": 99, "repos": 0, "at_once": 3, "hours": -2, "title": "  Two\nlines  "}"#.utf8
        )))
        #expect(read.parts == 20)
        #expect(read.repos == 1)
        #expect(read.hours == 0)
        #expect(read.title == "Two lines")
        #expect(TaskSizer.facts(from: Data(#"{"repos": 2}"#.utf8)) == nil)
        #expect(TaskSizeFacts(parts: 2, repos: 1, atOnce: 1, hours: 0.4).time == ("~20", "min"))
        #expect(TaskSizeFacts(parts: 2, repos: 1, atOnce: 1, hours: 5.4).time == ("5", "h"))
        #expect(TaskSizeFacts(parts: 2, repos: 1, atOnce: 1, hours: 30).time == ("3", "days+"))
    }

    @Test @MainActor func theSchedulerSizesTheLatestPromptOnceAndHurriesOnRequest() async {
        actor Asked {
            var keys: [String] = []
            func add(_ key: String) { keys.append(key) }
        }
        let asked = Asked()
        let scheduler = TaskSizeScheduler(debounce: .milliseconds(20)) { key in
            await asked.add(key)
            return TaskSizing(prompt: key, kind: .goal)
        }
        var delivered: [String] = []
        scheduler.ask("a b", deliver: { key, _ in delivered.append(key) })
        let last = scheduler.ask("a b c", deliver: { key, _ in delivered.append(key) })
        #expect(scheduler.ask("a b c", deliver: { _, _ in }) == nil)
        await last?.value
        #expect(delivered == ["a b c"])
        #expect(await asked.keys == ["a b c"])
        // ⌘↩ asks again at once, even for the same prompt, but only once.
        let now = scheduler.ask("a b c", now: true, deliver: { key, _ in delivered.append(key) })
        #expect(now != nil)
        #expect(scheduler.ask("a b c", now: true, deliver: { _, _ in }) == nil)
        await now?.value
        #expect(delivered == ["a b c", "a b c"])
    }
}

struct StartWorkSizeCardTests {
    @Test func aSmallTaskStartsAsBeforeWithNoQuestion() {
        var form = sizingForm("fix the flaky link checker in docs-toolkit")
        #expect(form.sizeQuestion == nil)
        guard case .start = form.handle(KeyStroke("CR", .command)) else {
            Testing.Issue.record("expected start")
            return
        }
    }

    @Test func sizingOffChatsAndPromotionsAreNeverSized() {
        var off = StartWorkForm(repos: records, settings: .default, prompt: big)
        #expect(off.sizeQuestion == nil)
        guard case .start = off.handle(KeyStroke("CR", .command)) else {
            Testing.Issue.record("expected start")
            return
        }
        var chat = StartWorkForm(repos: records, settings: .default, prompt: big, chat: true)
        chat.sizeCheck = true
        #expect(chat.sizeQuestion == nil)
    }

    @Test func commandReturnOnAnUnsizedPromptSizesFirstThenStartsWhenItIsNoGoal() {
        var form = sizingForm()
        #expect(form.handle(KeyStroke("CR", .command)) == .sizeFirst)
        #expect(form.waitingForSize)
        let key = TaskSizer.key(big)
        guard case .start = form.sized(TaskSizing(prompt: key, kind: .session), for: key) else {
            Testing.Issue.record("expected start once sized")
            return
        }
        // Sized now: ⌘↩ starts at once.
        guard case .start = form.handle(KeyStroke("CR", .command)) else {
            Testing.Issue.record("expected start")
            return
        }
    }

    @Test func aSecondCommandReturnDoesNotWaitAndAFailedSizingStarts() {
        var form = sizingForm()
        #expect(form.handle(KeyStroke("CR", .command)) == .sizeFirst)
        guard case .start = form.handle(KeyStroke("CR", .command)) else {
            Testing.Issue.record("expected start without waiting")
            return
        }
        var failed = sizingForm()
        _ = failed.handle(KeyStroke("CR", .command))
        guard case .start = failed.sized(nil, for: TaskSizer.key(big)) else {
            Testing.Issue.record("expected start after a failed sizing")
            return
        }
    }

    @Test func aGoalShowsTheCardAndCommandReturnMakesTheGoal() {
        var form = sizingForm()
        #expect(form.handle(KeyStroke("CR", .command)) == .sizeFirst)
        #expect(form.sized(goalSizing(), for: TaskSizer.key(big)) == .handled)
        #expect(form.showsSizeCard)
        guard case let .goal(goal) = form.handle(KeyStroke("CR", .command)) else {
            Testing.Issue.record("expected a goal")
            return
        }
        #expect(goal.title == "Anchors survive moves")
        #expect(goal.statement == big)
        #expect(goal.repos == form.selectedRepos)
    }

    @Test func optionReturnStartsASessionAndControlReturnAChat() {
        var form = sizingForm()
        _ = form.sized(goalSizing(), for: TaskSizer.key(big))
        guard case let .start(plan) = form.handle(KeyStroke("CR", .option)) else {
            Testing.Issue.record("expected a session")
            return
        }
        #expect(plan.chat == nil)
        #expect(!form.showsSizeCard)
        var chat = sizingForm()
        _ = chat.sized(goalSizing(), for: TaskSizer.key(big))
        guard case let .start(plan) = chat.handle(KeyStroke("CR", .control)) else {
            Testing.Issue.record("expected a chat")
            return
        }
        #expect(plan.chat != nil)
    }

    @Test func withoutTheCardOptionReturnStillTypesANewline() {
        var form = sizingForm()
        _ = form.handle(KeyStroke("CR", .option))
        #expect(form.prompt.hasSuffix("\n"))
    }

    @Test func movingToTheFieldsPutsTheCardAwayForThatPrompt() {
        var form = sizingForm()
        _ = form.sized(goalSizing(), for: TaskSizer.key(big))
        _ = form.handle(.escape)
        #expect(form.handle(KeyStroke("j")) == .handled)
        #expect(!form.showsSizeCard)
        #expect(form.field != .prompt)
        // ⌘↩ now starts the work it shows.
        guard case .start = form.handle(KeyStroke("CR", .command)) else {
            Testing.Issue.record("expected start")
            return
        }
    }

    @Test func anAnswerForAPromptNoLongerTypedIsDropped() {
        var form = sizingForm()
        #expect(form.sized(
            goalSizing("something else entirely that is long enough to be sized at all ok"),
            for: "something else entirely"
        ) == .handled)
        #expect(form.sizing == nil)
        #expect(StartGoal.title(from: "make anchors survive page moves everywhere and then some more: rest")
            == "Make anchors survive page moves everywhere and then")
    }
}
