import Foundation
@testable import HeedCore
import Testing

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func work(
    files: Int? = 0, added: Int? = 0, removed: Int? = 0, repos: [String] = ["acme/docs-toolkit"],
    message: String? = nil, ended: Bool = false
) -> SessionWork {
    SessionWork(
        files: files, added: added, removed: removed, repos: repos, lastMessage: message, turnEnded: ended
    )
}

struct SessionMilestoneTests {
    let record = SessionPanelRecord.start(work(), at: start)
    let settings = SessionPanelSettings()

    @Test func nothingWhileLittleChanged() {
        #expect(SessionMilestones.detect(
            work(files: 9, added: 200, removed: 99), record: record, settings: settings, now: start
        ) == nil)
    }

    @Test func tenFilesOrThreeHundredLinesIsALotBuilt() throws {
        let byFiles = try #require(SessionMilestones.detect(
            work(files: 10, added: 20, removed: 2), record: record, settings: settings, now: start
        ))
        #expect(byFiles.kind == .built)
        #expect(byFiles.details == ["10 files", "+20 −2"])
        let byLines = try #require(SessionMilestones.detect(
            work(files: 3, added: 250, removed: 50), record: record, settings: settings, now: start
        ))
        #expect(byLines.kind == .built)
    }

    @Test func itCountsFromTheLastLookNotFromTheStart() {
        var record = record
        record.notNow(work(files: 12, added: 600, removed: 80), at: start)
        // Two more files and a few lines since: not a lot.
        #expect(SessionMilestones.detect(
            work(files: 14, added: 612, removed: 88), record: record, settings: settings, now: start
        ) == nil)
        #expect(SessionMilestones.detect(
            work(files: 14, added: 912, removed: 88), record: record, settings: settings, now: start
        )?.kind == .built)
    }

    @Test func thresholdsComeFromTheSettings() {
        var settings = settings
        settings.builtFiles = 3
        #expect(SessionMilestones.detect(work(files: 3), record: record, settings: settings, now: start)?
            .kind == .built)
        settings.built = false
        #expect(SessionMilestones.detect(work(files: 30), record: record, settings: settings, now: start) == nil)
    }

    @Test func aTurnThatSaysDoneCarriesItsWordsIntoALotBuilt() throws {
        let message = "All five redirects resolve. 14 files changed. I think this part is done."
        let built = try #require(SessionMilestones.detect(
            work(files: 14, added: 612, removed: 88, message: message, ended: true), record: record,
            settings: settings, now: start
        ))
        #expect(built.kind == .built)
        #expect(built.details == ["14 files", "+612 −88", "\u{201C}I think this part is done\u{201D}"])
    }

    @Test func saysDoneOnItsOwnOnlyAtATurnsEnd() throws {
        let message = "The fix is in and the tests pass. Ready for review."
        #expect(SessionMilestones.detect(
            work(message: message, ended: false), record: record, settings: settings, now: start
        ) == nil)
        let done = try #require(SessionMilestones.detect(
            work(message: message, ended: true), record: record, settings: settings, now: start
        ))
        #expect(done.kind == .saysDone)
        #expect(done.quote == "Ready for review")
    }

    @Test func oneOfferPerMilestone() throws {
        var record = record
        let message = "Done."
        let done = try #require(SessionMilestones.detect(
            work(message: message, ended: true), record: record, settings: settings, now: start
        ))
        record.offering(done)
        #expect(record.offer == done)
        #expect(SessionMilestones.detect(
            work(message: message, ended: true), record: record, settings: settings, now: start
        ) == nil)
        // Another turn that says it is done is another milestone.
        #expect(SessionMilestones.detect(
            work(message: "That's it, ready for review.", ended: true), record: record, settings: settings, now: start
        ) != nil)
    }

    @Test func aSecondRepoAndLongWithoutALookAreOffByDefault() {
        let wider = work(files: 1, added: 10, removed: 0, repos: ["acme/docs-toolkit", "acme/docs-website"])
        let later = start.addingTimeInterval(5 * 3600)
        #expect(SessionMilestones.detect(wider, record: record, settings: settings, now: later) == nil)
        var settings = settings
        settings.secondRepo = true
        #expect(SessionMilestones.detect(wider, record: record, settings: settings, now: later)?.repo
            == "acme/docs-website")
        settings.secondRepo = false
        settings.long = true
        let long = SessionMilestones.detect(wider, record: record, settings: settings, now: later)
        #expect(long?.kind == .long)
        #expect(long?.hours == 5)
        // Four hours of nothing is not long without a look.
        #expect(SessionMilestones.detect(work(), record: record, settings: settings, now: later) == nil)
    }
}

struct SaysDoneTests {
    @Test(arguments: [
        ("I think this part is done.", "I think this part is done"),
        ("Tests pass. Everything is implemented.", "Everything is implemented"),
        ("Pushed the branch. Ready for review!", "Ready for review"),
        ("Done.", "Done"),
    ])
    func doneMarkers(text: String, quote: String) {
        #expect(SaysDone.quote(text) == quote)
    }

    @Test(arguments: [
        "I think this part is done. Should I also update the docs?",
        "Working on the parser next.",
        "Let me know if this is done enough for you to review?",
        "",
    ])
    func notDone(text: String) {
        #expect(SaysDone.quote(text) == nil)
    }
}

struct SessionPanelPolicyTests {
    let milestone = SessionMilestone(kind: .built, key: "built@0", at: start, files: 12)
    let record = SessionPanelRecord.start(work(), at: start)

    @Test func askMeOffersLookWithoutAskingLooksNeverDoesNothing() {
        var settings = SessionPanelSettings()
        #expect(SessionPanelPolicy.action(milestone, settings: settings, record: record, relevant: 2) == .offer)
        settings.offers = .look
        #expect(SessionPanelPolicy.action(milestone, settings: settings, record: record, relevant: 2) == .look)
        settings.offers = .never
        #expect(SessionPanelPolicy.action(milestone, settings: settings, record: record, relevant: 2) == .nothing)
    }

    @Test func noOneRelevantOrNeverHereOffersNothing() {
        let settings = SessionPanelSettings()
        #expect(SessionPanelPolicy.action(milestone, settings: settings, record: record, relevant: 0) == .nothing)
        var never = record
        never.never()
        #expect(SessionPanelPolicy.action(milestone, settings: settings, record: never, relevant: 3) == .nothing)
        // Asking by hand still looks.
        let asked = SessionMilestone(kind: .asked, key: "asked", at: start)
        #expect(SessionPanelPolicy.action(asked, settings: settings, record: never, relevant: 3) == .look)
    }

    @Test func notNowCountsAgainFromHere() {
        var record = record
        record.offering(milestone)
        record.notNow(work(files: 12, added: 300, removed: 0), at: start.addingTimeInterval(60))
        #expect(record.offer == nil)
        #expect(record.since.files == 12)
        #expect(record.since.lines == 300)
        #expect(record.offered.contains(milestone.key))
    }
}

struct SessionPanelInviteTests {
    static let skeptic: Persona = {
        var persona = BuiltInPersonas.persona(PanelInvites.skeptic)
        persona.joins = [.goalPanels, .beforePR]
        return persona
    }()

    static let style = Persona(
        name: "Your team's style", who: "how acme writes tests", scope: .org("acme"), joins: [.everyPlan],
        source: .learned
    )

    static let elsewhere = Persona(name: "Globex reviewer", scope: .org("globex"), joins: [.beforePR], source: .repos)

    static let library = PersonaLibrary(files: Dictionary(uniqueKeysWithValues: [
        skeptic, PersonaLibraryFixtures.docsSite, style, elsewhere, PersonaLibraryFixtures.redirectUser,
    ].map { ($0.id, $0) }))

    @Test func onlyPersonasThatJoinSessionsInScopeNarrowestFirst() {
        let relevant = SessionPanelInvites.relevant(
            Self.library, repos: ["acme/docs-toolkit", "acme/docs-website"]
        ).map(\.id)
        // Redirect-config user joins goal panels only; Globex's is walled into another org.
        #expect(relevant == ["docs-site-maintainer", "your-team-s-style", "skeptic"])
    }

    @Test func beforeAPRThoseWhoJoinBeforeAPRGoFirst() {
        let relevant = SessionPanelInvites.relevant(
            Self.library, repos: ["acme/docs-toolkit", "acme/docs-website"], for: .beforePR
        ).map(\.id)
        #expect(relevant == ["docs-site-maintainer", "skeptic", "purist"])
    }

    @Test func outOfTheBoxTheSkepticAndThePuristJoinSessionsAndNoOneElse() {
        let fresh = PersonaLibrary(files: [:])
        #expect(SessionPanelInvites.relevant(fresh, repos: ["acme/x"]).map(\.id) == ["skeptic", "purist"])
        #expect(SessionPanelInvites.relevant(fresh, repos: ["acme/x"], for: .beforePR).map(\.id)
            == ["skeptic", "purist"])
        // A default, not a file: nothing is written until you edit one.
        #expect(fresh.entries.filter(\.hasFile).isEmpty)
        let joining = fresh.personas.filter(SessionPanelInvites.joinsSessions).map(\.id)
        #expect(joining == ["skeptic", "purist"])
        #expect(fresh.entry("ux")?.persona.joins == [.goalPanels])
        // Turned off, or its join switched off in Settings, it stops looking.
        var skeptic = BuiltInPersonas.persona(PanelInvites.skeptic)
        skeptic.joins = [.goalPanels]
        let edited = PersonaLibrary(files: [skeptic.id: skeptic])
        #expect(SessionPanelInvites.relevant(edited, repos: ["acme/x"]).map(\.id) == ["purist"])
    }

    @Test func atMostThree() {
        #expect(SessionPanelInvites.relevant(Self.library, repos: ["acme/docs-website"], limit: 2).count == 2)
    }

    @Test func askingByHandAlwaysGetsSomeone() {
        // With nobody joining sessions (heed's two turned off), asking still gets the Skeptic.
        var skeptic = BuiltInPersonas.persona(PanelInvites.skeptic)
        skeptic.joins = [.goalPanels]
        var purist = BuiltInPersonas.persona(PanelInvites.purist)
        purist.on = false
        let empty = PersonaLibrary(files: [skeptic.id: skeptic, purist.id: purist])
        #expect(SessionPanelInvites.relevant(empty, repos: ["acme/x"]).isEmpty)
        #expect(SessionPanelInvites.asked(empty, repos: ["acme/x"]).map(\.id) == ["skeptic"])
        #expect(SessionPanelInvites.asked(Self.library, repos: ["acme/x"], picked: ["Your team's style"]).map(\.id)
            == ["your-team-s-style"])
    }
}

struct SessionLookTests {
    static let seats = SessionPanelInvites.seats([
        SessionPanelInviteTests.style, PersonaLibraryFixtures.docsSite, SessionPanelInviteTests.skeptic,
    ])

    static let answer = """
    {"verdicts": [
      {"persona": "your-team-s-style", "verdict": "concern", "quote": "RedirectBug2841Tests describes the bug; name it after the behaviour, like AnchorLookupTests.", "fix": "test names describe the bug, not the behaviour"},
      {"persona": "Docs-site maintainer", "verdict": "happy", "quote": "Server rules only, no chains. Old URLs keep working.", "fix": null},
      {"persona": "skeptic", "verdict": "ok", "quote": "Scope stayed small."}
    ]}
    """

    static func look() async throws -> SessionLook {
        let calls = SessionLookCalls { _ in LLMResponse(text: answer, agent: "claude", model: "haiku", duration: 5) }
        return try await calls.look(
            milestone: SessionMilestone(kind: .built, key: "k", at: start, files: 14, added: 612, removed: 88),
            task: "Fix broken anchors in redirects", lastTurn: "I think this part is done.", diff: "diff --git a b",
            stat: DiffStat(files: 14, added: 612, removed: 88), seats: seats, now: start
        )
    }

    @Test func theVerdictLineCountsAndLeadsWithTheTopConcern() async throws {
        let look = try await Self.look()
        #expect(look.count(.happy) == 2)
        #expect(look.count(.concern) == 1)
        #expect(look.count(.not) == 0)
        #expect(look.worried)
        #expect(look.topLine == "team style: test names describe the bug, not the behaviour")
        #expect(look.model == "haiku")
    }

    @Test func sendingCarriesOnlyTheConcerns() async throws {
        let message = try #require(try await Self.look().message)
        #expect(message.hasPrefix("From heed, the panel looked at your work (a lot got built):"))
        #expect(message.contains("Your team's style (concern): RedirectBug2841Tests"))
        #expect(message.contains("Suggested: test names describe the bug"))
        #expect(!message.contains("Docs-site maintainer"))
        var happy = try await Self.look()
        happy.verdicts = happy.verdicts.filter { $0.kind == .happy }
        #expect(happy.message == nil)
    }

    @Test func anUnreadableAnswerIsAnError() async {
        let calls = SessionLookCalls { _ in LLMResponse(text: "I think it looks fine", agent: "claude") }
        await #expect(throws: LLMError.self) {
            try await calls.look(
                milestone: SessionMilestone(kind: .asked, key: "k", at: start), task: "t", lastTurn: nil, diff: "",
                stat: nil, seats: Self.seats, now: start
            )
        }
    }

    @Test func thePromptIsBounded() {
        let big = (0 ..< 4).map { file in
            "diff --git a/f\(file) b/f\(file)\n" + String(repeating: "+line \(file)\n", count: 2000)
        }.joined(separator: "\n")
        let bounded = SessionLookPrompt.bounded(diff: big, limit: 4000)
        // Every file keeps its header, however long the first one is.
        for file in 0 ..< 4 {
            #expect(bounded.contains("diff --git a/f\(file) b/f\(file)"))
        }
        #expect(bounded.count < 4000 + 200)
        let prompt = SessionLookPrompt.prompt(
            milestone: SessionMilestone(kind: .saysDone, key: "k", at: start, quote: "done"),
            task: String(repeating: "t", count: 5000), lastTurn: "done", diff: big, stat: nil, seats: Self.seats
        )
        #expect(prompt.contains("# Why you are looking\nThe agent says it's done"))
        #expect(prompt.contains("more characters)"))
        #expect(prompt.count < SessionLookPrompt.diffLimit + SessionLookPrompt.taskLimit + 3000)
        #expect(prompt.contains("- skeptic (Skeptic"))
    }
}

struct PRGateTests {
    @Test(arguments: [
        "gh pr create --fill",
        "git push -u origin HEAD && gh pr create --title \"Fix anchors\" --body x",
        "gh -R acme/docs-toolkit pr create --draft",
        "GH_TOKEN=x gh pr create",
        "cd repo; /opt/homebrew/bin/gh --repo=acme/x pr create",
    ])
    func opensAPR(command: String) {
        #expect(PRGate.isCreate(command))
    }

    @Test(arguments: [
        "gh pr view 12",
        "echo \"gh pr create\"",
        "gh pr list # then gh pr create",
        "git commit -m 'gh pr create later'",
        "ghx pr create",
    ])
    func doesNotOpenAPR(command: String) {
        #expect(!PRGate.isCreate(command))
    }

    @Test func githubsMCPToolOpensOneToo() {
        let ask = PermissionAsk(
            id: "a", session: "s", agent: "claude", tool: "mcp__github__create_pull_request", askedAt: start
        )
        #expect(PRGate.opensPR(ask))
        #expect(!PRGate.opensPR(PermissionAsk(id: "b", session: "s", agent: "claude", tool: "Edit", askedAt: start)))
    }

    @Test func choicesAnswerTheHook() async throws {
        let look = try await SessionLookTests.look()
        #expect(PRGate.answer(.letOpen, look: look).decision == .allow)
        let concern = PRGate.answer(.sendConcern, look: look)
        #expect(concern.decision == .deny)
        #expect(concern.message?.contains("RedirectBug2841Tests") == true)
        #expect(concern.message?.hasSuffix("then open the PR again.") == true)
        #expect(PRGate.answer(.hold, look: look).message?.contains("hold the PR") == true)
        #expect(PRGate.holds(look))
        var happy = look
        happy.verdicts = happy.verdicts.filter { $0.kind == .happy }
        #expect(!PRGate.holds(happy))
    }

    @Test func theApprovalsWaitFitsInsideTheHooksCeiling() {
        let ask = PermissionAsk(id: "a", session: "s", agent: "claude", tool: "Bash", askedAt: start)
        let hold = PRHold(ask: ask, since: start, until: start.addingTimeInterval(120))
        #expect(hold.remaining(start.addingTimeInterval(30)) == 90)
        #expect(hold.remaining(start.addingTimeInterval(500)) == 0)
        #expect(hold.approvalsWait(120, now: start.addingTimeInterval(120)) == 120)
        #expect(hold.approvalsWait(240, now: start.addingTimeInterval(120)) == 165)
    }
}

struct SessionFootTests {
    static let waiting = SessionHelperLine(entries: [SessionHelperLine.Entry(
        id: "h", number: 1, kind: .green, standing: .needsYou, status: "needs your OK", headline: "A helper"
    )])
    static let working = SessionHelperLine(entries: [SessionHelperLine.Entry(
        id: "h", number: 1, kind: .green, standing: .working, status: "step 1 of 3", headline: "A helper"
    )])

    @Test func mostUrgentFirst() {
        #expect(SessionFoot.order(helpers: Self.working, panel: .waits, growth: true) == [.helpers, .panel, .growth])
        #expect(SessionFoot.order(helpers: Self.working, panel: .needsYou, growth: true) == [.panel, .helpers, .growth])
        #expect(SessionFoot.order(helpers: Self.waiting, panel: .needsYou, growth: false) == [.helpers, .panel])
        #expect(SessionFoot.order(helpers: nil, panel: nil, growth: true) == [.growth])
    }

    @Test func theLineShowsAHeldPRFirstThenALookThenTheOfferThenTheVerdict() async throws {
        let look = try await SessionLookTests.look()
        let offer = SessionMilestone(kind: .built, key: "b", at: start)
        var record = SessionPanelRecord.start(work(), at: start)
        record.look = look
        #expect(SessionPanelLine.of(record: record, looking: nil, hold: nil) == .verdict(look))
        #expect(SessionPanelLine.of(record: record, looking: nil, hold: nil)?.urgency == .needsYou)
        record.offering(offer)
        #expect(SessionPanelLine.of(record: record, looking: nil, hold: nil) == .offer(offer))
        #expect(SessionPanelLine.of(record: record, looking: offer, hold: nil) == .looking(offer))
        let ask = PermissionAsk(id: "a", session: "s", agent: "claude", tool: "Bash", askedAt: start)
        let hold = PRHold(ask: ask, since: start, until: start)
        #expect(SessionPanelLine.of(record: record, looking: offer, hold: hold) == .holding(hold))
        #expect(SessionPanelLine.of(record: nil, looking: nil, hold: nil) == nil)
    }
}

struct SessionPanelConfigTests {
    @Test func thePersonasSectionReads() throws {
        let decoded = ConfigLoader.decode("""
        [personas]
        built_files = 4
        second_repo = true
        long_hours = 2
        offers = "look"
        hold_seconds = 60
        """)
        #expect(decoded.problems.isEmpty)
        let config = try #require(decoded.config)
        #expect(config.personas.builtFiles == 4)
        #expect(config.personas.secondRepo)
        #expect(config.personas.longHours == 2)
        #expect(config.personas.offers == .look)
        #expect(config.personas.holdSeconds == 60)
        #expect(config.personas.builtLines == 300)
    }

    @Test func aWrongOffersIsAProblem() {
        let decoded = ConfigLoader.decode("[personas]\noffers = \"sometimes\"\n")
        #expect(decoded.config?.personas.offers ?? .ask == .ask)
        #expect(decoded.problems.map(\.path) == ["personas.offers"])
    }
}

struct SessionPanelMenuTests {
    @Test func aSessionsMenuAsksThePanelOrOnePersona() throws {
        var facts = ContextMenus.SessionFacts(id: "s", title: "Fix it")
        facts.panelPersonas = ["Skeptic", "Docs-site maintainer"]
        let menu = ContextMenus.session(facts)
        let found = menu
            .compactMap { if case let .submenu(title, items) = $0, title == "Ask the panel…" { items } else { nil } }
        let items = try #require(found.first)
        #expect(items.map(\.title) == ["The relevant personas", "Only Skeptic", "Only Docs-site maintainer"])
        #expect(items.map(\.command.name) == ["panel.ask", "panel.ask", "panel.ask"])
        #expect(items[2].command.arguments == ["Docs-site maintainer"])
        #expect(items.allSatisfy { $0.command.target == .session("s") })
        // A chat has no diff to look at.
        facts.chat = true
        #expect(!ContextMenus.session(facts)
            .contains { if case .submenu("Ask the panel…", _) = $0 { true } else { false } })
    }

    @Test func gLAsksThePanelAndTheOfferHasItsOwnKeys() {
        #expect(DefaultKeys.normal.contains { $0 == ("gL", "panel.ask") })
        let offer = DefaultKeys.scoped["sessionsoffer"] ?? []
        #expect(offer.contains { $0 == ("x", "panel.notnow") })
        let pr = DefaultKeys.scoped["sessionspanelpr"] ?? []
        #expect(pr.contains { $0 == ("h", "panel.pr hold") })
    }
}

struct SessionPanelFixtureTests {
    @Test func theFakeWorldsLookReadsAndNamesItsPersonaOnce() {
        let library = SessionPanelFixtures.library()
        let repos = ["acme/docs-toolkit", "acme/docs-website"]
        let look = SessionPanelFixtures.look(
            SessionPanelFixtures.built(at: start), library: library, repos: repos
        )
        #expect(look.verdicts.count == 3)
        #expect(look.topLine == "team style: test names describe the bug, not the behaviour")
        #expect(SessionPanelInvites.relevant(library, repos: repos).count == 3)
    }
}
