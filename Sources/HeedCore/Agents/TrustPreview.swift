import Foundation

/// What trusting a repo turns on, so the offer can say it before you answer: for Claude Code, the hooks and MCP
/// servers its `.claude/settings.json` and `.mcp.json` set (and the commands it runs for a status line or a key); for
/// mise, what its config's `[env]` sets and sources and the hooks it runs. Names and commands only: an `[env]` value
/// is never shown, it may be a secret.
public struct TrustPreview: Equatable, Sendable {
    /// `PreToolUse: ./scripts/guard.sh`, `statusLine: ~/bin/line`.
    public var claudeCommands: [String] = []
    /// `github: npx -y @acme/github-mcp`, `docs: https://mcp.example.com`.
    public var claudeServers: [String] = []
    /// The variables `[env]` sets, by name.
    public var miseEnv: [String] = []
    /// What `[env]` runs or reads: `_.source scripts/env.sh`, `_.file .env`, `API_TOKEN runs a command`.
    public var miseRuns: [String] = []
    /// `enter: echo hi`.
    public var miseHooks: [String] = []
    /// Files heed could not read; trusting them is trusting what heed did not see.
    public var unreadable: [String] = []

    public init() {}

    /// The most of each list the offer shows; the rest are counted.
    public static let shown = 6

    // MARK: Reading a repo

    /// Reads the repo at `root`. Does file IO: call it off the main actor.
    public static func read(root: String, claude: Bool, mise: Bool) -> TrustPreview {
        func text(_ path: String) -> String? { try? String(contentsOfFile: "\(root)/\(path)", encoding: .utf8) }
        var preview = TrustPreview()
        if claude {
            preview.addClaude(settings: text(".claude/settings.json"), file: ".claude/settings.json")
            preview.addMCP(text(".mcp.json"), file: ".mcp.json")
        }
        if mise {
            for file in SetupDetection.miseFiles {
                if let toml = text(file) { preview.addMise(toml, file: file) }
            }
        }
        return preview
    }

    // MARK: Claude Code

    /// A Claude Code settings file's hooks, MCP servers, and the commands it runs for a status line or a key.
    public mutating func addClaude(settings text: String?, file: String) {
        guard let text else { return }
        guard let object = Self.json(text) else { return unreadable.append(file) }
        if let hooks = object["hooks"] as? [String: Any] {
            for event in hooks.keys.sorted() {
                for group in hooks[event] as? [[String: Any]] ?? [] {
                    let matcher = (group["matcher"] as? String).flatMap { $0.isEmpty || $0 == "*" ? nil : $0 }
                    for hook in group["hooks"] as? [[String: Any]] ?? [] {
                        guard let command = hook["command"] as? String ?? hook["url"] as? String else { continue }
                        claudeCommands.append("\(event)\(matcher.map { " (\($0))" } ?? ""): \(Self.short(command))")
                    }
                }
            }
        }
        for key in ["statusLine", "apiKeyHelper", "awsAuthRefresh", "awsCredentialExport", "otelHeadersHelper"] {
            let value = object[key]
            if let command = value as? String ?? (value as? [String: Any])?["command"] as? String {
                claudeCommands.append("\(key): \(Self.short(command))")
            }
        }
        addServers(object["mcpServers"])
    }

    /// A project's `.mcp.json`: its servers.
    public mutating func addMCP(_ text: String?, file: String) {
        guard let text else { return }
        guard let object = Self.json(text) else { return unreadable.append(file) }
        addServers(object["mcpServers"])
    }

    private mutating func addServers(_ value: Any?) {
        guard let servers = value as? [String: Any] else { return }
        for name in servers.keys.sorted() {
            let server = servers[name] as? [String: Any] ?? [:]
            if let command = server["command"] as? String {
                let args = (server["args"] as? [Any] ?? []).map { "\($0)" }
                claudeServers.append("\(name): \(Self.short(([command] + args).joined(separator: " ")))")
            } else if let url = server["url"] as? String {
                claudeServers.append("\(name): \(Self.short(url))")
            } else {
                claudeServers.append(name)
            }
        }
    }

    // MARK: mise

    /// A mise config's `[env]` (names, what `_.source`, `_.file` and `_.path` name, and values that run a command
    /// through a template's `exec`) and its `[hooks]`.
    public mutating func addMise(_ text: String, file: String) {
        guard let document = try? TOMLDocument(text) else {
            if MiseTrust.setsEnvironment(text) || text.contains("[hooks") { unreadable.append(file) }
            return
        }
        if let env = document.root["env"]?.table {
            for name in env.keys {
                guard let value = env[name] else { continue }
                if name == "_" {
                    for directive in value.table?.keys ?? [] {
                        for item in Self.strings(value.table?[directive]) {
                            miseRuns.append("_.\(directive) \(Self.short(item))")
                        }
                    }
                    continue
                }
                miseEnv.append(name)
                if Self.strings(value).contains(where: { $0.contains("exec(") }) {
                    miseRuns.append("\(name) runs a command")
                }
            }
        }
        if let hooks = document.root["hooks"]?.table {
            for name in hooks.keys {
                for command in Self.strings(hooks[name]) {
                    miseHooks.append("\(name): \(Self.short(command))")
                }
            }
        }
    }

    /// A string, the strings of an array, or a table's `script`, `run`, `value`, `path` and `file` strings.
    static func strings(_ value: TOMLValue?) -> [String] {
        switch value {
        case let .string(text)?: [text]
        case let .array(items)?: items.flatMap { strings($0) }
        case let .table(table)?: ["script", "run", "value", "path", "file", "source"].flatMap { strings(table[$0]) }
        default: []
        }
    }

    // MARK: The offer

    /// What the offer says Claude Code's trust turns on, one line each; empty when the repo sets none of it.
    public var claudeLines: [String] {
        Self.lines("Claude Code runs", claudeCommands) + Self.lines("MCP server", claudeServers)
    }

    /// What the offer says mise's trust turns on.
    public var miseLines: [String] {
        var lines: [String] = []
        if !miseEnv.isEmpty {
            let names = miseEnv.prefix(Self.shown * 2).joined(separator: ", ")
            let more = miseEnv.count > Self.shown * 2 ? " and \(miseEnv.count - Self.shown * 2) more" : ""
            lines.append("mise sets \(names)\(more)")
        }
        return lines + Self.lines("mise reads", miseRuns) + Self.lines("mise hook", miseHooks)
    }

    /// Files the offer says heed could not read.
    public var unreadableLine: String? {
        unreadable.isEmpty ? nil
            : "heed could not read \(unreadable.joined(separator: ", ")): look at it before you trust"
    }

    static func lines(_ label: String, _ items: [String]) -> [String] {
        var lines = items.prefix(shown).map { "\(label) \($0)" }
        if items.count > shown { lines.append("and \(items.count - shown) more") }
        return lines
    }

    /// One line of at most 100 characters, so a long command still fits the offer.
    static func short(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ⏎ ")
        return line.count > 100 ? String(line.prefix(99)) + "…" : line
    }

    static func json(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
