/// Short forms accepted on the `:` line, mapped onto canonical command names: `:start`, `:pr 2841`, `:wt sweep`,
/// `:agent codex`, `:track <url>`, `:import <path>`. Anything else is taken as a command name as typed.
public enum CommandAliases {
    public struct Alias: Sendable, Equatable {
        /// As typed: `start`, `wt sweep`.
        public let name: String
        /// The command line it runs, `work.start --agent` for `agent`.
        public let runs: String
        public let arguments: String?
    }

    /// The views `:sessions`, `:watch`, … switch to, and `:view` takes.
    public static let views = ["sessions", "inbox", "issues", "prs", "watch", "repos", "history", "log"]

    /// Every short form, for `:` completion. `resolve` is what runs them; a test keeps the two in step.
    public static let listed: [Alias] = [
        Alias(name: "start", runs: "work.start", arguments: "[prompt]"),
        Alias(name: "agent", runs: "work.start --agent", arguments: "<name>"),
        Alias(name: "pr", runs: "open.reader pr", arguments: "<number>"),
        Alias(name: "track", runs: "pr.track", arguments: "<url>"),
        Alias(name: "import", runs: "session.import", arguments: "<path>"),
        Alias(name: "wt sweep", runs: "cleanup.sweep", arguments: nil),
        Alias(name: "help", runs: "overlay.help", arguments: nil),
        Alias(name: "back", runs: "tutor.back", arguments: nil),
        Alias(name: "skip", runs: "tutor.skip", arguments: nil),
        Alias(name: "q", runs: "app.quit", arguments: nil),
        Alias(name: "quit", runs: "app.quit", arguments: nil),
        Alias(name: "update", runs: "update.check", arguments: nil),
    ] + views.map { Alias(name: $0, runs: "view \($0)", arguments: nil) }

    public static func resolve(_ line: String) -> CommandInvocation {
        let typed = CommandInvocation(parsing: line)
        let args = typed.arguments
        switch typed.name {
        case "start": return CommandInvocation(name: "work.start", arguments: args)
        case "agent": return CommandInvocation(name: "work.start", arguments: ["--agent"] + args)
        case "pr": return CommandInvocation(name: "open.reader", arguments: ["pr"] + args)
        case "track": return CommandInvocation(name: "pr.track", arguments: args)
        case "import": return CommandInvocation(name: "session.import", arguments: args)
        case "wt" where args.first == "sweep": return CommandInvocation(name: "cleanup.sweep")
        case "help": return CommandInvocation(name: "overlay.help")
        // The tutor's card offers these as :back and :skip.
        case "back": return CommandInvocation(name: "tutor.back")
        case "skip": return CommandInvocation(name: "tutor.skip")
        case "q", "quit": return CommandInvocation(name: "app.quit")
        case "update": return CommandInvocation(name: "update.check")
        default:
            if views.contains(typed.name) { return CommandInvocation(name: "view", arguments: [typed.name]) }
            return typed
        }
    }
}
