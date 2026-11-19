import Foundation
@testable import HeedCore
import Testing

private let claude = AgentProfile.builtIn.first { $0.name == "claude" }!
private let gemini = AgentProfile.builtIn.first { $0.name == "gemini" }!
private let codex = AgentProfile.builtIn.first { $0.name == "codex" }!
private let agentPane = PaneSpec(id: "agent", role: .agent, title: "claude", directory: "/w")
private let shellPane = PaneSpec(id: "shell", role: .shell, title: "shell", directory: "/w")
private let taskPane = PaneSpec(id: "task", role: .task, title: "test", directory: "/w")

private func session(
    id: String? = "conv", agent: String = "claude", parked: Bool = false, host: String? = nil
) -> Session {
    var session = Session(
        id: "s", title: "s", prompt: "do it", repos: [Repo(org: "o", name: "r")], branch: "b", agent: agent,
        agentSessionID: id, state: ObservedState(.working), parked: parked
    )
    session.host = host
    return session
}

private func layout(_ panes: PaneSpec...) -> SessionLayout {
    let tree = panes.dropFirst().reduce(PaneTree.leaf(panes[0])) { .split(.vertical, $0, .leaf($1), ratio: 0.5) }
    return SessionLayout(tabs: [PaneTab(title: "main", tree: tree)])
}

private func decide(
    _ session: Session = session(), _ purpose: ResumePlan.Purpose = .resume,
    layout: SessionLayout? = layout(agentPane), agent: AgentProfile? = claude, running: [String] = [],
    onDisk: Bool = true
) -> ResumePlan.Decision {
    var presence = AgentPresence()
    for pane in running {
        presence.started(pane)
    }
    return ResumePlan.decide(
        purpose, session: session, layout: layout, agent: agent, presence: presence, conversationOnDisk: onDisk
    )
}

struct ResumePlanTests {
    @Test func theDecisionTable() {
        // The offer holds: today's path.
        #expect(decide() == .resume(conversation: "conv"))
        // Heed kept an id, the transcript is not found: forced, with the id.
        #expect(decide(onDisk: false) == .forcedResume(conversation: "conv"))
        // No id kept: the latest conversation in the directory, where the agent has the form.
        #expect(decide(session(id: nil)) == .forcedLatest)
        #expect(decide(session(id: ""), onDisk: false) == .forcedLatest)
        #expect(decide(session(id: nil, agent: "codex"), agent: codex) == .forcedLatest)
        // No id and no latest form (gemini): nothing to resume; fresh still works.
        #expect(decide(session(id: nil, agent: "gemini"), agent: gemini) == .nothingToResume)
        #expect(decide(session(id: nil, agent: "gemini"), .fresh, agent: gemini) == .fresh)
        #expect(decide(session(), .fresh) == .fresh)
        // A task's or helper's agent is not the session's.
        #expect(decide(layout: layout(agentPane, taskPane), running: ["task"]) == .resume(conversation: "conv"))
    }

    @Test func nothingToRunIsUnavailableWithAReason() {
        #expect(decide(session(agent: "shell"), agent: nil).reason == "no agent is recorded for this session")
        #expect(decide(session(), layout: nil).reason == "it has no pane to run the agent in")
        #expect(decide(session(), agent: nil).reason != nil)
        #expect(decide(session(parked: true)).reason == "it is parked: unpark it first")
        #expect(decide(session(host: "box")).reason == "its agent lives in zmx on box: reattach to it there")
        for purpose in [ResumePlan.Purpose.resume, .fresh, .copy] {
            #expect(decide(session(host: "box"), purpose).reason != nil, "\(purpose)")
        }
    }

    // The owner's rule: while an agent runs, nothing launches. Resume and fresh are greyed out, with the pane.
    @Test func aRunningAgentNeverLaunchesAnything() {
        for purpose in [ResumePlan.Purpose.resume, .fresh] {
            for running in [["agent"], ["shell"]] {
                let found = decide(session(), purpose, layout: layout(agentPane, shellPane), running: running)
                #expect(!found.isAvailable, "\(purpose) \(running)")
                #expect(found.reason == "agent running in pane \(running == ["agent"] ? 1 : 2)")
            }
            // Whatever else is true of the session: id kept or not, on disk or not.
            for (id, onDisk) in [("conv", true), ("conv", false), (nil, false)] {
                #expect(!decide(session(id: id), purpose, running: ["agent"], onDisk: onDisk).isAvailable)
            }
        }
        // A fixture's or the tutor's panes (presence not tracking) count as running.
        let untracked = ResumePlan.decide(
            .resume, session: session(), layout: layout(agentPane), agent: claude,
            presence: AgentPresence(tracking: false), conversationOnDisk: true
        )
        #expect(!untracked.isAvailable)
        // Copy only copies text: it stays on.
        #expect(decide(session(), .copy, running: ["agent"]) == .resume(conversation: "conv"))
        // But a parked session still copies, and a host one does not.
        #expect(decide(session(parked: true), .copy).isAvailable)
        #expect(!decide(session(host: "h"), .copy).isAvailable)
    }

    @Test func theLatestFormsAreTheOnesCheckedAgainstTheClis() {
        let forms = Dictionary(uniqueKeysWithValues: AgentProfile.builtIn.map { ($0.name, $0.latestArguments) })
        #expect(forms == [
            "claude": "--continue", "codex": "resume --last", "opencode": "--continue", "pi": "--continue",
            "gemini": nil, "cursor": nil,
        ])
    }

    @Test func theCommandsAreBuiltByTheSamePiecesAsTheBanner() {
        let files = IntegrationFiles(directory: URL(fileURLWithPath: "/tmp/h"))
        let s = session()
        let viaPlan = ResumePlan.command(
            .resume(conversation: "conv"), session: s, settings: .default, integration: files
        )
        let viaCandidate = Resume.candidate(
            for: s, domain: Domain(sessions: [s], layouts: ["s": layout(agentPane)]), settings: .default,
            integration: files
        ) { _ in true }
        #expect(viaPlan == viaCandidate?.command)
        #expect(viaPlan?.posix == "claude --settings /tmp/h/claude-hooks.json --resume conv")
        // Forced: the same hooks, the id or the latest form.
        #expect(ResumePlan.command(
            .forcedResume(conversation: "conv"),
            session: s,
            settings: .default,
            integration: files
        ) == viaPlan)
        #expect(ResumePlan.command(.forcedLatest, session: s, settings: .default, integration: files)?.posix
            == "claude --settings /tmp/h/claude-hooks.json --continue")
        #expect(ResumePlan.command(.nothingToResume, session: s, settings: .default, integration: files) == nil)
        #expect(ResumePlan.command(.fresh, session: s, settings: .default, integration: files) == nil)
        let codexLatest = ResumePlan.command(
            .forcedLatest, session: session(agent: "codex"), settings: .default, integration: nil
        )
        #expect(codexLatest?.posix == "codex resume --last")
    }

    @Test func theCopiedLineHasTheHooksAndTheDirectory() {
        let files = IntegrationFiles(directory: URL(fileURLWithPath: "/tmp/Heed Support"))
        let command = ResumePlan.command(
            .forcedResume(conversation: "3f2a"), session: session(), settings: .default, integration: files
        )!
        let line = ResumeCopy.line(command: command, directory: "/Users/me/my wt/it's", shell: .posix)
        #expect(line
            .text ==
            "cd '/Users/me/my wt/it'\\''s' && claude --settings '/tmp/Heed Support/claude-hooks.json' --resume 3f2a")
        #expect(line.excluded.isEmpty)
        // The settings file is a durable path, not a temp file or an inline payload that dies with heed.
        #expect(line.text.contains("claude-hooks.json"))
        #expect(ResumeCopy.line(command: command, directory: "/a b", shell: .fish).text
            .hasPrefix("cd '/a b' && claude"))
        #expect(ResumeCopy.line(command: command, directory: nil, shell: .posix).text.hasPrefix("claude "))
    }

    @Test func anIdWithQuotesOrSpacesIsQuoted() {
        let command = ResumePlan.command(
            .resume(conversation: "a b'c"), session: session(), settings: .default, integration: nil
        )!
        #expect(ResumeCopy.line(command: command, directory: nil, shell: .posix).text == "claude --resume 'a b'\\''c'")
    }

    @Test func secretsAreLeftOffTheLine() {
        let command = ShellCommand(
            environment: [
                .init("ANTHROPIC_API_KEY", .text("sk-secret")), .init("HEED_SESSION_TOKEN", .text("tok")),
                .init("OTEL_EXPORTER_OTLP_HEADERS", .text("api-key=x")), .init("OTEL_METRICS_EXPORTER", .text("otlp")),
            ],
            words: [.raw("claude"), .raw("--continue")]
        )
        let line = ResumeCopy.line(command: command, directory: nil, shell: .posix)
        #expect(line.text == "OTEL_METRICS_EXPORTER=otlp claude --continue")
        #expect(!line.text.contains("sk-secret") && !line.text.contains("tok"))
        #expect(line.excluded == ["ANTHROPIC_API_KEY", "HEED_SESSION_TOKEN", "OTEL_EXPORTER_OTLP_HEADERS"])
    }

    // What heed puts in the environment of a real launch has none of those names: the copy loses nothing it needs.
    @Test func heedsOwnLaunchEnvironmentCarriesNoCredential() {
        var files = IntegrationFiles(directory: URL(fileURLWithPath: "/tmp/h"))
        files.telemetry = TelemetryExport(port: 4318)
        for agent in AgentProfile.builtIn {
            let env = AgentIntegration.launchEnvironment(agent: agent, files: files)
            #expect(env.keys.allSatisfy { !ResumeCopy.looksSecret($0) }, "\(agent.name): \(env.keys)")
        }
    }
}
