import Foundation

/// What heed adds to the agents it starts so they send their own OpenTelemetry to its receiver, and which agents it
/// leaves alone. Only to 127.0.0.1, and only when you have not set up telemetry of your own for that agent: an
/// endpoint or exporter you set in your shell, in heed's environment, in Claude Code's settings or in Codex's config
/// wins, and heed adds nothing to that agent (Settings says which, and why).
public struct TelemetryExport: Hashable, Sendable {
    /// `http://127.0.0.1:<port>`.
    public var endpoint: String
    public var toolDetails: Bool
    public var prompts: Bool
    /// Agents heed leaves alone, with why: `claude: OTEL_EXPORTER_OTLP_ENDPOINT is set in your shell`.
    public var leftAlone: [String: String]

    public init(port: Int, toolDetails: Bool = true, prompts: Bool = false, leftAlone: [String: String] = [:]) {
        endpoint = "http://127.0.0.1:\(port)"
        self.toolDetails = toolDetails
        self.prompts = prompts
        self.leftAlone = leftAlone
    }

    /// The agents heed knows how to point at it.
    public static let agents = ["claude", "codex"]

    /// Variables whose being set (to anything) means you send this agent's telemetry somewhere yourself.
    static let claudeOwn = [
        "OTEL_EXPORTER_OTLP_ENDPOINT", "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT",
        "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "CLAUDE_CODE_ENABLE_TELEMETRY", "OTEL_METRICS_EXPORTER",
        "OTEL_LOGS_EXPORTER", "OTEL_TRACES_EXPORTER",
    ]

    /// Decides who heed points at its receiver. `process` is heed's own environment, `shell` your login shell's (as
    /// it starts a pane), `claudeSettings` the text of `~/.claude/settings.json`, `codexConfig` that of
    /// `~/.codex/config.toml`.
    public static func decide(
        settings: TelemetrySettings, process: [String: String], shell: [String: String],
        claudeSettings: String?, codexConfig: String?
    ) -> TelemetryExport {
        var export = TelemetryExport(port: settings.port, toolDetails: settings.toolDetails, prompts: settings.prompts)
        if let name = claudeOwn.first(where: { !(shell[$0] ?? "").isEmpty }) {
            export.leftAlone["claude"] = "\(name) is set in your shell"
        } else if let name = claudeOwn.first(where: { !(process[$0] ?? "").isEmpty }) {
            export.leftAlone["claude"] = "\(name) is set in heed's environment"
        } else if let name = claudeSettingsEnv(claudeSettings).first(where: claudeOwn.contains) {
            export.leftAlone["claude"] = "\(name) is set in ~/.claude/settings.json"
        }
        if let key = codexOwn(codexConfig) {
            export.leftAlone["codex"] = "otel.\(key) is set in ~/.codex/config.toml"
        }
        return export
    }

    /// The `env` keys of a Claude Code settings file.
    static func claudeSettingsEnv(_ text: String?) -> [String] {
        guard let data = text?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = object["env"] as? [String: Any] else { return [] }
        return env.keys.sorted()
    }

    /// The first exporter Codex's config sets under `[otel]`, if any.
    static func codexOwn(_ text: String?) -> String? {
        guard let text, let document = try? TOMLDocument(text) else {
            // A config heed cannot read may still set one: say so rather than guess.
            return text?.contains("[otel") == true ? "exporter" : nil
        }
        return ["exporter", "trace_exporter", "metrics_exporter"].first { document.root.value(at: ["otel", $0]) != nil }
    }

    /// What your login shell is asked, to see what it sets: only the variables that matter here, so nothing else of
    /// your environment is read (or reaches the call log).
    public static let shellProbe = "env | grep -E '^(OTEL_|CLAUDE_CODE_ENABLE_TELEMETRY)'; true"

    /// `NAME=value` lines as a dictionary; other lines (a greeting an interactive shell printed) are skipped.
    public static func environment(fromProbe text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "="), line.hasPrefix("OTEL_") || line.hasPrefix("CLAUDE_CODE_")
            else { continue }
            out[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return out
    }

    /// Whether `agent` is pointed at heed.
    public func exports(_ agent: String) -> Bool { Self.agents.contains(agent) && leftAlone[agent] == nil }

    /// Set on the agent's own command line (so only that command, never the pane's shell, has them).
    public func environment(agent: String) -> [String: String] {
        guard exports(agent), agent == "claude" else { return [:] }
        var env = [
            "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
            "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA": "1",
            "OTEL_METRICS_EXPORTER": "otlp",
            "OTEL_LOGS_EXPORTER": "otlp",
            "OTEL_TRACES_EXPORTER": "otlp",
            "OTEL_EXPORTER_OTLP_PROTOCOL": "http/json",
            "OTEL_EXPORTER_OTLP_ENDPOINT": endpoint,
            // Live enough to watch: a minute between metric exports is Claude Code's default.
            "OTEL_METRIC_EXPORT_INTERVAL": "10000",
            "OTEL_LOGS_EXPORT_INTERVAL": "2000",
            "OTEL_TRACES_EXPORT_INTERVAL": "2000",
        ]
        if toolDetails { env["OTEL_LOG_TOOL_DETAILS"] = "1" }
        if prompts { env["OTEL_LOG_USER_PROMPTS"] = "1" }
        return env
    }

    /// Codex reads its exporters from config, so they go as `-c` layers for this run.
    public func arguments(agent: String) -> [String] {
        guard exports(agent), agent == "codex" else { return [] }
        func exporter(_ signal: String) -> String {
            "{otlp-http={endpoint=\(TOMLValue.quote("\(endpoint)/v1/\(signal)")),protocol=\"json\"}}"
        }
        var args = [
            "-c", "otel.exporter=\(exporter("logs"))",
            "-c", "otel.trace_exporter=\(exporter("traces"))",
            "-c", "otel.metrics_exporter=\(exporter("metrics"))",
        ]
        if prompts { args += ["-c", "otel.log_user_prompt=true"] }
        return args
    }

    /// What Settings shows: per agent, what heed does.
    public func summary(agent: String) -> String {
        if let reason = leftAlone[agent] { return "left alone: \(reason)" }
        return exports(agent) ? "sends to heed at \(endpoint)" : "heed does not know how to ask it"
    }
}
