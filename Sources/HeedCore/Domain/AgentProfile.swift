import Foundation

/// How a prompt reaches an agent.
public enum PromptDelivery: String, Sendable, Codable, CaseIterable {
    /// As a quoted command-line argument: `claude "<prompt>"`.
    case argument
    /// Piped on stdin.
    case stdin
    /// Typed into the pty once the agent is up.
    case paste
    /// Written to a file whose path is passed.
    case file
}

/// One agent as config describes it. Every agent, built-in or custom, has this same shape.
public struct AgentProfile: Identifiable, Hashable, Sendable, Codable {
    public var id: String { name }
    public var name: String
    /// The executable plus fixed arguments, e.g. `claude` or `codex --full-auto`.
    public var command: String
    public var prompt: PromptDelivery
    /// Named variants, e.g. `plan = "claude --permission-mode plan"`.
    public var profiles: [String: String]
    /// Arguments that make the agent plan before acting, for Start work's "Plan first".
    public var planArguments: String?
    /// Arguments that resume the agent's session `{id}`, e.g. `--resume {id}`. Nil: the agent cannot resume, so a
    /// restored session starts fresh with its prompt.
    public var resumeArguments: String?
    /// Screen patterns per state name (`blocked = "Allow\\?"`), for agents without hooks; see `ScreenGuess`.
    public var patterns: [String: String] = [:]

    public init(
        name: String, command: String, prompt: PromptDelivery = .argument, profiles: [String: String] = [:],
        planArguments: String? = nil, resumeArguments: String? = nil
    ) {
        self.resumeArguments = resumeArguments
        self.name = name
        self.command = command
        self.prompt = prompt
        self.profiles = profiles
        self.planArguments = planArguments
    }

    /// The command line typed into the session's shell to start the agent on `prompt`.
    public func launchCommand(prompt text: String, planFirst: Bool = false, extraArguments: [String] = []) -> String {
        var line = ([command] + extraArguments.map(ShellQuote.quote)).joined(separator: " ")
        if planFirst, let planArguments { line += " " + planArguments }
        guard !text.isEmpty else { return line }
        switch prompt {
        case .argument: return line + " " + ShellQuote.quote(text)
        case .stdin: return "printf '%s' \(ShellQuote.quote(text)) | " + line
        case .paste, .file: return line
        }
    }

    /// The command line that resumes session `id`, or nil when this agent cannot resume.
    public func resumeCommand(id: String, extraArguments: [String] = []) -> String? {
        guard let resumeArguments else { return nil }
        let resume = resumeArguments.replacingOccurrences(of: "{id}", with: ShellQuote.quote(id))
        return ([command] + extraArguments.map(ShellQuote.quote) + [resume]).joined(separator: " ")
    }

    /// Resume flags verified against each CLI's docs on 2026-10-12 (see docs/plan.md); gemini's is not, so it starts
    /// fresh until it is.
    public static let builtIn: [AgentProfile] = [
        AgentProfile(
            name: "claude", command: "claude", planArguments: "--permission-mode plan", resumeArguments: "--resume {id}"
        ),
        AgentProfile(name: "codex", command: "codex", resumeArguments: "resume {id}"),
        AgentProfile(name: "cursor", command: "cursor-agent", resumeArguments: "--resume {id}"),
        AgentProfile(name: "pi", command: "pi", resumeArguments: "--session {id}"),
        AgentProfile(name: "opencode", command: "opencode", prompt: .paste, resumeArguments: "--session {id}"),
        AgentProfile(name: "gemini", command: "gemini"),
    ]
}

/// POSIX shell quoting for command lines Heed types into a shell.
public enum ShellQuote {
    /// Single-quotes `text` unless it is made only of safe characters.
    public static func quote(_ text: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%+=:,./-_"))
        if !text.isEmpty, text.unicodeScalars.allSatisfy(safe.contains) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
