import Foundation
@testable import HeedCore
import Testing

/// The menu bar: every command is in some menu or left out for a stated reason, and an item enables, checks and
/// targets as the right-click menus do.
struct MenuBarTests {
    private let ref = PullRef(repo: Repo(org: "o", name: "r"), number: 7)

    private func items(_ facts: MenuBar.Facts) -> [MenuItem] { MenuBar.menus(facts).flatMap(\.items) }

    private func item(_ name: String, _ facts: MenuBar.Facts) -> MenuItem? {
        items(facts).first { $0.command.name == name }
    }

    private func session(pulls: Int = 0) -> ContextMenus.SessionFacts {
        var session = ContextMenus.SessionFacts(id: "s1", title: "Fix the anchors")
        session.pulls = pulls
        session.openPulls = pulls
        session.links = pulls
        session.hasGitHubRepo = true
        session.hasPrompt = true
        session.handoffAgents = ["codex"]
        return session
    }

    /// Facts with a session, a PR, a pin and two tabs: every item that can be built is built.
    private var full: MenuBar.Facts {
        var facts = MenuBar.Facts()
        facts.session = session(pulls: 2)
        facts.pinned = ["Fix the anchors"]
        facts.tabs = 2
        facts.panes = 2
        return facts
    }

    @Test func everyCommandIsInAMenuOrLeftOutForAReason() {
        let listed = Set(items(full).map(\.command.name))
        for spec in Commands.all {
            let reason = MenuBar.unlisted[spec.name]
            #expect(listed.contains(spec.name) || reason != nil, "\(spec.name) is in no menu and has no reason")
            #expect(!(listed.contains(spec.name) && reason != nil), "\(spec.name) is listed and left out")
        }
        for name in MenuBar.unlisted.keys {
            #expect(Commands.spec(name) != nil, "\(name) is left out but is no command")
            #expect(MenuBar.unlisted[name]?.isEmpty == false)
        }
    }

    @Test func theMenusAreTheMacsInItsOrder() {
        #expect(MenuBar.menus(MenuBar.Facts()).map(\.title) == [
            "File",
            "Session",
            "View",
            "PR",
            "Go",
            "Window",
            "Help",
        ])
    }

    @Test func withNoSessionItsItemsAreGreyed() {
        let facts = MenuBar.Facts()
        for name in ["session.agent", "session.pin", "session.close", "task.run", "overlay.diff", "pilot.green"] {
            #expect(item(name, facts)?.enabled == false, "\(name)")
        }
        #expect(item("work.start", facts)?.enabled == true)
        #expect(item("view.watch", facts)?.enabled == true)
    }

    @Test func aSessionsItemsActOnItAsItsRightClickMenuDoes() {
        var facts = full
        facts.session?.pinned = true
        let pin = item("session.pin", facts)
        #expect(pin?.enabled == true)
        #expect(pin?.checked == true)
        #expect(pin?.command.target == .session("s1"))
        #expect(item("pilot.green", facts)?.command.target == .session("s1"))
        #expect(items(facts).contains { $0.command.name == "agent.switch" && $0.command.arguments == ["codex"] })
    }

    @Test func aChatHasNoPullsOrDiffButPromotes() {
        var facts = MenuBar.Facts()
        var chat = session()
        chat.chat = true
        facts.session = chat
        #expect(item("overlay.diff", facts)?.enabled == false)
        #expect(item("pr.track", facts)?.enabled == false)
        #expect(item("chat.promote", facts)?.enabled == true)
        #expect(item("work.again", facts)?.title == "New chat from its prompt")
    }

    @Test func thePullInFrontIsWhatThePilotItemsActOn() {
        var facts = full
        var pull = ContextMenus.PullFacts(ref: ref, place: .prs)
        pull.pilot.merging = true
        facts.pull = pull
        let merge = item("pilot.merge", facts)
        #expect(merge?.command.target == .pull(ref))
        #expect(merge?.checked == true)
        #expect(item("pilot.merge.now", facts)?.command.target == .pull(ref))
        // A merged PR: the pilot greys, as on its right-click menu.
        facts.pull?.open = false
        #expect(item("pilot.merge", facts)?.enabled == false)
        #expect(item("pilot.merge.now", facts)?.enabled == false)
    }

    @Test func aViewsOwnItemsWorkOnlyThere() {
        var facts = MenuBar.Facts()
        #expect(item("log.failed", facts)?.enabled == false)
        facts.view = "log"
        facts.scope = "log"
        #expect(item("log.failed", facts)?.enabled == true)
        #expect(item("view.log", facts)?.checked == true)
        #expect(item("diff.hunk.next", facts)?.enabled == false)
        facts.scope = "diff"
        #expect(item("diff.hunk.next", facts)?.enabled == true)
    }

    @Test func pinsAndTabsAreListedByNumber() {
        let pins = items(full).filter { $0.command.name == "pin.jump" }
        #expect(pins.map(\.command.arguments) == [["1"]])
        #expect(pins.first?.title.hasSuffix("Fix the anchors") == true)
        #expect(items(full).filter { $0.command.name == "tab.go" }.map(\.command.arguments) == [["1"], ["2"]])
        #expect(item("pin.jump", MenuBar.Facts())?.enabled == false)
    }

    @Test func aCommandThatNeedsWordsAsksForThem() {
        #expect(MenuBar.asks(MenuItem("", CommandInvocation(name: "pr.track"))))
        #expect(MenuBar.asks(MenuItem("", CommandInvocation(name: "session.open"))))
        #expect(!MenuBar.asks(MenuItem("", CommandInvocation(name: "pin.jump", arguments: ["1"]))))
        #expect(!MenuBar.asks(MenuItem("", CommandInvocation(name: "issue.add"))))
        #expect(!MenuBar.asks(MenuItem("", CommandInvocation(name: "work.start"))))
    }
}
