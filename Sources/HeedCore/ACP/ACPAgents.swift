import Foundation

/// How heed reaches an agent over ACP: the agent itself (opencode, gemini speak it), or an adapter in front of it
/// (Claude Code and Codex need one, from the ACP project). What to run, and what to install when it is missing.
/// The names and commands are the ACP registry's (github.com/agentclientprotocol/registry), as of November 2026.
public struct ACPAdapter: Hashable, Sendable {
    /// heed's name for the agent (`[agents.<name>]`).
    public var agent: String
    /// What heed calls it: `claude via ACP`.
    public var title: String
    /// The executable, looked up on the login shell's PATH.
    public var executable: String
    public var arguments: [String]
    /// What to run to install it, when it is a separate adapter. heed never runs it: it shows it.
    public var install: String?

    public init(agent: String, title: String, executable: String, arguments: [String] = [], install: String? = nil) {
        self.agent = agent
        self.title = title
        self.executable = executable
        self.arguments = arguments
        self.install = install
    }

    /// The command line, as `[helpers] command` writes one.
    public var commandLine: String { ([executable] + arguments).joined(separator: " ") }
}

public enum ACPAgents {
    /// The agents heed knows an ACP way to.
    public static let known: [ACPAdapter] = [
        ACPAdapter(
            agent: "claude", title: "claude via ACP", executable: "claude-agent-acp",
            install: "npm install -g @agentclientprotocol/claude-agent-acp"
        ),
        ACPAdapter(
            agent: "codex", title: "codex via ACP", executable: "codex-acp",
            install: "npm install -g @agentclientprotocol/codex-acp"
        ),
        ACPAdapter(agent: "opencode", title: "opencode via ACP", executable: "opencode", arguments: ["acp"]),
        ACPAdapter(agent: "gemini", title: "gemini via ACP", executable: "gemini", arguments: ["--acp"]),
    ]

    public static func adapter(for agent: String) -> ACPAdapter? { known.first { $0.agent == agent } }

    /// The adapter helpers use: `[helpers] agent`, else the default agent when heed knows an ACP way to it, else
    /// claude. `[helpers] command` replaces its command line (`npx -y @agentclientprotocol/claude-agent-acp`, a path).
    public static func chosen(_ settings: HelperSettings, defaultAgent: String) -> ACPAdapter? {
        let name = settings.agent ?? (adapter(for: defaultAgent) != nil ? defaultAgent : "claude")
        let words = words(settings.command ?? "")
        if let first = words.first {
            return ACPAdapter(
                agent: name, title: "\(name) via ACP", executable: first, arguments: Array(words.dropFirst())
            )
        }
        return adapter(for: name)
    }

    /// A command line's words: split at spaces, with '…' and "…" keeping spaces in a word. No other shell syntax.
    public static func words(_ line: String) -> [String] {
        var words: [String] = []
        var word = ""
        var quote: Character?
        var started = false
        for character in line {
            if let open = quote {
                if character == open { quote = nil } else { word.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started || !word.isEmpty { words.append(word) }
                word = ""
                started = false
            } else {
                word.append(character)
            }
        }
        if started || !word.isEmpty { words.append(word) }
        return words
    }

    /// Whether helpers can run: the adapter found on the PATH, or why not and what would fix it.
    public enum Availability: Hashable, Sendable {
        case ready(ACPAdapter, path: String)
        /// The adapter is not installed: what to install (nil when heed knows no command for it).
        case missing(ACPAdapter)
        /// heed knows no ACP way to the agent: set `[helpers] command`.
        case unknown(agent: String)

        public var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        /// One sentence for the helper view and the proposal.
        public var text: String {
            switch self {
            case let .ready(adapter, _): "helpers run \(adapter.title)"
            case let .missing(adapter):
                "\(adapter.executable) is not installed: helpers need it to run \(adapter.agent)"
                    + (adapter.install.map { ". Install it with \($0)" } ?? "")
                    + ", or set [helpers] command"
            case let .unknown(agent):
                "heed knows no ACP adapter for \(agent): set [helpers] agent to claude, codex, opencode or gemini, or "
                    + "[helpers] command"
            }
        }
    }

    /// Looks the chosen adapter up with `find` (a name to a path, or nil).
    public static func availability(
        _ settings: HelperSettings, defaultAgent: String, find: (String) -> String?
    ) -> Availability {
        guard let adapter = chosen(settings, defaultAgent: defaultAgent) else {
            return .unknown(agent: settings.agent ?? defaultAgent)
        }
        let path = adapter.executable.contains("/")
            ? (FileManager.default.isExecutableFile(atPath: adapter.executable) ? adapter.executable : nil)
            : find(adapter.executable)
        guard let path else { return .missing(adapter) }
        return .ready(adapter, path: path)
    }
}

/// `[helpers]`: the agent heed's helpers run over ACP, and how much one may spend.
public struct HelperSettings: Equatable, Sendable {
    /// `agent`: claude, codex, opencode or gemini; nil: the default agent when heed knows an ACP way to it.
    public var agent: String?
    /// `command`: the adapter's command line, replacing the known one.
    public var command: String?
    /// `spend_cap`: dollars one helper may spend before heed stops it, counted from what the agent reports
    /// (`usage_update`); 0: no cap. An agent that reports no cost is held to `run_timeout` only.
    public var spendCap: Double = 0.5

    public init(agent: String? = nil, command: String? = nil, spendCap: Double = 0.5) {
        self.agent = agent
        self.command = command
        self.spendCap = spendCap
    }
}
