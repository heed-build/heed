@testable import HeedCore
import Testing

private func pane(_ id: String) -> PaneSpec { PaneSpec(id: id, role: .shell, title: id, directory: "/") }

private func session(_ id: String, _ state: AgentState, pinned: Bool = false, parked: Bool = false) -> Session {
    Session(
        id: id, title: id, repos: [Repo(org: "o", name: "r")], branch: id, agent: "claude",
        state: ObservedState(state), pinned: pinned, parked: parked
    )
}

struct PaneTreeTests {
    @Test func splitsAndReadingOrder() {
        var tab = PaneTab(title: "t", tree: .leaf(pane("a")))
        tab.split(.horizontal, with: pane("b"))
        tab.focused = "a"
        tab.split(.vertical, with: pane("c"))
        #expect(tab.tree.panes.map(\.id) == ["a", "c", "b"])
        #expect(tab.focused == "c")
    }

    @Test func focusMovesAcrossSplits() {
        var tab = PaneTab(title: "t", tree: .leaf(pane("a")))
        tab.split(.horizontal, with: pane("b"))
        tab.focused = "a"
        tab.split(.vertical, with: pane("c"))
        tab.focus(.right)
        #expect(tab.focused == "b")
        tab.focus(.left)
        #expect(tab.focused == "c")
        tab.focus(.up)
        #expect(tab.focused == "a")
        tab.focus(.up)
        #expect(tab.focused == "a")
    }

    @Test func closingCollapsesToTheSibling() {
        var tab = PaneTab(title: "t", tree: .leaf(pane("a")))
        tab.split(.horizontal, with: pane("b"))
        let closed = tab.closeFocused()
        #expect(closed)
        #expect(tab.tree == .leaf(pane("a")))
        #expect(tab.focused == "a")
        let closedLast = tab.closeFocused()
        #expect(!closedLast)
    }
}

struct SessionListTests {
    @Test func groupsInOrder() {
        let list = SessionList([
            session("parked", .done), session("busy", .working), session("pin", .working, pinned: true),
            session("ask", .asking), session("held", .working, parked: true),
        ])
        #expect(list.sections.map(\.group) == [.pinned, .needsYou, .working, .parked])
        #expect(list.ordered.map(\.id) == ["pin", "ask", "busy", "parked", "held"])
    }

    @Test func relativeLineNumbers() {
        let list = SessionList((0 ..< 5).map { session("s\($0)", .working) })
        #expect((0 ..< 5).map { list.lineNumber(of: $0, cursor: 2) } == [2, 1, 3, 1, 2])
    }

    @Test func nextNeedingYouWraps() {
        let list = SessionList([
            session("a", .working), session("b", .blocked), session("c", .working), session("d", .asking),
        ])
        // Ordered: needs-you first (b, d), then working (a, c).
        #expect(list.ordered.map(\.id) == ["b", "d", "a", "c"])
        #expect(list.nextNeedingYou(after: 0) == 1)
        #expect(list.nextNeedingYou(after: 1) == 0)
        #expect(SessionList([session("a", .working)]).nextNeedingYou(after: 0) == nil)
    }

    @Test func hintLabelsNeverPrefixEachOther() {
        #expect(HintLabels.generate(count: 3) == ["a", "s", "d"])
        let many = HintLabels.generate(count: 40)
        #expect(many.count == 40)
        #expect(Set(many.map(\.count)) == [2])
    }

    @Test func aliases() {
        #expect(CommandAliases.resolve("wt sweep") == CommandInvocation(name: "cleanup.sweep"))
        #expect(CommandAliases.resolve("pr 2841") == CommandInvocation(name: "open.reader", arguments: ["pr", "2841"]))
        #expect(CommandAliases.resolve("inbox") == CommandInvocation(name: "view", arguments: ["inbox"]))
        #expect(CommandAliases.resolve("pane.zoom") == CommandInvocation(name: "pane.zoom"))
    }

    @Test func removingAPaneFromAnyTab() {
        let agent = PaneSpec(role: .agent, title: "claude", directory: "/w")
        let shell = PaneSpec(role: .shell, title: "zsh", directory: "/w")
        let tests = PaneSpec(role: .shell, title: "tests", directory: "/w")
        var first = PaneTab(title: "agent", tree: .leaf(agent))
        first.split(.horizontal, with: shell)
        var layout = SessionLayout(tabs: [first, PaneTab(title: "tests", tree: .leaf(tests))], activeTab: 1)
        // A pane in a tab that is not active, and not focused there: the focus stays where it was.
        let focused = layout.tabs[0].focused
        let other = layout.removePane(focused == shell.id ? agent.id : shell.id)
        #expect(other)
        #expect(layout.tabs[0].tree.panes.count == 1)
        #expect(layout.activeTab == 1)
        // The last pane of a tab takes the tab with it; the active tab stays the one you were on.
        let last = layout.removePane(layout.tabs[0].tree.panes[0].id)
        #expect(last)
        #expect(layout.tabs.map(\.title) == ["tests"])
        #expect(layout.activeTab == 0)
        let missing = layout.removePane("nope")
        #expect(!missing)
        let final = layout.removePane(tests.id)
        #expect(final)
        #expect(layout.tabs.isEmpty)
    }

    @Test func removingATabKeepsTheActiveOne() {
        let tabs = ["a", "b", "c"].map { PaneTab(
            title: $0,
            tree: .leaf(PaneSpec(role: .shell, title: $0, directory: "/"))
        ) }
        var layout = SessionLayout(tabs: tabs, activeTab: 2)
        layout.removeTab(at: 0)
        #expect(layout.tabs[layout.activeTab].title == "c")
        layout.removeTab(at: layout.activeTab)
        #expect(layout.tabs[layout.activeTab].title == "b")
    }
}
