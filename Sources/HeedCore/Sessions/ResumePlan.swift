import Foundation

/// What "Resume its agent", "Start its agent fresh" and "Copy resume command" do for one session right now, decided
/// from plain facts so the menus, the keys and the app all agree. Resume is available whenever there is something to
/// run; it is greyed out, with its reason, while an agent runs in the session (nothing is ever typed into a running
/// pane, and no pane is opened for it).
public enum ResumePlan {
    public enum Purpose: Sendable { case resume, fresh, copy }

    public enum Decision: Equatable, Sendable {
        /// Nothing can run: the reason, for the item's text and the flash.
        case unavailable(String)
        /// heed kept the agent's session id and the agent still has that conversation: the banner's resume, which
        /// falls back to a fresh start if the conversation turns out to be gone.
        case resume(conversation: String)
        /// heed kept an id but cannot find the conversation (not on disk, or not checked yet): the agent's own
        /// resume anyway; the agent says if it cannot.
        case forcedResume(conversation: String)
        /// No id was kept: the agent's "latest conversation in this directory" form.
        case forcedLatest
        /// No id and the agent has no "latest" form: nothing to resume; start fresh instead.
        case nothingToResume
        /// Start again from the original prompt.
        case fresh

        public var reason: String? {
            if case let .unavailable(reason) = self { reason } else { nil }
        }

        public var isAvailable: Bool { reason == nil }
    }

    /// `conversationOnDisk` is the last check of the agent's conversation (`ConversationCheck.onDisk`).
    public static func decide(
        _ purpose: Purpose, session: Session, layout: SessionLayout?, agent: AgentProfile?, presence: AgentPresence,
        conversationOnDisk: Bool
    ) -> Decision {
        guard session.agent != "shell", let agent else { return .unavailable("no agent is recorded for this session") }
        let panes = layout?.tabs.flatMap(\.tree.panes) ?? []
        guard !panes.isEmpty else { return .unavailable("it has no pane to run the agent in") }
        if let host = session.host {
            // An agent on a host lives in zmx there, and the hooks and files heed would put on the line are this
            // Mac's: heed does not launch or copy it from here.
            return .unavailable("its agent lives in zmx on \(host): reattach to it there")
        }
        if purpose != .copy {
            if let running = panes
                .firstIndex(where: { ($0.role == .agent || $0.role == .shell) && presence.isRunning($0.id) })
            {
                return .unavailable("agent running in pane \(running + 1)")
            }
            if session.parked { return .unavailable("it is parked: unpark it first") }
        }
        if purpose == .fresh { return .fresh }
        if let id = session.agentSessionID, !id.isEmpty, agent.resumeArguments != nil {
            return conversationOnDisk ? .resume(conversation: id) : .forcedResume(conversation: id)
        }
        return agent.latestArguments != nil && agent.resumeArguments != nil ? .forcedLatest : .nothingToResume
    }

    /// The line a decision runs, built by the same pieces as the launch dialog and the banner (`Resume`): the same
    /// hooks, environment and sign-off arguments. Nil for a decision that runs nothing resumed.
    public static func command(
        _ decision: Decision, session: Session, settings: WorkSettings, integration: IntegrationFiles?
    ) -> ShellCommand? {
        guard let agent = settings.agent(session.agent) else { return nil }
        let (extra, env) = Resume.injection(
            session: session,
            agent: agent,
            settings: settings,
            integration: integration
        )
        switch decision {
        case let .resume(id), let .forcedResume(id): return agent.resumeCommand(
                id: id,
                extraArguments: extra,
                environment: env
            )
        case .forcedLatest: return agent.latestCommand(extraArguments: extra, environment: env)
        default: return nil
        }
    }
}

/// The resume command as a line for the clipboard: runnable in a shell in the session's folder, now or after heed has
/// quit.
public enum ResumeCopy {
    public struct Line: Equatable, Sendable {
        public var text: String
        /// Environment names left off because they look like credentials.
        public var excluded: [String]
    }

    /// Names that look like they carry a credential. heed's own launch puts none on the line (its hooks and telemetry
    /// are files, local endpoints and flags), but a custom agent's or a future integration's environment must never
    /// reach the clipboard.
    static func looksSecret(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["TOKEN", "KEY", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL", "AUTH", "BEARER", "COOKIE", "HEADERS"]
            .contains { upper.contains($0) }
    }

    /// `cd '<directory>' && ENV=… agent … --resume <id>`, in the syntax of `shell`, without credential-like
    /// environment. The hooks settings are a path under heed's support folder that heed keeps, so the line stays valid
    /// after heed exits. The pane's own `HEED_SESSION_TOKEN` is never copied: pasted in one of heed's panes, the shell
    /// already has it; anywhere else the hooks run but heed does not accept what they say.
    public static func line(command: ShellCommand, directory: String?, shell: PaneShell) -> Line {
        var excluded: [String] = []
        let steps = command.steps.map { step -> ShellCommand.Step in
            guard case let .run(simples) = step else { return step }
            return .run(simples.map { simple in
                var simple = simple
                simple.environment = simple.environment.filter { assignment in
                    guard looksSecret(assignment.name) else { return true }
                    excluded.append(assignment.name)
                    return false
                }
                return simple
            })
        }
        let body = ShellCommand(steps).rendered(for: shell)
        let prefix = directory.flatMap { $0.isEmpty ? nil : "cd \(shell.quote($0)) && " } ?? ""
        return Line(text: prefix + body, excluded: excluded)
    }
}
