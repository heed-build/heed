import Foundation

/// A way to hand an agent a message other than typing it into its terminal, learned from the agent itself (its hooks
/// tell heed where it listens). Kept per pane: a session's swarm workers are panes of their own.
public enum AgentInbox: Hashable, Sendable {
    /// Claude Code's cross-session inbox: the Unix socket each running session binds and exports to its hooks as
    /// `CLAUDE_CODE_MESSAGING_SOCKET`.
    case claude(socket: String)
    /// A codex thread on codex's shared app-server daemon, which `codex queue --thread` adds a message to.
    case codex(thread: String)

    public var channel: DeliveryChannel {
        switch self {
        case .claude: .claudeInbox
        case .codex: .codexQueue
        }
    }
}

/// How a message reached an agent.
public enum DeliveryChannel: String, Hashable, Sendable, Codable {
    case claudeInbox = "claude-inbox"
    case codexQueue = "codex-queue"
    case typed

    public var label: String {
        switch self {
        case .claudeInbox: "Claude's inbox"
        case .codexQueue: "codex's queue"
        case .typed: "typed into its pane"
        }
    }
}

/// Which channels heed may use besides typing (`[sessions] claude_inbox`, `codex_queue`).
public struct ChannelSettings: Hashable, Sendable, Codable {
    /// Claude sessions get heed's messages through their cross-session inbox, when they have one.
    public var claudeInbox: Bool
    /// Codex sessions get them with `codex queue`: off by default, see `docs/agents/messages.md`.
    public var codexQueue: Bool

    public init(claudeInbox: Bool = true, codexQueue: Bool = false) {
        self.claudeInbox = claudeInbox
        self.codexQueue = codexQueue
    }

    public func allows(_ inbox: AgentInbox) -> Bool {
        switch inbox {
        case .claude: claudeInbox
        case .codex: codexQueue
        }
    }
}

/// What a channel said about one message.
public enum ChannelResult: Equatable, Sendable {
    /// The agent has it: Claude reads it between tool calls, or starts a turn with it when idle.
    case accepted
    /// The agent holds it, undelivered for now: Claude until you approve it there, codex in its thread's queue.
    case queued(String)
    /// The session takes no messages this way (a setting there refuses them).
    case refused(String)
    /// Nothing answered at the address: the agent has exited, or the address is stale.
    case unreachable(String)
}

/// Where a message to an agent ended up: what heed records and shows.
public enum DeliveryOutcome: Equatable, Sendable {
    case delivered(DeliveryChannel)
    case queued(DeliveryChannel, String)
    /// Typed into the agent's pane; `fallback` says why its channel was not used, when it had one.
    case typed(fallback: String?)
    /// Nothing sent yet: why it waits.
    case waiting(String)
    case failed(String)

    /// The agent has it, or holds it: the message counts as sent.
    public var sent: Bool {
        switch self {
        case .delivered, .queued, .typed: true
        case .waiting, .failed: false
        }
    }

    /// Why nothing was sent, when nothing was.
    public var why: String? {
        switch self {
        case let .waiting(why), let .failed(why): why
        case .delivered, .queued, .typed: nil
        }
    }

    /// `agent` as the logs name where something went: just the agent when it was typed as always, else with how
    /// ("claude, through Claude's inbox").
    public func target(_ agent: String) -> String {
        self == .typed(fallback: nil) ? agent : "\(agent), \(summary)"
    }

    /// How it went, for a session's activity log and the status line: "through Claude's inbox", "typed into its
    /// pane (Claude's inbox refused it: …)".
    public var summary: String {
        switch self {
        case let .delivered(channel): "through \(channel.label)"
        case let .queued(channel, why): "queued in \(channel.label): \(why)"
        case let .typed(fallback): fallback.map { "typed into its pane (\($0))" } ?? "typed into its pane"
        case let .waiting(why): "waiting: \(why)"
        case let .failed(why): "not sent: \(why)"
        }
    }
}

/// What to do with one message for an agent.
public enum DeliveryRoute: Equatable, Sendable {
    case channel(AgentInbox)
    case type
    case wait(String)
}

public extension Delivery {
    /// The best way to reach the agent now. Its channel when it has one heed may use: Claude's inbox and codex's
    /// queue hold a message until the agent can read it, so they go while it works, is blocked or asks, and need no
    /// typing grace (nothing is typed under your fingers). A long grace (`typingGrace` over 20 seconds: you are
    /// working in it, leave it alone) still holds. Without a channel, `verdict` decides when it is typed.
    static func route(
        state: AgentState, lastTyped: Date?, inbox: AgentInbox?, settings: ChannelSettings, now: Date = Date(),
        typingGrace: TimeInterval = 20
    ) -> DeliveryRoute {
        if let inbox, settings.allows(inbox), state != .exited {
            if typingGrace > 20, let lastTyped, now.timeIntervalSince(lastTyped) < typingGrace {
                return .wait(
                    "you're working in it (sends \(PilotDuration.text(typingGrace)) after your last keystroke)"
                )
            }
            return .channel(inbox)
        }
        switch verdict(state: state, lastTyped: lastTyped, now: now, typingGrace: typingGrace) {
        case .deliver: return .type
        case let .wait(reason): return .wait(reason)
        }
    }

    /// What a channel's answer comes to. A refused or unreachable channel falls back to typing, when `verdict` allows
    /// it now (else the message waits as a typed one would), and `forget` says the address is no use any more.
    static func resolve(
        _ result: ChannelResult, via inbox: AgentInbox, state: AgentState, lastTyped: Date?, now: Date = Date(),
        typingGrace: TimeInterval = 20
    ) -> (outcome: DeliveryOutcome, typeNow: Bool, forget: Bool) {
        let channel = inbox.channel
        switch result {
        case .accepted:
            return (.delivered(channel), false, false)
        case let .queued(why):
            return (.queued(channel, why), false, false)
        case let .refused(why), let .unreachable(why):
            let fallback = "\(channel.label): \(why)"
            switch verdict(state: state, lastTyped: lastTyped, now: now, typingGrace: typingGrace) {
            case .deliver: return (.typed(fallback: fallback), true, true)
            case let .wait(reason): return (.waiting("\(reason); \(fallback)"), false, true)
            }
        }
    }
}
