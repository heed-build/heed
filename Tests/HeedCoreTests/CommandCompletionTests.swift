@testable import HeedCore
import Testing

/// What `:` offers, and which key a command shows as.
struct CommandCompletionTests {
    // MARK: Completion

    @Test func everyMatchIsListedNotTheFirstEight() {
        let matches = CommandCompletions.candidates("pilot.")
        #expect(matches.count == Commands.all.count { $0.name.hasPrefix("pilot.") })
        #expect(matches.count > 8)
        #expect(matches.allSatisfy { $0.kind == .command })
    }

    @Test func aliasesAreListedWithWhatTheyRun() {
        let matches = CommandCompletions.candidates("st")
        let start = matches.first { $0.label == "start" }
        #expect(start?.kind == .alias)
        #expect(start?.summary == "→ :work.start")
        #expect(start?.line == "start ")
        #expect(CommandCompletions.candidates("wa").contains { $0.kind == .alias && $0.summary == "→ :view watch" })
        #expect(CommandCompletions.candidates("q").map(\.label).contains("quit"))
    }

    @Test func everyListedAliasRunsWhatItSays() {
        for alias in CommandAliases.listed {
            let typed = alias.name + (alias.arguments == nil ? "" : " x")
            let resolved = CommandAliases.resolve(typed)
            let claimed = CommandInvocation(parsing: alias.runs)
            #expect(resolved.name == claimed.name, "\(alias.name)")
            #expect(Array(resolved.arguments.prefix(claimed.arguments.count)) == claimed.arguments, "\(alias.name)")
        }
    }

    @Test func keyOnlyCommandsAreNotOffered() {
        let names = CommandCompletions.candidates("command").map(\.label)
        #expect(names.isEmpty)
        // The mode switches work from `:` (AppModel enters the mode), so they stay.
        #expect(CommandCompletions.candidates("mode.").count == 5)
    }

    @Test func aCommandWithArgumentsCompletesToASpace() {
        let view = CommandCompletions.candidates("view").first { $0.label == "view" }
        #expect(view?.line == "view ")
        #expect(view?.arguments?.contains("watch") == true)
        #expect(CommandCompletions.candidates("view.watch").first?.line == "view.watch")
    }

    @Test func argumentsAfterASpace() {
        var context = CompletionContext()
        context.sessions = ["Fix the docs", "Release notes"]
        context.pins = ["Release notes"]
        context.tabs = ["agent", "shell"]
        context.hosts = ["devbox"]
        context.agents = ["claude", "codex"]
        context.mergeRepos = ["acme/api"]
        context.issueRepos = ["api"]

        #expect(CommandCompletions.candidates("view ", context).map(\.label) == CommandAliases.views)
        #expect(CommandCompletions.candidates("view w", context).map(\.line) == ["view watch"])
        // Words match anywhere in a title, the ones starting with them first.
        #expect(CommandCompletions.candidates("session.open no", context).map(\.label) == ["Release notes"])
        #expect(CommandCompletions.candidates("session.open ", context).count == 2)
        #expect(CommandCompletions.candidates("pin.jump ", context).map(\.label) == ["1"])
        #expect(CommandCompletions.candidates("pin.jump ", context).first?.summary == "Release notes")
        #expect(CommandCompletions.candidates("tab.go ", context).map(\.label) == ["1", "2"])
        #expect(CommandCompletions.candidates("host.filter d", context).map(\.label) == ["devbox"])
        #expect(CommandCompletions.candidates("agent co", context).map(\.line) == ["agent codex"])
        #expect(CommandCompletions.candidates("settings.open k", context).map(\.label) == ["keys"])
        #expect(CommandCompletions.candidates("pilot.pause ", context).map(\.label).contains("forever"))
        #expect(CommandCompletions.candidates("merge.run ", context).map(\.label) == ["acme/api", "all"])
        #expect(CommandCompletions.candidates("issues.repo ", context).map(\.label) == ["api"])
        #expect(CommandCompletions.candidates("tutor.hide ", context).map(\.label) == ["all"])
        #expect(CommandCompletions.candidates("tutor ", context).map(\.label).contains("tour"))
        #expect(CommandCompletions.candidates("tutor ", context).map(\.label).contains("sessions"))
        #expect(CommandCompletions.candidates("wt ", context).map(\.line) == ["wt sweep"])
        // Free text has nothing to offer.
        #expect(CommandCompletions.candidates("repo.add ~/", context).isEmpty)
    }

    @Test func everyOfferedArgumentIsAccepted() {
        for (value, _) in CommandCompletions.arguments(for: "tutor", CompletionContext()) {
            #expect(Tutor.lessonID(named: value) != nil, "\(value)")
        }
        for (value, _) in CommandCompletions.pauseDurations {
            #expect(PilotDuration.parse(value) != nil, "\(value)")
        }
        for view in CommandAliases.views {
            #expect(Commands.spec("view.\(view)") != nil, "\(view)")
        }
    }

    // MARK: Key labels

    private var built: (keymaps: [Mode: Keymap], scoped: [String: Keymap], problems: [Keymaps.Problem]) {
        Keymaps.build()
    }

    @Test func theDefaultsHaveNoProblems() {
        #expect(built.problems.isEmpty, "\(built.problems)")
    }

    @Test func theNewKeysRunTheirCommands() throws {
        let normal = try #require(built.keymaps[.normal])
        let expected = [
            "gb": "pilot.run", "gl": "links.pick", "gI": "issue.add", "z?": "pilot.why", "zv": "pilot.reviewers",
            "<C-w>c": "tab.close", "zx": "pilot.run.stop",
        ]
        for (notation, command) in expected {
            #expect(try normal.lookup(KeyNotation.parse(notation)) == .command(command), "\(notation)")
        }
        let command = try #require(built.keymaps[.command])
        #expect(try command.lookup(KeyNotation.parse("<S-Tab>")) == .command("command.complete.prev"))
        #expect(try command.lookup(KeyNotation.parse("<Down>")) == .command("command.complete"))
    }

    /// No default is bound twice in one table, and no view's key hides or is hidden by a NORMAL one.
    @Test func defaultKeysAreUniquePerTable() throws {
        var tables = Mode.allCases.map { ($0.rawValue, DefaultKeys.table(for: $0)) }
        tables += DefaultKeys.scoped.map { ($0.key, $0.value) }
        for (name, table) in tables {
            let keys = try table.map { try KeyNotation.parse($0.0) }
            #expect(Set(keys).count == keys.count, "\(name) binds a key twice")
        }
    }

    private func label(_ command: String, scope: String? = nil, mode: Mode = .normal) -> KeyLabels.Label? {
        KeyLabels.label(for: command, keymaps: built.keymaps, scoped: built.scoped, scope: scope, mode: mode)
    }

    @Test func aCommandBoundPerArgumentReadsAsARange() {
        #expect(label("pin.jump")?.text == "'1…'9")
        #expect(label("pin.jump 3")?.text == "'3")
        #expect(label("pin.jump 12") == nil)
    }

    @Test func theKeyThatWorksHereComesFirst() {
        // VISUAL's `m` pins the selection; NORMAL has no key for it.
        #expect(label("select.pin") == KeyLabels.Label(text: "m", context: "VISUAL"))
        #expect(label("select.pin", mode: .visual) == KeyLabels.Label(text: "m", context: nil))
        // In Repos `dd` removes the selection; elsewhere it is a Repos key.
        #expect(label("select.remove", scope: "repos") == KeyLabels.Label(text: "dd", context: nil))
        #expect(label("select.remove", mode: .visual) == KeyLabels.Label(text: "d", context: nil))
        #expect(label("session.import") == KeyLabels.Label(text: "Iw", context: "sessions"))
        // Repos' `o` starts work in the repo, so `work.start` has no key there.
        #expect(label("work.start")?.text == "o")
        #expect(label("work.start", scope: "repos") == nil)
        #expect(label("welcome") == nil)
    }

    @Test func keyCapText() {
        #expect(KeyCapText.of("<C-w>c") == "⌃w c")
        #expect(KeyCapText.of("z?") == "z?")
    }
}
