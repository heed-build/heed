import Foundation

/// The docs' generated reference pages, from the code itself, so they cannot drift: every command and its default keys,
/// and every config key with its default. `mise run shots` writes them; a test fails when the checked-in pages differ.
public enum DocsReference {
    /// docs/keyboard/reference.md.
    public static func keys() -> String {
        var bindings: [String: [String]] = [:]
        func add(_ table: [(String, String)], _ context: String?) {
            for (notation, command) in table {
                let name = CommandInvocation(parsing: command).name
                let key = "`\(notation)`" + (context.map { " (\($0))" } ?? "")
                bindings[name, default: []].append(key)
            }
        }
        add(DefaultKeys.normal, nil)
        add(DefaultKeys.visual, "VISUAL")
        add(DefaultKeys.insert, "INSERT")
        add(DefaultKeys.command, "COMMAND")
        for scope in DefaultKeys.scoped.keys.sorted() {
            add(DefaultKeys.scoped[scope] ?? [], scope)
        }
        var lines = [
            "---",
            "description: Every command and its default keys. Generated from the code.",
            "---",
            "",
            "# Key reference",
            "",
            "Every command Heed has, with its default keys. Keys in parentheses apply in that mode or view only. Any",
            "command can also be run by name on the command line (`:`), and any key changed in `config.toml`; see",
            "[Customizing keys](customizing.md).",
            "",
            "This page is generated from the code (`mise run shots`).",
        ]
        for group in CommandSpec.Group.allCases {
            let specs = Commands.all.filter { $0.group == group }
            guard !specs.isEmpty else { continue }
            lines += ["", "## \(group.rawValue)", "", "| Command | Keys | Does |", "|---|---|---|"]
            for spec in specs {
                let name = "`\(spec.name)`" + (spec.arguments.map { " `\($0)`" } ?? "")
                let keys = bindings[spec.name]?.joined(separator: ", ") ?? ""
                lines.append("| \(name) | \(escape(keys)) | \(escape(spec.summary)) |")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// docs/configuration/reference.md.
    public static func config() -> String {
        var lines = [
            "---",
            "description: Every key in config.toml with its default. Generated from the code.",
            "---",
            "",
            "# config.toml reference",
            "",
            "`~/.config/heed/config.toml`, as Heed writes it the first time it opens: every key with its default and what",
            "it does. Saving the file applies it right away; a mistake is reported in the status bar and the last good",
            "config stays in use.",
            "",
            "This page is generated from the code (`mise run shots`).",
            "",
            "```toml",
        ]
        lines += ConfigLoader.defaultSource.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.append("```")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Pipes would end a table cell; backslashes would vanish.
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|")
    }
}
