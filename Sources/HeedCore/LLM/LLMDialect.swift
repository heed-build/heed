import Foundation

/// One model call as heed asks for it: instructions, the input, and optionally a JSON Schema the answer must match.
public struct LLMCall: Hashable, Sendable {
    /// What the model is (the system prompt where the CLI takes one; put in front of the input elsewhere).
    public var system: String
    public var prompt: String
    /// A JSON Schema (as JSON text) the answer must match; nil for a text answer.
    public var schema: String?

    public init(system: String, prompt: String, schema: String? = nil) {
        self.system = system
        self.prompt = prompt
        self.schema = schema
    }

    /// The system prompt with the schema spelled out, for CLIs that cannot enforce one.
    var systemWithSchema: String {
        guard let schema else { return system }
        return system + "\n\nReply with only a JSON object that matches this JSON Schema, with no prose and no code "
            + "fence:\n" + schema
    }

    /// System and input in one text, for CLIs without a system prompt flag.
    var combined: String {
        systemWithSchema + "\n\n---\n\n" + prompt
    }
}

/// What a CLI answered, read from its JSON output.
public struct LLMOutput: Equatable, Sendable {
    public var text: String
    /// The answer as a JSON object, when a schema was asked for.
    public var json: Data?
    public var model: String?
    public var tokens: TokenCounts?
    /// What the CLI said the call cost.
    public var cost: Double?

    public init(
        text: String, json: Data? = nil, model: String? = nil, tokens: TokenCounts? = nil, cost: Double? = nil
    ) {
        self.text = text
        self.json = json
        self.model = model
        self.tokens = tokens
        self.cost = cost
    }
}

public struct LLMOutputError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// How heed calls one agent CLI headless: its free login check, how to find a cheap model, the call's arguments, and
/// how to read its output. Flags checked against each CLI's `--help` on 2026-10-22 (claude 2.1, codex 0.163, pi 1.3,
/// opencode 1.19); gemini and cursor-agent were not installed, so theirs follow their docs and are untested.
public enum LLMDialect: String, Sendable, CaseIterable {
    case claude, codex, gemini, opencode, pi, cursor

    /// The dialect of a built-in agent; custom agents take no part.
    public static func of(_ agent: AgentProfile) -> LLMDialect? { LLMDialect(rawValue: agent.name) }

    // MARK: Login

    /// Arguments of a check that costs nothing and says whether the CLI is logged in; nil when there is none.
    public var loginCheck: [String]? {
        switch self {
        case .claude: ["auth", "status"]
        case .codex: ["login", "status"]
        case .gemini: nil
        case .opencode: ["providers", "list"]
        // Lists only the models of providers with credentials: none means not logged in.
        case .pi: ["--list-models"]
        case .cursor: ["status"]
        }
    }

    /// Whether the check's result says logged in.
    public func loggedIn(_ result: ProcessResult) -> Bool {
        let output = result.stdout + "\n" + result.stderr
        switch self {
        case .claude:
            guard result.succeeded else { return false }
            let json = (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8))) as? [String: Any]
            return json?["loggedIn"] as? Bool ?? true
        case .codex: return result.succeeded && !output.localizedCaseInsensitiveContains("not logged in")
        case .gemini: return result.succeeded
        case .opencode:
            // `└  2 credentials`, and a section for providers set from the environment.
            guard result.succeeded else { return false }
            let counts = Self.matches(#"(\d+)\s+(?:credentials?|environment)"#, in: Self.plain(output))
            return counts.contains { (Int($0) ?? 0) > 0 }
        case .pi: return result.succeeded && !Self.piModels(result.stdout).isEmpty
        case .cursor:
            return result.succeeded && !output.localizedCaseInsensitiveContains("not logged in")
                && !output.localizedCaseInsensitiveContains("not authenticated")
        }
    }

    // MARK: The cheap model

    /// The model used when the CLI cannot list its own (claude's alias, gemini's).
    public var fixedModel: String? {
        switch self {
        case .claude: "haiku"
        case .gemini: "flash-lite"
        default: nil
        }
    }

    /// Arguments that list the models to pick a cheap one from; nil when `fixedModel` is used.
    public var modelListing: [String]? {
        switch self {
        case .claude, .gemini: nil
        case .codex: ["debug", "models"]
        case .opencode: ["models", "--verbose"]
        case .pi: ["--list-models"]
        case .cursor: ["models"]
        }
    }

    /// The cheap model in a listing; nil leaves the CLI's own default. `login` is the login check's output (opencode:
    /// which providers have credentials).
    public func cheapModel(listing: String, login: String = "") -> String? {
        switch self {
        case .claude, .gemini: return fixedModel
        case .codex: return Self.codexModel(listing)
        case .opencode: return Self.opencodeModel(listing, providers: login)
        case .pi: return Self.cheapest(Self.piModels(listing))
        case .cursor:
            let ids = listing.split(whereSeparator: \.isNewline).compactMap { line in
                Self.plain(String(line)).split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
            }.filter { $0.contains("-") }
            return Self.cheapest(ids)
        }
    }

    /// Words in a model id that mark a small, cheap one, best first.
    static let cheapWords = ["haiku", "flash-lite", "nano", "mini", "luna", "flash", "lite", "small", "fast"]

    /// The id with the best cheap word; nil when none has one.
    static func cheapest(_ ids: [String]) -> String? {
        for word in cheapWords {
            if let id = ids.first(where: { $0.lowercased().contains(word) }) { return id }
        }
        return nil
    }

    /// codex's catalog: the listed model whose description says it is fast and affordable, highest priority first.
    static func codexModel(_ listing: String) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(listing.utf8)) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else { return nil }
        let listed = models.filter { ($0["visibility"] as? String ?? "list") == "list" }
            .sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
        for words in [["affordable"], ["fast", "cheap", "efficient"]] {
            if let model = listed.first(where: { model in
                let description = (model["description"] as? String ?? "").lowercased()
                return words.contains { description.contains($0) }
            }) {
                return model["slug"] as? String
            }
        }
        return nil
    }

    /// `opencode models --verbose`: a `provider/model` line, then that model as JSON. The cheapest that costs
    /// anything, from a provider the login check lists.
    static func opencodeModel(_ listing: String, providers: String) -> String? {
        let known = plain(providers).lowercased()
        var best: (id: String, price: Double)?
        var id: String?
        var json = ""
        func finish() {
            defer { json = "" }
            guard let current = id,
                  let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            else { return }
            let provider = (object["providerID"] as? String ?? current.split(separator: "/").first.map(String.init))?
                .lowercased() ?? ""
            guard !provider.isEmpty, known.contains(provider) else { return }
            if let status = object["status"] as? String, status != "active" { return }
            let cost = object["cost"] as? [String: Any]
            let price = ((cost?["input"] as? NSNumber)?.doubleValue ?? 0) + ((cost?["output"] as? NSNumber)?
                .doubleValue ?? 0)
            guard price > 0 else { return }
            if best == nil || price < best!.price { best = (current, price) }
        }
        for line in listing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if !line.hasPrefix(" "), !line.hasPrefix("{"), !line.hasPrefix("}"), line.contains("/") {
                finish()
                id = line.trimmingCharacters(in: .whitespaces)
            } else {
                json += line + "\n"
            }
        }
        finish()
        return best?.id
    }

    /// `pi --list-models`: a table of provider, model, …; `provider/model` per row.
    static func piModels(_ listing: String) -> [String] {
        guard !listing.localizedCaseInsensitiveContains("no models available") else { return [] }
        return listing.split(separator: "\n").compactMap { line in
            let columns = plain(String(line)).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard columns.count >= 2, columns[0] != "provider", !columns[0].hasSuffix(":"),
                  columns[0].allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) })
            else { return nil }
            return "\(columns[0])/\(columns[1])"
        }
    }

    // MARK: The call

    /// What to run: the arguments, what goes on stdin, and files written into the scratch directory first.
    public struct Invocation: Equatable, Sendable {
        public var arguments: [String]
        public var stdin: String?
        public var files: [String: String] = [:]
    }

    /// The headless call in `scratch` (an empty temporary directory): tools off, nothing saved, `model` when given.
    public func invocation(_ call: LLMCall, model: String?, scratch: String) -> Invocation {
        let model = model.flatMap { $0.isEmpty ? nil : $0 }
        switch self {
        case .claude:
            // --system-prompt replaces Claude Code's own, which made a one-line call cost 60 times more. Never --bare:
            // it ignores a subscription login.
            var arguments = [
                "-p", "--output-format", "json", "--tools", "", "--strict-mcp-config", "--setting-sources", "",
                "--no-session-persistence", "--system-prompt", call.system,
            ]
            if let model { arguments += ["--model", model] }
            if let schema = call.schema { arguments += ["--json-schema", schema] }
            return Invocation(arguments: arguments, stdin: call.prompt)
        case .codex:
            var arguments = [
                "exec", "--json", "--ephemeral", "-s", "read-only", "--skip-git-repo-check", "-C", scratch,
                "-c", "model_reasoning_effort=\"low\"",
            ]
            if let model { arguments += ["-m", model] }
            var files: [String: String] = [:]
            if let schema = call.schema {
                files["schema.json"] = schema
                arguments += ["--output-schema", "\(scratch)/schema.json"]
            }
            let prompt = call.system + "\n\n---\n\n" + call.prompt
            return Invocation(arguments: arguments + ["-"], stdin: prompt, files: files)
        case .gemini:
            var arguments = ["-o", "json"]
            if let model { arguments += ["-m", model] }
            return Invocation(arguments: arguments + ["-p", call.combined], stdin: nil)
        case .opencode:
            var arguments = ["run", "--format", "json", "--dir", scratch]
            if let model { arguments += ["-m", model] }
            return Invocation(arguments: arguments + [call.combined], stdin: nil)
        case .pi:
            var arguments = [
                "-p", "--mode", "json", "--no-session", "--no-tools", "--no-extensions", "--no-skills",
                "--no-context-files", "--no-mcp", "--system-prompt", call.systemWithSchema,
            ]
            if let model { arguments += ["--model", model] }
            return Invocation(arguments: arguments, stdin: call.prompt)
        case .cursor:
            var arguments = ["-p", "--output-format", "json", "--mode", "ask"]
            if let model { arguments += ["--model", model] }
            return Invocation(arguments: arguments + [call.combined], stdin: nil)
        }
    }

    /// Reads the CLI's output. Throws with the CLI's own message when it reports an error.
    public func parse(_ stdout: String, schema: Bool) throws -> LLMOutput {
        var output = switch self {
        case .claude, .cursor: try Self.parseClaude(stdout)
        case .codex: try Self.parseCodex(stdout)
        case .gemini: try Self.parseGemini(stdout)
        case .opencode: try Self.parseOpencode(stdout)
        case .pi: try Self.parsePi(stdout)
        }
        if schema, output.json == nil { output.json = Self.jsonObject(in: output.text) }
        return output
    }

    private static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private static func lines(_ text: String) -> [[String: Any]] {
        text.split(whereSeparator: \.isNewline).compactMap { object(String($0)) }
    }

    private static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
    private static func double(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

    /// claude (and cursor-agent, which answers the same shape): one JSON object.
    static func parseClaude(_ stdout: String) throws -> LLMOutput {
        guard let json = object(stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? lines(stdout).last(where: { $0["type"] as? String == "result" })
        else { throw LLMOutputError("not JSON") }
        let text = json["result"] as? String ?? ""
        if json["is_error"] as? Bool ==
            true { throw LLMOutputError(text.isEmpty ? "the agent reported an error" : text) }
        var output = LLMOutput(text: text)
        if let structured = json["structured_output"], JSONSerialization.isValidJSONObject(structured) {
            output.json = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys])
        }
        if let usage = json["usage"] as? [String: Any] {
            output.tokens = TokenCounts(
                input: int(usage["input_tokens"]), output: int(usage["output_tokens"]),
                cacheRead: int(usage["cache_read_input_tokens"]), cacheWrite: int(usage["cache_creation_input_tokens"])
            )
        }
        output.cost = double(json["total_cost_usd"])
        output.model = (json["modelUsage"] as? [String: Any])?.keys.sorted().first ?? json["model"] as? String
        return output
    }

    /// codex exec --json: events, one per line.
    static func parseCodex(_ stdout: String) throws -> LLMOutput {
        var text: String?
        var tokens: TokenCounts?
        for event in lines(stdout) {
            switch event["type"] as? String {
            case "item.completed":
                let item = event["item"] as? [String: Any]
                if item?["type"] as? String == "agent_message" { text = item?["text"] as? String }
            case "turn.completed":
                if let usage = event["usage"] as? [String: Any] {
                    let cached = int(usage["cached_input_tokens"])
                    tokens = TokenCounts(
                        input: max(0, int(usage["input_tokens"]) - cached), output: int(usage["output_tokens"]),
                        cacheRead: cached
                    )
                }
            case "turn.failed", "error":
                let error = (event["error"] as? [String: Any])?["message"] as? String ?? event["message"] as? String
                throw LLMOutputError(error ?? "the agent reported an error")
            default: break
            }
        }
        guard let text else { throw LLMOutputError("no answer in the output") }
        return LLMOutput(text: text, tokens: tokens)
    }

    /// gemini -o json: one object with the response and per-model stats.
    static func parseGemini(_ stdout: String) throws -> LLMOutput {
        guard let json = object(stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw LLMOutputError("not JSON")
        }
        if let error = json["error"] as? [String: Any] {
            throw LLMOutputError(error["message"] as? String ?? "the agent reported an error")
        }
        guard let text = json["response"] as? String else { throw LLMOutputError("no answer in the output") }
        var output = LLMOutput(text: text)
        if let models = (json["stats"] as? [String: Any])?["models"] as? [String: Any],
           let (name, stats) = models.sorted(by: { $0.key < $1.key }).first,
           let counts = (stats as? [String: Any])?["tokens"] as? [String: Any]
        {
            output.model = name
            let cached = int(counts["cached"])
            output.tokens = TokenCounts(
                input: max(0, int(counts["prompt"]) - cached), output: int(counts["candidates"]), cacheRead: cached
            )
        }
        return output
    }

    /// opencode run --format json: events; text parts make the answer, step_finish parts carry cost and tokens.
    static func parseOpencode(_ stdout: String) throws -> LLMOutput {
        var text = ""
        var tokens = TokenCounts()
        var cost: Double?
        var sawText = false
        for event in lines(stdout) {
            let part = event["part"] as? [String: Any]
            switch event["type"] as? String {
            case "text":
                sawText = true
                text += part?["text"] as? String ?? ""
            case "step_finish":
                if let value = double(part?["cost"]) { cost = (cost ?? 0) + value }
                if let counts = part?["tokens"] as? [String: Any] {
                    let cache = counts["cache"] as? [String: Any]
                    tokens += TokenCounts(
                        input: int(counts["input"]), output: int(counts["output"]) + int(counts["reasoning"]),
                        cacheRead: int(cache?["read"]), cacheWrite: int(cache?["write"])
                    )
                }
            case "error":
                let error = event["error"] as? [String: Any]
                let message = (error?["data"] as? [String: Any])?["message"] as? String ?? error?["message"] as? String
                throw LLMOutputError(message ?? "the agent reported an error")
            default: break
            }
        }
        guard sawText else { throw LLMOutputError("no answer in the output") }
        return LLMOutput(text: text, tokens: tokens.isEmpty ? nil : tokens, cost: cost)
    }

    /// pi --mode json: events; the last assistant `message_end` is the answer.
    static func parsePi(_ stdout: String) throws -> LLMOutput {
        guard let message = lines(stdout).last(where: { event in
            event["type"] as? String == "message_end"
                && (event["message"] as? [String: Any])?["role"] as? String == "assistant"
        })?["message"] as? [String: Any] else { throw LLMOutputError("no answer in the output") }
        if message["stopReason"] as? String == "error" {
            throw LLMOutputError(message["errorMessage"] as? String ?? "the agent reported an error")
        }
        let text = (message["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }.joined()
        var output = LLMOutput(text: text, model: message["model"] as? String)
        if let usage = message["usage"] as? [String: Any] {
            output.tokens = TokenCounts(
                input: int(usage["input"]), output: int(usage["output"]), cacheRead: int(usage["cacheRead"]),
                cacheWrite: int(usage["cacheWrite"])
            )
            if let total = double((usage["cost"] as? [String: Any])?["total"]), total > 0 { output.cost = total }
        }
        return output
    }

    /// The JSON object in a reply that may wrap it in prose or a code fence.
    static func jsonObject(in text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let candidate = Data(text[start ... end].utf8)
        guard (try? JSONSerialization.jsonObject(with: candidate)) is [String: Any] else { return nil }
        return candidate
    }

    // MARK: Text helpers

    /// Without terminal colour codes.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: #"\u{1B}\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// When a failed call's message says the agent is rate limited: the reset it names, or nil when it names none.
    /// `limited` is false when the message is not about a limit at all.
    static func rateLimit(in message: String, now: Date) -> (limited: Bool, resetsAt: Date?) {
        let patterns = ScreenGuess.common[.limited] ?? []
        let limited = patterns.contains { message.range(of: $0, options: .regularExpression) != nil }
            || message.localizedCaseInsensitiveContains("hit your limit")
            || message.localizedCaseInsensitiveContains("session limit")
        guard limited else { return (false, nil) }
        return (true, UsageTranscripts.claudeReset(in: message, after: now))
    }
}
