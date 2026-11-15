import Foundation

/// What heed adds to the agents it starts so they send their own OpenTelemetry to its receiver on 127.0.0.1. An
/// agent you send telemetry from yourself (OTEL variables in your shell or heed's environment, Codex's `[otel]`
/// exporters) is pointed at heed anyway with `[telemetry] proxy` on, and heed forwards every export unchanged to where
/// it went before; with it off, or where heed cannot stand in between (gRPC, Claude Code's own settings file), heed
/// leaves that agent alone. Settings says which, per agent.
public struct TelemetryExport: Hashable, Sendable {
    /// What heed does with one agent.
    public enum Mode: Hashable, Sendable {
        /// Exports to heed only.
        case heed
        /// Exports to heed, which forwards each signal you exported before to where it went.
        case forward([OTLPSignal: TelemetryUpstream])
        /// Your own setup, which heed stays out of, and why.
        case own(String)
    }

    /// `http://127.0.0.1:<port>`.
    public var endpoint: String
    public var toolDetails: Bool
    public var prompts: Bool
    /// Per agent heed knows; an agent missing is `.heed`.
    public var modes: [String: Mode]

    public init(port: Int, toolDetails: Bool = true, prompts: Bool = false, modes: [String: Mode] = [:]) {
        endpoint = "http://127.0.0.1:\(port)"
        self.toolDetails = toolDetails
        self.prompts = prompts
        self.modes = modes
    }

    /// The agents heed knows how to point at it.
    public static let agents = ["claude", "codex"]

    public func mode(_ agent: String) -> Mode { modes[agent] ?? .heed }

    /// Agents heed leaves alone, with why.
    public var leftAlone: [String: String] {
        modes.compactMapValues { if case let .own(reason) = $0 { reason } else { nil } }
    }

    /// The signals heed forwards for `agent`, and where.
    public func upstreams(_ agent: String) -> [OTLPSignal: TelemetryUpstream] {
        if case let .forward(upstreams) = mode(agent) { return upstreams }
        return [:]
    }

    /// Every forward, as the receiver routes them: agent → signal → your collector.
    public var routes: [String: [OTLPSignal: URL]] {
        Dictionary(uniqueKeysWithValues: Self.agents.compactMap { agent in
            let upstreams = upstreams(agent)
            return upstreams.isEmpty ? nil : (agent, upstreams.mapValues(\.url))
        })
    }

    /// The names of the headers each forward passes on: agent → signal → the names your setup sends.
    public var forwardHeaders: [String: [OTLPSignal: Set<String>]] {
        Dictionary(uniqueKeysWithValues: Self.agents.compactMap { agent in
            let upstreams = upstreams(agent)
            return upstreams.isEmpty ? nil : (agent, upstreams.mapValues(\.headers))
        })
    }

    /// The header names in an OTLP headers value (`api-key=x,Authorization=Bearer y`: `api-key`, `authorization`).
    /// A value that already holds only names (`api-key,authorization`) reads the same.
    public static func headerNames(_ value: String) -> Set<String> {
        Set(value.split(separator: ",").compactMap { part in
            let name = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            return name.isEmpty ? nil : name
        })
    }

    /// Whether heed sits between any agent and your collector (the OpenTelemetry tab says so).
    public var proxying: Bool { !routes.isEmpty }

    /// The path an agent posts a signal heed forwards to: `/forward/claude/v1/traces`.
    public static func forwardPath(
        agent: String,
        signal: OTLPSignal
    ) -> String { "/forward/\(agent)/v1/\(signal.rawValue)" }

    /// The agent and signal of a forward path; nil for anything else.
    public static func forwardRoute(path: String) -> (agent: String, signal: OTLPSignal)? {
        let parts = (path.split(separator: "?").first ?? "").split(separator: "/").map(String.init)
        guard parts.count == 4, parts[0] == "forward", parts[2] == "v1", let signal = OTLPSignal(rawValue: parts[3])
        else { return nil }
        return (parts[1], signal)
    }

    /// Variables whose being set (to anything) means you set up this agent's telemetry yourself.
    static let claudeOwn = [
        "OTEL_EXPORTER_OTLP_ENDPOINT", "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT",
        "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "CLAUDE_CODE_ENABLE_TELEMETRY", "OTEL_METRICS_EXPORTER",
        "OTEL_LOGS_EXPORTER", "OTEL_TRACES_EXPORTER",
    ]

    /// Decides who heed points at its receiver, and what it forwards. `process` is heed's own environment, `shell`
    /// your login shell's (as it starts a pane), `claudeSettings` the text of `~/.claude/settings.json`,
    /// `codexConfig` that of Codex's `config.toml`.
    public static func decide(
        settings: TelemetrySettings, process: [String: String], shell: [String: String],
        claudeSettings: String?, codexConfig: String?
    ) -> TelemetryExport {
        var export = TelemetryExport(port: settings.port, toolDetails: settings.toolDetails, prompts: settings.prompts)
        let own = export.endpoint
        if let name = claudeSettingsEnv(claudeSettings).first(where: claudeOwn.contains) {
            export.modes["claude"] = .own("\(name) is set in ~/.claude/settings.json, which heed leaves to Claude Code")
        } else if let name = claudeOwn.first(where: { !(shell[$0] ?? "").isEmpty || !(process[$0] ?? "").isEmpty }) {
            let place = (shell[name] ?? "").isEmpty ? "heed's environment" : "your shell"
            if settings.proxy {
                // Your shell's values win over heed's environment in a pane, as they do here; Claude Code's settings
                // can add headers.
                let env = process.merging(shell) { _, shell in shell }
                    .merging(claudeSettingsHeaders(claudeSettings)) { _, settings in settings }
                export.modes["claude"] = claudeMode(env, heed: own)
            } else {
                export.modes["claude"] = .own("\(name) is set in \(place)")
            }
        }
        if let codex = codexMode(codexConfig, heed: own) {
            if settings.proxy || codex == .heed {
                export.modes["codex"] = codex
            } else {
                export.modes["codex"] = .own("[otel] exporters are set in Codex's config.toml")
            }
        }
        return export
    }

    /// What Claude Code exports with `env`, per signal: OTLP over HTTP to an endpoint (per signal, or the shared
    /// one with `/v1/<signal>`, or Claude Code's default), in the protocol asked for.
    static func claudeMode(_ env: [String: String], heed: String) -> Mode {
        func on(_ name: String) -> Bool { ["1", "true", "yes"].contains((env[name] ?? "").lowercased()) }
        guard on("CLAUDE_CODE_ENABLE_TELEMETRY") else { return .heed }
        var upstreams: [OTLPSignal: TelemetryUpstream] = [:]
        for signal in OTLPSignal.allCases {
            let upper = signal.rawValue.uppercased()
            let exporters = (env["OTEL_\(upper)_EXPORTER"] ?? "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard exporters.contains("otlp") else { continue }
            if signal == .traces, !(on("CLAUDE_CODE_ENHANCED_TELEMETRY_BETA") || on("ENABLE_ENHANCED_TELEMETRY_BETA")) {
                continue
            }
            let wire = env["OTEL_EXPORTER_OTLP_\(upper)_PROTOCOL"] ?? env["OTEL_EXPORTER_OTLP_PROTOCOL"]
            let url: String = if let own = env["OTEL_EXPORTER_OTLP_\(upper)_ENDPOINT"], !own.isEmpty { own } else {
                (env["OTEL_EXPORTER_OTLP_ENDPOINT"].flatMap { $0.isEmpty ? nil : $0 } ?? "http://localhost:4318")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/\(signal.rawValue)"
            }
            guard let parsed = URL(string: url), let host = parsed.host else {
                return .own("its \(signal.rawValue) endpoint is not a URL heed can forward to")
            }
            // An endpoint on gRPC's port with no protocol said is gRPC.
            if wire == "grpc" || (wire == nil && parsed.port == 4317) {
                return .own("it exports over gRPC to \(host), which heed does not forward")
            }
            if url.hasPrefix(heed) { continue }
            let headers = headerNames(env["OTEL_EXPORTER_OTLP_\(upper)_HEADERS"] ?? "")
                .union(headerNames(env["OTEL_EXPORTER_OTLP_HEADERS"] ?? ""))
            upstreams[signal] = TelemetryUpstream(
                url: parsed, wire: wire == "http/json" ? .json : .protobuf, headers: headers
            )
        }
        return upstreams.isEmpty ? .heed : .forward(upstreams)
    }

    /// The config keys of Codex's exporters, by signal.
    static let codexKeys: [(OTLPSignal, String)] = [
        (.logs, "exporter"),
        (.traces, "trace_exporter"),
        (.metrics, "metrics_exporter"),
    ]

    /// What Codex's config exports, per signal: nil when its `[otel]` sets no exporter.
    static func codexMode(_ text: String?, heed: String) -> Mode? {
        guard let text else { return nil }
        guard let document = try? TOMLDocument(text) else {
            return text.contains("[otel") ? .own("heed cannot read Codex's config.toml") : nil
        }
        var upstreams: [OTLPSignal: TelemetryUpstream] = [:]
        var any = false
        for (signal, key) in codexKeys {
            guard let value = document.root.value(at: ["otel", key]) else { continue }
            if value.string == "none" { continue }
            any = true
            guard let table = value.table
            else { return .own("otel.\(key) is \(value.literal), which heed does not forward") }
            if table["otlp-grpc"] != nil { return .own("otel.\(key) exports over gRPC, which heed does not forward") }
            guard let http = table["otlp-http"]?.table, let endpoint = http["endpoint"]?.string,
                  let url = URL(string: endpoint), url.host != nil
            else { return .own("otel.\(key) is not an otlp-http exporter heed can forward") }
            if endpoint.hasPrefix(heed) { continue }
            upstreams[signal] = TelemetryUpstream(
                url: url,
                wire: http["protocol"]?.string == "json" ? .json : .protobuf,
                headers: Set((http["headers"]?.table?.keys ?? []).map { $0.lowercased() })
            )
        }
        guard any else { return nil }
        return upstreams.isEmpty ? .heed : .forward(upstreams)
    }

    /// The `env` keys of a Claude Code settings file.
    static func claudeSettingsEnv(_ text: String?) -> [String] {
        guard let data = text?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = object["env"] as? [String: Any] else { return [] }
        return env.keys.sorted()
    }

    /// The `*_HEADERS` variables of a Claude Code settings file's `env`, as header names only.
    static func claudeSettingsHeaders(_ text: String?) -> [String: String] {
        guard let data = text?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = object["env"] as? [String: Any] else { return [:] }
        return env.reduce(into: [:]) { out, entry in
            guard entry.key.hasPrefix("OTEL_EXPORTER_OTLP_"), entry.key.hasSuffix("_HEADERS"),
                  let value = entry.value as? String else { return }
            out[entry.key] = headerNames(value).sorted().joined(separator: ",")
        }
    }

    /// What your login shell is asked, to see what it sets: only the variables that matter here, so nothing else of
    /// your environment is read (or reaches the call log).
    /// Of a `*_HEADERS` variable only the header names come back (`OTEL_EXPORTER_OTLP_HEADERS=api-key,authorization`):
    /// heed passes those headers on to your collector and nothing else, and never holds their values (an agent sends
    /// them with each export).
    public static let shellProbe =
        "env | grep -E '^(OTEL_|CLAUDE_CODE_ENABLE_TELEMETRY|CLAUDE_CODE_ENHANCED_TELEMETRY_BETA|"
            + "ENABLE_ENHANCED_TELEMETRY_BETA)' | grep -v '_HEADERS='; "
            + "env | awk '/^OTEL_EXPORTER_OTLP_([A-Z]+_)?HEADERS=/ { i = index($0, \"=\"); "
            + "c = split(substr($0, i + 1), p, \",\"); s = \"\"; "
            + "for (j = 1; j <= c; j++) { k = p[j]; sub(/=.*/, \"\", k); s = s (j > 1 ? \",\" : \"\") k }; "
            + "print substr($0, 1, i - 1) \"=\" s }'; true"

    /// `NAME=value` lines as a dictionary; other lines (a greeting an interactive shell printed) are skipped. A
    /// `*_HEADERS` line keeps only its header names, whatever the line held.
    public static func environment(fromProbe text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "="),
                  line.hasPrefix("OTEL_") || line.hasPrefix("CLAUDE_CODE_") || line.hasPrefix("ENABLE_ENHANCED")
            else { continue }
            let name = String(line[..<equals])
            let value = String(line[line.index(after: equals)...])
            out[name] = name.hasSuffix("_HEADERS") ? headerNames(value).sorted().joined(separator: ",") : value
        }
        return out
    }

    /// Whether `agent` is pointed at heed.
    public func exports(_ agent: String) -> Bool {
        guard Self.agents.contains(agent) else { return false }
        if case .own = mode(agent) { return false }
        return true
    }

    /// Set on the agent's own command line (so only that command, never the pane's shell, has them). A signal heed
    /// forwards keeps your protocol, so the bytes are what your collector takes; your headers stay in your
    /// environment, and the agent sends them with each export. Nothing else of yours changes: not your intervals,
    /// not what your exports include.
    public func environment(agent: String) -> [String: String] {
        guard exports(agent), agent == "claude" else { return [:] }
        let upstreams = upstreams(agent)
        var env = [
            "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
            "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA": "1",
            "OTEL_METRICS_EXPORTER": "otlp",
            "OTEL_LOGS_EXPORTER": "otlp",
            "OTEL_TRACES_EXPORTER": "otlp",
        ]
        for signal in OTLPSignal.allCases {
            let upper = signal.rawValue.uppercased()
            if let upstream = upstreams[signal] {
                env["OTEL_EXPORTER_OTLP_\(upper)_ENDPOINT"] = endpoint + Self.forwardPath(agent: agent, signal: signal)
                env["OTEL_EXPORTER_OTLP_\(upper)_PROTOCOL"] = upstream.wire.rawValue
            } else {
                env["OTEL_EXPORTER_OTLP_\(upper)_ENDPOINT"] = "\(endpoint)/v1/\(signal.rawValue)"
                env["OTEL_EXPORTER_OTLP_\(upper)_PROTOCOL"] = "http/json"
            }
        }
        guard upstreams.isEmpty else { return env }
        env["OTEL_EXPORTER_OTLP_PROTOCOL"] = "http/json"
        env["OTEL_EXPORTER_OTLP_ENDPOINT"] = endpoint
        // Live enough to watch: a minute between metric exports is Claude Code's default.
        env["OTEL_METRIC_EXPORT_INTERVAL"] = "10000"
        env["OTEL_LOGS_EXPORT_INTERVAL"] = "2000"
        env["OTEL_TRACES_EXPORT_INTERVAL"] = "2000"
        if toolDetails { env["OTEL_LOG_TOOL_DETAILS"] = "1" }
        if prompts { env["OTEL_LOG_USER_PROMPTS"] = "1" }
        return env
    }

    /// Codex reads its exporters from config, so they go as `-c` layers for this run. One heed forwards changes only
    /// its endpoint, so your protocol and headers in config.toml still apply.
    public func arguments(agent: String) -> [String] {
        guard exports(agent), agent == "codex" else { return [] }
        let upstreams = upstreams(agent)
        var args: [String] = []
        for (signal, key) in Self.codexKeys {
            if upstreams[signal] != nil {
                let path = TOMLValue.quote(endpoint + Self.forwardPath(agent: agent, signal: signal))
                args += ["-c", "otel.\(key).otlp-http.endpoint=\(path)"]
            } else {
                let url = TOMLValue.quote("\(endpoint)/v1/\(signal.rawValue)")
                args += ["-c", "otel.\(key)={otlp-http={endpoint=\(url),protocol=\"json\"}}"]
            }
        }
        if prompts, upstreams.isEmpty { args += ["-c", "otel.log_user_prompt=true"] }
        return args
    }

    /// What Settings shows: per agent, what heed does.
    public func summary(agent: String) -> String {
        switch mode(agent) {
        case let .own(reason): return "your own setup, heed not involved: \(reason)"
        case let .forward(upstreams):
            let hosts = Array(Set(upstreams.values.map(\.host))).sorted().joined(separator: ", ")
            return "forwarding to \(hosts) through heed"
        case .heed: return Self.agents.contains(agent) ? "exporting to heed" : "heed does not know how to ask it"
        }
    }
}
