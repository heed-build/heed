import Foundation
@testable import HeedCore
import Testing

struct TOMLTests {
    @Test func parsesTheConstructsTheConfigUses() throws {
        let doc = try TOMLDocument("""
        # comment
        top = "level" # trailing
        [worktrees]
        root = '~/code/wt'
        roots = [
          "~/Projects", # one
          "~/code",
        ]
        [agents.claude]
        command = "claude \\"quoted\\""
        days = 1_4
        ratio = 0.5
        on = true
        [repos."elastic/docs-builder".tasks]
        test = "dotnet test"
        inline = { a = 1, "b c" = "d" }
        prompt = \"\"\"
        line one
        line two\"\"\"
        """)
        #expect(doc.root.value(at: ["top"]) == .string("level"))
        #expect(doc.root.value(at: ["worktrees", "root"]) == .string("~/code/wt"))
        #expect(doc.root.value(at: ["worktrees", "roots"])?.array?.count == 2)
        #expect(doc.root.value(at: ["agents", "claude", "command"]) == .string("claude \"quoted\""))
        #expect(doc.root.value(at: ["agents", "claude", "days"]) == .integer(14))
        #expect(doc.root.value(at: ["agents", "claude", "ratio"]) == .float(0.5))
        #expect(doc.root.value(at: ["agents", "claude", "on"]) == .bool(true))
        #expect(doc.root.value(at: ["repos", "elastic/docs-builder", "tasks", "test"]) == .string("dotnet test"))
        #expect(doc.root.value(at: ["repos", "elastic/docs-builder", "tasks", "inline", "b c"]) == .string("d"))
        #expect(doc.root
            .value(at: ["repos", "elastic/docs-builder", "tasks", "prompt"]) == .string("line one\nline two"))
    }

    @Test func reportsErrorsWithLines() {
        #expect(throws: TOMLError.self) { try TOMLDocument("a = \"open") }
        #expect(throws: TOMLError.self) { try TOMLDocument("[[arrays]]") }
        #expect(throws: TOMLError.self) { try TOMLDocument("a = 1\na = 2") }
        do {
            _ = try TOMLDocument("ok = 1\n[t]\nbad = \n")
        } catch {
            #expect(error.line == 3)
        }
    }

    @Test func settingKeepsCommentsAndLayout() throws {
        let source = """
        # my notes
        [worktrees]
        root = "~/code/wt"   # where they go

        [cleanup]
        idle_days = 14
        """
        let doc = try TOMLDocument(source)
        let edited = doc.setting(["worktrees", "root"], to: .string("~/wt"))
        #expect(edited.contains("root = \"~/wt\"   # where they go"))
        #expect(edited.contains("# my notes"))
        let added = try TOMLDocument(edited).setting(["cleanup", "delete_branch"], to: .bool(false))
        #expect(added.contains("idle_days = 14\ndelete_branch = false"))
        let newTable = try TOMLDocument(added).setting(["orgs", "elastic", "color"], to: .string("teal"))
        #expect(try TOMLDocument(newTable).root.value(at: ["orgs", "elastic", "color"]) == .string("teal"))
        #expect(newTable.hasSuffix("[orgs.elastic]\ncolor = \"teal\"\n"))
    }
}

struct ConfigTests {
    @Test func theDefaultFileMeansTheDefaults() {
        let (config, problems) = ConfigLoader.decode(ConfigLoader.defaultSource)
        #expect(problems.isEmpty)
        #expect(config == HeedConfig.default)
        #expect(config?.insertEscape == "<C-\\>")
    }

    @Test func valuesOverrideAndCustomAgentsAppear() throws {
        let (decoded, problems) = ConfigLoader.decode("""
        [worktrees]
        root = "~/wt"
        [sessions]
        default_agent = "mytool"
        resume_on_launch = "always"
        [agents.mytool]
        command = "mytool --fast"
        prompt = "stdin"
        [agents.codex]
        resume = ""
        [orgs.elastic]
        color = "teal"
        [repos."elastic/docs-builder".tasks]
        test = "dotnet test"
        [keys]
        insert_escape = "<C-g>"
        [keys.normal]
        "J" = "row.next"
        [keys.repos]
        "D" = "select.remove"
        """)
        #expect(problems.isEmpty)
        let config = try #require(decoded)
        #expect(config.work.worktreeRoot == "~/wt")
        #expect(config.work.resumeOnLaunch == .always)
        #expect(config.work.agent("mytool")?.prompt == .stdin)
        #expect(config.work.agent("codex")?.resumeArguments == nil)
        #expect(config.orgColors["elastic"] == "teal")
        #expect(config.repos["elastic/docs-builder"]?.tasks.first?.1 == "dotnet test")
        let built = config.keymaps()
        #expect(built.problems.isEmpty)
        #expect(try built.keymaps[.normal]?.lookup(KeyNotation.parse("J")) == .command("row.next"))
        #expect(try built.keymaps[.insert]?.lookup(KeyNotation.parse("<C-g>")) == .command("mode.normal"))
        #expect(try built.scoped["repos"]?.lookup(KeyNotation.parse("D")) == .command("select.remove"))
    }

    @Test func badValuesAreReportedAndDefaultsKept() throws {
        let (decoded, problems) = ConfigLoader.decode("""
        [sessions]
        resume_on_launch = "sometimes"
        default_agent = "nobody"
        [cleanup]
        idle_days = 0
        [agents.ghost]
        prompt = "argument"
        [keys.nonsense]
        "x" = "row.next"
        """)
        let config = try #require(decoded)
        #expect(config.work.resumeOnLaunch == .ask)
        #expect(config.work.defaultAgent == "claude")
        #expect(config.cleanup.idleDays == 14)
        #expect(Set(problems.map(\.path)) == [
            "sessions.resume_on_launch", "sessions.default_agent", "cleanup.idle_days", "agents.ghost.command",
            "keys.nonsense",
        ])
    }

    @Test func syntaxErrorsGiveNoConfig() {
        let (config, problems) = ConfigLoader.decode("[worktrees\nroot = 1")
        #expect(config == nil)
        #expect(problems.first?.message.contains("line 1") == true)
    }
}

struct OutsideWindowConfigTests {
    @Test func uiAndActivateShortcutDecode() {
        #expect(HeedConfig.default.showMenuBarItem && HeedConfig.default.showDockState)
        #expect(HeedConfig.default.globalActivate == "<C-M-h>")
        let (config, problems) = ConfigLoader.decode("""
        [ui]
        menu_bar = false
        dock_state = false
        [keys]
        global_activate = ""
        """)
        #expect(problems.isEmpty)
        #expect(config?.showMenuBarItem == false)
        #expect(config?.showDockState == false)
        #expect(config?.globalActivate == "")
    }

    @Test func theSummaryOpensAfterEightHoursAwayByDefault() {
        #expect(HeedConfig.default.summaryAwayHours == 8)
        let (config, problems) = ConfigLoader.decode("""
        [summary]
        away_hours = 0
        """)
        #expect(problems.isEmpty)
        #expect(config?.summaryAwayHours == 0)
    }

    @Test func updatesAreCheckedAndAskedAboutByDefault() {
        #expect(HeedConfig.default.updates == UpdateSettings(check: true, install: .ask))
        let (config, problems) = ConfigLoader.decode("""
        [updates]
        check = false
        install = "auto"
        """)
        #expect(problems.isEmpty)
        #expect(config?.updates == UpdateSettings(check: false, install: .auto))
        let (_, bad) = ConfigLoader.decode("""
        [updates]
        install = "silently"
        """)
        #expect(bad.map(\.path) == ["updates.install"])
    }
}
