import Foundation

public enum ResumePolicy: String, Hashable, Sendable, Codable, CaseIterable {
    case ask, always, never
}

/// What happens to one session on launch. design/screens/Resume.png.
public struct ResumeCandidate: Identifiable, Hashable, Sendable {
    public enum Mode: String, Hashable, Sendable {
        /// Was mid-turn: resume, then send the continue prompt once idle.
        case resumeThenContinue = "resume, then continue"
        /// Was waiting on you (blocked, asking): resume only; the agent asks again.
        case resumeOnly = "resume only"
        /// The agent no longer has the session (or cannot resume): start again from the prompt.
        case startFresh = "start fresh"
        /// Idle or finished: ticked in the dialog like the rest, but `always` leaves it closed.
        case leftClosed = "left closed"
    }

    public var id: String { session.id }
    public let session: Session
    public let mode: Mode
    /// The exact line typed into the agent pane.
    public let command: ShellCommand
    public let paneCount: Int
    /// The agent no longer has the session, so `command` starts it again from its prompt.
    public var startsFresh = false

    /// What the dialog says will happen. An idle or finished session is "left closed" until you tick it; ticked, it
    /// resumes (or starts fresh when the agent no longer has the session).
    public func label(ticked: Bool) -> String {
        guard mode == .leftClosed else { return mode.rawValue }
        guard ticked else { return mode.rawValue }
        return startsFresh ? Mode.startFresh.rawValue : "resume"
    }

    /// Whether `resume_on_launch = "always"` resumes it without asking (the dialog ticks every candidate).
    public var resumesWithoutAsking: Bool { mode != .leftClosed }

    /// "was working", "was blocked on a permission prompt", "idle for 2h".
    public var summary: String {
        switch session.state.state {
        case .working: "was working"
        case .blocked: "was blocked on a permission prompt"
        case .asking: "was asking\(session.state.reason.map { " \($0)" } ?? "")"
        case .limited: "was rate limited"
        case .done: "had finished"
        case .idle, .exited: "idle"
        }
    }

    public var note: String? {
        switch mode {
        case .resumeOnly where session.state.state == .blocked: "The prompt is gone after a restart. The agent will ask again."
        case .startFresh: "The agent no longer has this session; it starts again from the original prompt."
        default: nil
        }
    }
}

public enum Resume {
    /// The sessions worth offering on launch: every non-parked session with an agent. `hasSession` answers whether
    /// the agent still has a session id (nil when unknown); it does file IO, so call this off the main actor.
    public static func candidates(
        domain: Domain, settings: WorkSettings, integration: IntegrationFiles?,
        hasSession: (Session) -> Bool? = { _ in nil }
    ) -> [ResumeCandidate] {
        domain.sessions.compactMap { session -> ResumeCandidate? in
            guard !session.parked, let agent = settings.agent(session.agent) else { return nil }
            let panes = domain.layouts[session.id]?.tabs.flatMap(\.tree.panes).count ?? 0
            let signOff = settings.signOffArguments(agent: agent, repo: session.repos.first)
            let extra = integration.map {
                AgentIntegration.launchArguments(
                    agent: agent, sessionID: session.id, files: $0, resuming: true, signOff: signOff
                )
            } ?? []
            let env = integration.map { AgentIntegration.launchEnvironment(agent: agent, files: $0) } ?? [:]
            let resumable = session.agentSessionID.flatMap { id -> ShellCommand? in
                hasSession(session) == false ? nil : agent.resumeCommand(
                    id: id,
                    extraArguments: extra,
                    environment: env
                )
            }
            guard let resume = resumable else {
                // Fresh start: a new agent session from the original prompt.
                let fresh = integration.map {
                    AgentIntegration.launchArguments(agent: agent, sessionID: session.id, files: $0, signOff: signOff)
                } ?? []
                let command = agent.launchCommand(prompt: session.prompt, extraArguments: fresh, environment: env)
                let active = [.working, .blocked, .asking, .limited].contains(session.state.state)
                return ResumeCandidate(
                    session: session, mode: active ? .startFresh : .leftClosed, command: command, paneCount: panes,
                    startsFresh: true
                )
            }
            let mode: ResumeCandidate.Mode = switch session.state.state {
            case .working, .limited: .resumeThenContinue
            case .blocked, .asking: .resumeOnly
            case .idle, .done, .exited: .leftClosed
            }
            return ResumeCandidate(session: session, mode: mode, command: resume, paneCount: panes)
        }
    }
}

/// The resume dialog as a value: which candidates are ticked, the cursor, and the keys.
public struct ResumeForm: Sendable {
    public enum Outcome: Equatable, Sendable {
        case handled
        /// Resume these candidates.
        case resume([ResumeCandidate])
        /// Start without resuming anything.
        case startEmpty
    }

    public let candidates: [ResumeCandidate]
    public private(set) var selected: Set<String>
    public private(set) var cursor = 0

    public init(candidates: [ResumeCandidate]) {
        self.candidates = candidates
        selected = Set(candidates.map(\.id))
    }

    public var chosen: [ResumeCandidate] { candidates.filter { selected.contains($0.id) } }

    public mutating func handle(_ stroke: KeyStroke) -> Outcome {
        switch stroke {
        case KeyStroke("j"), KeyStroke("Down"):
            cursor = min(cursor + 1, max(candidates.count - 1, 0))
        case KeyStroke("k"), KeyStroke("Up"):
            cursor = max(cursor - 1, 0)
        case KeyStroke("Space"), KeyStroke("x"):
            guard candidates.indices.contains(cursor) else { break }
            let id = candidates[cursor].id
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        case KeyStroke("CR", .command), KeyStroke("CR"):
            return .resume(chosen)
        case .escape:
            return .startEmpty
        default:
            break
        }
        return .handled
    }
}
