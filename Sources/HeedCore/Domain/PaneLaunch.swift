import Foundation

/// How a pane starts its command: as the pane's own process, never typed into a shell. Text typed into a shell that is
/// still starting races its startup (fish's terminal queries, a slow config) and can arrive cut short or mixed with the
/// terminal's replies, so instead your login shell runs the line itself, interactive so your config, aliases and
/// functions apply, and then hands the pane over to a login shell of its own, whether the line passed or not:
///
///     <shell> -l -i -c '<line>
///     exec <shell> -l'
///
/// The prompt never appears on that line: it is `"$HEED_PROMPT"` there, and `environment` carries it. A shell heed
/// does not write the syntax of (`PaneShell.other`) gets the line run by `/bin/sh`, then the hand-over to it.
public struct PaneLaunch: Hashable, Sendable {
    /// The variable that carries the prompt.
    public static let promptVariable = "HEED_PROMPT"

    /// The shell that runs the line, then takes over the pane.
    public enum Shell: Hashable, Sendable {
        /// Your login shell here, by its path.
        case path(String)
        /// The login shell on a host, as `"$SHELL"` (the host check knows its name, not its path).
        case login
    }

    public var command: ShellCommand
    public var shell: Shell
    /// The syntax `shell` reads.
    public var kind: PaneShell

    public init(command: ShellCommand, shell: Shell, kind: PaneShell) {
        self.command = command
        self.shell = shell
        self.kind = kind
    }

    /// For your login shell here, at `path`.
    public init(command: ShellCommand, shellPath: String) {
        self.init(command: command, shell: .path(shellPath), kind: PaneShell(name: shellPath))
    }

    /// The environment the line needs: the prompt, when it has one.
    public var environment: [String: String] {
        command.prompt.map { [Self.promptVariable: $0] } ?? [:]
    }

    /// The syntax the line is written in: the shell's own, or sh's when `/bin/sh` runs it.
    private var lineKind: PaneShell { kind == .fish ? .fish : .posix }

    private func shellWord(for syntax: PaneShell) -> String {
        switch shell {
        case let .path(path): syntax.quote(path)
        case .login: "\"$SHELL\""
        }
    }

    /// What the shell runs: the command, then the prompt dropped from the environment and a login shell in its place.
    /// Lines, not `;`, so a command ending in a comment cannot swallow the hand-over.
    public var line: String {
        let unset = command.prompt == nil ? [] : [
            lineKind == .fish ? "set -e \(Self.promptVariable)" : "unset \(Self.promptVariable)",
        ]
        return ([command.rendered(for: lineKind)] + unset + ["exec \(shellWord(for: lineKind)) -l"])
            .joined(separator: "\n")
    }

    /// The process, as words for a shell of `outer` syntax to read: `<shell> -l -i -c '<line>'`, the line quoted for
    /// `outer`.
    public func commandLine(quotedFor outer: PaneShell) -> String {
        let runner = kind == .other ? ["/bin/sh", "-c"] : [shellWord(for: outer), "-l", "-i", "-c"]
        return (runner + [outer.quote(line)]).joined(separator: " ")
    }
}
