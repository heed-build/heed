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
    /// Flag the prompt follows (`-i` for gemini, `--prompt` for opencode); nil passes it as a bare argument.
    public var promptFlag: String?
    /// Flag that assigns the agent's own session id at launch (`--session-id`), so resume works from the start.
    public var sessionIDFlag: String?
    /// Flag that picks the model (`--model`), for get it green runs that choose one; nil: the agent cannot.
    public var modelFlag: String?
    /// Screen patterns per state name (`blocked = "Allow\\?"`), for agents without hooks; see `ScreenGuess`.
    public var patterns: [String: String] = [:]

    public init(
        name: String, command: String, prompt: PromptDelivery = .argument, profiles: [String: String] = [:],
        planArguments: String? = nil, resumeArguments: String? = nil, promptFlag: String? = nil,
        sessionIDFlag: String? = nil
    ) {
        self.resumeArguments = resumeArguments
        self.promptFlag = promptFlag
        self.sessionIDFlag = sessionIDFlag
        self.name = name
        self.command = command
        self.prompt = prompt
        self.profiles = profiles
        self.planArguments = planArguments
    }

    /// The command line that starts the agent on `prompt`, run by your login shell as the pane's process
    /// (`PaneLaunch`). The agent is called by its `command` as configured, never a resolved path, so an alias or
    /// function of that name in your shell applies. The prompt is `"$HEED_PROMPT"` on the line, never the text itself.
    public func launchCommand(
        prompt text: String, planFirst: Bool = false, extraArguments: [String] = [],
        environment: [String: String] = [:],
        model: String? = nil
    ) -> ShellCommand {
        var words: [ShellCommand.Word] = [.raw(command)] + extraArguments.map(ShellCommand.Word.text)
        if let model, !model.isEmpty, let modelFlag { words += [.raw(modelFlag), .text(model)] }
        if planFirst, let planArguments { words.append(.raw(planArguments)) }
        let agent = ShellCommand.Simple(environment: Self.assignments(environment), words: words)
        guard !text.isEmpty else { return ShellCommand([.run([agent])]) }
        switch prompt {
        case .argument:
            let prompt = (promptFlag.map { [ShellCommand.Word.raw($0)] } ?? []) + [ShellCommand.Word([.prompt(text)])]
            return ShellCommand([.run([ShellCommand.Simple(environment: agent.environment, words: words + prompt)])])
        case .stdin:
            let printf = ShellCommand.Simple(words: [.raw("printf"), .raw("'%s'"), ShellCommand.Word([.prompt(text)])])
            return ShellCommand([.run([printf, agent])])
        case .paste, .file: return ShellCommand([.run([agent])])
        }
    }

    /// The command line that resumes session `id`, or nil when this agent cannot resume.
    /// `prompt`, when given, goes last as the resumed session's next message (claude takes it as its query).
    public func resumeCommand(
        id: String, extraArguments: [String] = [], environment: [String: String] = [:], prompt: String? = nil
    ) -> ShellCommand? {
        guard let resumeArguments else { return nil }
        // `{id}` is quoted for the shell wherever it sits; the rest is typed as configured.
        var resume: [ShellCommand.Segment] = []
        for (index, part) in resumeArguments.components(separatedBy: "{id}").enumerated() {
            if index > 0 { resume.append(.text(id)) }
            if !part.isEmpty { resume.append(.raw(part)) }
        }
        let words: [ShellCommand.Word] = [.raw(command)] + extraArguments.map(ShellCommand.Word.text)
            + [ShellCommand.Word(resume)] + (prompt.map { [ShellCommand.Word.text($0)] } ?? [])
        return ShellCommand(environment: Self.assignments(environment), words: words)
    }

    private static func assignments(_ environment: [String: String]) -> [ShellCommand.Assignment] {
        environment.sorted { $0.key < $1.key }.map { ShellCommand.Assignment($0.key, .text($0.value)) }
    }

    /// Flags verified against each CLI's source or docs on 2026-10-12 (see PLAN.md).
    public static let builtIn: [AgentProfile] = [
        AgentProfile(
            name: "claude", command: "claude", planArguments: "--permission-mode plan",
            resumeArguments: "--resume {id}",
            sessionIDFlag: "--session-id"
        ),
        AgentProfile(name: "codex", command: "codex", resumeArguments: "resume {id}"),
        AgentProfile(name: "cursor", command: "cursor-agent", resumeArguments: "--resume {id}"),
        AgentProfile(name: "pi", command: "pi", resumeArguments: "--session {id}", sessionIDFlag: "--session-id"),
        AgentProfile(name: "opencode", command: "opencode", resumeArguments: "--session {id}", promptFlag: "--prompt"),
        AgentProfile(
            name: "gemini", command: "gemini", resumeArguments: "--resume {id}", promptFlag: "-i",
            sessionIDFlag: "--session-id"
        ),
    ].map { agent in
        // Every built-in takes --model.
        var agent = agent
        agent.modelFlag = "--model"
        return agent
    }
}
