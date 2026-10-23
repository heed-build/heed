import Foundation
@testable import HeedCore
import Testing

/// A stand-in for the on-device model: answers what it is told to, and remembers what it was asked.
private final class FakeAdvisor: StartWorkAdvisor, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [StartWorkQuestion] = []
    private let answer: @Sendable (StartWorkQuestion) async throws -> StartWorkAdvice

    init(answer: @escaping @Sendable (StartWorkQuestion) async throws -> StartWorkAdvice) {
        self.answer = answer
    }

    var questions: [StartWorkQuestion] { lock.withLock { asked } }

    func advise(_ question: StartWorkQuestion) async throws -> StartWorkAdvice {
        lock.withLock { asked.append(question) }
        return try await answer(question)
    }
}

private let records = ["docs-toolkit", "ledger", "mobile", "infra"].map {
    RepoRecord(repo: Repo(org: "acme", name: $0), path: "/code/\($0)")
}

private func form(_ prompt: String = "", repos: [RepoRecord] = records, settings: WorkSettings = .default)
    -> StartWorkForm
{
    StartWorkForm(repos: repos, settings: settings, prompt: prompt)
}

private func type(_ text: String, into form: inout StartWorkForm) {
    for character in text {
        _ = form.handle(character == " " ? KeyStroke("Space") : KeyStroke(String(character)))
    }
}

struct StartWorkRepoAdviceTests {
    @Test func theModelsPickGoesOnTopWithWhyAndKeepsEveryOtherChip() throws {
        var start = form("look why deploys are slow")
        let question = try #require(start.question)
        #expect(question.candidates.map(\.id) == start.guesses.map(\.repo.id))
        let before = start.guesses.map(\.repo.id)
        start.apply(StartWorkAdvice(repo: "acme/infra", why: "Deploy pipelines live here."), for: question)
        #expect(start.guesses.first?.repo.id == "acme/infra")
        #expect(start.guesses.first?.reason.hasPrefix("Fits the prompt: Deploy pipelines live here.") == true)
        #expect(start.guesses.first?.advised == true)
        #expect(Set(start.guesses.map(\.repo.id)) == Set(before))
        #expect(start.guesses.count == before.count)
        #expect(start.selectedRepos == ["acme/infra"])
        #expect(start.guessedRepo == "acme/infra")
    }

    @Test func aRepoThePromptNamesIsNotAsked() throws {
        let start = form("fix the build in ledger")
        let question = try #require(start.question)
        #expect(!question.asksRepo)
        #expect(start.selectedRepos == ["acme/ledger"])
    }

    @Test func aNamedRepoIsKeptWhateverTheModelSays() {
        var start = form("fix the build in ledger")
        let question = StartWorkQuestion(prompt: start.prompt, candidates: [.init(id: "acme/infra")])
        start.apply(StartWorkAdvice(repo: "acme/infra"), for: question)
        // Answered as if asked: still, a named repo's guess wins once the prompt changes, and nothing named is lost.
        type("!", into: &start)
        #expect(start.selectedRepos == ["acme/ledger"])
        #expect(start.guesses.first?.repo.id == "acme/ledger")
    }

    @Test func aRepoYouPickedIsNotAskedNorChanged() {
        var start = form("look why deploys are slow")
        start.choose(repo: "acme/mobile")
        #expect(start.question?.asksRepo == false)
        start.apply(
            StartWorkAdvice(repo: "acme/infra"),
            for: StartWorkQuestion(prompt: start.prompt, candidates: [.init(id: "acme/infra")])
        )
        #expect(start.selectedRepos == ["acme/mobile"])
    }

    @Test func aPickThatIsNoCandidateChangesNothing() throws {
        var start = form("look why deploys are slow")
        let before = start.guesses
        try start.apply(StartWorkAdvice(repo: "acme/elsewhere"), for: #require(start.question))
        #expect(start.guesses == before)
    }

    @Test func anAnswerToAnOlderPromptIsDropped() throws {
        var start = form("look why deploys")
        let question = try #require(start.question)
        type(" are slow", into: &start)
        let before = start.guesses
        start.thinking = true
        start.apply(StartWorkAdvice(repo: "acme/infra", name: "slow-deploys"), for: question)
        #expect(start.guesses == before)
        #expect(start.thinking)
    }

    @Test func thePickStaysWhileYouTypeOn() throws {
        var start = form("look why deploys")
        try start.apply(StartWorkAdvice(repo: "acme/infra"), for: #require(start.question))
        type(" are slow", into: &start)
        #expect(start.selectedRepos == ["acme/infra"])
        // Until the prompt names a repo.
        type(" in mobile", into: &start)
        #expect(start.selectedRepos == ["acme/mobile"])
    }

    @Test func atMostTenCandidatesWithWhatIsKnownOfThem() throws {
        let many = (1 ... 14).map { RepoRecord(repo: Repo(org: "acme", name: "repo\($0)"), path: "/code/repo\($0)") }
        var start = form("make it faster", repos: many)
        start.hints = StartWorkHints(about: ["acme/repo1": "The first one."], recent: ["acme/repo1": ["Old work"]])
        let question = try #require(start.question)
        #expect(question.candidates.count == 10)
        let first = try #require(question.candidates.first { $0.id == "acme/repo1" })
        #expect(first.about == "The first one.")
        #expect(first.recent == ["Old work"])
    }

    @Test func mergeOnlyMovesThePick() {
        let guesses = records.enumerated().map { index, record in
            RepoGuess(repo: record, confidence: 40 - index * 10, reason: "r\(index).")
        }
        let merged = StartWork.merge(guesses, pick: "acme/mobile", why: nil)
        #expect(merged.map(\.repo.id) == ["acme/mobile", "acme/docs-toolkit", "acme/ledger", "acme/infra"])
        #expect(merged[0].confidence == 40)
        #expect(merged[0].reason == "Fits the prompt. r2.")
        #expect(StartWork.merge(guesses, pick: nil, why: "x") == guesses)
    }
}

struct StartWorkNameAdviceTests {
    @Test func cleansTheModelsSlug() {
        #expect(StartWork.cleanSlug("Spacing Tokens for Tooltips") == "spacing-tokens-for-tooltips")
        #expect(StartWork.cleanSlug("fix/currency-symbol") == "currency-symbol")
        #expect(StartWork.cleanSlug("slowDeploys") == "slow-deploys")
        #expect(StartWork.cleanSlug("fix-currency-symbol", prefixes: ["fix"]) == "currency-symbol")
        #expect(StartWork.cleanSlug("fix-currency-symbol", prefixes: ["docs"]) == "fix-currency-symbol")
        #expect(StartWork.cleanSlug("fix", prefixes: ["fix"]) == "fix")
        #expect(StartWork.cleanSlug("one two three four five six seven") == "one-two-three-four-five")
        #expect(StartWork.cleanSlug("  Ünïcode__and  -- dashes!! ") == "n-code-and-dashes")
        #expect(StartWork.cleanSlug("…") == nil)
        #expect(StartWork.cleanSlug("") == nil)
    }

    @Test func theModelsNameReplacesTheRulesUntilYouTypeOne() throws {
        var start = form("look why deploys are slow lately")
        #expect(start.name == "feature/look-why-deploys-slow")
        let question = try #require(start.question)
        #expect(question.asksName)
        start.apply(StartWorkAdvice(name: "slow-deploys", prefix: "perf"), for: question)
        #expect(start.name == "perf/slow-deploys")
        #expect(start.guessedName == "perf/slow-deploys")
        #expect(start.advised)
    }

    @Test func aNameYouTypedIsNotAskedNorReplaced() {
        var start = form("look why deploys are slow")
        _ = start.handle(KeyStroke("Tab"))
        _ = start.handle(KeyStroke("Tab"))
        #expect(start.field == .worktree)
        _ = start.handle(KeyStroke("i"))
        type("x", into: &start)
        let typed = start.name
        #expect(start.question?.asksName == false)
        start.apply(
            StartWorkAdvice(name: "slow-deploys", prefix: "perf"),
            for: StartWorkQuestion(prompt: start.prompt, asksName: true, prefixes: ["perf"])
        )
        #expect(start.name == typed)
    }

    @Test func aChatIsNeverAsked() {
        let start = StartWorkForm(repos: records, settings: .default, prompt: "what is this", chat: true)
        #expect(start.question == nil)
        #expect(form("  ").question == nil)
    }
}

struct StartWorkPrefixAdviceTests {
    @Test func theKeywordRuleWinsWhenItFires() throws {
        var start = form("fix the slow deploys")
        let question = try #require(start.question)
        #expect(question.prefixes.isEmpty)
        start.apply(StartWorkAdvice(name: "fix-slow-deploys", prefix: "docs"), for: question)
        #expect(start.name == "fix/slow-deploys")
        // Even when a prefix comes along unasked.
        let unasked = StartWorkAdvice(name: "slow-deploys", prefix: "docs")
        #expect(StartWork
            .branchName(for: "fix the slow deploys", prefixes: .default, advice: unasked) == "fix/slow-deploys")
        var none = BranchPrefixes.default
        none.defaultPrefix = ""
        #expect(StartWork.branchName(for: "deploys are slow", prefixes: none, advice: unasked) == "slow-deploys")
    }

    @Test func otherwiseTheModelPicksAmongTheConfiguredPrefixes() throws {
        let question = try #require(form("tooltips use the new spacing").question)
        #expect(question.prefixes == StartWork.prefixChoices(.default))
        #expect(question.prefixes.contains("feature"))
        let prefixes = BranchPrefixes.default
        let docs = StartWorkAdvice(name: "tooltip-spacing", prefix: "docs")
        #expect(StartWork
            .branchName(for: "tooltips use spacing", prefixes: prefixes, advice: docs) == "docs/tooltip-spacing")
        // A prefix that is not configured falls back to the default.
        let odd = StartWorkAdvice(name: "tooltip-spacing", prefix: "style")
        #expect(StartWork
            .branchName(for: "tooltips use spacing", prefixes: prefixes, advice: odd) == "feature/tooltip-spacing")
        // No name: the rule's words, under the model's prefix.
        let bare = StartWorkAdvice(prefix: "perf")
        #expect(StartWork.branchName(for: "deploys are slow", prefixes: prefixes, advice: bare) == "perf/deploys-slow")
        #expect(StartWork
            .branchName(for: "deploys are slow", prefixes: prefixes, advice: nil) == "feature/deploys-slow")
    }

    @Test func noDefaultPrefixMeansNoneIsAsked() throws {
        var settings = WorkSettings.default
        settings.prefixes.defaultPrefix = ""
        var start = form("tooltips use the new spacing", settings: settings)
        let question = try #require(start.question)
        #expect(question.prefixes.isEmpty)
        start.apply(StartWorkAdvice(name: "tooltip-spacing", prefix: "docs"), for: question)
        #expect(start.name == "tooltip-spacing")
    }

    @Test func choicesAreTheConfiguredPrefixesAndTheDefault() {
        let prefixes = BranchPrefixes(prefixes: ["fix": ["fix"]], defaultPrefix: "work")
        #expect(StartWork.prefixChoices(prefixes) == ["fix", "work"])
        #expect(StartWork.keywordPrefix(for: "Fix it", prefixes: prefixes) == "fix")
        #expect(StartWork.keywordPrefix(for: "look at it", prefixes: prefixes) == nil)
    }
}

@MainActor
struct StartWorkAdviceSchedulerTests {
    private let question = { (prompt: String) in StartWorkQuestion(prompt: prompt, asksName: true) }

    @Test func asksOnceTypingPausesWithTheLastQuestion() async {
        let advisor = FakeAdvisor { StartWorkAdvice(name: $0.prompt) }
        let scheduler = StartWorkAdviceScheduler(advisor: advisor, debounce: .milliseconds(50))
        var delivered: [String] = []
        let tasks = ["l", "lo", "loo"].map { prompt in
            scheduler.ask(question(prompt)) { _, advice in delivered.append(advice?.name ?? "") }
        }
        for task in tasks {
            await task?.value
        }
        #expect(advisor.questions.map(\.prompt) == ["loo"])
        #expect(delivered == ["loo"])
    }

    @Test func theSameQuestionIsNotAskedAgain() async {
        let advisor = FakeAdvisor { _ in StartWorkAdvice() }
        let scheduler = StartWorkAdviceScheduler(advisor: advisor, debounce: .zero)
        await scheduler.ask(question("a")) { _, _ in }?.value
        #expect(scheduler.ask(question("a")) { _, _ in } == nil)
        #expect(advisor.questions.count == 1)
    }

    @Test func anAnswerInFlightForAnOlderQuestionIsDropped() async {
        let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        let (release, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
        let advisor = FakeAdvisor { question in
            if question.prompt == "old" {
                startedContinuation.yield()
                for await _ in release {
                    break
                }
            }
            return StartWorkAdvice(name: question.prompt)
        }
        let scheduler = StartWorkAdviceScheduler(advisor: advisor, debounce: .zero)
        var delivered: [String] = []
        let old = scheduler.ask(question("old")) { _, advice in delivered.append(advice?.name ?? "") }
        for await _ in started {
            break
        }
        let new = scheduler.ask(question("new")) { _, advice in delivered.append(advice?.name ?? "") }
        releaseContinuation.yield()
        await old?.value
        await new?.value
        #expect(delivered == ["new"])
    }

    @Test func cancelDeliversNothingAndAFailureDeliversNil() async {
        struct Failure: Error {}
        let failing = FakeAdvisor { _ in throw Failure() }
        let scheduler = StartWorkAdviceScheduler(advisor: failing, debounce: .milliseconds(50))
        var delivered: [StartWorkAdvice?] = []
        let task = scheduler.ask(question("a")) { delivered.append($1) }
        scheduler.cancel()
        await task?.value
        #expect(delivered.isEmpty)
        #expect(failing.questions.isEmpty)
        await scheduler.ask(question("b")) { delivered.append($1) }?.value
        #expect(delivered == [nil])
        // Nil asks nothing and cancels what waits.
        let waiting = scheduler.ask(question("c")) { delivered.append($1) }
        #expect(scheduler.ask(nil) { delivered.append($1) } == nil)
        await waiting?.value
        #expect(delivered == [nil])
    }
}

struct StartWorkHintsTests {
    @Test func recentTitlesPerRepoAndBranchesNewestFirst() {
        let repo = Repo(org: "acme", name: "ledger")
        let day = Date(timeIntervalSince1970: 1_000_000)
        let sessions = (1 ... 5).map { index in
            Session(
                title: "Work \(index)", repos: [repo], branch: "fix/work-\(index)", agent: "claude",
                state: .init(.idle), lastActivity: day.addingTimeInterval(Double(index) * 60)
            )
        }
        let closed = [HistoryEntry(
            session: Session(
                title: "Newest",
                repos: [repo],
                branch: "feature/newest",
                agent: "claude",
                state: .init(.done)
            ),
            closedAt: day.addingTimeInterval(3600), outcome: .merged
        )]
        let hints = StartWorkHints.from(sessions: sessions, closed: closed)
        #expect(hints.recent["acme/ledger"] == ["Newest", "Work 5", "Work 4"])
        #expect(hints.branches == ["feature/newest", "fix/work-5", "fix/work-4", "fix/work-3", "fix/work-2"])
    }

    @Test func readmeSummaryIsTheFirstProse() {
        let readme = """
        ---
        title: x
        ---
        # Ledger

        [![CI](https://example.invalid/badge.svg)](https://example.invalid)
        <p align="center"><img src="logo.png"></p>

        > Invoicing backend: the billing API and payment webhooks.

        More text.
        """
        #expect(StartWorkHints.readmeSummary(readme) == "Invoicing backend: the billing API and payment webhooks.")
        #expect(StartWorkHints.readmeSummary("# Only a title\n\n```\ncode\n```") == "Only a title")
        #expect(StartWorkHints.readmeSummary("Title\n=====\n") == "Title")
        #expect(StartWorkHints.readmeSummary("") == nil)
        let long = String(repeating: "word ", count: 60)
        #expect(StartWorkHints.readmeSummary(long)?.count == 140)
    }
}

struct StartWorkOutcomeTests {
    @Test func recordsWhatWasGuessedAndWhatWasChosen() throws {
        var start = form("look why deploys are slow")
        try start.apply(
            StartWorkAdvice(repo: "acme/infra", name: "slow-deploys", prefix: "perf"),
            for: #require(start.question)
        )
        start.choose(repo: "acme/mobile")
        let at = Date(timeIntervalSince1970: 2_000_000)
        let outcome = try #require(start.outcome(at: at))
        #expect(outcome.guessedRepo == "acme/infra")
        #expect(outcome.guessedName == "perf/slow-deploys")
        #expect(outcome.guessedPrefix == "perf")
        #expect(outcome.repos == ["acme/mobile"])
        #expect(outcome.name == "perf/slow-deploys")
        #expect(outcome.prefix == "perf")
        #expect(outcome.agent == "claude")
        #expect(!outcome.planFirst)
        #expect(outcome.advised)
        #expect(StartWorkForm(repos: records, settings: .default, prompt: "x", chat: true).outcome(at: at) == nil)
        #expect(StartWorkOutcome.prefix(of: "plain") == nil)
        #expect(StartWorkOutcome.prefix(of: "/odd") == nil)
    }

    @Test func keptInHeedSqliteAndPrunedByAge() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = try EventLog(path: dir.appendingPathComponent("heed.sqlite").path)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = StartWorkOutcome(
            at: now.addingTimeInterval(-40 * 86400), prompt: "old", guessedRepo: nil, guessedName: "x", advised: false,
            repos: ["acme/a"], name: "x", agent: nil, planFirst: false
        )
        let new = StartWorkOutcome(
            at: now, prompt: "new", guessedRepo: "acme/a", guessedName: "fix/a", advised: true,
            repos: ["acme/a", "acme/b"], name: "fix/b", agent: "codex", planFirst: true
        )
        await log.record(old, keepDays: 365)
        #expect(try await log.startOutcomeCount() == 1)
        await log.record(new, keepDays: 30)
        #expect(try await log.startOutcomes() == [new])
        #expect(try await log.startOutcomeCount() == 1)
    }
}
