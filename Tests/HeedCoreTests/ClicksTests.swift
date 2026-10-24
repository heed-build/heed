@testable import HeedCore
import Testing

/// What a click on a key hint, a help row, a PR tab or a list row runs: the command its key runs.
struct ClicksTests {
    private func engine(scoped: [String: [(String, String)]] = [:]) -> ModeEngine {
        let built = Keymaps.build(scopedOverrides: scoped)
        return ModeEngine(keymaps: built.keymaps, scoped: built.scoped)
    }

    private let enter = [KeyStroke("CR")]

    // MARK: Double-click on a row runs what ↩ runs there

    @Test func aDoubleClickInHistoryAndItsViewsReopensAsReturnDoes() {
        for view in ["history", "timeline", "ledger", "dashboard"] {
            #expect(engine().normalCommand(for: enter, scope: view)?.name == "history.reopen", "\(view)")
        }
    }

    @Test func aDoubleClickElsewhereRunsTheViewsOwnReturnOrOpensTheReader() {
        #expect(engine().normalCommand(for: enter, scope: "repos")?.name == "select.open")
        #expect(engine().normalCommand(for: enter, scope: "sessions")?.name == "session.agent")
        #expect(engine().normalCommand(for: enter, scope: "inbox")?.name == "open.reader")
        #expect(engine().normalCommand(for: enter, scope: nil)?.name == "open.reader")
    }

    @Test func aDoubleClickFollowsReturnAsYouBoundIt() {
        let rebound = engine(scoped: ["ledger": [("<CR>", "ledger.edit")]])
        #expect(rebound.normalCommand(for: enter, scope: "ledger")?.name == "ledger.edit")
        let withArgument = engine(scoped: ["history": [("<CR>", "view inbox")]])
        #expect(withArgument.normalCommand(for: enter, scope: "history") == CommandInvocation(
            name: "view", arguments: ["inbox"]
        ))
    }

    @Test func returnStillShowsAsTheLetterInHistorysHints() {
        let built = Keymaps.build()
        for view in ["history", "timeline", "ledger", "dashboard"] {
            #expect(built.scoped[view]?.keys(for: "history.reopen").first == [KeyStroke("R")], "\(view)")
        }
    }

    // MARK: Help rows

    @Test func aHelpRowRunsItsCommandUnlessItNeedsAnArgument() {
        #expect(Clicks.helpAction(for: Commands.spec("row.next")!) == .run(CommandInvocation(name: "row.next")))
        #expect(Clicks.helpAction(for: Commands.spec("pin.jump")!) == .prompt("pin.jump "))
        // An optional argument: the key runs it bare, so does the click.
        #expect(Clicks.helpAction(for: Commands.spec("session.import")!)
            == .run(CommandInvocation(name: "session.import")))
    }

    @Test func aHintsTooltipNamesItsCommand() {
        #expect(Clicks.help(CommandInvocation(name: "pilot.green", arguments: ["ask"]))
            == ":pilot.green ask: cycle get it green for the PR: off, ask, auto (or set the one named)")
        #expect(Clicks.help(CommandInvocation(name: "no.such")) == ":no.such")
    }

    // MARK: PR overlay tabs

    @Test func aClickedTabIsReachedByCountingAsTheKeysWould() {
        #expect(Clicks.tabStep(from: 0, to: 2, count: 4) == CommandInvocation(name: "pr.next", count: 2))
        #expect(Clicks.tabStep(from: 3, to: 1, count: 4) == CommandInvocation(name: "pr.prev", count: 2))
        #expect(Clicks.tabStep(from: 1, to: 1, count: 4) == nil)
        #expect(Clicks.tabStep(from: 0, to: 4, count: 4) == nil)
        #expect(Clicks.tabStep(from: -1, to: 0, count: 4) == nil)
    }

    // MARK: Arguments a click passes

    @Test func greenTakesTheModeNamedOrCycles() {
        // Each named mode differs from the next in the cycle, so a name ignored would show.
        #expect(AutoFeed.chosen("auto", after: .off) == .auto)
        #expect(AutoFeed.chosen("OFF", after: .ask) == .off)
        #expect(AutoFeed.chosen("ask", after: .ask) == .ask)
        #expect(AutoFeed.chosen(nil, after: .off) == .ask)
        #expect(AutoFeed.chosen("sometimes", after: .auto) == .off)
    }

    @Test func theLogsAllChipShowsEveryKindAndAKindChipToggles() {
        var query = CallLogQuery()
        query.cycleKind(named: "github")
        #expect(query.kind == .github)
        query.cycleKind(named: "all")
        #expect(query.kind == nil)
        query.cycleKind(named: "all")
        #expect(query.kind == nil)
        query.cycleKind(named: "shell")
        query.cycleKind(named: "shell")
        #expect(query.kind == nil)
        query.cycleKind(named: nil)
        #expect(query.kind == CallKind.all.first)
    }

    // MARK: The status bar's hints

    @Test func aNarrowStatusBarDropsHintsFromTheEnd() {
        #expect(HintLine.shortenings("j k move · / filter · R reopen") == [
            "j k move · / filter · R reopen", "j k move · / filter", "j k move",
        ])
        #expect(HintLine.shortenings("y or ↩ confirm") == ["y or ↩ confirm"])
    }
}
