import Foundation
@testable import HeedCore
import Testing

struct GoalDocTests {
    private let full = GoalDoc(
        title: "Anchors survive page moves",
        goal: "A moved page keeps every inbound anchor working.\nOld URLs redirect to the right heading.",
        notTheGoal: ["Rewriting the link checker", "Changing URL shapes"],
        doneWhen: [
            GoalDoc.Criterion("redirects resolve to real headings", met: true, evidence: "PR acme/docs-toolkit#2841"),
            GoalDoc.Criterion("the validator runs in CI"),
        ],
        openQuestions: ["Do assemblies need their own redirects file?"],
        decisions: [
            GoalDoc.Decision("Redirect targets name a heading id", source: "you, 16 Oct"),
            GoalDoc.Decision("Keep redirects.yml as the one source"),
        ],
        preamble: "Owner: docs team.",
        extras: [GoalDoc.Extra(heading: "Notes", body: "Some *notes*\n\n- a list of mine")]
    )

    @Test func renderReadsBackTheSameDoc() {
        #expect(GoalDoc.parse(full.render()) == full)
        let empty = GoalDoc(title: "Only a title")
        #expect(GoalDoc.parse(empty.render()) == empty)
    }

    @Test func rendersTheCanonicalSections() {
        let text = full.render()
        #expect(text.hasPrefix("# Anchors survive page moves\n\nOwner: docs team.\n\n## Goal\n\nA moved page"))
        #expect(text.contains("- [x] redirects resolve to real headings (evidence: PR acme/docs-toolkit#2841)\n"))
        #expect(text.contains("- [ ] the validator runs in CI\n"))
        #expect(text.contains("- Redirect targets name a heading id (source: you, 16 Oct)\n"))
        #expect(text.hasSuffix("## Notes\n\nSome *notes*\n\n- a list of mine\n"))
        // Empty sections still show, so a reader sees where things go.
        #expect(GoalDoc(title: "t").render() == """
        # t

        ## Goal

        ## Not the goal

        ## Done when

        ## Open questions

        ## Decisions

        """)
    }

    @Test func readsOddMarkdown() {
        let doc = GoalDoc.parse("""
        Some words before the title.\r
        # Docs nav model #\r
        ### the goal\r
        \r
        One nav model for every page.\r
        ## NON-GOALS\r
        * Theming\r
        + Search\r
        ## Done When:\r
        - [X] nav built from the toc\r
          and the assemblies (evidence: #2852)\r
        -  [ ] breadcrumbs match\r
        1. numbered counts too\r
        ## Questions\r
        Is the sidebar collapsible?\r
        ## Decisions\r
        - Toc order wins (Source: chat)\r
        - Parens (like these) stay\r
        ## Mine\r
        ```\r
        # not a heading\r
        ```\r
        """)
        #expect(doc.title == "Docs nav model")
        #expect(doc.preamble == "Some words before the title.")
        #expect(doc.goal == "One nav model for every page.")
        #expect(doc.notTheGoal == ["Theming", "Search"])
        #expect(doc.doneWhen == [
            GoalDoc.Criterion("nav built from the toc and the assemblies", met: true, evidence: "#2852"),
            GoalDoc.Criterion("breadcrumbs match"),
            GoalDoc.Criterion("numbered counts too"),
        ])
        #expect(doc.openQuestions == ["Is the sidebar collapsible?"])
        #expect(doc.decisions == [
            GoalDoc.Decision("Toc order wins", source: "chat"), GoalDoc.Decision("Parens (like these) stay"),
        ])
        #expect(doc.extras == [GoalDoc.Extra(heading: "Mine", body: "```\n# not a heading\n```")])
        // Read and written once, it is stable.
        let once = doc.render()
        #expect(GoalDoc.parse(once).render() == once)
        #expect(doc.criteriaMet == (1, 3))
    }

    @Test func aFileWithNoTitleOrSectionsKeepsItsWords() {
        let doc = GoalDoc.parse("just some text\n\nand more")
        #expect(doc.title.isEmpty && doc.preamble == "just some text\n\nand more")
        #expect(GoalDoc.parse(doc.render()).preamble == doc.preamble)
        #expect(doc.render().hasPrefix("# Untitled goal\n"))
    }

    @Test func onlyATrailingLabelIsRead() {
        #expect(GoalDoc.trailing("source", of: "Keep (source: notes) near the top") == (
            "Keep (source: notes) near the top",
            nil
        ))
        #expect(GoalDoc.trailing("source", of: "Keep it (Source: chat)") == ("Keep it", "chat"))
        #expect(GoalDoc.trailing("evidence", of: "done (evidence: )") == ("done", nil))
    }

    @Test func listItemsAreOneLine() {
        var doc = GoalDoc(title: "t")
        doc.notTheGoal = ["two\nlines"]
        doc.doneWhen = [GoalDoc.Criterion("c", met: true, evidence: "e\nf")]
        #expect(GoalDoc.parse(doc.render()).notTheGoal == ["two lines"])
        #expect(GoalDoc.parse(doc.render()).doneWhen.first?.evidence == "e f")
    }

    @Test func slugsAreFolderNamesAndUnique() {
        #expect(GoalSlug.make("Anchors survive page moves!", taken: []) == "anchors-survive-page-moves")
        #expect(GoalSlug.make("Café ünder", taken: []) == "cafe-under")
        #expect(GoalSlug.make("??", taken: []) == "goal")
        #expect(GoalSlug.make("Docs nav", taken: ["docs-nav", "docs-nav-2"]) == "docs-nav-3")
        #expect(GoalSlug.make(String(repeating: "word ", count: 30), taken: []).count <= 48)
    }
}

struct GoalStoreTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("heed-goals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func migratesOnceAndKeepsWhatItHolds() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("goals.sqlite").path
        let store = try GoalStore(path: path)
        #expect(try store.schemaVersion == GoalStore.schema.count)
        var goal = HeedGoal(id: "g", title: "G", createdAt: now, tracker: GoalTracker(repo: "acme/plans", metaIssue: 7))
        try store.insert(goal, first: GoalVersion(goal: "g", number: 1, at: now, text: "# G\n", note: "created"))
        goal.score = 6.5
        try store.update(goal)
        let reopened = try GoalStore(path: path)
        #expect(try reopened.schemaVersion == GoalStore.schema.count)
        #expect(try reopened.goals() == [goal])
        // Every table later parts fill is there already.
        for table in [
            "goal_items",
            "goal_evidence",
            "goal_edits",
            "goal_reviews",
            "goal_evaluations",
            "goal_attach_decisions",
        ] {
            let db = try SQLiteDatabase(path: path)
            #expect(try db.scalar("SELECT COUNT(*) FROM \(table)")?.int == 0)
        }
    }
}

struct GoalOpsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ops() throws -> (GoalOps, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heed-goal-ops-\(UUID().uuidString)")
        let ops = try GoalOps(
            path: dir.appendingPathComponent("goals.sqlite").path,
            files: GoalFiles(root: dir.appendingPathComponent("goals"))
        )
        return (ops, dir)
    }

    @Test func createWritesTheFirstVersionAndTheFiles() async throws {
        let (ops, dir) = try ops()
        defer { try? FileManager.default.removeItem(at: dir) }
        let goal = try await ops.create(
            title: "Anchors survive page moves",
            statement: "Moved pages keep anchors.",
            now: now
        )
        #expect(goal.id == "anchors-survive-page-moves" && goal.version == 1 && goal.status == .active)
        let text = try String(contentsOf: ops.files.doc(goal.id), encoding: .utf8)
        #expect(GoalDoc.parse(text).goal == "Moved pages keep anchors.")
        #expect(try await ops.versions(of: goal.id).map(\.note) == ["created"])
        #expect(FileManager.default.fileExists(atPath: ops.files.links(goal.id).path))
        let again = try await ops.create(title: "Anchors survive page moves", statement: "", now: now)
        #expect(again.id == "anchors-survive-page-moves-2")
        await #expect(throws: GoalOpError.noTitle) { try await ops.create(title: "  ", statement: "x", now: now) }
    }

    @Test func everySaveIsANewVersionAndRestoreKeepsHistory() async throws {
        let (ops, dir) = try ops()
        defer { try? FileManager.default.removeItem(at: dir) }
        let goal = try await ops.create(title: "Docs nav", statement: "One nav.", now: now)
        var doc = try await GoalDoc.parse(ops.text(of: goal.id))
        doc.notTheGoal = ["Theming"]
        let v2 = try await ops.save(goal: goal.id, doc: doc, note: "added a non-goal", now: now + 60)
        #expect(v2?.number == 2)
        // Saving the same text again is no new version.
        #expect(try await ops.save(goal: goal.id, doc: doc, note: "same", now: now + 120) == nil)
        // The title line renames the goal.
        doc.title = "Docs nav model"
        _ = try await ops.save(goal: goal.id, doc: doc, note: "renamed", now: now + 180)
        #expect(try await ops.snapshot().goal(goal.id)?.title == "Docs nav model")
        let restored = try await ops.restore(goal: goal.id, version: 1, now: now + 240)
        #expect(restored?.number == 4 && restored?.author == .restore && restored?.note == "restored v1")
        let snapshot = try await ops.snapshot()
        #expect(snapshot.goal(goal.id)?.version == 4 && snapshot.goal(goal.id)?.title == "Docs nav")
        #expect(snapshot.docs[goal.id]?.notTheGoal == [])
        #expect(try await ops.versions(of: goal.id).map(\.number) == [4, 3, 2, 1])
        let onDisk = try String(contentsOf: ops.files.doc(goal.id), encoding: .utf8)
        #expect(try await onDisk == (ops.versions(of: goal.id).first?.text))
        await #expect(throws: GoalOpError.unknownVersion(goal.id, 9)) {
            try await ops.restore(goal: goal.id, version: 9, now: now)
        }
    }

    @Test func attachingMovesAThingAndDetachingTakesItOff() async throws {
        let (ops, dir) = try ops()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try await ops.create(title: "First", statement: "", now: now)
        let second = try await ops.create(title: "Second", statement: "", now: now)
        #expect(try await ops.attach(GoalLink(goal: first.id, kind: .session, target: "s1", at: now)) == nil)
        try await ops.attach(GoalLink(goal: first.id, kind: .chat, target: "c1", at: now))
        // Again on the same goal: nothing moved.
        #expect(try await ops.attach(GoalLink(goal: first.id, kind: .session, target: "s1", at: now)) == nil)
        let moved = try await ops.attach(GoalLink(
            goal: second.id, kind: .session, target: "s1", origin: .auto, confidence: 0.9, reason: "same branch",
            at: now
        ))
        #expect(moved == first.id)
        var snapshot = try await ops.snapshot()
        #expect(snapshot.links(of: first.id).map(\.target) == ["c1"])
        #expect(snapshot.links(of: second.id).first?.confidence == 0.9)
        let exported = try Data(contentsOf: ops.files.links(first.id))
        #expect(String(decoding: exported, as: UTF8.self).contains("\"c1\""))
        #expect(!String(decoding: exported, as: UTF8.self).contains("\"s1\""))
        #expect(try await ops.detach(kind: .session, target: "s1") == second.id)
        #expect(try await ops.detach(kind: .session, target: "s1") == nil)
        snapshot = try await ops.snapshot()
        #expect(snapshot.links(of: second.id).isEmpty)
        await #expect(throws: GoalOpError.unknownGoal("nope")) {
            try await ops.attach(GoalLink(goal: "nope", kind: .pr, target: "acme/x#1", at: now))
        }
    }

    @Test func archiveTogglesAndOrdersLast() async throws {
        let (ops, dir) = try ops()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = try await ops.create(title: "Old", statement: "", now: now)
        _ = try await ops.create(title: "New", statement: "", now: now + 60)
        #expect(try await ops.archive(goal: old.id, now: now) == .archived)
        #expect(try await ops.snapshot().ordered.map(\.id) == ["new", "old"])
        #expect(try await ops.archive(goal: old.id, now: now) == .active)
        #expect(try await ops.snapshot().ordered.map(\.id) == ["new", "old"])
        try await ops.setStatus(goal: "new", .done, now: now)
        #expect(try await ops.snapshot().ordered.map(\.id) == ["old", "new"])
    }

    @Test func fixturesAndShotsWriteNothing() async throws {
        let ops = try GoalOps.inMemory()
        let goal = try await ops.create(title: "Shot", statement: "s", now: now)
        #expect(!FileManager.default.fileExists(atPath: ops.files.doc(goal.id).path))
        #expect(ops.files.doc(goal.id).path == "/Users/you/Library/Application Support/Heed/goals/shot/GOAL.md")
    }
}

struct GoalPointerTests {
    private let claude = AgentProfile.builtIn.first { $0.name == "claude" }!
    private let codex = AgentProfile.builtIn.first { $0.name == "codex" }!

    @Test func thePointerNamesTheGoalAndItsFileInPlainWords() {
        let text = GoalPointer.text(title: "Say \"hi\" `now`", path: "/Users/you/goals/x/GOAL.md")
        #expect(text.hasPrefix("This work belongs to the goal Say hi now. Read /Users/you/goals/x/GOAL.md first"))
        #expect(text.contains("Not the goal"))
        #expect(!text.contains { "\"'`$\\".contains($0) })
    }

    @Test func onlySessionsOnALiveGoalAreTold() {
        let now = Date(timeIntervalSince1970: 0)
        let snapshot = GoalSnapshot(
            goals: [
                HeedGoal(id: "a", title: "A", createdAt: now),
                HeedGoal(id: "b", title: "B", status: .archived, createdAt: now),
            ],
            links: [
                GoalLink(goal: "a", kind: .session, target: "s1", at: now),
                GoalLink(goal: "a", kind: .chat, target: "c1", at: now),
                GoalLink(goal: "a", kind: .pr, target: "acme/x#1", at: now),
                GoalLink(goal: "b", kind: .session, target: "s2", at: now),
            ]
        )
        let pointers = GoalPointer.bySession(snapshot, files: .fixture)
        #expect(Set(pointers.keys) == ["s1", "c1"])
        #expect(pointers["s1"]?.contains("/Heed/goals/a/GOAL.md") == true)
    }

    @Test func launchesCarryThePointerWithTheSignOffInOneArgument() {
        var settings = WorkSettings.default
        settings.goalPointers = ["s1": "POINTER"]
        #expect(settings.signOffArguments(agent: claude, repo: nil, session: "s1") == [
            "--append-system-prompt",
            "POINTER",
        ])
        #expect(settings.signOffArguments(agent: claude, repo: nil, session: "s2").isEmpty)
        #expect(settings.signOffArguments(agent: claude, repo: nil).isEmpty)
        settings.signOff = SignOffRule(defaults: true)
        #expect(settings.signOffArguments(agent: claude, repo: nil, session: "s1")
            == ["--append-system-prompt", SignOff.instruction + " POINTER"])
        #expect(settings.signOffArguments(agent: codex, repo: nil, session: "s1")
            == ["-c", "developer_instructions=" + TOMLValue.quote(SignOff.instruction + " POINTER")])
        #expect(AgentInstructions.arguments(agent: "gemini", ["x"]).isEmpty)
    }

    @Test func resumeTellsTheAgentItsGoal() {
        var settings = WorkSettings.default
        settings.goalPointers = ["s1": "POINTER"]
        let files = IntegrationFiles(directory: URL(fileURLWithPath: "/s"), heedBinary: "/app/heed")
        let domain = Domain(sessions: [
            Session(
                id: "s1",
                title: "t",
                repos: [],
                branch: "b",
                agent: "claude",
                agentSessionID: "x",
                state: ObservedState(.idle)
            ),
            Session(
                id: "s2",
                title: "t",
                repos: [],
                branch: "c",
                agent: "claude",
                agentSessionID: "y",
                state: ObservedState(.idle)
            ),
        ])
        let candidates = Resume.candidates(domain: domain, settings: settings, integration: files)
        let line = { (id: String) in candidates.first { $0.id == id }?.command.posix ?? "" }
        #expect(line("s1").contains("POINTER"))
        #expect(!line("s2").contains("POINTER"))
    }

    @Test func configTurnsItOff() {
        #expect(ConfigLoader.decode(ConfigLoader.defaultSource).config?.goals.tellAgents == true)
        #expect(ConfigLoader.decode("[goals]\ntell_agents = false").config?.goals.tellAgents == false)
    }
}

struct GoalOverviewTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let repo = Repo(org: "acme", name: "docs-toolkit")

    private func session(_ id: String, prs: [Int] = [], minutesAgo: Double = 0) -> Session {
        Session(
            id: id, title: "Session \(id)", repos: [repo], branch: id, agent: "claude", state: ObservedState(.idle),
            trackedPRs: prs.map { PullRef(repo: repo, number: $0) }, lastActivity: now - minutesAgo * 60
        )
    }

    private func pull(_ number: Int, _ state: PullRequest.State) -> PullRequest {
        PullRequest(
            ref: PullRef(repo: repo, number: number), title: "PR \(number)", url: "", state: state, isDraft: false,
            headBranch: "b", review: nil, checks: CheckSummary(), unresolvedThreads: 0, updatedAt: now
        )
    }

    @Test func countsWhatIsOnTheGoalAndWhereItWasLeft() {
        var doc = GoalDoc(title: "G")
        doc.doneWhen = [GoalDoc.Criterion("a", met: true), GoalDoc.Criterion("b")]
        let links = [
            GoalLink(goal: "g", kind: .session, target: "open", at: now - 60),
            GoalLink(goal: "g", kind: .session, target: "closed", at: now - 120),
            GoalLink(goal: "g", kind: .pr, target: "acme/docs-toolkit#3", at: now),
        ]
        let closed = HistoryEntry(session: session("closed", prs: [2]), closedAt: now - 30, outcome: .merged)
        var older = LedgerEntry(id: "closed", title: "closed one", startedAt: now - 9000)
        older.summary = "older words"
        older.summarizedAt = now - 5000
        var newer = LedgerEntry(id: "open", title: "open one", startedAt: now - 9000)
        newer.summary = "where it stands"
        newer.summarizedAt = now - 100
        var github = GitHubState()
        github.pulls = [pull(1, .merged), pull(2, .open)]
        let overview = GoalOverview.build(
            doc: doc, links: links, sessions: [session("open", prs: [1, 2])], history: [closed], github: github,
            ledger: ["open": newer, "closed": older]
        )
        #expect(overview.criteriaMet == 1 && overview.criteriaTotal == 2)
        #expect(overview.rows.map(\.link.target) == ["open", "closed"])
        #expect(overview.rows.map(\.open) == [true, false])
        // PRs once each, from every session and the goal's own; unknown until GitHub says.
        #expect(overview.pulls.map(\.ref.number) == [1, 2, 3])
        #expect(overview.pulls.map(\.state) == ["merged", "open", "unknown"])
        #expect(overview.merged == 1 && overview.sessions == 2)
        #expect(overview.lastTime?.summary == "where it stands" && overview.lastTime?.session == "open")
    }

    @Test func aGoalWithNothingOnItIsEmpty() {
        let overview = GoalOverview.build(
            doc: nil, links: [], sessions: [], history: [], github: GitHubState(), ledger: [:]
        )
        #expect(overview.rows.isEmpty && overview.pulls.isEmpty && overview.lastTime == nil)
        #expect(overview.criteriaTotal == 0)
    }

    @Test func goalsAreFoundBySlugTitleOrAnUnambiguousPart() {
        let snapshot = GoalSnapshot(goals: [
            HeedGoal(id: "anchors-survive", title: "Anchors survive", createdAt: now),
            HeedGoal(id: "docs-nav", title: "Docs nav", createdAt: now),
            HeedGoal(id: "docs-search", title: "Docs search", createdAt: now),
            HeedGoal(id: "old", title: "Old anchors", status: .archived, createdAt: now),
        ])
        #expect(snapshot.find("docs-nav")?.id == "docs-nav")
        #expect(snapshot.find("Anchors Survive")?.id == "anchors-survive")
        #expect(snapshot.find("anch")?.id == "anchors-survive")
        #expect(snapshot.find("search")?.id == "docs-search")
        // Two start with it: none, rather than a guess.
        #expect(snapshot.find("docs") == nil)
        // An archived goal only by its name.
        #expect(snapshot.find("old")?.id == "old")
        #expect(snapshot.find("") == nil && snapshot.find("nothing") == nil)
        #expect(PullRef(slug: "acme/x#12") == PullRef(repo: Repo(org: "acme", name: "x"), number: 12))
        #expect(PullRef(slug: "acme#12") == nil && PullRef(slug: "acme/x#y") == nil)
    }

    @Test func fixtureGoalsAreOnTheFakeWorldsSessions() async throws {
        let ids = Set(Fixtures.main.sessions.map(\.id) + Fixtures.main.history.map(\.id))
        let fixtures = GoalFixtures.all(now: Date(timeIntervalSince1970: 1_800_000_000.75))
        #expect(fixtures.count == 3 && fixtures.contains { $0.goal.status == .done })
        for link in fixtures.flatMap(\.links) {
            #expect(ids.contains(link.target), "\(link.target) is not in Fixtures.main")
        }
        // Laid into a store, they read back as the view's first snapshot.
        let ops = try GoalOps.inMemory()
        try await ops.adopt(fixtures)
        #expect(try await ops.snapshot() == GoalFixtures.snapshot(fixtures))
        let first = try #require(fixtures.first)
        #expect(try await ops.versions(of: first.goal.id) == GoalFixtures.versions(fixtures)[first.goal.id])
    }
}
