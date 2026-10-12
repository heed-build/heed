@testable import HeedCore
import Testing

private func engine() -> ModeEngine {
    let built = Keymaps.build()
    #expect(built.problems.isEmpty)
    return ModeEngine(keymaps: built.keymaps)
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
        try keymap.bind(KeyNotation.parse("gg"), to: "session.first")
        #expect(try keymap.lookup(KeyNotation.parse("g")) == .prefix)
        #expect(try keymap.lookup(KeyNotation.parse("gg")) == .command("session.first"))
        #expect(try keymap.lookup(KeyNotation.parse("gx")) == .none)
    }

    @Test func shadowingIsRejectedBothWays() throws {
        var keymap = Keymap()
        try keymap.bind(KeyNotation.parse("gg"), to: "session.first")
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
        #expect(outcomes == [.pending, .run(CommandInvocation(name: "session.next", count: 3))])
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

struct KeymapsTests {
    @Test func defaultsHaveNoProblems() {
        #expect(Keymaps.build().problems.isEmpty)
    }

    @Test func overridesReplaceUnbindAndReport() throws {
        let built = Keymaps.build(overrides: [
            .normal: [("gs", ""), ("J", "session.next"), ("g", "session.first"), ("gz", "nope")],
            .insert: [("ab", "mode.normal")],
        ])
        let normal = try #require(built.keymaps[.normal])
        #expect(try normal.lookup(KeyNotation.parse("gs")) == .none)
        #expect(try normal.lookup(KeyNotation.parse("J")) == .command("session.next"))
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
            == .state(.blocked, reason: "Bash(dotnet publish)"))
        #expect(try HookCommandLine.parse(["pr", "add", "https://github.com/o/r/pull/1"])
            == .prAdd(url: "https://github.com/o/r/pull/1"))
        #expect(try HookCommandLine.parse(["title", "Fix anchors"]) == .title("Fix anchors"))
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
