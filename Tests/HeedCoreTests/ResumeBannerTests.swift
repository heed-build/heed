import Foundation
@testable import HeedCore
import Testing

private let agentPane = PaneSpec(id: "agent", role: .agent, title: "claude", directory: "/w")
private let shellPane = PaneSpec(id: "shell", role: .shell, title: "shell", directory: "/w")
private let taskPane = PaneSpec(id: "task", role: .task, title: "test", directory: "/w")
private let claude = AgentProfile.builtIn.first { $0.name == "claude" }!

private func work(
    agentID: String? = "conv", state: AgentState = .working, parked: Bool = false, host: String? = nil
) -> Session {
    var session = Session(
        id: "s", title: "s", prompt: "do it", repos: [Repo(org: "o", name: "r")], branch: "b", agent: "claude",
        agentSessionID: agentID, state: ObservedState(state), parked: parked
    )
    session.host = host
    return session
}

private func chat(agentID: String?) -> Session {
    Session(
        id: "c", title: "c", prompt: "ask", repos: [], branch: "", agent: "claude", agentSessionID: agentID,
        state: ObservedState(.done), workspace: .chat(ChatFolder(.scratch, path: "/chats/c"))
    )
}

private func layout(_ panes: PaneSpec...) -> SessionLayout {
    let tree = panes.dropFirst().reduce(PaneTree.leaf(panes[0])) { .split(.vertical, $0, .leaf($1), ratio: 0.5) }
    return SessionLayout(tabs: [PaneTab(title: "main", tree: tree)])
}

private func offer(
    _ session: Session, _ layout: SessionLayout? = layout(agentPane), presence: AgentPresence = AgentPresence(),
    agent: AgentProfile? = claude, onDisk: Bool = true
) -> ResumeBanner.Offer? {
    ResumeBanner.offer(
        session: session, layout: layout, agent: agent, presence: presence, conversationOnDisk: onDisk
    )
}

struct ResumeBannerTests {
    // Not resumed on launch: heed started nothing, so no pane has an agent, whatever the saved state says.
    @Test func aSessionLeftClosedOnLaunchIsOffered() {
        for state in AgentState.allCases {
            let found = offer(work(state: state))
            #expect(found == ResumeBanner.Offer(sessionID: "s", agent: "claude", conversation: "conv"), "\(state)")
        }
    }

    // The agent exited and its shell lives on.
    @Test func anAgentThatExitedLeavesTheOffer() {
        var presence = AgentPresence()
        presence.started("agent")
        #expect(offer(work(), presence: presence) == nil)
        presence.observed(.exited, in: "agent")
        #expect(offer(work(state: .exited), presence: presence) != nil)
    }

    @Test func aRunningAgentNeedsNoBanner() {
        var presence = AgentPresence()
        presence.observed(.working, in: "agent")
        #expect(offer(work(), presence: presence) == nil)
        // Resuming or starting it puts the pane in, whatever the hooks say yet.
        var resumed = AgentPresence()
        resumed.started("agent")
        #expect(offer(work(state: .idle), presence: resumed) == nil)
    }

    @Test func anAgentRunningInASplitPaneShowsNoBanner() {
        let split = layout(agentPane, shellPane)
        var presence = AgentPresence()
        presence.observed(.idle, in: "shell")
        #expect(offer(work(), split, presence: presence) == nil)
        // The agent pane itself running, with a plain shell beside it, is the same.
        var other = AgentPresence()
        other.started("agent")
        #expect(offer(work(), split, presence: other) == nil)
        // Neither running: offered.
        #expect(offer(work(), split) != nil)
    }

    @Test func aTasksOrHelpersAgentIsNotTheSessionsAgent() {
        var presence = AgentPresence()
        presence.started("task")
        #expect(offer(work(), layout(agentPane, taskPane), presence: presence) != nil)
    }

    @Test func aChatWithAConversationIsOfferedAndOneWithoutIsNot() {
        #expect(offer(chat(agentID: "talk"))?.conversation == "talk")
        #expect(offer(chat(agentID: nil)) == nil)
    }

    @Test func nothingToResumeNoBanner() {
        // The agent never started: no id.
        #expect(offer(work(agentID: nil)) == nil)
        #expect(offer(work(agentID: "")) == nil)
        // An id, but the agent has no conversation under it (it never got to a first turn, or lost it).
        #expect(offer(work(), onDisk: false) == nil)
        // An agent that cannot resume, or one that is not configured, or a plain shell.
        var cannot = claude
        cannot.resumeArguments = nil
        #expect(offer(work(), agent: cannot) == nil)
        #expect(offer(work(), agent: nil) == nil)
        var shell = work()
        shell.agent = "shell"
        #expect(offer(shell) == nil)
        // Nowhere to start it.
        #expect(offer(work(), nil) == nil)
    }

    @Test func parkedAndRemoteSessionsAreLeftAlone() {
        #expect(offer(work(parked: true)) == nil)
        #expect(offer(work(host: "build")) == nil)
    }

    @Test func fixturesAndTheTutorNeverTrackAgents() {
        #expect(offer(work(), presence: AgentPresence(tracking: false)) == nil)
    }

    @Test func zmxKeepsAnAgentAcrossARestartUnlessItHadEnded() {
        var presence = AgentPresence()
        presence.reattached("agent", sessionState: .working)
        #expect(offer(work(), presence: presence) == nil)
        var ended = AgentPresence()
        ended.reattached("agent", sessionState: .exited)
        #expect(offer(work(state: .exited), presence: ended) != nil)
    }

    @Test func aClosedPaneIsForgotten() {
        var presence = AgentPresence()
        presence.started("agent")
        presence.forget("agent")
        #expect(offer(work(), presence: presence) != nil)
    }

    // The later resume is the launch dialog's code: the agent's own resume, or fresh when it lost the session.
    @Test func resumingLaterUsesTheDialogsCommands() {
        let domain = Domain(sessions: [work()], layouts: ["s": layout(agentPane)])
        let resume = Resume.candidate(for: work(), domain: domain, settings: .default, integration: nil) { _ in true }
        #expect(resume?.command.posix == "claude --resume conv")
        #expect(resume?.startsFresh == false)
        let lost = Resume.candidate(for: work(), domain: domain, settings: .default, integration: nil) { _ in false }
        #expect(lost?.command.posix == "claude 'do it'")
        #expect(lost?.startsFresh == true)
        // Parked in the domain makes no difference to the one asked for.
        let parked = Resume.candidate(
            for: work(parked: true), domain: domain, settings: .default, integration: nil
        ) { _ in true }
        #expect(parked != nil)
    }

    @Test func theMenusOfferItOnlyWhenTheAgentIsntRunning() {
        var facts = ContextMenus.SessionFacts(id: "s", title: "s")
        let names = { (facts: ContextMenus.SessionFacts) in
            MenuBar.Menu("", ContextMenus.session(facts)).items.map(\.command.name)
        }
        #expect(!names(facts).contains("agent.resume"))
        facts.agentless = true
        #expect(names(facts).contains("agent.resume") && names(facts).contains("agent.fresh"))
    }

    @Test func theKeysAreBoundInTheSessionsScopeAlone() {
        let sessions = Dictionary(DefaultKeys.sessions, uniquingKeysWith: { first, _ in first })
        #expect(sessions["gu"] == "agent.resume" && sessions["gf"] == "agent.fresh")
        #expect(sessions["gq"] == "agent.resume.dismiss")
        let everywhere = DefaultKeys.normal + DefaultKeys.scoped.filter { $0.key != "sessions" }.flatMap(\.value)
        for key in ["gu", "gf", "gq"] {
            #expect(!everywhere.contains { $0.0 == key && !$0.1.hasPrefix("agent.") }, "\(key) clashes")
        }
    }
}
