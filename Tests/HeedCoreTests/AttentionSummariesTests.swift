import Foundation
@testable import HeedCore
import Testing

struct AttentionSummariesTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let docs = Repo(org: "acme", name: "docs")

    private func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    private func comment(_ id: String, _ login: String, _ minutes: Double, _ text: String = "") -> ThreadComment {
        ThreadComment(
            id: id, author: ThreadAuthor(login: login), createdAt: ago(minutes),
            bodyHTML: "<p>\(text.isEmpty ? id : text)</p>"
        )
    }

    private func thread(_ comments: [ThreadComment], state: String = "OPEN") -> ThreadConversation {
        ThreadConversation(
            repo: docs, number: 41, kind: .pr, title: "Validate links", url: "https://github.com/acme/docs/pull/41",
            state: state, author: ThreadAuthor(login: "maria"), createdAt: ago(600),
            bodyHTML: "<p>Validates <code>every</code> link &amp; anchor.</p>", comments: comments, fetchedAt: now
        )
    }

    private func item(
        _ id: String = "acme/docs#41", kind: AttentionItem.Kind = .pr, minutes: Double = 5, others: Double? = nil
    ) -> AttentionItem {
        AttentionItem(
            id: id, kind: kind, repo: docs, number: 41, title: id, url: nil, reasons: [.reviewRequested],
            updatedAt: ago(minutes), activity: others.map { ThreadActivity(others: ago($0)) }
        )
    }

    private func summary(
        covers minutes: Double, since: Double? = 60, state: String = "open", written: Double = 1
    ) -> CatchUpSummary {
        CatchUpSummary(
            text: "- Asks one thing.\n- Checks pass.", since: since.map(ago), coversUpTo: ago(minutes), count: 1,
            state: state, writtenAt: ago(written), agent: "claude", model: "haiku"
        )
    }

    // MARK: Your own comments are seen

    @Test func yourOwnCommentIsNotNewAndNeitherIsWhatCameBefore() {
        let comments = [comment("a", "maria", 30), comment("b", "you", 20), comment("c", "maria", 4)]
        // Looked 25 minutes ago, then answered at 20: only Maria's later comment is new.
        let fold = ThreadFold.compute(comments, seenAt: ago(25), viewer: "You")
        #expect(fold == ThreadFold(folded: 2, divider: 2, newCount: 1))
        // Without the viewer, your answer counted as new (the bug).
        #expect(ThreadFold.compute(comments, seenAt: ago(25)).newCount == 2)
        // Never looked in heed, but you answered on GitHub: what came before your answer is read.
        #expect(ThreadFold.compute(comments, seenAt: nil, viewer: "you") == ThreadFold(
            folded: 2,
            divider: 2,
            newCount: 1
        ))
        // Your answer last: nothing is new.
        let answered = [comment("a", "maria", 30), comment("b", "you", 2)]
        #expect(ThreadFold.compute(answered, seenAt: ago(60), viewer: "you").newCount == 0)
    }

    // MARK: What a catch-up covers

    @Test func onlyTheNewCommentsByOthersSinceYouLooked() {
        let conversation = thread([
            comment("a", "maria", 90, "Old question"), comment("b", "you", 20, "My answer"),
            comment("c", "maria", 10, "One more question"), comment("d", "ci-bot", 3, "Checks pass"),
        ])
        let input = CatchUp.input(conversation, seenAt: ago(60), viewer: "you")
        #expect(input.since == ago(20))
        #expect(input.comments.map(\.id) == ["c", "d"])
        #expect(input.count == 2)
        #expect(input.coversUpTo == ago(3))
        #expect(input.state == "open" && !input.stateChanged)

        let inputs = CatchUp.inputs(for: item(), conversation: conversation, input: input)
        #expect(inputs.timeline == ["maria commented: One more question", "ci-bot commented: Checks pass"])
        // Neither the old comments nor the description go to the model.
        #expect(!inputs.prompt.contains("Old question") && !inputs.prompt.contains("My answer"))
        #expect(!inputs.prompt.contains("Validates"))
        #expect(inputs.prompt.contains("Only what came after follows: 2 new."))
    }

    @Test func theWholeThreadWhenYouNeverLookedOrNothingIsNew() {
        let conversation = thread([comment("a", "maria", 90), comment("b", "sam", 30)])
        let never = CatchUp.input(conversation, seenAt: nil, viewer: "you")
        #expect(never.since == nil && never.comments.map(\.id) == ["a", "b"] && never.count == 2)
        let inputs = CatchUp.inputs(for: item(), conversation: conversation, input: never)
        #expect(inputs.prompt.contains("Validates every link & anchor."))
        #expect(inputs.prompt.contains("never looked"))

        let nothingNew = CatchUp.input(conversation, seenAt: ago(10), viewer: "you")
        #expect(nothingNew.since == nil && nothingNew.count == 2)
    }

    @Test func aNewStateIsWhatChangedEvenWithoutComments() {
        let conversation = thread([comment("a", "maria", 90)], state: "MERGED")
        let input = CatchUp.input(conversation, seenAt: ago(30), viewer: "you", previous: summary(covers: 90))
        #expect(input.since == ago(30) && input.comments.isEmpty && input.stateChanged)
        #expect(CatchUp.inputs(for: item(), conversation: conversation, input: input).prompt
            .contains("State: merged (was open when they looked)"))
    }

    // MARK: Up to date or stale

    @Test func staleWhenSomeoneElseCommentedAfterWhatItCovers() {
        let written = summary(covers: 10)
        #expect(CatchUp.freshness(nil, item: item(), conversation: nil, detail: nil, viewer: "you") == .missing)
        let same = thread([comment("a", "maria", 10)])
        #expect(CatchUp.freshness(written, item: item(), conversation: same, detail: nil, viewer: "you") == .upToDate)
        // Your own comment after it does not make it stale.
        let mine = thread([comment("a", "maria", 10), comment("b", "you", 2)])
        #expect(CatchUp.freshness(written, item: item(), conversation: mine, detail: nil, viewer: "you") == .upToDate)
        let two = thread([comment("a", "maria", 10), comment("b", "sam", 4), comment("c", "maria", 2)])
        #expect(CatchUp.freshness(written, item: item(), conversation: two, detail: nil, viewer: "you")
            == .stale(new: 2, stateChanged: false))
        // Merged since: stale for the state.
        #expect(CatchUp.freshness(
            written, item: item(), conversation: thread([comment("a", "maria", 10)], state: "MERGED"), detail: nil,
            viewer: "you"
        ) == .stale(new: 0, stateChanged: true))
    }

    @Test func staleFromWhatTheSyncKnowsBeforeTheThreadLoads() {
        let written = summary(covers: 10)
        let detail = ThreadDetail(url: "u", comments: [
            .init(author: "maria", text: "x", at: ago(10)), .init(author: "you", text: "y", at: ago(5)),
            .init(author: "sam", text: "z", at: ago(3)),
        ], updatedAt: ago(3))
        #expect(CatchUp.freshness(written, item: item(), conversation: nil, detail: detail, viewer: "you")
            == .stale(new: 1, stateChanged: false))
        // Only the item's activity says someone else spoke since.
        #expect(CatchUp.freshness(written, item: item(others: 2), conversation: nil, detail: nil, viewer: "you")
            == .stale(new: 1, stateChanged: false))
        #expect(CatchUp.freshness(written, item: item(others: 20), conversation: nil, detail: nil, viewer: "you")
            == .upToDate)
    }

    // MARK: When one is due

    private func due(
        _ item: AttentionItem, _ trigger: SummaryQueue.Trigger, mode: AttentionSummaryMode = .ahead,
        modelCalls: Bool = true, freshness: CatchUpFreshness = .missing, failure: SummaryFailure? = nil,
        running: Bool = false
    ) -> Bool {
        SummaryQueue.due(
            item, trigger: trigger, mode: mode, modelCalls: modelCalls, freshness: freshness, failure: failure,
            running: running, now: now, backoff: 600
        )
    }

    @Test func dueByModeAndFreshness() {
        let pr = item()
        #expect(due(pr, .ahead))
        #expect(due(pr, .open))
        #expect(due(pr, .open, freshness: .stale(new: 1, stateChanged: false)))
        #expect(!due(pr, .open, freshness: .upToDate))
        // ↻ rewrites one that is up to date.
        #expect(due(pr, .asked, freshness: .upToDate))
        // "open" writes none ahead; "off" none at all, and neither does model calls being off.
        #expect(!due(pr, .ahead, mode: .open))
        #expect(due(pr, .open, mode: .open))
        #expect(!due(pr, .asked, mode: .off))
        #expect(!due(pr, .open, modelCalls: false))
        // Never for agents, goals or CI runs; never twice at once.
        #expect(!due(item("ag", kind: .agent), .asked))
        #expect(!due(item("go", kind: .goal), .open))
        #expect(!due(item("ci", kind: .ci), .ahead))
        #expect(!due(pr, .open, running: true))
    }

    @Test func aFailureWaitsForItsTimeOrANewUpdate() {
        let pr = item(minutes: 30)
        let limited = SummaryFailure(
            kind: .rateLimited,
            text: "",
            until: now.addingTimeInterval(60),
            at: ago(1),
            forUpdate: ago(30)
        )
        #expect(!due(pr, .open, failure: limited))
        #expect(due(pr, .asked, failure: limited))
        // The thread changed since it failed: try again.
        #expect(due(item(minutes: 2), .open, failure: limited))
        // No time named: after the back-off (10 minutes here).
        let failed = SummaryFailure(kind: .failed, text: "", at: ago(5), forUpdate: ago(30))
        #expect(!due(pr, .ahead, failure: failed))
        #expect(due(pr, .ahead, failure: SummaryFailure(kind: .failed, text: "", at: ago(11), forUpdate: ago(30))))
    }

    // MARK: The ahead queue

    @Test func aheadIsNewestFirstAndStopsAtTheBudget() {
        let items = [item("a", minutes: 30), item("b", minutes: 2), item("c", minutes: 10), item("d", minutes: 1)]
        let new = AttentionRanking.entries(
            live: items, rules: AttentionRules(lines: []), marks: [:], viewer: "you", now: now
        )
        let plan = SummaryQueue.ahead(new, budget: 2) { $0.id != "d" }
        #expect(plan.ids == ["b", "c"])
        #expect(plan.cut == 1)
        let none = SummaryQueue.ahead(new, budget: 0) { _ in true }
        #expect(none.ids.isEmpty && none.cut == 4)
    }

    @Test func theBudgetIsWhatTheDayLeavesLessAReserve() {
        var settings = LLMSettings()
        settings.dailyCalls = 100
        settings.dailyDollars = 1
        let spent: [String: (calls: Int, dollars: Double)] = ["claude": (85, 0.2), "codex": (10, 1.5)]
        // claude has 15 left, codex is past its dollars: 15 less the reserve of 10.
        #expect(SummaryQueue.budget(settings: settings, spent: spent, agents: ["claude", "codex"]) == 5)
        // Never more than one run's worth.
        #expect(SummaryQueue.budget(settings: settings, spent: [:], agents: ["claude", "codex"]) == 25)
        settings.agent = "codex"
        #expect(SummaryQueue.budget(settings: settings, spent: spent, agents: ["claude", "codex"]) == 0)
        settings.agent = nil
        settings.enabled = false
        #expect(SummaryQueue.budget(settings: settings, spent: [:], agents: ["claude"]) == 0)
    }

    @Test func progressSaysWhichOfHowMany() {
        #expect(SummaryProgress(total: 5, done: 1).text == "summarizing 2 of 5")
        #expect(SummaryProgress(total: 5, done: 5).text == "summarizing 5 of 5")
    }

    // MARK: The runner's reasons

    @Test func aFailureSaysTheRunnersReason() throws {
        let limited = try #require(SummaryFailure.of(
            LLMError.noAgent(reasons: ["codex: not logged in", "claude: rate limited until 14:10"]), at: now,
            forUpdate: now
        ))
        #expect(limited.kind == .rateLimited)
        #expect(limited.text == "claude rate limited until 14:10")
        #expect(limited.until.map { AgentUsage.clock($0) } == "14:10")

        let out = SummaryFailure.of(LLMError.noAgent(reasons: ["claude: not logged in"]), at: now, forUpdate: now)
        #expect(out?.kind == .loggedOut && out?.text == "claude not logged in")

        let until = now.addingTimeInterval(3600)
        let budget = SummaryFailure.of(
            LLMError.overBudget(until: until, reasons: ["claude: daily cap of 100 calls reached"]), at: now,
            forUpdate: now
        )
        #expect(budget?.kind == .budget && budget?.until == until)
        #expect(budget?.text.hasPrefix("claude daily cap of 100 calls reached, until") == true)

        let timeout = SummaryFailure.of(
            LLMError.failed(reasons: ["claude: timed out after 120.0 seconds"]), at: now, forUpdate: now
        )
        #expect(timeout?.kind == .timeout)
        #expect(SummaryFailure.of(LLMError.failed(reasons: ["claude: exit 1"]), at: now, forUpdate: now)?.kind
            == .failed)
        // Model calls off is the off state, not a failure.
        #expect(SummaryFailure.of(LLMError.disabled, at: now, forUpdate: now) == nil)
        // The thread did not load.
        struct Gone: Error {}
        #expect(SummaryFailure.of(Gone(), at: now, forUpdate: now)?.kind == .thread)
    }

    // MARK: The card

    @Test func theCardIsAlwaysOneState() {
        let written = summary(covers: 10, written: 5)
        func state(
            _ summary: CatchUpSummary? = nil, _ freshness: CatchUpFreshness = .missing, run: SummaryRun? = nil,
            failure: SummaryFailure? = nil, mode: AttentionSummaryMode = .ahead, modelCalls: Bool = true
        ) -> SummaryCardState {
            SummaryCardState.of(
                summary: summary, freshness: freshness, run: run, failure: failure, mode: mode, modelCalls: modelCalls
            )
        }
        #expect(state(written, .upToDate, modelCalls: false) == .off(.modelCalls))
        #expect(state(written, .upToDate, mode: .off) == .off(.summaries))
        #expect(SummaryCardState.Off.modelCalls.command == "settings.open model-calls")
        let run = SummaryRun(startedAt: ago(0.05), agent: "claude", model: "haiku")
        #expect(state(written, .upToDate, run: run) == .summarizing(run, previous: written))
        #expect(state(written, .upToDate, run: run).line(now: now) == "claude haiku, started 3 s ago")
        let failure = SummaryFailure(
            kind: .rateLimited,
            text: "claude rate limited until 14:10",
            at: ago(1),
            forUpdate: ago(5)
        )
        #expect(state(written, .upToDate, failure: failure) == .failed(failure, previous: written))
        #expect(state(written, .upToDate, failure: failure).line(now: now) == "claude rate limited until 14:10")
        #expect(state(written, .upToDate) == .upToDate(written))
        #expect(state(written, .upToDate).line(now: now) == "written for the 1 new comment")
        let stale = state(written, .stale(new: 2, stateChanged: false))
        #expect(stale.chip == "stale · 2 new")
        #expect(state(nil, .missing) == .summarizing(nil, previous: nil))
        #expect(written.lines == ["Asks one thing.", "Checks pass."])
        #expect(written.firstLine == "Asks one thing.")
    }

    // MARK: The row's preview and the title bar

    @Test func thePreviewIsTheSummaryWhenUpToDateElseTheNewestComment() {
        let pr = item()
        let detail = ThreadDetail(
            url: "u",
            comments: [.init(author: "maria", text: "One question", at: ago(1))],
            updatedAt: now
        )
        #expect(AttentionPreview.of(pr, detail: detail, summary: "Asks one thing.", isNew: true, seenAt: ago(9))
            == .summary("Asks one thing."))
        #expect(AttentionPreview.of(pr, detail: detail, summary: nil, isNew: true, seenAt: ago(9))
            == .comment(author: "maria", text: "One question"))
        #expect(AttentionPreview.of(pr, detail: detail, summary: "Asks one thing.", isNew: false, seenAt: ago(9))
            == .nothingNew(since: ago(9)))
    }

    @Test func theTitleBarCountsNew() {
        let entries = AttentionRanking.entries(
            live: [item("fresh", others: 2), item("read", minutes: 30, others: 30)],
            rules: AttentionRules(lines: []), marks: [:], viewer: "you", now: now
        )
        let seen = AttentionSeen(threads: ["read": ago(20)], leftAt: ago(60))
        #expect(AttentionListing.newCount(entries, seen: seen, now: now) == 1)
        #expect(AttentionListing.counts(entries, seen: seen, now: now)[.forYou] == 2)
    }

    // MARK: Text, config and the store

    @Test func htmlBecomesPlainText() {
        let html = "<p>Hi <code>a&lt;b</code> &amp; more</p><ul><li>one</li><li>two</li></ul><br><p></p><p>end</p>"
        #expect(ThreadText.plain(html) == "Hi a<b & more\n- one\n- two\n\nend")
    }

    @Test func theSettingReadsAndARefusedValueIsAProblem() throws {
        #expect(HeedConfig.default.attention.summaries == .ahead)
        let open = try #require(ConfigLoader.decode("[attention]\nsummaries = \"open\"\n").config)
        #expect(open.attention.summaries == .open)
        let (config, problems) = ConfigLoader.decode("[attention]\nsummaries = \"always\"\n")
        #expect(config?.attention.summaries == .ahead)
        #expect(problems.contains { $0.path == "attention.summaries" })
    }

    @Test func catchUpsAreKeptAndPruned() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heed-summaries-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try AttentionStore(path: dir.appendingPathComponent("attention.sqlite").path)
        let written = summary(covers: 10)
        try await store.record([item("acme/docs#41")], now: now)
        try await store.saveCatchUp(written, for: "acme/docs#41")
        try await store.saveCatchUp(written, for: "gone")
        #expect(try await store.catchUps() == ["acme/docs#41": written, "gone": written])
        try await store.prune(now: now)
        #expect(try await store.catchUps() == ["acme/docs#41": written])
    }
}
