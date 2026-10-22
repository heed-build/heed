import Foundation

/// The opt-in sign-off (`[pilot] summary_sign_off`, per org and repo, off by default): agents are asked at launch to
/// end their final message with a `heed-summary:` line. When it is there, it is the ledger's summary, and the cheap
/// model only fills in what else the ledger includes.
public enum SignOff {
    /// What the agent is told, appended to its system prompt (claude) or developer instructions (codex). No quotes
    /// or backticks, so it reads the same in every shell.
    public static let instruction = "When you finish a task, end your final message with one line that starts with "
        + "heed-summary: and says in one or two plain sentences what you did and where the work stands."

    /// The launch arguments that carry it, for the agents that take one: none for the others.
    public static func arguments(agent: String) -> [String] {
        switch agent {
        case "claude": ["--append-system-prompt", instruction]
        case "codex": ["-c", "developer_instructions=" + TOMLValue.quote(instruction)]
        default: []
        }
    }

    /// The text of the last `heed-summary:` line in `message` (markdown emphasis and a list marker allowed), nil when
    /// there is none or it says nothing.
    public static func extract(_ message: String?) -> String? {
        guard let message else { return nil }
        for raw in message.split(separator: "\n").reversed() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("> ") { line.removeFirst(2) }
            guard line.lowercased().hasPrefix("heed-summary:") else { continue }
            let text = line.dropFirst("heed-summary:".count).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        return nil
    }
}

/// Whether sessions in a repo are asked to sign off: `[pilot]`, then `[orgs.<name>]`, then `[repos."org/name"]`.
public struct SignOffRule: Hashable, Sendable, Codable {
    public var defaults = false
    public var orgs: [String: Bool] = [:]
    public var repos: [String: Bool] = [:]

    public init(defaults: Bool = false, orgs: [String: Bool] = [:], repos: [String: Bool] = [:]) {
        self.defaults = defaults
        self.orgs = orgs
        self.repos = repos
    }

    /// For a chat (no repo): the global setting.
    public func applies(to repo: Repo?) -> Bool {
        guard let repo else { return defaults }
        return repos[repo.slug] ?? orgs[repo.org] ?? defaults
    }
}

public extension PilotRules {
    /// The sign-off setting at every level, for launches (`WorkSettings.signOff`).
    var signOffRule: SignOffRule {
        SignOffRule(
            defaults: defaults.summarySignOff, orgs: orgs.compactMapValues(\.summarySignOff),
            repos: repos.compactMapValues(\.summarySignOff)
        )
    }
}
