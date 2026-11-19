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
    /// How the agent takes a reasoning effort (thinking level) at launch: a flag the level follows (`--effort`), or
    /// arguments with `{level}` in them (`-c model_reasoning_effort={level}`); nil: it takes none.
    public var effortFlag: String?
    /// The model and effort its launches use when nothing more specific picks one (`[agents.<name>] model`,
    /// `effort`); nil: the agent's own default.
    public var model: String?
    public var effort: String?
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
    /// function of that name in your shell applies. The prompt is `"$HEED_PROMPT"` on the line, never the text itself,
    /// and never starts with `-` there (`Prompt.argument`), so the agent cannot read it as an option.
    /// `prefix`: words before the command (a sandboxed run's `/usr/bin/env -u …`).
    public func launchCommand(
        prompt: Prompt, planFirst: Bool = false, extraArguments: [String] = [],
        environment: [String: String] = [:],
        model: String? = nil, effort: String? = nil, prefix: [String] = []
    ) -> ShellCommand {
        var words: [ShellCommand.Word] = prefix.map(ShellCommand.Word.text) + [.raw(command)]
            + extraArguments.map(ShellCommand.Word.text)
        words += modelWords(model: model, effort: effort)
        if planFirst, let planArguments { words.append(.raw(planArguments)) }
        let agent = ShellCommand.Simple(environment: Self.assignments(environment), words: words)
        let text = prompt.argument
        guard !prompt.isEmpty, !text.isEmpty else { return ShellCommand([.run([agent])]) }
        switch self.prompt {
        case .argument:
            let prompt = (promptFlag.map { [ShellCommand.Word.raw($0)] } ?? []) + [ShellCommand.Word([.prompt(text)])]
            return ShellCommand([.run([ShellCommand.Simple(environment: agent.environment, words: words + prompt)])])
        case .stdin:
            let printf = ShellCommand.Simple(words: [.raw("printf"), .raw("'%s'"), ShellCommand.Word([.prompt(text)])])
            return ShellCommand([.run([printf, agent])])
        case .paste, .file: return ShellCommand([.run([agent])])
        }
    }

    /// The model and effort arguments of a launch: `model` and `effort` when given, else this agent's configured
    /// ones; each only when the agent has a flag for it.
    public func modelWords(model: String? = nil, effort: String? = nil) -> [ShellCommand.Word] {
        var words: [ShellCommand.Word] = []
        if let model = Self.nonEmpty(model) ?? Self.nonEmpty(self.model), let modelFlag {
            words += [.raw(modelFlag), .text(model)]
        }
        if let effort = Self.nonEmpty(effort) ?? Self.nonEmpty(self.effort),
           let effortFlag = Self.nonEmpty(effortFlag)
        {
            if effortFlag.contains("{level}") {
                // `{level}` is quoted for the shell wherever it sits; the rest is typed as configured.
                var segments: [ShellCommand.Segment] = []
                for (index, part) in effortFlag.components(separatedBy: "{level}").enumerated() {
                    if index > 0 { segments.append(.text(effort)) }
                    if !part.isEmpty { segments.append(.raw(part)) }
                }
                words.append(ShellCommand.Word(segments))
            } else {
                words += [.raw(effortFlag), .text(effort)]
            }
        }
        return words
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }

    /// The command line that resumes session `id`, or nil when this agent cannot resume.
    /// `prompt`, when given, goes last as the resumed session's next message (claude takes it as its query).
    public func resumeCommand(
        id: String, extraArguments: [String] = [], environment: [String: String] = [:], prompt: Prompt? = nil
    ) -> ShellCommand? {
        guard let resumeArguments else { return nil }
        // `{id}` is quoted for the shell wherever it sits; the rest is typed as configured.
        var resume: [ShellCommand.Segment] = []
        for (index, part) in resumeArguments.components(separatedBy: "{id}").enumerated() {
            if index > 0 { resume.append(.text(id)) }
            if !part.isEmpty { resume.append(.raw(part)) }
        }
        let words: [ShellCommand.Word] = [.raw(command)] + extraArguments.map(ShellCommand.Word.text)
            + [ShellCommand.Word(resume)] + (prompt.map { [ShellCommand.Word.text($0.argument)] } ?? [])
        return ShellCommand(environment: Self.assignments(environment), words: words)
    }

    /// The arguments that continue the latest conversation in the directory the agent starts in, for a session whose
    /// agent session id heed never kept. Checked against each CLI's `--help` on 2026-11-19: claude `--continue`,
    /// codex `resume --last`, opencode `--continue`, pi `--continue`. gemini and cursor-agent were not installed to
    /// check, so they have none here. Only the built-in names have one: a custom agent has no way to say it.
    public var latestArguments: String? {
        switch name {
        case "claude", "opencode", "pi": "--continue"
        case "codex": "resume --last"
        default: nil
        }
    }

    /// The command line that continues the latest conversation in the directory, or nil when this agent has no such
    /// form (`latestArguments`). Built as `resumeCommand` is, so every injected argument is the same.
    public func latestCommand(extraArguments: [String] = [], environment: [String: String] = [:]) -> ShellCommand? {
        guard let latestArguments, resumeArguments != nil else { return nil }
        let words: [ShellCommand.Word] = [.raw(command)] + extraArguments.map(ShellCommand.Word.text)
            + [.raw(latestArguments)]
        return ShellCommand(environment: Self.assignments(environment), words: words)
    }

    private static func assignments(_ environment: [String: String]) -> [ShellCommand.Assignment] {
        environment.sorted { $0.key < $1.key }.map { ShellCommand.Assignment($0.key, .text($0.value)) }
    }

    /// Flags verified against each CLI's source or docs on 2026-10-12 (see PLAN.md); effort flags against
    /// `claude --help` (`--effort`), `codex --help` (`-c` with `model_reasoning_effort`) and `pi --help` (`--thinking`)
    /// on 2026-10-29 (see `AgentModels`). cursor-agent, opencode's TUI and gemini take no effort at launch.
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
        agent.effortFlag = switch agent.name {
        case "claude": "--effort"
        case "codex": "-c model_reasoning_effort={level}"
        case "pi": "--thinking"
        default: nil
        }
        return agent
    }
}
