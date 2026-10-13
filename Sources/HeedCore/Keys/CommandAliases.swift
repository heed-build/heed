/// Short forms accepted on the `:` line, mapped onto canonical command names: `:start`, `:pr 2841`, `:wt sweep`,
/// `:agent codex`, `:track <url>`, `:import <path>`. Anything else is taken as a command name as typed.
public enum CommandAliases {
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
        case "q", "quit": return CommandInvocation(name: "app.quit")
        default:
            if let view = ["sessions", "inbox", "issues", "prs", "repos", "history"]
                .first(where: { $0 == typed.name })
            {
                return CommandInvocation(name: "view", arguments: [view])
            }
            return typed
        }
    }
}
