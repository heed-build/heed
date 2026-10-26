import Foundation
@testable import HeedCore
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let caller = GoalCaller(session: "s1", title: "Fix anchors", repo: "acme/docs")

private func parse(_ line: String) throws -> GoalCommand {
    try GoalCommandLine.parse(line.split(separator: " ").map(String.init))
}

/// A goal with a GOAL.md that has something in each section, and `s1` on it.
private func world() async throws -> (GoalOps, HeedGoal) {
    let ops = try GoalOps.inMemory()
    let goal = try await ops.create(title: "Faster builds", statement: "Builds take under a minute.", now: now)
    let doc = GoalDoc(
        title: "Faster builds", goal: "Builds take under a minute.", notTheGoal: ["Rewriting the bundler"],
        doneWhen: [GoalDoc.Criterion("Cold build under 60s"), GoalDoc.Criterion("CI uses the cache")],
        openQuestions: ["Which cache backend?"]
    )
    try await ops.save(goal: goal.id, doc: doc, note: "filled in", now: now)
    try await ops.attach(GoalLink(goal: goal.id, kind: .session, target: "s1", at: now))
    return (ops, goal)
}

private func run(
    _ line: String, _ ops: GoalOps, caller: GoalCaller? = caller
) async throws -> GoalControl.Outcome {
    try await GoalControl.run(parse(line), caller: caller, ops: ops, files: .fixture, now: now + 60)
}

private func reply(_ outcome: GoalControl.Outcome) -> GoalReply? {
    if case let .reply(reply) = outcome { return reply }
    return nil
}

struct GoalCommandLineTests {
    @Test func everyCommandParses() throws {
        #expect(try parse("goal list").verb == .list)
        #expect(try parse("show --json") == GoalCommand(.show, json: true))
        #expect(try parse("attach faster-builds") == GoalCommand(.attach, subject: "faster-builds"))
        #expect(try parse("attach").subject == nil)
        #expect(try parse("item add Cache the toolchain --parent cache --by-subagent explorer") == GoalCommand(
            .itemAdd, text: "Cache the toolchain", parent: "cache", bySubagent: "explorer"
        ))
        #expect(try parse("item done cache --evidence=tests-pass") == GoalCommand(
            .itemDone, subject: "cache", evidence: "tests-pass"
        ))
        #expect(try parse("item move cache verify") == GoalCommand(.itemMove, subject: "cache", text: "verify"))
        #expect(try parse("item spawn cache --agent codex --background") == GoalCommand(
            .itemSpawn, subject: "cache", agent: "codex", background: true
        ))
        #expect(try parse("decision add Use sccache") == GoalCommand(.decisionAdd, text: "Use sccache"))
        #expect(try parse("question add Which backend") == GoalCommand(.questionAdd, text: "Which backend"))
        #expect(try parse("question answer 1 Use S3") == GoalCommand(.questionAnswer, subject: "1", text: "Use S3"))
        #expect(try parse("criterion check 2 --evidence ci-run-81") == GoalCommand(
            .criterionCheck, subject: "2", evidence: "ci-run-81"
        ))
        #expect(try parse("propose not-the-goal Remote execution") == GoalCommand(
            .propose, subject: "not-the-goal", text: "Remote execution"
        ))
        #expect(try parse("link pr #12 --item cache") == GoalCommand(.linkPR, subject: "#12", item: "cache"))
        #expect(try parse("link pr https://github.com/acme/docs/pull/12")
            .subject == "https://github.com/acme/docs/pull/12")
        #expect(try parse("review request security --goal other") == GoalCommand(
            .reviewRequest, goal: "other", subject: "security"
        ))
    }

    @Test func mistakesAreUsageErrorsThatSayWhat() {
        let bad = [
            ("frobnicate", "no command frobnicate"),
            ("item", "item needs a command"),
            ("item fly x", "no command item fly"),
            ("item add", "item add needs text"),
            ("item add x --evidence e", "item add takes no --evidence"),
            ("item add x --colour red", "unknown option --colour"),
            ("item move cache sideways", "no column sideways"),
            ("item move cache", "item move takes an item id and a column"),
            ("criterion check 1", "criterion check needs --evidence"),
            ("propose scope more", "propose takes a section"),
            ("propose decision", "propose needs text"),
            ("link pr twelve", "not a PR: twelve"),
            ("list extra", "list takes no words"),
            ("decision add x --background", "decision add takes no --background"),
            ("show --goal", "--goal needs a value"),
        ]
        for (line, says) in bad {
            #expect {
                try parse(line)
            } throws: { error in
                "\(error)".contains(says) && "\(error)".contains("usage: heed goal")
            }
        }
    }

    @Test func helpIsAskedForNotAnError() {
        #expect(GoalCommandLine.wantsHelp(["goal"]))
        #expect(GoalCommandLine.wantsHelp(["goal", "--help"]))
        #expect(GoalCommandLine.wantsHelp(["goal", "item", "add", "-h"]))
        #expect(GoalCommandLine.wantsHelp(["goal", "help"]))
        #expect(!GoalCommandLine.wantsHelp(["goal", "list"]))
        // The usage teaches: every command, the default goal, and the exit codes.
        for word in ["item spawn", "criterion check", "propose", "HEED_SESSION_ID", "--json", "4 no goal"] {
            #expect(GoalCommandLine.usage.contains(word))
        }
    }

    @Test func theRequestCarriesThePanesSessionAndARunsGoal() throws {
        let inPane = try GoalCommandLine.request(["goal", "show"], environment: ["HEED_SESSION_ID": "s1"])
        #expect(inPane.method == .goal && inPane.session == "s1" && inPane.goal?.goal == nil)
        let run = try GoalCommandLine.request(["goal", "show"], environment: ["HEED_GOAL": "faster-builds"])
        #expect(run.session == nil && run.goal?.goal == "faster-builds")
        // --goal wins over a run's goal.
        let named = try GoalCommandLine.request(["goal", "show", "--goal", "x"], environment: ["HEED_GOAL": "y"])
        #expect(named.goal?.goal == "x")
        // The control verbs do not take goal: it has its own parser.
        #expect(throws: HookCommandLine.UsageError.self) { try ControlCommandLine.parse(["goal"], directory: "/") }
    }

    @Test func exitCodesAndOutputFollowTheReply() {
        let done = GoalCommandLine.finish(ControlReply(goal: GoalReply("added", message: "added g/a")), json: false)
        #expect(done.out == "added g/a" && done.err == nil && done.code == 0)
        let refused = GoalCommandLine.finish(ControlReply(goal: .refused("no item x")), json: false)
        #expect(refused.out == nil && refused.err == "heed goal: no item x" && refused.code == 1)
        // With --json even a refusal is JSON on stdout, for the agent to parse; the code still says it failed.
        let json = GoalCommandLine.finish(ControlReply(goal: .refused("no item x")), json: true)
        #expect(json.code == 1 && json.out?.contains("\"exit\" : 1") == true)
        let held = GoalCommandLine.finish(
            ControlReply(goal: GoalReply("held", exit: .waiting, message: "m")),
            json: false
        )
        #expect(held.code == 5)
        // An app too old to know `goal` answers without one.
        let old = GoalCommandLine.finish(ControlReply.failure("not a request"), json: false)
        #expect(old.code == 1 && old.err?.contains("not a request") == true)
    }
}

struct GoalControlTests {
    @Test func theGoalIsTheCallersUnlessNamed() async throws {
        let (ops, goal) = try await world()
        let other = try await ops.create(title: "Docs site", statement: "x", now: now)
        #expect(try await reply(run("show", ops))?.goal == goal.id)
        #expect(try await reply(run("show --goal \(other.id)", ops))?.goal == other.id)
        // By title too.
        let titled = await GoalControl.run(
            GoalCommand(.show, goal: "docs site"), caller: caller, ops: ops, files: .fixture, now: now
        )
        #expect(reply(titled)?.goal == other.id)
        let loose = try await reply(run("show", ops, caller: GoalCaller(session: "s9", title: "Loose")))
        #expect(loose?.exit == .noGoal && loose?.message.contains("heed goal attach") == true)
        #expect(try await reply(run("show", ops, caller: nil))?.exit == .noGoal)
        #expect(try await reply(run("show --goal nope", ops))?.exit == .refused)
    }

    @Test func recordsApplyAndScopeWaits() async throws {
        let (ops, goal) = try await world()
        let before = try await ops.snapshot().goal(goal.id)?.version ?? 0
        let decided = try #require(try await reply(run("decision add Use sccache", ops)))
        #expect(decided.outcome == "applied" && decided.version == before + 1)
        #expect(try await ops.text(of: goal.id).contains("- Use sccache (source: Fix anchors)"))

        let scoped = try #require(try await reply(run("propose not-the-goal Remote execution", ops)))
        #expect(scoped.outcome == "proposed" && scoped.exit == .ok && scoped.edit != nil)
        #expect(try await !ops.text(of: goal.id).contains("Remote execution"))
        #expect(try await ops.snapshot().proposals(of: goal.id).map(\.text) == ["Remote execution"])
        // Proposing what only records applies, as in the UI: the edit's kind decides, not the command.
        #expect(try await reply(run("propose decision Keep the old cache", ops))?.outcome == "applied")
        // Proposing a new criterion or a new goal statement waits too.
        #expect(try await reply(run("propose done-when Warm build under 5s", ops))?.outcome == "proposed")
        #expect(try await reply(run("propose goal Builds are instant", ops))?.outcome == "proposed")
        // The same decision twice changes nothing.
        #expect(try await reply(run("decision add Use sccache", ops))?.outcome == "moot")
    }

    @Test func criteriaAreCheckedOnlyWithEvidenceByNumberOrText() async throws {
        let (ops, goal) = try await world()
        let checked = try #require(try await reply(run("criterion check 2 --evidence ci-run-81", ops)))
        #expect(checked.outcome == "applied")
        let doc = try await GoalDoc.parse(ops.text(of: goal.id))
        #expect(doc.doneWhen[1].met && doc.doneWhen[1].evidence == "ci-run-81" && !doc.doneWhen[0].met)
        #expect(try await reply(run("criterion check cold build under 60s --evidence bench", ops))?
            .outcome == "applied")
        let missing = try #require(try await reply(run("criterion check 7 --evidence x", ops)))
        #expect(missing.exit == .refused && missing.message.contains("1. Cold build under 60s"))
        // Without evidence the edit would be scope; the router never sees one, but GoalOps would make it wait.
        let bare = GoalCommand(.criterionCheck, subject: "1")
        let waited = try await reply(GoalControl.run(bare, caller: caller, ops: ops, files: .fixture, now: now))
        #expect(waited?.outcome == "moot" || waited?.outcome == "proposed")
    }

    @Test func questionsAreCardsAndAnswersAreDecisions() async throws {
        let (ops, goal) = try await world()
        let asked = try #require(try await reply(run("question add Do we cache tests too", ops)))
        let id = try #require(asked.item)
        var snapshot = try await ops.snapshot()
        let card = try #require(snapshot.item(id))
        #expect(card.kind == .question && card.source == .session && card.links == [GoalItem.Link(.session, "s1")])
        #expect(Board.column(card, evidence: snapshot.evidence) == .toExplore)

        let answered = try #require(try await reply(run("question answer \(card.slug) Yes, unit tests only", ops)))
        #expect(answered.outcome == "applied" && answered.item == id)
        snapshot = try await ops.snapshot()
        #expect(try Board.column(#require(snapshot.item(id)), evidence: snapshot.evidence) == .done)
        #expect(try await ops.text(of: goal.id).contains("- Yes, unit tests only"))

        // A GOAL.md open question, by number: answered, it leaves GOAL.md (a record) and the answer is a decision.
        #expect(try await reply(run("question answer 1 Local disk", ops))?.outcome == "applied")
        let doc = try await GoalDoc.parse(ops.text(of: goal.id))
        #expect(doc.openQuestions.isEmpty && doc.decisions.map(\.text).contains("Local disk"))
        let none = try #require(try await reply(run("question answer nothing-here Hm", ops)))
        #expect(none.exit == .refused)
    }

    @Test func itemsAddSplitMoveAndFinish() async throws {
        let (ops, goal) = try await world()
        let parent = try #require(try await reply(run("item add Cache the toolchain", ops))?.item)
        #expect(parent == "\(goal.id)/cache-the-toolchain")
        let child = try #require(try await reply(run(
            "item add Measure cold builds --parent cache-the-toolchain --by-subagent explorer", ops
        ))?.item)
        let snapshot = try await ops.snapshot()
        let made = try #require(snapshot.item(child))
        #expect(made.parent == parent && made.source == .subagent)
        #expect(made.reason == "added by subagent explorer in Fix anchors")
        #expect(try await reply(run("item add X --parent nope", ops))?.exit == .refused)

        #expect(try await reply(run("item move cache-the-toolchain verify", ops))?.message.contains("Verify") == true)
        #expect(try await ops.snapshot().item(parent)?.placement?.column == .verify)
        let done = try await reply(run("item done \(child) --evidence bench-12", ops))
        #expect(done?.outcome == "moved")
        let after = try await ops.snapshot()
        #expect(try Board.column(#require(after.item(child)), evidence: after.evidence) == .done)
        #expect(after.evidence.contains { $0.item == child && $0.text == "bench-12" && $0.source == "session s1" })
        #expect(try await reply(run("item done nope", ops))?.exit == .refused)
    }

    @Test func attachAndLinkPullRequests() async throws {
        let (ops, goal) = try await world()
        let other = try await ops.create(title: "Docs site", statement: "x", now: now)
        let moved = try #require(try await reply(run("attach \(other.id)", ops)))
        #expect(moved.outcome == "attached" && moved.message.contains("was \(goal.id)"))
        #expect(try await ops.snapshot().links.first { $0.target == "s1" }?.goal == other.id)
        #expect(try await reply(run("attach", ops))?.message.contains(other.id) == true)
        #expect(try await reply(run("attach nope", ops))?.exit == .refused)

        let item = try #require(try await reply(run("item add Cache", ops))?.item)
        let linked = try await reply(run("link pr #12 --item cache", ops))
        #expect(linked?.outcome == "linked" && linked?.message.contains("acme/docs#12") == true)
        let snapshot = try await ops.snapshot()
        #expect(snapshot.links.contains { $0.kind == .pr && $0.target == "acme/docs#12" && $0.goal == other.id })
        #expect(snapshot.item(item)?.linked(.pr) == ["acme/docs#12"])
        // #n needs the caller's repo.
        let chat = GoalCaller(session: "s1", title: "Chat", isChat: true)
        #expect(try await reply(run("link pr #3", ops, caller: chat))?.exit == .refused)
        #expect(GoalControl.pull("https://github.com/a/b/pull/9", repo: nil)?.description == "a/b#9")
        #expect(GoalControl.pull("a/b#9", repo: nil)?.description == "a/b#9")
    }

    @Test func spawnAndReviewGoToTheApp() async throws {
        let (ops, goal) = try await world()
        let item = try #require(try await reply(run("item add Cache", ops))?.item)
        let spawned = try await run("item spawn cache --agent codex --background", ops)
        #expect(try spawned == .app(.spawn(GoalSpawn(
            goal: goal.id, item: item, agent: "codex", background: true, from: "Fix anchors", caller: "s1"
        )), goal: #require(try await ops.snapshot().goal(goal.id))))
        #expect(try await reply(run("item spawn nope", ops))?.exit == .refused)
        guard case .app(.review(goal: goal.id, kind: "security"), _) = try await run("review request security", ops)
        else { Issue.record("review did not go to the app"); return }
    }

    @Test func listAndShowReadEverything() async throws {
        let (ops, goal) = try await world()
        _ = try await run("item add Cache", ops)
        _ = try await run("propose not-the-goal Remote execution", ops)
        let list = try #require(try await reply(run("list", ops))?.goals)
        #expect(list.map(\.id) == [goal.id] && list[0].current && list[0].criteriaTotal == 2 && list[0].items == 1)
        #expect(GoalRow.table(list).hasPrefix("* \(goal.id)"))

        let view = try #require(try await reply(run("show", ops))?.view)
        #expect(view.items.map(\.id) == ["\(goal.id)/cache"])
        // Added from a session, it is linked to it: Working.
        #expect(view.items[0].stages.count == Stage.allCases.count && view.items[0].column == "working")
        #expect(view.proposals == ["+ Not the goal: Remote execution"])
        #expect(view.doc.contains("Cold build under 60s"))
        #expect(view.text.contains("Waiting for you") && view.text.contains("\(goal.id)/cache"))
        let json = try #require(try await reply(run("show --json", ops))).rendered(json: true)
        let decoded = try JSONDecoder().decode(GoalReply.self, from: Data(json.utf8))
        #expect(decoded.view == view)
    }
}

struct GoalSpawnCapTests {
    private func spawn(_ ref: String, hours: Double) -> GoalEvidence {
        GoalEvidence(
            goal: "g",
            item: "g/a",
            kind: .built,
            state: .inProgress,
            at: now + hours * 3600,
            source: "spawn",
            ref: ref
        )
    }

    @Test func atOnceThenPerDay() {
        let calendar = Calendar(identifier: .gregorian)
        let two = [spawn("s1", hours: 0), spawn("s2", hours: 1)]
        func verdict(_ evidence: [GoalEvidence], going: Set<String>, hours: Double = 2) -> GoalSpawnCap.Verdict {
            GoalSpawnCap.verdict(
                goal: "g", evidence: evidence, going: { going.contains($0) }, atOnce: 2, perDay: 3,
                now: now + hours * 3600, calendar: calendar
            )
        }
        #expect(verdict(two, going: ["s1", "s2"]) == .atOnce(limit: 2))
        #expect(verdict(two, going: ["s1"]) == .go)
        let three = two + [spawn("run:x", hours: 1.5)]
        #expect(verdict(three, going: []) == .today(limit: 3))
        // Tomorrow the day's count starts again; other goals and a run's end do not count.
        #expect(verdict(three, going: [], hours: 30) == .go)
        let noise = [
            GoalEvidence(goal: "h", item: "h/a", kind: .built, state: .inProgress, at: now, source: "spawn", ref: "q"),
            GoalEvidence(goal: "g", item: "g/a", kind: .built, state: .done, at: now, source: "spawn", ref: "r"),
            GoalEvidence(
                goal: "g",
                item: "g/a",
                kind: .built,
                state: .inProgress,
                at: now,
                source: "session s",
                ref: "s"
            ),
        ]
        #expect(verdict(two + noise, going: ["q", "r", "s"]) == .go)
        #expect(GoalSpawnCap.Verdict.go.reason == nil && verdict(two, going: ["s1", "s2"]).reason != nil)
    }

    @Test func aSpawnLeavesEvidenceTheCapCounts() {
        let spawn = GoalSpawn(goal: "g", item: "g/a", agent: nil, background: false, from: "Fix", caller: "s1")
        let entry = GoalSpawnCap.started(spawn, ref: "s7", title: "Cache", now: now)
        #expect(GoalSpawnCap.spawns([entry], goal: "g").map(\.ref) == ["s7"])
        #expect(entry.item == "g/a" && entry.kind == .built && entry.text == "session Cache, spawned by Fix")
    }

    @Test func backgroundRunsAreHeadlessInTheirOwnWorktree() {
        let claude = GoalSpawnRun.headless(
            agent: "claude", command: "claude", prompt: "do it", worktree: "/w", instructions: ["--plugin-dir", "/p"]
        )
        #expect(claude?.prefix(3) == ["claude", "-p", "do it"])
        #expect(claude?.contains("acceptEdits") == true && claude?.contains("Bash(heed goal *)") == true)
        // The plugin comes before the variadic --allowedTools, which would swallow it.
        #expect(claude.flatMap { $0.firstIndex(of: "--plugin-dir") }! < claude
            .flatMap { $0.firstIndex(of: "--allowedTools") }!)
        let codex = GoalSpawnRun.headless(
            agent: "codex",
            command: "codex",
            prompt: "do it",
            worktree: "/w",
            instructions: []
        )
        #expect(codex == ["codex", "exec", "--sandbox", "workspace-write", "-C", "/w", "do it"])
        #expect(GoalSpawnRun.headless(agent: "pi", command: "pi", prompt: "", worktree: "/w", instructions: []) == nil)
        let item = GoalItem(id: "g/cache", goal: "g", title: "Cache", source: .you, createdAt: now)
        #expect(GoalSpawnRun.branch(item: item) == "heed/spawn/g/cache")
        #expect(GoalSpawnRun.worktreePath(root: "/wt", repo: Repo(org: "a", name: "b"), item: item)
            == "/wt/heed/b/spawn-g-cache")
    }

    @Test func heldSpawnsAreOneAttentionAskPerGoal() {
        let goal = HeedGoal(id: "g", title: "Faster builds", createdAt: now)
        let spawn = GoalSpawn(goal: "g", item: "g/a", agent: nil, background: false, from: "Fix", caller: "s1")
        let held = [
            GoalHeldSpawn(spawn: spawn, title: "A", reason: "2 at once", at: now),
            GoalHeldSpawn(spawn: spawn, title: "B", reason: "2 at once", at: now + 5),
        ]
        let items = GoalAttention.items(goals: [goal], qualities: [:], waiting: [:], spawns: ["g": held], now: now)
        #expect(items.map(\.id) == ["goal:g:spawn"])
        #expect(items[0].reasons == [.goalSpawn] && items[0].title.contains("2 spawns wait"))
        #expect(GoalAttention.goal(of: items[0]) == "g")
        #expect(items[0].placeholderSummary.contains("y starts it"))
    }
}

struct GoalSpawnConfigTests {
    @Test func theCapsAreReadAndDocumented() throws {
        let (decoded, problems) = ConfigLoader.decode("""
        [goals]
        spawn_concurrent = 1
        spawn_per_day = 10
        """)
        let config = try #require(decoded)
        #expect(problems.isEmpty && config.goals.spawnConcurrent == 1 && config.goals.spawnPerDay == 10)
        let (bad, complaints) = ConfigLoader.decode("[goals]\nspawn_concurrent = 99\n")
        #expect(bad?.goals.spawnConcurrent == 2 && complaints.map(\.path) == ["goals.spawn_concurrent"])
        let defaults = try #require(ConfigLoader.decode(ConfigLoader.defaultSource).config)
        #expect(defaults.goals.spawnConcurrent == 2 && defaults.goals.spawnPerDay == 6)
        #expect(ConfigLoader.defaultSource.contains("spawn_concurrent = 2"))
    }
}

struct HeedPluginTests {
    @Test func thePluginIsAManifestAndOneSkill() throws {
        let files = HeedPlugin.files(version: "1.2.3")
        #expect(Set(files.keys) == [".claude-plugin/plugin.json", "skills/heed-goal/SKILL.md"])
        let json = try #require(files[".claude-plugin/plugin.json"])
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(manifest["name"] as? String == "heed" && manifest["version"] as? String == "1.2.3")
        let skill = try #require(files["skills/heed-goal/SKILL.md"])
        #expect(skill.hasPrefix("---\nname: heed-goal\ndescription: "))
        #expect(skill.components(separatedBy: "\n---\n").count == 2)
        // Every rule is in the skill, with its command.
        for rule in GoalGuidance.rules {
            #expect(skill.contains(rule.text))
            if let command = rule.command { #expect(skill.contains("`\(command)`")) }
        }
        for word in ["GOAL.md", "Not the goal", "--by-subagent", "--evidence", "propose", "spawn", "summary"] {
            #expect(skill.contains(word))
        }
    }

    @Test func writingKeepsItCurrentAndOnlyItsOwn() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("heed-plugin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try HeedPlugin.write(to: folder, version: "1.0")
        let manifest = folder.appendingPathComponent(".claude-plugin/plugin.json")
        let skill = folder.appendingPathComponent("skills/heed-goal/SKILL.md")
        #expect(try String(contentsOf: manifest, encoding: .utf8).contains("\"1.0\""))
        let stale = folder.appendingPathComponent("skills/old/SKILL.md")
        try FileManager.default.createDirectory(
            at: stale.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "old".write(to: stale, atomically: true, encoding: .utf8)
        let written = try FileManager.default.attributesOfItem(atPath: skill.path)[.modificationDate] as? Date
        try HeedPlugin.write(to: folder, version: "1.1")
        #expect(try String(contentsOf: manifest, encoding: .utf8).contains("\"1.1\""))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        // What did not change is not written again.
        #expect(try FileManager.default.attributesOfItem(atPath: skill.path)[.modificationDate] as? Date == written)
    }

    @Test func integrationFilesWriteThePluginBesideTheHooks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("heed-int-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = IntegrationFiles(directory: folder, version: "9.9")
        #expect(files.plugin == folder.appendingPathComponent("plugin").path)
        try files.write()
        #expect(FileManager.default.fileExists(atPath: files.plugin + "/skills/heed-goal/SKILL.md"))
    }

    @Test func theGuidanceIsPlainForCommandLinesAndTOML() {
        let text = GoalGuidance.instructions
        #expect(!text.contains { "\"'`$\\|".contains($0) })
        #expect(text.contains("heed goal show") && text.contains("--evidence"))
    }
}

struct GoalLaunchTests {
    private let pointer = GoalPointer.text(title: "Faster builds", path: "/g/GOAL.md")

    @Test func claudeLoadsThePluginInsteadOfThePointer() {
        let args = GoalLaunch.arguments(agent: "claude", signOff: nil, pointer: pointer, plugin: "/p")
        #expect(args == ["--plugin-dir", "/p"])
        let signed = GoalLaunch.arguments(agent: "claude", signOff: SignOff.instruction, pointer: pointer, plugin: "/p")
        #expect(signed == ["--plugin-dir", "/p", "--append-system-prompt", SignOff.instruction])
    }

    @Test func withoutThePluginClaudeGetsThePointer() {
        #expect(GoalLaunch.arguments(agent: "claude", signOff: nil, pointer: pointer, plugin: nil)
            == ["--append-system-prompt", pointer])
    }

    @Test func codexGetsThePointerAndTheSameGuidance() {
        let args = GoalLaunch.arguments(agent: "codex", signOff: nil, pointer: pointer, plugin: "/p")
        #expect(args.count == 2 && args[0] == "-c" && !args.contains("--plugin-dir"))
        #expect(args[1].contains(pointer) && args[1].contains("heed goal decision add"))
    }

    @Test func noGoalNoGoalArguments() {
        #expect(GoalLaunch.arguments(agent: "claude", signOff: nil, pointer: nil, plugin: "/p") == [])
        #expect(GoalLaunch.arguments(agent: "claude", signOff: "x", pointer: nil, plugin: "/p")
            == ["--append-system-prompt", "x"])
        #expect(GoalLaunch.arguments(agent: "pi", signOff: nil, pointer: pointer, plugin: "/p") == [])
    }

    @Test func workSettingsPassThePluginOnlyOnThisMac() throws {
        var settings = WorkSettings()
        settings.goalPointers = ["s1": pointer]
        settings.goalPlugin = "/p"
        let claude = try #require(settings.agent("claude"))
        #expect(settings.signOffArguments(agent: claude, repo: nil, session: "s1") == ["--plugin-dir", "/p"])
        #expect(settings.signOffArguments(agent: claude, repo: nil, session: "s1", host: "box")
            == ["--append-system-prompt", pointer])
        #expect(settings.signOffArguments(agent: claude, repo: nil, session: "s2") == [])
        settings.goalPlugin = nil
        #expect(settings.signOffArguments(agent: claude, repo: nil, session: "s1") == [
            "--append-system-prompt",
            pointer,
        ])
    }
}

struct GoalSocketTests {
    /// The CLI's path end to end: its request over a real socket to a fake app that runs `GoalControl` on an
    /// in-memory store, and the reply back as an exit code and words.
    @Test func aCommandCrossesTheSocket() async throws {
        let (ops, goal) = try await world()
        let path = "/tmp/heed-goal-\(UUID().uuidString.prefix(8)).sock"
        let server = ControlServer(path: path) { request in
            guard request.method == .goal, let command = request.goal else { return .failure("no") }
            let caller = request.session == "s1" ? caller : nil
            switch await GoalControl.run(command, caller: caller, ops: ops, files: .fixture, now: now) {
            case let .reply(reply): return ControlReply(goal: reply)
            case .app: return ControlReply(goal: GoalReply("started", message: "app"))
            }
        }
        try server.start()
        defer { server.stop() }
        let decided = try GoalCommandLine.request(
            ["goal", "decision", "add", "Use", "sccache"], environment: ["HEED_SESSION_ID": "s1"]
        )
        let outside = try GoalCommandLine.request(["goal", "show"], environment: [:])
        let replies = try await onThread {
            let client = try ControlClient(path: path)
            return try (client.call(decided), client.call(outside))
        }
        #expect(GoalCommandLine.finish(replies.0, json: false).code == 0)
        #expect(replies.0.goal?.outcome == "applied")
        #expect(try await ops.text(of: goal.id).contains("Use sccache"))
        #expect(GoalCommandLine.finish(replies.1, json: false).code == GoalExit.noGoal.rawValue)
        // No app at all: the client cannot connect, which the CLI turns into exit 3.
        #expect(throws: ControlClientError.self) { try ControlClient(path: path + ".gone") }
    }
}

private func onThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result { try body() }) }.start()
    }
}
