@testable import HeedCore
import Testing

private func engine() -> ModeEngine {
    let built = Keymaps.build()
    #expect(built.problems.isEmpty)
    return ModeEngine(keymaps: built.keymaps, scoped: built.scoped)
}

private func press(_ engine: inout ModeEngine, _ notation: String) -> [ModeEngine.Outcome] {
    // swiftlint:disable:next force_try
    try! KeyNotation.parse(notation).map { engine.handle($0) }
}

struct KeyNotationTests {
    @Test func parsesPlainAndBracketedKeys() throws {
        #expect(try KeyNotation.parse("gg") == [KeyStroke("g"), KeyStroke("g")])
        #expect(try KeyNotation.parse("<C-w>v") == [KeyStroke("w", .control), KeyStroke("v")])
        #expect(try KeyNotation.parse("<C-W>") == [KeyStroke("w", .control)])
        #expect(try KeyNotation.parse("<D-/>") == [KeyStroke("/", .command)])
        #expect(try KeyNotation.parse("<C-\\>") == [KeyStroke("\\", .control)])
        #expect(try KeyNotation.parse("<esc>") == [.escape])
        #expect(try KeyNotation.parse("<lt>") == [KeyStroke("<")])
    }

    @Test func roundTrips() throws {
        for notation in ["gg", "<C-w>v", "''", "<D-1>", "<CR>", "<S-Tab>", "]p"] {
            #expect(try KeyNotation.format(KeyNotation.parse(notation)) == notation)
        }
    }

    @Test func rejectsUnknownNames() {
        #expect(throws: KeyNotation.ParseError.self) { try KeyNotation.parse("<Nope>") }
        #expect(throws: KeyNotation.ParseError.self) { try KeyNotation.parse("<X-a>") }
    }

    @Test func glyphs() throws {
        #expect(try KeyNotation.parse("<C-w>")[0].glyph == "⌃w")
        #expect(try KeyNotation.parse("<D-/>")[0].glyph == "⌘/")
    }
}

struct KeymapTests {
    @Test func prefixesWait() throws {
        var keymap = Keymap()
        try keymap.bind(KeyNotation.parse("gg"), to: "row.first")
        #expect(try keymap.lookup(KeyNotation.parse("g")) == .prefix)
        #expect(try keymap.lookup(KeyNotation.parse("gg")) == .command("row.first"))
        #expect(try keymap.lookup(KeyNotation.parse("gx")) == .none)
    }

    @Test func shadowingIsRejectedBothWays() throws {
        var keymap = Keymap()
        try keymap.bind(KeyNotation.parse("gg"), to: "row.first")
        #expect(throws: Keymap.BindError.self) { try keymap.bind(KeyNotation.parse("g"), to: "x") }
        var other = Keymap()
        try other.bind(KeyNotation.parse("g"), to: "x")
        #expect(throws: Keymap.BindError.self) { try other.bind(KeyNotation.parse("gg"), to: "y") }
    }

    @Test func copiesDoNotShareEdits() throws {
        var first = Keymap()
        try first.bind(KeyNotation.parse("gg"), to: "a")
        var second = first
        try second.bind(KeyNotation.parse("gt"), to: "b")
        #expect(try first.lookup(KeyNotation.parse("gt")) == .none)
        #expect(try second.lookup(KeyNotation.parse("gt")) == .command("b"))
    }
}

struct ModeEngineTests {
    @Test func countsApplyToTheNextCommand() {
        var engine = engine()
        let outcomes = press(&engine, "3j")
        #expect(outcomes == [.pending, .run(CommandInvocation(name: "row.next", count: 3))])
        #expect(engine.pendingDisplay.isEmpty)
    }

    @Test func multiKeySequencesShowWhatIsPending() {
        var engine = engine()
        #expect(press(&engine, "2<C-w>") == [.pending, .pending])
        #expect(engine.pendingDisplay == "2<C-w>")
        #expect(press(&engine, "v") == [.run(CommandInvocation(name: "pane.split.right", count: 2))])
    }

    @Test func argumentsComeFromTheBinding() {
        var engine = engine()
        #expect(press(&engine, "'3").last == .run(CommandInvocation(name: "pin.jump", arguments: ["3"])))
    }

    @Test func escapeClearsPendingFirst() {
        var engine = engine()
        _ = press(&engine, "g")
        #expect(engine.handle(.escape) == .cleared)
        #expect(engine.handle(.escape) == .run(CommandInvocation(name: "overlay.close")))
    }

    @Test func unboundSequencesClear() throws {
        var engine = engine()
        #expect(try press(&engine, "gq") == [.pending, .unbound(KeyNotation.parse("gq"))])
        #expect(engine.pendingDisplay.isEmpty)
    }

    @Test func insertPassesEverythingButTheEscapeChord() {
        var engine = engine()
        _ = press(&engine, "i")
        #expect(engine.mode == .insert)
        #expect(press(&engine, "jk:<Esc>") == [.terminal, .terminal, .terminal, .terminal])
        #expect(press(&engine, "<C-\\>") == [.run(CommandInvocation(name: "mode.normal"))])
        #expect(engine.mode == .normal)
    }

    @Test func helpWorksInInsert() {
        var engine = engine()
        engine.enter(.insert)
        #expect(press(&engine, "?") == [.terminal])
        #expect(press(&engine, "<D-/>") == [.run(CommandInvocation(name: "overlay.help"))])
    }

    @Test func commandModeFeedsText() {
        var engine = engine()
        _ = press(&engine, ":")
        #expect(engine.mode == .command)
        #expect(press(&engine, "pr") == [.text(KeyStroke("p")), .text(KeyStroke("r"))])
        #expect(press(&engine, "<CR>") == [.run(CommandInvocation(name: "command.submit"))])
    }
}

struct ContinuationTests {
    @Test func pendingPrefixesListWhatCanFollow() throws {
        var engine = engine()
        #expect(engine.continuations.isEmpty)
        _ = press(&engine, "<C-w>")
        let next = engine.continuations.map { KeyNotation.format($0.rest) }
        #expect(next.contains("v") && next.contains("s") && next.contains("z"))
        #expect(engine.continuations.first { KeyNotation.format($0.rest) == "v" }?.command == "pane.split.right")
        _ = engine.handle(.escape)
        #expect(engine.continuations.isEmpty)
    }

    @Test func viewBindingsWinOverTheModesOwn() {
        var engine = engine()
        engine.scope = "diff"
        _ = press(&engine, "]")
        let rows = Dictionary(uniqueKeysWithValues: engine.continuations
            .map { (KeyNotation.format($0.rest), $0.command) })
        #expect(rows["f"] == "diff.file.next")
        #expect(rows["p"] == "pr.next")
    }
}

struct ScopedKeyTests {
    @Test func scopedBindingsApplyOnlyInTheirView() {
        var engine = engine()
        #expect(press(&engine, "r") == [.unbound([KeyStroke("r")])])
        #expect(press(&engine, "o") == [.run(CommandInvocation(name: "work.start"))])
        engine.scope = "repos"
        #expect(press(&engine, "r") == [.run(CommandInvocation(name: "repo.scan"))])
        // o still starts work, in the repo under the cursor.
        #expect(press(&engine, "o") == [.run(CommandInvocation(name: "worktree.new"))])
        #expect(press(&engine, "j") == [.run(CommandInvocation(name: "row.next"))])
    }

    @Test func enterInSessionsTypesIntoTheAgentAndReadsElsewhere() {
        var engine = engine()
        engine.scope = "sessions"
        #expect(press(&engine, "<CR>") == [.run(CommandInvocation(name: "session.agent"))])
        // The reader and the browser keep their own keys there.
        #expect(press(&engine, "go").last == .run(CommandInvocation(name: "overlay.item")))
        #expect(press(&engine, "gB").last == .run(CommandInvocation(name: "open.browser")))
        engine.scope = "inbox"
        #expect(press(&engine, "<CR>") == [.run(CommandInvocation(name: "open.reader"))])
        #expect(Commands.spec("session.agent") != nil)
    }

    @Test func oneKeyOneMeaning() {
        // x is "done with it" wherever it is bound, o is always starting work (a goal's board: on the card's item), and
        // the GitHub views read with ↩.
        #expect(DefaultKeys.normal.contains { $0 == ("x", "session.close") })
        #expect(DefaultKeys.scoped["inbox"]?.contains { $0 == ("x", "items.read") } == true)
        #expect(DefaultKeys.scoped["pr"]?.contains { $0 == ("x", "feedback.dismiss") } == true)
        for (scope, table) in DefaultKeys.scoped {
            for (keys, command) in table where keys == "o" {
                #expect(["worktree.new", "goal.item.work"].contains(command), "o in \(scope) is \(command)")
            }
        }
        #expect(DefaultKeys.normal.contains { $0 == ("m", "session.pin") })
    }

    @Test func goalPaneCapitalsAreTheSameInEveryGoalsView() throws {
        // E B R P X U S W T switch a goal's pane from every view of Goals, and no pane binds one to an action of its
        // own.
        let built = Keymaps.build()
        #expect(DefaultKeys.goalPanes.map(\.0) == ["E", "B", "R", "P", "X", "U", "S", "W", "T"])
        for scope in DefaultKeys.goalScopes {
            let keymap = try #require(built.scoped[scope], "\(scope)")
            let table = try #require(DefaultKeys.scoped[scope], "\(scope)")
            for (key, command) in DefaultKeys.goalPanes {
                #expect(try keymap.lookup(KeyNotation.parse(key)) == .command(command), "\(key) in \(scope)")
                for (bound, other) in table where bound == key {
                    #expect(other == command, "\(key) in \(scope) is \(other)")
                }
            }
        }
        // Every view that has Goals' keys is one of Goals' scopes, so a new pane cannot slip past the rule.
        for (scope, table) in DefaultKeys.scoped where table.contains(where: { $0 == ("B", "goal.board") }) {
            #expect(DefaultKeys.goalScopes.contains(scope), "\(scope)")
        }
    }

    @Test func goalActionsStayOnTheGoal() throws {
        // a archive, x detach, e edit, n new, w sharpen, u undo, r re-check act on the goal: only on the list, the
        // overview and GOAL.md. A pane binds the key to its own row's meaning or leaves it unbound.
        let built = Keymaps.build()
        let onTheGoal: Set = ["goals", "goaldoc"]
        let actions = Set(DefaultKeys.goalActions.map(\.1))
        // A pane may bind an action to its own row where it means just that there (Reviewers re-checks its reviewers,
        // Unassigned takes back its last attach).
        let ownMeaning: Set = ["goalreviewers review.recheck", "unassigned goal.attach.undo"]
        for scope in DefaultKeys.goalScopes where !onTheGoal.contains(scope) {
            let keymap = try #require(built.scoped[scope], "\(scope)")
            for command in ["goal.archive", "goal.detach"] {
                #expect(keymap.keys(for: command).isEmpty, "\(scope) binds \(command)")
            }
            for command in actions where !ownMeaning.contains("\(scope) \(command)") {
                #expect(keymap.keys(for: command).isEmpty, "\(scope) inherits \(command)")
            }
        }
        for scope in onTheGoal {
            let keymap = try #require(built.scoped[scope])
            #expect(try keymap.lookup(KeyNotation.parse("a")) == .command("goal.archive"), "\(scope)")
            #expect(try keymap.lookup(KeyNotation.parse("x")) == .command("goal.detach"), "\(scope)")
        }
    }

    @Test func goalStatusBarHintsAreBoundInTheirPane() throws {
        // Every hint the status bar shows in a Goals pane is a key of that pane: the map does not offer `a archive`.
        // A new Goals scope without hints of its own gets the list's, which it does not bind, and fails here.
        let built = Keymaps.build()
        let focuses = [
            "goals",
            "links",
            "reviewers",
            "objections",
            "personas",
            "friction",
            "tasks",
            "versions",
            "steering",
            "agents",
        ]
        var contexts: [GoalHints.Context] = []
        for focus in focuses {
            for flags in 0 ..< 16 {
                contexts.append(GoalHints.Context(
                    focus: focus, proposals: flags & 1 != 0, running: flags & 2 != 0, pendingChange: flags & 4 != 0,
                    done: flags & 8 != 0
                ))
            }
        }
        for scope in DefaultKeys.goalScopes {
            let keymap = try #require(built.scoped[scope], "\(scope)")
            for context in contexts {
                let hints = GoalHints.hints(scope: scope, context).hints
                #expect(!hints.isEmpty, "\(scope) has no hints")
                for hint in hints {
                    #expect(!keymap.keys(for: hint.command).isEmpty, "\(scope) shows \(hint.command), not bound there")
                }
            }
        }
        // The goal's own actions show only where the goal is what you are on.
        for scope in ["goalmap", "goalagents", "goalplan", "goalboard"] {
            let commands = GoalHints.hints(scope: scope, GoalHints.Context()).hints.map(\.command)
            #expect(!commands.contains("goal.archive") && !commands.contains("goal.new"), "\(scope)")
        }
    }

    @Test func goalLowercaseKeysMeanTheSameAcrossPanes() throws {
        let built = Keymaps.build()
        func command(_ key: String, _ scope: String) throws -> String? {
            guard case let .command(line) = try built.scoped[scope]?.lookup(KeyNotation.parse(key)) else { return nil }
            return line
        }
        // s starts a session on the thing under the cursor, c a chat about it.
        #expect(try command("s", "goalboard") == "goal.item.work")
        #expect(try command("s", "goalreviewers") == "review.fix")
        #expect(try command("s", "goalevals") == "eval.fix")
        #expect(try command("s", "goalpersonas") == "persona.session")
        #expect(try command("c", "goalreviewers") == "review.why")
        #expect(try command("c", "goalpersonas") == "persona.chat")
        // y n answer the change waiting; A accepts or approves; a adds; r does it again; c is free in the plan.
        for scope in ["goaldoc", "goalplan"] {
            #expect(try command("y", scope)?.hasSuffix("accept") == true, "y in \(scope)")
            #expect(try command("n", scope)?.hasSuffix("reject") == true, "n in \(scope)")
        }
        #expect(try command("A", "goalreviewers") == "review.accept")
        #expect(try command("A", "goalevals") == "eval.accept")
        #expect(try command("A", "goalplan") == "swarm.approve")
        #expect(try command("a", "goalboard") == "goal.item.add")
        #expect(try command("a", "goalplan") == "swarm.task.add")
        #expect(try command("r", "goalpersonas") == "persona.derive")
        #expect(try command("c", "goalplan") == "swarm.controller")
        #expect(try command("i", "goalplan") == "swarm.answer")
        // Landing: m the merge order, b a stacked PR's new base; o stays starting work.
        #expect(try command("m", "goalplan") == "swarm.order")
        #expect(try command("b", "goalplan") == "swarm.land")
    }

    @Test func aViewThatBindsADigitHasItUnlessACountIsBeingTyped() {
        var engine = engine()
        engine.scope = "goalplan"
        #expect(press(&engine, "2") == [.run(CommandInvocation(name: "swarm.answer.option", arguments: ["2"]))])
        // Elsewhere a digit is a count, as in vim.
        engine.scope = "goals"
        #expect(press(&engine, "2j") == [.pending, .run(CommandInvocation(name: "row.next", count: 2))])
    }

    @Test func commandsOutliveTheirKeys() {
        // Unbinding a key keeps its command: : runs it, and config can bind it again.
        for name in ["repo.add", "cleanup.rules"] {
            #expect(Commands.spec(name) != nil, "\(name)")
        }
    }
}

struct RowGroupTests {
    @Test func bracesMoveByGroupLikeParagraphs() {
        let keys = ["pinned", "pinned", "needs", "working", "working", "parked"]
        #expect(RowGroups.next(keys, from: 0) == 2)
        #expect(RowGroups.next(keys, from: 3) == 5)
        #expect(RowGroups.next(keys, from: 5) == nil)
        // { goes to the start of this group first, then to the previous one.
        #expect(RowGroups.previous(keys, from: 4) == 3)
        #expect(RowGroups.previous(keys, from: 3) == 2)
        #expect(RowGroups.previous(keys, from: 2) == 0)
        #expect(RowGroups.previous(keys, from: 0) == nil)
        #expect(RowGroups.next([], from: 0) == nil)
    }
}

struct KeymapsTests {
    @Test func defaultsHaveNoProblems() {
        #expect(Keymaps.build().problems.isEmpty)
    }

    @Test func overridesReplaceUnbindAndReport() throws {
        let built = Keymaps.build(overrides: [
            .normal: [("gs", ""), ("J", "row.next"), ("g", "row.first"), ("gz", "nope")],
            .insert: [("ab", "mode.normal")],
        ])
        let normal = try #require(built.keymaps[.normal])
        #expect(try normal.lookup(KeyNotation.parse("gs")) == .none)
        #expect(try normal.lookup(KeyNotation.parse("J")) == .command("row.next"))
        #expect(built.problems.map(\.keys) == ["g", "gz", "ab"])
    }

    @Test func insertEscapeIsConfigurable() throws {
        let built = Keymaps.build(insertEscape: "<C-g>")
        let insert = try #require(built.keymaps[.insert])
        #expect(try insert.lookup(KeyNotation.parse("<C-g>")) == .command("mode.normal"))
        #expect(try insert.lookup(KeyNotation.parse("<C-\\>")) == .none)
    }
}

struct HookCommandLineTests {
    @Test func parsesEachVerb() throws {
        #expect(try HookCommandLine.parse(["state", "blocked", "--reason", "Bash(dotnet publish)"])
            == [.state(.blocked, reason: "Bash(dotnet publish)")])
        #expect(try HookCommandLine.parse(["pr", "add", "https://github.com/o/r/pull/1"])
            == [.prAdd(url: "https://github.com/o/r/pull/1")])
        #expect(try HookCommandLine.parse(["title", "Fix anchors"]) == [.title("Fix anchors")])
        #expect(throws: HookCommandLine.UsageError.self) { try HookCommandLine.parse(["state", "sleepy"]) }
    }

    @Test func messagesRoundTripAsOneLine() throws {
        let message = HookMessage(session: "s1", kind: .state(.asking, reason: "3 questions"))
        let line = try message.encodedLine()
        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)
        let decoded = try HookMessage.decode(line: line.dropLast())
        #expect(decoded.kind == message.kind)
    }

    @Test func guessesNeverOverrideReports() {
        let reported = ObservedState(.working)
        #expect(reported.accepting(ObservedState(.blocked, source: .guessed)) == reported)
        #expect(reported.accepting(ObservedState(.exited, source: .guessed)).state == .exited)
        #expect(reported.accepting(ObservedState(.done)).state == .done)
    }
}

struct InsertEscapeTests {
    @Test func shiftEscapeLeavesInsertAndPlainEscapeReachesTheTerminal() {
        let built = Keymaps.build(insertEscape: "<C-]>")
        #expect(built.problems.isEmpty)
        let insert = built.keymaps[.insert]
        #expect(insert?.lookup([KeyStroke("Esc", .shift)]) == .command("mode.normal"))
        #expect(insert?.lookup([KeyStroke("]", .control)]) == .command("mode.normal"))
        #expect(insert?.lookup([KeyStroke("\\", .control)]) == Keymap.Lookup.none)
        #expect(insert?.lookup([.escape]) == Keymap.Lookup.none)
    }
}

struct DeleteKeyTests {
    @Test func ddDeletesInSessionsAndRemovesInRepos() {
        let built = Keymaps.build()
        #expect(built.problems.isEmpty)
        let dd = [KeyStroke("d"), KeyStroke("d")]
        #expect(built.scoped["sessions"]?.lookup(dd) == .command("session.delete"))
        #expect(built.scoped["repos"]?.lookup(dd) == .command("select.remove"))
        // Nowhere else: dd in Inbox must not delete the session you are not looking at.
        #expect(built.keymaps[.normal]?.lookup(dd) == Keymap.Lookup.none)
    }
}

struct ViewBindingClashTests {
    @Test func defaultsHaveNoClashes() {
        #expect(Keymaps.build().problems.isEmpty)
    }

    @Test func aViewBindingMayNotHideANormalKey() {
        let built = Keymaps.build(scopedOverrides: ["sessions": [("iw", "session.import"), ("g", "session.import")]])
        let messages = built.problems.map(\.message)
        #expect(messages.contains { $0.contains("starts with i, which is mode.insert") })
        #expect(messages.contains { $0.contains("would hide") })
        // Neither was bound: i stays immediate, g still leads.
        #expect(built.scoped["sessions"]?.lookup([KeyStroke("i")]) == Keymap.Lookup.none)
    }

    @Test func importKeysAreIwAndIp() {
        let built = Keymaps.build()
        #expect(built.scoped["sessions"]?.lookup([KeyStroke("I"), KeyStroke("w")]) == .command("session.import"))
        #expect(built.scoped["sessions"]?.lookup([KeyStroke("I"), KeyStroke("p")]) == .command("session.import.path"))
    }
}

struct VisualKeysTests {
    @Test func visualDRemovesAtOnceInAViewThatBindsDD() {
        let built = Keymaps.build()
        var engine = ModeEngine(keymaps: built.keymaps, scoped: built.scoped)
        engine.scope = "repos"
        engine.enter(.visual)
        #expect(engine.handle(KeyStroke("d")) == .run(CommandInvocation(name: "select.remove")))
    }
}

struct DiffKeysTests {
    @Test func returnInTheDiffWritesANoteAsADoubleClickDoes() {
        var engine = engine()
        engine.scope = "diff"
        #expect(press(&engine, "<CR>") == [.run(CommandInvocation(name: "diff.ask"))])
        #expect(engine.normalCommand(for: [KeyStroke("CR")], scope: "diff") == CommandInvocation(name: "diff.ask"))
    }

    @Test func theDiffsKeysActOnASelectionInVisual() {
        var engine = engine()
        engine.scope = "diff"
        engine.enter(.visual)
        #expect(press(&engine, "a") == [.run(CommandInvocation(name: "diff.ask"))])
        #expect(press(&engine, "A") == [.run(CommandInvocation(name: "diff.ask.now"))])
        #expect(press(&engine, "y") == [.run(CommandInvocation(name: "diff.copy"))])
        #expect(press(&engine, "j") == [.run(CommandInvocation(name: "row.next"))])
        #expect(engine.mode == .visual)
        // Other views keep VISUAL's own keys: Repos' dd does not make d wait.
        engine.scope = "repos"
        #expect(press(&engine, "d") == [.run(CommandInvocation(name: "select.remove"))])
        #expect(press(&engine, "y") == [.run(CommandInvocation(name: "select.copy"))])
    }

    @Test func oneCommitByName() {
        #expect(Commands.spec("diff.commit")?.arguments != nil)
    }
}
