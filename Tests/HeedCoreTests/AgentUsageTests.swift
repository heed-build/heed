import Foundation
@testable import HeedCore
import Testing

struct AgentUsageTests {
    static func lines(_ objects: [[String: Any]]) -> Data {
        Data(objects.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
            .map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n").utf8)
    }

    static func assistant(
        _ request: String,
        model: String = "model-a",
        input: Int,
        output: Int,
        read: Int = 0,
        write: Int = 0
    ) -> [String: Any] {
        [
            "type": "assistant", "requestId": request,
            "message": [
                "model": model, "role": "assistant",
                "usage": [
                    "input_tokens": input, "output_tokens": output, "cache_read_input_tokens": read,
                    "cache_creation_input_tokens": write,
                ],
            ],
        ]
    }

    @Test func claudeTranscriptDedupesARequestWrittenAsSeveralLines() throws {
        let data = Self.lines([
            ["type": "user", "message": ["role": "user", "content": "do it"]],
            Self.assistant("req_1", input: 10, output: 5, read: 100),
            Self.assistant("req_1", input: 10, output: 7, read: 100),
            ["type": "user", "message": ["role": "user", "content": [["type": "tool_result"]]]],
            Self.assistant("req_2", model: "model-b", input: 3, output: 20, read: 200, write: 50),
        ])
        let report = try #require(UsageTranscripts.claude(data))
        #expect(report.model == "model-b")
        #expect(report.requests?.map(\.id) == ["req_1", "req_2"])
        #expect(report.requests?.first?.tokens == TokenCounts(input: 10, output: 7, cacheRead: 100))
        #expect(report.contextTokens == 253)
    }

    @Test func aTornFirstLineAndJunkAreSkipped() throws {
        var data = Data("ant\",\"type\":\"assistant\"}\nnot json\n".utf8)
        data.append(Self.lines([Self.assistant("req_9", input: 1, output: 2)]))
        let report = try #require(UsageTranscripts.claude(data))
        #expect(report.requests?.map(\.id) == ["req_9"])
        #expect(UsageTranscripts.claude(Data("{}\n".utf8)) == nil)
    }

    @Test func theTailStartsAtAWholeLine() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try (String(repeating: "x", count: 100) + "\n{\"a\":1}\n").write(to: url, atomically: true, encoding: .utf8)
        let tail = try #require(UsageTranscripts.tail(path: url.path, maxBytes: 20))
        #expect(String(decoding: tail, as: UTF8.self) == "{\"a\":1}\n")
        #expect(UsageTranscripts.tail(path: "/nonexistent/heed-test.jsonl") == nil)
    }

    @Test func aClaudeRateLimitSaysWhenItResets() throws {
        let data = Self.lines([[
            "type": "assistant", "isApiErrorMessage": true, "error": "rate_limit",
            "timestamp": "2026-09-27T07:14:02.770Z",
            "message": [
                "model": "<synthetic>",
                "content": [[
                    "type": "text",
                    "text": "You've hit your session limit · resets 6:20pm (Europe/Amsterdam)",
                ]],
            ],
        ]])
        let report = try #require(UsageTranscripts.claude(data))
        #expect(report.model == nil)
        #expect(report.requests == nil)
        // 18:20 in Amsterdam (CEST) on the same day is 16:20 UTC.
        #expect(report.rateLimitResetsAt == UsageTranscripts.parseTimestamp("2026-09-27T16:20:00Z"))
        let after = try #require(UsageTranscripts.parseTimestamp("2026-09-27T20:00:00Z"))
        #expect(UsageTranscripts.claudeReset(in: "resets 6:20pm (Europe/Amsterdam)", after: after)
            == UsageTranscripts.parseTimestamp("2026-09-28T16:20:00Z"))
        #expect(UsageTranscripts.claudeReset(in: "resets Oct 3, 9am (UTC)", after: after)
            == UsageTranscripts.parseTimestamp("2026-10-03T09:00:00Z"))
        #expect(UsageTranscripts.claudeReset(in: "no time here", after: after) == nil)
    }

    @Test func codexRolloutGivesTotalsContextAndTheFullestRateLimit() throws {
        let data = Self.lines([
            ["type": "turn_context", "payload": ["model": "model-c"]],
            ["type": "event_msg", "payload": ["type": "token_count", "info": NSNull()]],
            [
                "type": "event_msg", "timestamp": "2026-10-01T10:00:00Z",
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 5000, "cached_input_tokens": 3000, "output_tokens": 800,
                            "reasoning_output_tokens": 200, "total_tokens": 5800,
                        ],
                        "last_token_usage": ["input_tokens": 2000, "output_tokens": 100, "total_tokens": 2100],
                        "model_context_window": 10000,
                    ],
                    "rate_limits": [
                        "primary": ["used_percent": 20.0, "window_minutes": 300, "resets_in_seconds": 600],
                        "secondary": ["used_percent": 90.0, "window_minutes": 10080, "resets_at": 1_791_000_000],
                    ],
                ],
            ],
        ])
        let report = try #require(UsageTranscripts.codex(data))
        #expect(report.model == "model-c")
        #expect(report.totals == TokenCounts(input: 2000, output: 800, cacheRead: 3000))
        #expect(report.contextTokens == 2100 && report.contextWindow == 10000)
        #expect(report.rateLimitResetsAt == Date(timeIntervalSince1970: 1_791_000_000))
    }

    @Test func requestsAlreadyCountedAreNotCountedAgain() {
        let one = RequestUsage(id: "a", tokens: TokenCounts(input: 1, output: 10))
        let two = RequestUsage(id: "b", tokens: TokenCounts(input: 2, output: 20))
        let three = RequestUsage(id: "c", tokens: TokenCounts(input: 4, output: 40), costUSD: 0.5)
        var usage = AgentUsage().applying(UsageReport(model: "model-a", requests: [one, two]))
        #expect(usage.tokens == TokenCounts(input: 3, output: 30) && usage.lastRequestID == "b")
        // The next hook reads the same tail, and one more request.
        usage = usage.applying(UsageReport(requests: [one, two, three]))
        #expect(usage.tokens == TokenCounts(input: 7, output: 70) && usage.costUSD == 0.5)
        #expect(usage.model == "model-a")
        // Totals (codex) replace what was known.
        usage = usage.applying(UsageReport(totals: TokenCounts(input: 1, output: 1)))
        #expect(usage.tokens == TokenCounts(input: 1, output: 1) && usage.costUSD == nil)
    }

    @Test func pricesEstimateFromTheLongestPrefix() throws {
        let prices = try UsagePrices([
            "model": #require(UsagePrices.Price(parsing: "1 / 2")),
            "model-a": #require(UsagePrices.Price(parsing: "3 / 15")),
        ])
        let usage = AgentUsage(
            model: "provider/model-a-large",
            tokens: TokenCounts(input: 1_000_000, output: 100_000, cacheRead: 1_000_000, cacheWrite: 100_000)
        )
        // 3 + 1.5 + 0.3 (a tenth of input) + 0.375 (1.25× input).
        #expect(abs((prices.estimate(usage) ?? 0) - 5.175) < 0.0001)
        #expect(prices.price(for: "model-b")?.input == 1)
        #expect(prices.price(for: "other") == nil)
        #expect(UsagePrices.Price(parsing: "1 / 2 / 3 / 4")?.cacheWrite == 4)
        #expect(UsagePrices.Price(parsing: "1 / x") == nil && UsagePrices.Price(parsing: "1") == nil)
        // A reported cost wins over the estimate; show_cost = false shows none.
        var reported = usage
        reported.costUSD = 0.25
        #expect(UsageSettings(prices: prices).cost(of: reported) == 0.25)
        #expect(UsageSettings(showCost: false, prices: prices).cost(of: usage) == nil)
    }

    @Test func theSummaryShowsOnlyWhatIsKnown() {
        let usage = AgentUsage(
            model: "model-a", tokens: TokenCounts(input: 1300, output: 4100, cacheRead: 11000),
            contextTokens: 76000, contextWindow: 200_000
        )
        #expect(usage.summary(cost: 0.42) == "model-a · 12.3k in / 4.1k out · ≈$0.42 · ctx 38%")
        #expect(AgentUsage(model: "model-a").summary(cost: nil) == "model-a")
        #expect(AgentUsage(contextTokens: 76000).summary(cost: nil, includeModel: false) == "ctx 76k")
        #expect(AgentUsage.count(950) == "950" && AgentUsage.count(12345) == "12.3k" && AgentUsage
            .count(123_456) == "123k" && AgentUsage.count(2_500_000) == "2.5M")
        #expect(AgentUsage.dollars(0.004) == "<$0.01" && AgentUsage.dollars(12.4) == "$12")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let utc = TimeZone(identifier: "UTC")!
        let limited = AgentUsage(rateLimitResetsAt: now.addingTimeInterval(3600))
        #expect(limited.resetText(now: now, timeZone: utc) == "resets at 09:00")
        #expect(limited.resetText(now: now.addingTimeInterval(7200)) == nil)
    }

    @Test func cachesWithoutUsageStillLoad() throws {
        var current = Session(title: "t", repos: [], branch: "b", agent: "claude", state: ObservedState(.idle))
        current.usage = AgentUsage(model: "model-a")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        #expect(object["usage"] != nil)
        object["usage"] = nil
        let session = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(session.usage == nil)
        // And a usage written by a later heed with fields this one does not know, or without ones it does.
        let usage = try JSONDecoder().decode(AgentUsage.self, from: Data(#"{"model":"model-a","later":1}"#.utf8))
        #expect(usage == AgentUsage(model: "model-a"))
        var run = PilotRun(
            ref: PullRef(repo: Repo(org: "o", name: "r"), number: 1), sessionID: "s", goal: .green, agent: "codex",
            model: nil, startedAt: Date(timeIntervalSince1970: 0), items: 1, prBranch: "p", branch: "b", worktree: "w",
            startSHA: nil
        )
        let encoded = try JSONEncoder().encode(run)
        #expect(try JSONDecoder().decode(PilotRun.self, from: encoded).usage == nil)
        run.usage = AgentUsage(model: "model-a", tokens: TokenCounts(output: 3))
        #expect(try JSONDecoder().decode(PilotRun.self, from: JSONEncoder().encode(run)).usage == run.usage)
    }

    @Test func usageTravelsOverTheSocket() throws {
        let message = HookMessage(session: "s", kind: .usage(UsageReport(
            model: "model-a", requests: [RequestUsage(id: "r", tokens: TokenCounts(input: 1))],
            rateLimitResetsAt: Date(timeIntervalSince1970: 1_800_000_000)
        )), sentAt: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(try HookMessage.decode(line: message.encodedLine()) == message)
    }
}

struct UsageHookTests {
    @Test func agentsReportTheirModel() {
        #expect(AgentIntegration.claudeHook(event: "SessionStart", input: ["model": "model-a"]) == [
            .usage(UsageReport(model: "model-a")), .state(.idle, reason: nil),
        ])
        #expect(AgentIntegration.codexHook(event: "UserPromptSubmit", input: ["model": "model-b"]) == [
            .usage(UsageReport(model: "model-b")), .state(.working, reason: "prompt"),
        ])
        #expect(AgentIntegration.codexHook(event: "Stop", input: ["model": "model-b"]) == [
            .usage(UsageReport(model: "model-b")), .state(.done, reason: nil),
        ])
        #expect(AgentIntegration.cursorHook(event: "stop", input: ["model": "model-c"]) == [
            .usage(UsageReport(model: "model-c")), .state(.done, reason: nil),
        ])
    }

    @Test func claudeReadsItsTranscriptAtTheEndOfATurn() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try AgentUsageTests.lines([AgentUsageTests.assistant("req_1", input: 5, output: 6)]).write(to: url)
        let kinds = AgentIntegration.claudeHook(event: "StopFailure", input: [
            "transcript_path": url.path, "error": "rate_limit",
        ])
        #expect(kinds == [
            .usage(UsageReport(
                model: "model-a", requests: [RequestUsage(id: "req_1", tokens: TokenCounts(input: 5, output: 6))],
                contextTokens: 5
            )),
            .state(.limited, reason: "rate limited"),
        ])
        // A transcript that is not there: nothing, and the state as before.
        #expect(AgentIntegration.claudeHook(event: "Stop", input: ["transcript_path": "/nonexistent/x.jsonl"])
            == [.state(.done, reason: nil)])
    }

    @Test func opencodeForwardsFinishedMessages() {
        let detail = #"{"id":"m1","model":"model-d","cost":0.02,"input":10,"output":4,"reasoning":1,"cacheRead":30,"cacheWrite":0}"#
        #expect(AgentIntegration.opencodeHook(event: "usage", sessionID: "s", detail: detail) == [
            .usage(UsageReport(model: "model-d", requests: [
                RequestUsage(id: "m1", tokens: TokenCounts(input: 10, output: 5, cacheRead: 30), costUSD: 0.02),
            ])),
        ])
        #expect(AgentIntegration.opencodeHook(event: "usage", sessionID: "s", detail: "junk").isEmpty)
    }

    @Test func usagePricesAreConfigured() {
        let (config, problems) = ConfigLoader.decode("""
        [usage]
        show_cost = false
        [usage.prices]
        "model-a" = "3 / 15"
        "model-b" = "three"
        """)
        #expect(config?.usage.showCost == false)
        #expect(config?.usage.prices.byPrefix["model-a"] == UsagePrices.Price(input: 3, output: 15))
        #expect(problems.map(\.path) == ["usage.prices.model-b"])
        #expect(HeedConfig.default.usage == UsageSettings())
    }

    @Test func aModelIdIsShortenedForTheSidebar() {
        #expect(AgentUsage.shortModel("model-a") == "model-a")
        #expect(AgentUsage.shortModel("provider/model-a") == "model-a")
        #expect(AgentUsage.shortModel("model-a-20250101") == "model-a")
        #expect(AgentUsage.shortModel("vendor/model-b-mini-2025-01-01") == "model-b-mini")
        #expect(AgentUsage.shortModel("model-c@20250101") == "model-c")
        // A date alone is all there is: it stays.
        #expect(AgentUsage.shortModel("20250101") == "20250101")
        let long = AgentUsage.shortModel("model-very-long-name-preview-x")
        #expect(long == "model-ver…review-x")
        #expect(long.count == 18)
    }

    @Test func theSidebarLineShowsTheModelAndContextOnlyWhenKnown() {
        let usage = AgentUsage(model: "provider/model-a-20250101", contextTokens: 76000, contextWindow: 200_000)
        let working = AgentUsage.line(agent: "agent-a", working: true, activity: "running tests", usage: usage)
        #expect(working.text == "agent-a · model-a · ctx 38%")
        #expect(!working.contextIsHigh)
        let idle = AgentUsage.line(agent: "agent-a", working: false, activity: "idle 4m", usage: usage)
        #expect(idle.text == "agent-a · model-a · idle 4m")
        #expect(idle.context == nil)
        let full = AgentUsage(model: "model-a", contextTokens: 160_000, contextWindow: 200_000)
        #expect(AgentUsage.line(agent: "agent-a", working: true, activity: "", usage: full).contextIsHigh)
        // No window: no percentage.
        let noWindow = AgentUsage(model: "model-a", contextTokens: 76000)
        #expect(AgentUsage.line(agent: "agent-a", working: true, activity: "", usage: noWindow).text
            == "agent-a · model-a")
        #expect(AgentUsage.line(agent: "agent-a", working: true, activity: "x", usage: nil).text == "agent-a")
        #expect(AgentUsage.line(agent: "agent-a", working: true, activity: "", usage: usage, subagents: 2).text
            == "agent-a · model-a · ctx 38% · 2 subagents")
        #expect(AgentUsage.line(agent: "agent-a", working: false, activity: "idle", usage: nil, subagents: 1).text
            == "agent-a · 1 subagent · idle")
        #expect(AgentUsage.line(agent: "agent-a", working: false, activity: "idle", usage: nil).text
            == "agent-a · idle")
    }
}
