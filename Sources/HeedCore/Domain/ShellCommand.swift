import Foundation

/// The shell a pane runs, for the syntax heed types its command in. zsh, bash, dash, ksh and sh read the same quoting;
/// fish reads it differently (`'\''` is not an escaped quote there). Anything else gets sh syntax.
public enum PaneShell: String, Hashable, Sendable, Codable, CaseIterable {
    case posix, fish, other

    /// From a shell's name or path (`/opt/homebrew/bin/fish`, `-zsh`, `bash`); nil or unknown reads as sh syntax.
    public init(name: String?) {
        let base = (name ?? "").split(separator: "/").last.map(String.init) ?? ""
        let shell = base.hasPrefix("-") ? String(base.dropFirst()) : base
        switch shell {
        case "fish": self = .fish
        case "", "sh", "bash", "zsh", "dash", "ksh", "mksh", "oksh", "yash", "ash", "busybox": self = .posix
        default: self = .other
        }
    }

    /// Your login shell, as libghostty picks the shell a pane runs: `$SHELL` when heed was started from a terminal,
    /// else the user database (where `chsh` writes). Read when a pane starts, so a changed shell is picked up.
    public static func loginShellPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let fromTerminal = getppid() != 1 && environment["GHOSTTY_MAC_LAUNCH_SOURCE"] != "app"
            && !(environment["TERM_PROGRAM"] ?? "").isEmpty
        if fromTerminal, let shell = environment["SHELL"], !shell.isEmpty { return shell }
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return environment["SHELL"] }
        return String(cString: shell)
    }

    public static func login() -> PaneShell { PaneShell(name: loginShellPath()) }

    /// Quotes `text` as one word unless it is made only of characters every shell leaves alone.
    public func quote(_ text: String) -> String {
        switch self {
        case .posix, .other: return ShellQuote.quote(text)
        case .fish:
            // `%` stays quoted: fish expands `%self`.
            let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@+=:,./-_"))
            if !text.isEmpty, text.unicodeScalars.allSatisfy(safe.contains) { return text }
            // Inside fish's single quotes, `\` escapes only `\` and `'`.
            return "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                + "'"
        }
    }
}

/// A pane's command line, kept as structure so it can be written in its shell's own syntax (`rendered(for:)`): sh
/// syntax for sh, bash and zsh, fish's for fish. It runs as the pane's process, in your login shell (`PaneLaunch`),
/// never typed into one. The agent runs in that shell itself, by the name you configured, so your aliases, functions
/// and environment apply; only the worktree setup runs under `sh -c`, as a step of its own before it. A prompt is
/// never on the line: it is `"$HEED_PROMPT"` there, and the pane's environment holds it.
public struct ShellCommand: Hashable, Sendable, Codable, CustomStringConvertible {
    /// One piece of a word.
    public enum Segment: Hashable, Sendable, Codable {
        /// Quoted as needed for the shell.
        case text(String)
        /// Shell text as you wrote it in config (an agent's `command`, its plan arguments), typed as it is.
        case raw(String)
        /// Your home directory, as `"$HOME"`.
        case home
        /// The prompt, as `"$HEED_PROMPT"`: the pane's environment carries it (`PaneLaunch`), so it never has to
        /// survive a command line's quoting. Shown in place for reading (`posix`).
        case prompt(String)
    }

    /// One word of a command: its segments, side by side.
    public struct Word: Hashable, Sendable, Codable {
        public var segments: [Segment]

        public init(_ segments: [Segment]) { self.segments = segments }

        public static func text(_ text: String) -> Word { Word([.text(text)]) }
        public static func raw(_ text: String) -> Word { Word([.raw(text)]) }
        /// A path; `~/x` becomes `"$HOME"/x` so it works quoted.
        public static func path(_ path: String) -> Word {
            path.hasPrefix("~/") ? Word([.home, .raw("/"), .text(String(path.dropFirst(2)))]) : .text(path)
        }

        func rendered(for shell: PaneShell, promptInPlace: Bool) -> String {
            segments.map { segment in
                switch segment {
                case let .text(text): shell.quote(text)
                case let .raw(text): text
                case .home: "\"$HOME\""
                case let .prompt(text): promptInPlace ? shell.quote(text) : "\"$\(PaneLaunch.promptVariable)\""
                }
            }.joined()
        }
    }

    /// `NAME=value` set for one command.
    public struct Assignment: Hashable, Sendable, Codable {
        public var name: String
        public var value: Word

        public init(_ name: String, _ value: Word) {
            self.name = name
            self.value = value
        }
    }

    /// A program with its arguments and environment.
    public struct Simple: Hashable, Sendable, Codable {
        public var environment: [Assignment]
        public var words: [Word]

        public init(environment: [Assignment] = [], words: [Word]) {
            self.environment = environment
            self.words = words
        }

        func rendered(for shell: PaneShell, promptInPlace: Bool) -> String {
            // fish 3.1 and later take `NAME=value cmd` too, and set it for a function or alias of that name as well
            // (`env NAME=value cmd` would skip those and run the program on PATH).
            environment.map { "\($0.name)=\($0.value.rendered(for: shell, promptInPlace: promptInPlace)) " }.joined()
                + words.map { $0.rendered(for: shell, promptInPlace: promptInPlace) }.joined(separator: " ")
        }
    }

    public enum Step: Hashable, Sendable, Codable {
        /// A pipeline (`printf … | agent`); usually one command.
        case run([Simple])
        /// A worktree's setup commands, run under `sh -c` (the script is sh in every shell; only its quoting as one
        /// argument follows the pane's shell).
        case setup(SetupScript)
        /// The previous step's exit code, told to heed (`heed task-exit`): a task pane's glyph.
        case reportExit
        /// A line in sh syntax as it is (panes cached before commands were kept as structure).
        case line(String)
    }

    public var steps: [Step]

    public init(_ steps: [Step]) { self.steps = steps }

    /// One command: `words` with `environment`.
    public init(environment: [Assignment] = [], words: [Word]) {
        self.init([.run([Simple(environment: environment, words: words)])])
    }

    /// A command line exactly as written (a task's command from config), in sh syntax.
    public init(line: String) { self.init([.line(line)]) }

    /// The steps, each after the one before passed (`&&`); an exit report follows whatever came before (`;`). The
    /// prompt is `"$HEED_PROMPT"`.
    public func rendered(for shell: PaneShell) -> String { rendered(for: shell, promptInPlace: false) }

    func rendered(for shell: PaneShell, promptInPlace: Bool) -> String {
        var out = ""
        for (index, step) in steps.enumerated() {
            if index > 0 { out += step == .reportExit ? "; " : " && " }
            switch step {
            case let .run(pipeline):
                out += pipeline.map { $0.rendered(for: shell, promptInPlace: promptInPlace) }.joined(separator: " | ")
            case let .setup(setup):
                let rest = ShellCommand(Array(steps.dropFirst(index + 1)))
                out += "sh -c " + shell.quote(setup.script(agent: rest.agentName))
            case .reportExit:
                // fish has `$status` for `$?`, and no `${…:-…}`; sh reads the fallback for both.
                out += shell == .fish
                    ? #"sh -c '"${HEED_BIN:-true}" task-exit "$1"' sh $status"#
                    : #""${HEED_BIN:-true}" task-exit $?"#
            case let .line(line):
                out += line
            }
        }
        return out
    }

    /// In sh syntax (zsh, bash), the prompt in place: for showing the command, and for panes cached by older versions.
    public var posix: String { rendered(for: .posix, promptInPlace: true) }

    /// The prompt the line passes as `"$HEED_PROMPT"`, for the pane's environment; nil when it has none.
    public var prompt: String? {
        for case let .run(pipeline) in steps {
            for simple in pipeline {
                for word in simple.environment.map(\.value) + simple.words {
                    for case let .prompt(text) in word.segments {
                        return text
                    }
                }
            }
        }
        return nil
    }

    /// The program the first command runs, by its first word as configured (`claude`, `codex`): the agent, for a
    /// failed setup's hint. A pipeline's last command is the agent (`printf … | agent`).
    public var agentName: String? {
        for case let .run(pipeline) in steps {
            guard let word = pipeline.last?.words.first else { return nil }
            let text = word.rendered(for: .posix, promptInPlace: true)
            return text.split(separator: " ").first.map(String.init)
        }
        return nil
    }

    public var description: String { posix }

    /// `self`, then `next` once it passed.
    public static func + (lhs: ShellCommand, rhs: ShellCommand) -> ShellCommand { ShellCommand(lhs.steps + rhs.steps) }
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
