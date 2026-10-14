import Foundation

/// PRs an agent opened, read from its tool calls: the `gh pr create` it ran, the GitHub MCP `create_pull_request` it
/// called. Only a creation counts; a PR URL the agent merely read or quoted is not this session's work.
public enum PullCreation {
    /// The PR URLs a tool call created. `tool` is the tool's name, `command` the shell command it ran (if any),
    /// `output` everything it printed or returned.
    public static func urls(tool: String?, command: String?, output: String) -> [String] {
        guard creates(tool: tool, command: command) else { return [] }
        return pullURLs(in: output)
    }

    static func creates(tool: String?, command: String?) -> Bool {
        let name = (tool ?? "").lowercased()
        if name.contains("create_pull_request") { return true }
        guard let command = command?.lowercased() else { return false }
        if command.range(of: #"\bgh\s+pr\s+create\b"#, options: .regularExpression) != nil { return true }
        if command.range(of: #"\bhub\s+pull-request\b"#, options: .regularExpression) != nil { return true }
        // `gh api repos/o/r/pulls -X POST` (or with -f fields, which makes it a POST).
        if command.range(of: #"\bgh\s+api\b.*\/pulls\b"#, options: .regularExpression) != nil {
            return command.contains("post") || command.range(of: #"\s-(f|F)\s"#, options: .regularExpression) != nil
        }
        return false
    }

    /// `https://github.com/o/r/pull/12` links, each once, in the order they appear.
    public static func pullURLs(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"https://github\.com/[\w.-]+/[\w.-]+/pull/\d+"#) else {
            return []
        }
        var seen: [String] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let url = String(text[range])
            if !seen.contains(url) { seen.append(url) }
        }
        return seen
    }

    /// Every string inside a hook's JSON value (or the string itself), joined: tool responses come as strings,
    /// `{stdout, stderr}`, MCP content arrays or JSON-encoded text.
    public static func text(_ value: Any?) -> String {
        switch value {
        case let string as String: string
        case let array as [Any]: array.map(text).joined(separator: "\n")
        case let object as [String: Any]: object.keys.sorted().map { text(object[$0]) }.joined(separator: "\n")
        default: ""
        }
    }

    /// The shell command in a hook's tool input: `{command: …}`, or the input itself when it is a string.
    public static func command(_ input: Any?) -> String? {
        if let object = input as? [String: Any] { return (object["command"] ?? object["cmd"]) as? String }
        if let string = input as? String {
            if let data = string.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                return (object["command"] ?? object["cmd"]) as? String
            }
            return string
        }
        return nil
    }
}
