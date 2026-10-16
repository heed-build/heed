@testable import HeedCore
import Testing

/// Handing a session to another agent (`agent.switch`): the prompt the new agent starts on, what `:` offers, and the
/// right-click menus' Hand off to… submenu.
struct HandoffTests {
    private func session(prompt: String = "Fix the broken anchors in redirects.yml") -> Session {
        Session(
            title: "Fix anchors", prompt: prompt, repos: [Repo(org: "o", name: "r")], branch: "fix/anchors",
            agent: "claude", state: ObservedState(.working)
        )
    }

    @Test func thePromptSaysWhatIsTakenOverAndHowToSeeWhatIsDone() {
        let text = Handoff.prompt(session: session(), from: "claude", base: "main")
        #expect(text.contains("taking over work on the branch fix/anchors from claude"))
        #expect(text.contains("Fix the broken anchors in redirects.yml"))
        #expect(text.contains("git status"))
        #expect(text.contains("git log main..HEAD"))
        #expect(!text.contains("Pull request"))
    }

    @Test func thePromptNamesItsPRsAndTheRepoInstructions() {
        let refs = [PullRef(repo: Repo(org: "o", name: "r"), number: 7)]
        let text = Handoff.prompt(
            session: session(), from: "codex", prs: refs, base: nil, instructions: "  Run mise run test first.\n"
        )
        #expect(text.contains("Pull request already open for it: https://github.com/o/r/pull/7"))
        #expect(text.contains("git log against the base branch"))
        #expect(text.hasSuffix("Run mise run test first."))
        let two = Handoff.prompt(session: session(), from: "codex", prs: refs + refs)
        #expect(two.contains("Pull requests already open"))
    }

    @Test func aSessionWithoutAPromptHasNoTaskLine() {
        let text = Handoff.prompt(session: session(prompt: "  "), from: "claude")
        #expect(!text.contains("The task was"))
    }

    @Test func completionOffersEveryAgentButTheCurrentOne() {
        var context = CompletionContext()
        context.agents = ["claude", "codex", "cursor"]
        context.currentAgent = "claude"
        #expect(CommandCompletions.candidates("agent.switch ", context).map(\.line)
            == ["agent.switch codex", "agent.switch cursor"])
        #expect(CommandCompletions.candidates("agent.switch cu", context).map(\.label) == ["cursor"])
        #expect(CommandCompletions.candidates("agent.sw", context).first?.line == "agent.switch ")
        // `gA` opens the line on it.
        #expect(DefaultKeys.normal.contains { $0 == ("gA", "agent.switch") })
    }

    @Test func theSessionMenuHasAHandOffSubmenu() throws {
        var facts = ContextMenus.SessionFacts(id: "s", title: "Fix it")
        #expect(!ContextMenus.session(facts).contains { if case .submenu = $0 { true } else { false } })
        facts.handoffAgents = ["codex", "cursor"]
        let menu = ContextMenus.session(facts)
        let found = menu.compactMap { if case let .submenu(title, items) = $0 { (title, items) } else { nil } }.first
        let (title, items) = try #require(found)
        #expect(title == "Hand off to…")
        #expect(items.map(\.title) == ["codex", "cursor"])
        #expect(items.map(\.command) == [
            CommandInvocation(name: "agent.switch", arguments: ["codex"], target: .session("s")),
            CommandInvocation(name: "agent.switch", arguments: ["cursor"], target: .session("s")),
        ])
        // A section of its own, between the others, never next to another separator.
        let index = try #require(menu.firstIndex { if case .submenu = $0 { true } else { false } })
        #expect(menu[index - 1] == .separator)
        #expect(menu[index + 1] == .separator)
    }

    @Test func theAgentsTabHandsOffAndOtherTabsDoNot() {
        let tab = ContextMenus.tab(id: "t1", title: "agent", zoomed: false, runLive: false, handoffAgents: ["pi"])
        #expect(tab.contains(.submenu("Hand off to…", [
            MenuItem("pi", CommandInvocation(name: "agent.switch", arguments: ["pi"], target: .tab("t1"))),
        ])))
        let shell = ContextMenus.tab(id: "t2", title: "shell", zoomed: false, runLive: false)
        #expect(!shell.contains { if case .submenu = $0 { true } else { false } })
    }

    @Test func candidatesLeaveOutTheCurrentAgent() {
        #expect(Handoff.candidates(agents: ["claude", "codex"], current: "claude") == ["codex"])
        #expect(Handoff.candidates(agents: ["claude", "codex"], current: "shell") == ["claude", "codex"])
    }
}
