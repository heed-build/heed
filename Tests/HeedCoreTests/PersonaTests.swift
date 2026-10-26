import Foundation
@testable import HeedCore
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private let caching = """
name: Cache and CI specialist
knows: build caches, ephemeral runners, content-addressed stores
skeptical about: cache keys, stale hits
asks first: what is the key? who clears it?
may: read, run, write notes
may not: edit code
"""

struct PersonaFileTests {
    @Test func parsesEverySection() throws {
        let persona = try #require(Persona.parse(caching))
        #expect(persona.name == "Cache and CI specialist")
        #expect(persona.id == "cache-and-ci-specialist")
        #expect(persona.knows == ["build caches", "ephemeral runners", "content-addressed stores"])
        #expect(persona.skepticalAbout == ["cache keys", "stale hits"])
        #expect(persona.asksFirst == ["what is the key?", "who clears it?"])
        #expect(persona.may == ["read", "run", "write notes"])
        #expect(persona.mayNot == ["edit code"])
        #expect(persona.notes.isEmpty)
    }

    @Test func rendersWhatItParsed() throws {
        let persona = try #require(Persona.parse(caching))
        #expect(persona.render() == caching + "\n")
        #expect(Persona.parse(persona.render()) == persona)
    }

    @Test func roundTripsEmptySectionsAndNotes() throws {
        let persona = Persona(
            name: "Technical writer",
            knows: [],
            asksFirst: [],
            may: ["read"],
            mayNot: [],
            notes: "Writes for people new to the tool.\n\nKeeps it short."
        )
        let text = persona.render()
        #expect(text.contains("\nknows:\n"))
        #expect(Persona.parse(text) == persona)
    }

    @Test func readsLooselyWritten() throws {
        let text = """
        Name:   Release engineer
        Skeptical_About: unsigned artifacts,
          hand-made notes
        knows:
        - notarization
        - update feeds
        asks-first: what does a user download
        A line of my own.
        """
        let persona = try #require(Persona.parse(text))
        #expect(persona.name == "Release engineer")
        #expect(persona.skepticalAbout == ["unsigned artifacts", "hand-made notes"])
        #expect(persona.knows == ["notarization", "update feeds"])
        #expect(persona.asksFirst == ["what does a user download"])
        #expect(persona.notes == "A line of my own.")
        // Sections it does not mention are empty, not defaulted: the file is what you wrote.
        #expect(persona.may.isEmpty)
    }

    @Test func noNameIsNoPersona() {
        #expect(Persona.parse("knows: things") == nil)
        #expect(Persona.parse("name:   \nknows: x") == nil)
    }

    @Test func briefSaysWhoItIs() throws {
        let brief = try #require(Persona.parse(caching)).brief
        #expect(brief.hasPrefix("You are Cache and CI specialist."))
        #expect(brief.contains("You may not edit code."))
        #expect(brief.contains("You ask first: what is the key? who clears it?"))
    }
}

private func item(_ slug: String, _ kind: GoalItem.Kind = .work, links: [GoalItem.Link] = []) -> GoalItem {
    GoalItem(id: "g/\(slug)", goal: "g", title: slug, kind: kind, source: .planner, links: links, createdAt: t0)
}

private func need(
    _ name: String, _ when: PersonaNeed.When, items: [String], reviewer: ReviewerKind? = nil
) -> PersonaNeed {
    PersonaNeed(
        persona: Persona(name: name), when: when, why: "because",
        evidence: items.map { PersonaRef(.item, "g/\($0)", label: $0) }, reviewer: reviewer
    )
}

private func reviewer(_ id: String, _ kind: ReviewerKind, persona: String? = nil) -> ReviewerState {
    ReviewerState(
        config: ReviewerConfig(id: id, kind: kind, persona: persona), objections: [], score: nil, history: [],
        summary: ""
    )
}

struct PersonaCoverageTests {
    let items = [item("a"), item("b"), item("c"), item("d")]

    @Test func countsItemsItsSessionsChatsAndReviewersTouched() {
        let need = need("Cache specialist", .now, items: ["a", "b", "c", "d"])
        var items = items
        items[0].links = [GoalItem.Link(.session, "s1")]
        items[1].links = [GoalItem.Link(.review, "custom-2")]
        let evidence = [GoalEvidence(goal: "g", item: "g/c", kind: .built, at: t0, source: "x", ref: "c1")]
        let spawns = [
            PersonaSpawn(persona: need.id, mode: .session, target: "s1"),
            PersonaSpawn(persona: need.id, mode: .chat, target: "c1"),
            PersonaSpawn(persona: need.id, mode: .reviewer, target: "custom-2"),
        ]
        let coverage = PersonaCoverage.of(
            need, items: items, evidence: evidence, links: [], spawns: spawns, reviewers: [], live: []
        )
        #expect(coverage.touched == 3)
        #expect(coverage.total == 4)
        #expect(coverage.share == 0.75)
        #expect(coverage.state == .consulted)
        #expect(coverage.spawned == "1 sess.")
    }

    @Test func otherPeoplesWorkDoesNotCount() {
        let need = need("Cache specialist", .now, items: ["a"])
        var items = items
        items[0].links = [GoalItem.Link(.session, "someone-else"), GoalItem.Link(.review, "implementation")]
        let coverage = PersonaCoverage.of(
            need, items: items, evidence: [], links: [], spawns: [], reviewers: [reviewer(
                "implementation",
                .implementation
            )],
            live: []
        )
        #expect(coverage.touched == 0)
        #expect(coverage.state == .gap)
    }

    @Test func aReviewerOfItsKindCounts() {
        let need = need("Performance engineer", .now, items: ["a", "b"], reviewer: .perfProber)
        let evidence = [GoalEvidence(
            goal: "g",
            item: "g/a",
            kind: .perf,
            at: t0,
            source: "x",
            ref: "review:perf-prober"
        )]
        let coverage = PersonaCoverage.of(
            need, items: items, evidence: evidence, links: [], spawns: [],
            reviewers: [reviewer("perf-prober", .perfProber)], live: []
        )
        #expect(coverage.touched == 1)
        #expect(coverage.reviewers == 1)
    }

    @Test func aReviewerSpawnedFromThePersonaCounts() {
        let need = need("Cache specialist", .now, items: ["a"])
        let evidence = [GoalEvidence(
            goal: "g",
            item: "g/a",
            kind: .codeReview,
            at: t0,
            source: "x",
            ref: "review:custom"
        )]
        let coverage = PersonaCoverage.of(
            need, items: items, evidence: evidence, links: [], spawns: [],
            reviewers: [reviewer("custom", .custom, persona: "Cache specialist")], live: []
        )
        #expect(coverage.touched == 1)
    }

    @Test func aGoalLinkOnTheItemCounts() {
        let need = need("Cache specialist", .later, items: ["a"])
        let link = GoalLink(goal: "g", kind: .session, target: "s1", item: "g/a", at: t0)
        let coverage = PersonaCoverage.of(
            need, items: items, evidence: [], links: [link],
            spawns: [PersonaSpawn(persona: need.id, mode: .session, target: "s1")], reviewers: [], live: []
        )
        #expect(coverage.touched == 1)
        #expect(coverage.state == .consulted)
    }

    @Test func statesFollowWhenAndWhatIsLive() {
        let now = need("A", .now, items: ["a"])
        let soon = need("B", .soon, items: ["a"])
        func state(_ need: PersonaNeed, live: Set<String> = [], spawns: [PersonaSpawn] = []) -> PersonaState {
            PersonaCoverage.of(need, items: items, evidence: [], links: [], spawns: spawns, reviewers: [], live: live)
                .state
        }
        #expect(state(now) == .gap)
        #expect(state(soon) == .notYet)
        let spawn = PersonaSpawn(persona: now.id, mode: .chat, target: "c1")
        #expect(state(now, live: ["c1"], spawns: [spawn]) == .active)
        // A chat that ended and touched nothing leaves the gap.
        #expect(state(now, spawns: [spawn]) == .gap)
    }

    @Test func noItemsIsNoShare() {
        let coverage = PersonaCoverage.of(
            need("A", .now, items: []), items: items, evidence: [], links: [], spawns: [], reviewers: [], live: []
        )
        #expect(coverage.total == 0)
        #expect(coverage.share == 0)
        #expect(coverage.text == "no items yet")
    }
}

struct PersonaOrderTests {
    @Test func gapsComeFirstThenSoonerThenLessCovered() {
        var items = (1 ... 4).map { item("i\($0)") }
        items[0].links = [GoalItem.Link(.session, "s")]
        let needs = [
            need("Later one", .later, items: ["i2"]),
            need("Consulted", .now, items: ["i1", "i2"]),
            need("Second gap", .now, items: ["i3"]),
            need("Active", .soon, items: ["i4"]),
            need("A gap", .now, items: ["i4"]),
            need("Soon one", .soon, items: ["i2"]),
        ]
        let board = PersonaBoard(
            derivation: PersonaDerivation(needs: needs, signature: "x", goalVersion: 1), derivedAt: t0,
            spawns: [
                PersonaSpawn(persona: Persona.slug("Consulted"), mode: .session, target: "s"),
                PersonaSpawn(persona: Persona.slug("Active"), mode: .chat, target: "c"),
            ],
            spawnedAt: [t0, t0]
        )
        let rows = board.rows(files: [:], items: items, evidence: [], links: [], reviewers: [], live: ["c"])
        #expect(rows.map(\.need.name) == ["A gap", "Second gap", "Active", "Consulted", "Soon one", "Later one"])
        #expect(rows.map(\.coverage.state) == [.gap, .gap, .active, .consulted, .notYet, .notYet])
    }

    @Test func aFileOverridesTheDraft() {
        let draft = need("Cache specialist", .now, items: [])
        let edited = Persona(name: "Cache specialist", knows: ["mine"])
        let board = PersonaBoard(
            derivation: PersonaDerivation(needs: [draft], signature: "x", goalVersion: 1), derivedAt: t0, spawns: [],
            spawnedAt: []
        )
        let rows = board.rows(files: [draft.id: edited], items: [], evidence: [], links: [], reviewers: [], live: [])
        #expect(rows.first?.persona.knows == ["mine"])
    }
}

struct PersonaAutoSpawnTests {
    private func row(_ name: String, _ when: PersonaNeed.When, evidence: Bool, state: PersonaState) -> PersonaRow {
        var need = need(name, when, items: evidence ? ["a"] : [])
        if !evidence { need.evidence = [] }
        return PersonaRow(
            need: need, persona: need.persona,
            coverage: PersonaCoverage(
                touched: 0, total: 1, state: state, sessions: 0, chats: 0, reviewers: 0, live: false
            )
        )
    }

    @Test func strongGapsSpawnWithinTheBudgetAndTheRestAreSuggested() {
        let rows = [
            row("One", .now, evidence: true, state: .gap),
            row("Two", .now, evidence: true, state: .gap),
            row("No evidence", .now, evidence: false, state: .gap),
            row("Fine", .now, evidence: true, state: .consulted),
            row("Three", .now, evidence: true, state: .gap),
        ]
        let picked = PersonaAutoSpawn.pick(rows: rows, spawns: [], used: 4, limit: 6)
        #expect(picked.spawn == ["one", "two"])
        #expect(picked.suggest == ["no-evidence", "three"])
    }

    @Test func aSpentBudgetOnlySuggests() {
        let rows = [row("One", .now, evidence: true, state: .gap)]
        #expect(PersonaAutoSpawn.pick(rows: rows, spawns: [], used: 6, limit: 6) == ([], ["one"]))
        #expect(PersonaAutoSpawn.pick(rows: rows, spawns: [], used: 9, limit: 6) == ([], ["one"]))
    }

    @Test func aPersonaIsSpawnedAsAReviewerOnce() {
        let rows = [row("One", .now, evidence: true, state: .gap)]
        let spawns = [PersonaSpawn(persona: "one", mode: .reviewer, target: "custom", auto: true)]
        #expect(PersonaAutoSpawn.pick(rows: rows, spawns: spawns, used: 0, limit: 6) == ([], ["one"]))
    }

    @Test func notNeededNowIsNeverAGap() {
        // A need for later never reads as a gap, so nothing about it is spawned or suggested.
        let rows = [row("Later", .later, evidence: true, state: .notYet)]
        #expect(PersonaAutoSpawn.pick(rows: rows, spawns: [], used: 0, limit: 6) == ([], []))
    }
}

struct PersonaDerivationTests {
    let doc = GoalDoc.parse("""
    # Faster builds

    ## Goal
    Builds take half the time.

    ## Done when
    - [ ] a warm build takes under a minute
    - [x] the cache folder is documented

    ## Open questions
    - Does the cache survive between CI runs?
    """)

    var refs: [String: PersonaRef] {
        PersonaDerivation.refs(doc: doc, items: [item("cache-keys"), item("bench")], evidence: [], quality: nil)
    }

    @Test func handlesForWhatIsOpen() {
        #expect(Set(refs.keys) == ["item:cache-keys", "item:bench", "criterion:1", "question:1"])
        #expect(refs["criterion:1"]?.text == "criterion 1")
        #expect(refs["item:cache-keys"]?.id == "g/cache-keys")
    }

    @Test func parsesTheAnswerKeepingOnlyKnownEvidence() {
        let answer = """
        Here you go:
        {"personas": [
          {"name": "Cache specialist", "when": "needed now", "why": "Nobody looked at the cache.",
           "evidence": ["item:cache-keys", "question:1", "item:made-up"], "reviewer": "perf-prober",
           "knows": ["build caches"], "skepticalAbout": "cache keys, stale hits", "asksFirst": "what is the key?"},
          {"name": "cache specialist", "when": "later", "why": "duplicate"},
          {"name": "Technical writer", "when": "Later", "why": "Docs once it settles."},
          {"why": "no name"}
        ]}
        """
        let needs = PersonaDerivation.parse(answer, refs: refs)
        #expect(needs.map(\.name) == ["Cache specialist", "Technical writer"])
        #expect(needs[0].when == .now)
        #expect(needs[0].evidence.map(\.handle) == ["item:cache-keys", "question:1"])
        #expect(needs[0].reviewer == .perfProber)
        #expect(needs[0].persona.skepticalAbout == ["cache keys", "stale hits"])
        #expect(needs[0].persona.asksFirst == ["what is the key?"])
        #expect(needs[0].persona.may == Persona.readOnly)
        #expect(needs[1].when == .later)
        #expect(needs[1].evidence.isEmpty)
        #expect(PersonaDerivation.parse("no json", refs: refs).isEmpty)
    }

    @Test func atMostEight() {
        let list = (1 ... 12).map { "{\"name\": \"P\($0)\", \"when\": \"soon\"}" }.joined(separator: ",")
        #expect(PersonaDerivation.parse("{\"personas\": [\(list)]}", refs: [:]).count == 8)
    }

    @Test func theSignatureMovesOnlyOnMaterialChange() {
        let items = [item("cache-keys"), item("bench")]
        let base = PersonaDerivation.signature(doc: doc, items: items, evidence: [], quality: nil)
        // A new item is material.
        #expect(PersonaDerivation.signature(doc: doc, items: items + [item("new")], evidence: [], quality: nil) != base)
        // Passing evidence is not; failing evidence is.
        let passing = GoalEvidence(goal: "g", item: "g/bench", kind: .perf, state: .inProgress, at: t0, source: "x")
        #expect(PersonaDerivation.signature(doc: doc, items: items, evidence: [passing], quality: nil) == base)
        var failing = passing
        failing.state = .issue
        #expect(PersonaDerivation.signature(doc: doc, items: items, evidence: [failing], quality: nil) != base)
        // An item done drops out.
        let merged = GoalEvidence(goal: "g", item: "g/bench", kind: .merged, at: t0, source: "x")
        #expect(PersonaDerivation.signature(doc: doc, items: items, evidence: [merged], quality: nil) != base)
        // Order does not matter.
        #expect(PersonaDerivation.signature(doc: doc, items: items.reversed(), evidence: [], quality: nil) == base)
    }

    @Test func dueIsDebounced() {
        let now = t0.addingTimeInterval(3600)
        func due(_ last: (String, Date)?, changed: TimeInterval, empty: Bool = false) -> Bool {
            PersonaDerivation.due(
                last: last.map { (signature: $0.0, at: $0.1) }, signature: "new",
                changedAt: now.addingTimeInterval(-changed),
                now: now, empty: empty
            )
        }
        #expect(due(nil, changed: 300))
        #expect(!due(nil, changed: 30)) // still changing
        #expect(!due(nil, changed: 300, empty: true))
        #expect(!due(("new", t0), changed: 300)) // nothing new
        #expect(due(("old", t0), changed: 300))
        #expect(!due(("old", now.addingTimeInterval(-60)), changed: 300)) // asked a minute ago
    }
}

struct PersonaStoreTests {
    @Test func derivationsWriteFilesOnceAndKeepYourEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("personas-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = GoalFiles(root: root.appendingPathComponent("goals"))
        let ops = try GoalOps(path: ":memory:", files: files)
        let goal = try await ops.create(title: "Faster builds", statement: "Half the time.", now: t0)
        let cache = need("Cache specialist", .now, items: [])
        try await ops.derived(PersonaDerivation(needs: [cache], signature: "a", goalVersion: 1), goal: goal.id, now: t0)
        let path = files.persona(cache.id, goal: goal.id).path
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(path.hasSuffix("goals/faster-builds/personas/cache-specialist.md"))
        let edited = "name: Cache specialist\nknows: mine\n"
        try await ops.savePersona(edited, id: cache.id, goal: goal.id)
        try await ops.derived(
            PersonaDerivation(needs: [cache], signature: "b", goalVersion: 1), goal: goal.id,
            now: t0.addingTimeInterval(1)
        )
        #expect(try await ops.personaText(cache.id, goal: goal.id) == edited)
        let board = try await ops.personaBoard(of: goal.id)
        #expect(board.derivation?.signature == "b")
        // The goal's quality fold ignores persona entries.
        #expect(try await ops.quality(of: goal.id).reviewers.isEmpty)
    }

    @Test func theLibrarySharesAcrossGoals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("personas-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = GoalFiles(root: root.appendingPathComponent("goals"))
        #expect(files.library.path == root.appendingPathComponent("personas").path)
        let ops = try GoalOps(path: ":memory:", files: files)
        let one = try await ops.create(title: "One", statement: "x", now: t0)
        let two = try await ops.create(title: "Two", statement: "y", now: t0)
        try await ops.savePersona(caching, id: "cache-and-ci-specialist", goal: one.id)
        try await ops.share(persona: "cache-and-ci-specialist", goal: one.id)
        #expect(try await ops.library().keys.sorted() == ["cache-and-ci-specialist"])
        // A derivation naming it on another goal copies the library's.
        let named = need("Cache and CI specialist", .now, items: [])
        try await ops.derived(PersonaDerivation(needs: [named], signature: "a", goalVersion: 1), goal: two.id, now: t0)
        #expect(try await ops.personas(of: two.id)[named.id]?.knows.count == 3)
    }

    @Test func renamingMovesTheFile() async throws {
        let ops = try GoalOps.inMemory()
        let goal = try await ops.create(title: "One", statement: "x", now: t0)
        try await ops.savePersona(caching, id: "cache-and-ci-specialist", goal: goal.id)
        try await ops.savePersona(
            caching.replacingOccurrences(of: "Cache and CI specialist", with: "Cache expert"),
            id: "cache-and-ci-specialist", goal: goal.id
        )
        #expect(try await ops.personas(of: goal.id).keys.sorted() == ["cache-expert"])
        await #expect(throws: PersonaError.noName) { try await ops.savePersona("knows: x", id: "x", goal: goal.id) }
    }
}

struct PersonaSpawnTests {
    @Test func aPersonaReviewerReviewsAsThePersona() throws {
        let persona = try #require(Persona.parse(caching))
        let config = ReviewerConfig(
            id: "persona-cache", kind: .custom, instructions: persona.brief, persona: persona.name
        )
        #expect(config.title == "Cache and CI specialist")
        let prompt = ReviewRun.prompt(
            config: config, goalTitle: "Faster builds", doc: "# Faster builds", bar: nil, changed: [],
            worktree: "/tmp/w", known: []
        )
        #expect(prompt.hasPrefix("You review the goal \"Faster builds\" as Cache and CI specialist"))
        #expect(prompt.contains("Who you are:\nYou are Cache and CI specialist."))
        #expect(!prompt.contains("custom reviewer"))
        // Read-only, as every reviewer.
        #expect(prompt.contains("never edit files, commit or push"))
        // A reviewer without a persona reads as before.
        let plain = ReviewRun.prompt(
            config: ReviewerConfig(id: "custom", kind: .custom, instructions: "Look at caches."),
            goalTitle: "Faster builds", doc: "", bar: nil, changed: [], worktree: "/tmp/w", known: []
        )
        #expect(plain.hasPrefix("You are the custom reviewer"))
        #expect(plain.contains("Instructions:\nLook at caches."))
    }

    @Test func oldReviewerRecordsStillDecode() throws {
        let json = #"{"reviewer":{"_0":{"id":"custom","kind":"custom","policy":"on-change","removed":false}}}"#
        let entry = try JSONDecoder().decode(QualityEntry.self, from: Data(json.utf8))
        guard case let .reviewer(config) = entry else { Issue.record("not a reviewer"); return }
        #expect(config.persona == nil)
    }

    @Test func gapsHeedSuggestsAreOneAttentionItemPerGoal() {
        let goals = [
            HeedGoal(id: "a", title: "A", createdAt: t0),
            HeedGoal(id: "b", title: "B", status: .done, createdAt: t0),
            HeedGoal(id: "c", title: "C", createdAt: t0),
        ]
        let items = GoalAttention.personaGaps(
            goals: goals, gaps: ["a": ["Cache specialist", "Writer"], "b": ["X"], "c": []], at: [:], now: t0
        )
        #expect(items.map(\.id) == ["goal:a:personas"])
        #expect(items.first?.title == "A: nobody has looked as Cache specialist, Writer yet")
        #expect(items.first?.reasons == [.goalPersonaGap])
        #expect(items.first.flatMap(GoalAttention.goal(of:)) == "a")
    }

    @Test func theFixtureWorldShowsEveryState() {
        let records = PersonaFixtures.records(now: t0)
        let board = PersonaBoard.fold(records)
        #expect(board.derivation?.needs.count == 6)
        let files = PersonaFixtures.files()["anchors-survive-page-moves"] ?? [:]
        // Every need has a file, and the one you edited parses with your edits.
        #expect(Set(files.keys) == Set(board.derivation?.needs.map(\.id) ?? []))
        #expect(files.values.allSatisfy { Persona.parse($0) != nil })
        #expect(Persona.parse(files["docs-information-architect"] ?? "")?.notes.isEmpty == false)
    }
}
