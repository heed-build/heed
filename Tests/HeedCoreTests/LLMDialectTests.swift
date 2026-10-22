import Foundation
@testable import HeedCore
import Testing

struct LLMDialectTests {
    private func result(_ stdout: String, status: Int32 = 0) -> ProcessResult {
        ProcessResult(status: status, stdout: stdout, stderr: "")
    }

    // MARK: Reading answers

    /// claude 2.1's `-p --output-format json --json-schema` answer, trimmed.
    @Test func claudeStructuredOutput() throws {
        let stdout = """
        {"type":"result","subtype":"success","is_error":false,"result":"{\\"answer\\":\\"blue\\"}",\
        "structured_output":{"answer":"blue","confidence":0.95},"total_cost_usd":0.0002614,\
        "usage":{"input_tokens":2,"cache_creation_input_tokens":1111,"cache_read_input_tokens":0,"output_tokens":78},\
        "modelUsage":{"model-h":{"inputTokens":2,"outputTokens":78,"costUSD":0.0002614}}}
        """
        let output = try LLMDialect.claude.parse(stdout, schema: true)
        #expect(output.model == "model-h" && output.cost == 0.0002614)
        #expect(output.tokens == TokenCounts(input: 2, output: 78, cacheRead: 0, cacheWrite: 1111))
        let json = try JSONSerialization.jsonObject(with: #require(output.json)) as? [String: Any]
        #expect(json?["answer"] as? String == "blue")
    }

    @Test func claudeErrorsThrowTheirMessage() {
        #expect(throws: LLMOutputError("You have hit your limit")) {
            try LLMDialect.claude.parse(
                #"{"type":"result","is_error":true,"result":"You have hit your limit"}"#,
                schema: false
            )
        }
        #expect(throws: LLMOutputError.self) { try LLMDialect.claude.parse("Error: no", schema: false) }
    }

    @Test func codexEvents() throws {
        let stdout = """
        {"type":"thread.started","thread_id":"t"}
        {"type":"item.completed","item":{"id":"i","type":"reasoning","text":"thinking"}}
        {"type":"item.completed","item":{"id":"j","type":"agent_message","text":"{\\"answer\\":\\"yes\\"}"}}
        {"type":"turn.completed","usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":12}}
        """
        let output = try LLMDialect.codex.parse(stdout, schema: true)
        #expect(output.text == #"{"answer":"yes"}"# && output.json != nil)
        #expect(output.tokens == TokenCounts(input: 600, output: 12, cacheRead: 400))
        #expect(throws: LLMOutputError("not logged in")) {
            try LLMDialect.codex.parse(#"{"type":"turn.failed","error":{"message":"not logged in"}}"#, schema: false)
        }
    }

    @Test func piEvents() throws {
        let stdout = """
        {"type":"session","id":"s"}
        {"type":"message_end","message":{"role":"user","content":"hi"}}
        {"type":"message_end","message":{"role":"assistant","model":"m-mini","stopReason":"stop",\
        "content":[{"type":"thinking","thinking":"x"},{"type":"text","text":"Hello"}],\
        "usage":{"input":10,"output":2,"cacheRead":5,"cacheWrite":0,"cost":{"total":0.0001}}}}
        {"type":"agent_settled","aborted":false}
        """
        let output = try LLMDialect.pi.parse(stdout, schema: false)
        #expect(output.text == "Hello" && output.model == "m-mini" && output.cost == 0.0001)
        #expect(output.tokens == TokenCounts(input: 10, output: 2, cacheRead: 5))
    }

    @Test func opencodeEvents() throws {
        let stdout = """
        {"type":"step_start","part":{}}
        {"type":"text","part":{"type":"text","text":"Here: {\\"a\\": 1}"}}
        {"type":"step_finish","part":{"cost":0.002,"tokens":{"input":50,"output":4,"reasoning":1,"cache":{"read":7,"write":0}}}}
        """
        let output = try LLMDialect.opencode.parse(stdout, schema: true)
        #expect(output.cost == 0.002 && output.tokens == TokenCounts(input: 50, output: 5, cacheRead: 7))
        #expect(output.json.flatMap { String(data: $0, encoding: .utf8) } == #"{"a": 1}"#)
    }

    @Test func geminiObject() throws {
        let stdout = #"{"response":"ok","stats":{"models":{"m-flash-lite":{"tokens":{"prompt":30,"candidates":2,"cached":10}}}}}"#
        let output = try LLMDialect.gemini.parse(stdout, schema: false)
        #expect(output.text == "ok" && output.model == "m-flash-lite")
        #expect(output.tokens == TokenCounts(input: 20, output: 2, cacheRead: 10))
    }

    @Test func jsonIsFoundInProseAndFences() {
        #expect(LLMDialect.jsonObject(in: "Sure:\n```json\n{\"a\": {\"b\": 1}}\n```") != nil)
        #expect(LLMDialect.jsonObject(in: "no json here") == nil)
        #expect(LLMDialect.jsonObject(in: "{not json}") == nil)
    }

    // MARK: Logins

    @Test func loginChecks() {
        #expect(LLMDialect.claude.loggedIn(result(#"{"loggedIn": true}"#)))
        #expect(!LLMDialect.claude.loggedIn(result(#"{"loggedIn": false}"#)))
        #expect(!LLMDialect.claude.loggedIn(result("", status: 1)))
        #expect(!LLMDialect.codex.loggedIn(result("Not logged in", status: 1)))
        #expect(LLMDialect.codex.loggedIn(result("Logged in using ChatGPT")))
        // opencode 1.19 with no credentials, colour codes and all.
        #expect(!LLMDialect.opencode
            .loggedIn(result("\u{1B}[0m\n┌  Credentials ~/.local/share/opencode/auth.json\n│\n└  0 credentials\n")))
        #expect(LLMDialect.opencode.loggedIn(result("┌  Credentials\n│\n●  Example api\n│\n└  1 credentials\n")))
        #expect(!LLMDialect.pi.loggedIn(result("No models available. Use /login to log into a provider.\n")))
        #expect(LLMDialect.pi
            .loggedIn(
                result(
                    "provider   model         context  max-out  thinking  images\nacme  acme-mini  200K  8K  no  yes\n"
                )
            ))
        #expect(LLMDialect.gemini.loginCheck == nil)
    }

    // MARK: Cheap models

    @Test func codexPicksTheFastAndAffordableModel() {
        let listing = """
        {"models":[{"slug":"m-big","description":"Frontier intelligence.","visibility":"list","priority":2},
        {"slug":"m-old-fast","description":"Older fast and efficient model.","visibility":"list","priority":9},
        {"slug":"m-luna","description":"Fast and affordable model for easier tasks.","visibility":"list","priority":4},
        {"slug":"m-hidden","description":"Affordable.","visibility":"hide","priority":1}]}
        """
        #expect(LLMDialect.codex.cheapModel(listing: listing) == "m-luna")
        #expect(LLMDialect.codex.cheapModel(listing: "nope") == nil)
    }

    @Test func piPicksByName() {
        let listing = "provider  model       context\nacme      acme-large  200K\nacme      acme-haiku  200K\n"
        #expect(LLMDialect.pi.cheapModel(listing: listing) == "acme/acme-haiku")
        #expect(LLMDialect.pi.cheapModel(listing: "provider model\nacme acme-large 1\n") == nil)
    }

    @Test func opencodePicksTheCheapestFromALoggedInProvider() {
        let listing = """
        acme/big
        {
          "providerID": "acme",
          "status": "active",
          "cost": { "input": 3, "output": 15 }
        }
        acme/small
        {
          "providerID": "acme",
          "status": "active",
          "cost": { "input": 0.25, "output": 1.25 }
        }
        acme/free
        {
          "providerID": "acme",
          "cost": { "input": 0, "output": 0 }
        }
        other/tiny
        {
          "providerID": "other",
          "cost": { "input": 0.01, "output": 0.01 }
        }
        """
        #expect(LLMDialect.opencode
            .cheapModel(listing: listing, login: "●  Acme api\n└  1 credentials") == "acme/small")
        #expect(LLMDialect.opencode.cheapModel(listing: listing, login: "└  0 credentials") == nil)
    }

    // MARK: Calls

    @Test func claudeCallsHaveNoToolsAndSaveNothing() {
        let call = LLMCall(system: "Be brief.", prompt: "hi", schema: "{}")
        let invocation = LLMDialect.claude.invocation(call, model: "haiku", scratch: "/tmp/x")
        #expect(invocation.stdin == "hi")
        #expect(invocation.arguments == [
            "-p", "--output-format", "json", "--tools", "", "--strict-mcp-config", "--setting-sources", "",
            "--no-session-persistence", "--system-prompt", "Be brief.", "--model", "haiku", "--json-schema", "{}",
        ])
        #expect(!invocation.arguments.contains("--bare"))
    }

    @Test func codexWritesItsSchemaToAFile() {
        let call = LLMCall(system: "S", prompt: "P", schema: "{}")
        let invocation = LLMDialect.codex.invocation(call, model: nil, scratch: "/tmp/x")
        #expect(invocation.files == ["schema.json": "{}"])
        #expect(invocation.arguments.suffix(3) == ["--output-schema", "/tmp/x/schema.json", "-"])
        #expect(invocation.arguments.contains("--ephemeral") && !invocation.arguments.contains("-m"))
        #expect(invocation.stdin == "S\n\n---\n\nP")
    }

    @Test func clisWithoutASchemaFlagGetItSpelledOut() {
        let call = LLMCall(system: "S", prompt: "P", schema: #"{"type":"object"}"#)
        let pi = LLMDialect.pi.invocation(call, model: "acme/m", scratch: "/tmp/x")
        let system = pi.arguments[pi.arguments.firstIndex(of: "--system-prompt")! + 1]
        #expect(system.hasPrefix("S\n\n") && system.contains(#"{"type":"object"}"#))
        #expect(pi.arguments.contains("--no-session") && pi.arguments.contains("--no-tools"))
        let opencode = LLMDialect.opencode.invocation(call, model: nil, scratch: "/tmp/x")
        #expect(opencode.arguments.last?.hasSuffix("---\n\nP") == true && opencode.stdin == nil)
    }

    @Test func rateLimitMessagesAreRecognised() {
        let now = ISO8601DateFormatter().date(from: "2026-10-22T09:00:00Z")!
        let limit = LLMDialect.rateLimit(in: "You've hit your session limit · resets 6pm (UTC)", now: now)
        #expect(limit.limited && limit.resetsAt == ISO8601DateFormatter().date(from: "2026-10-22T18:00:00Z"))
        #expect(LLMDialect.rateLimit(in: "429 Too Many Requests", now: now) == (true, nil))
        #expect(!LLMDialect.rateLimit(in: "exit 1: boom", now: now).limited)
    }

    // MARK: Config

    @Test func llmConfig() throws {
        let source = """
        [llm]
        enabled = false
        timeout_seconds = 60
        concurrency = 3
        backoff_minutes = 5
        daily_calls = 0
        daily_dollars = 2.5

        [agents.claude]
        llm_model = "sonnet"

        [agents.codex]
        llm = false
        """
        let (config, problems) = ConfigLoader.decode(source)
        #expect(problems.isEmpty)
        let llm = try #require(config?.llm)
        #expect(!llm.enabled && llm.timeoutSeconds == 60 && llm.concurrency == 3 && llm.backoffMinutes == 5)
        #expect(llm.dailyCalls == 0 && llm.dailyDollars == 2.5)
        #expect(llm.model(for: "claude") == "sonnet" && llm.isEnabled("claude"))
        #expect(!llm.isEnabled("codex") && llm.model(for: "codex") == nil && llm.isEnabled("pi"))
        // The claude table only set llm_model: its command is still the built-in one.
        #expect(config?.work.agent("claude")?.command == "claude")
    }

    @Test func llmConfigProblems() {
        let (_, problems) = ConfigLoader.decode("[llm]\ndaily_dollars = \"lots\"\nconcurrency = 0\n")
        #expect(problems.map(\.path).sorted() == ["llm.concurrency", "llm.daily_dollars"])
    }

    @Test func theDefaultConfigHasTheLLMDefaults() throws {
        let (config, problems) = ConfigLoader.decode(ConfigLoader.defaultSource)
        #expect(problems.isEmpty)
        #expect(config?.llm == LLMSettings())
    }
}
