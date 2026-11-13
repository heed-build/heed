import Foundation
@testable import HeedCore
import Testing

/// The agents' own OpenTelemetry: OTLP/JSON as Claude Code and Codex send it (recorded from their documented schemas
/// in Fixtures/otlp), read into heed's spans, made whole, summed, and served over HTTP.
struct TelemetryTests {
    static func payload(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/otlp"
        ))
        return try Data(contentsOf: url)
    }

    static func records(_ names: String...) throws -> TelemetryRecords {
        try names.reduce(TelemetryRecords()) { records, name in
            try records + TelemetryReader.records(OTLPJSON.decode(payload(name)))
        }
    }

    static let session = Session(
        id: "s1", title: "Fix broken anchors", repos: [Repo(org: "acme", name: "docs-toolkit")], branch: "b",
        agent: "claude", agentSessionID: "7f3a9c1e-52b4-4e0d-9a61-0c8d3e1f2b77", state: ObservedState(.working)
    )
    static let codex = Session(
        id: "s3", title: "Backpressure", repos: [Repo(org: "acme", name: "ingest")], branch: "b", agent: "codex",
        agentSessionID: "91be40d2-7a35-4c68-b2f9-13e5a8d07c46", state: ObservedState(.working)
    )

    // MARK: OTLP

    @Test func decodesClaudeCodeSpans() throws {
        let batch = try OTLPJSON.decode(Self.payload("claude-traces"), signal: .traces)
        #expect(batch.spans.count == 5)
        let request = try #require(batch.spans.first { $0.name == "claude_code.llm_request" })
        #expect(request.traceID == "5b8efff798038103d269b633813fc60c")
        #expect(request.parentID == "eee19b7ec3c1b174")
        #expect(request.attributes["input_tokens"] == "1200")
        #expect(request.attributes["success"] == "true")
        #expect(request.attributes["ttft_ms"] == "812.5")
        #expect(request.resource["service.name"] == "claude-code")
        #expect(abs(request.end.timeIntervalSince(request.start) - 4.9) < 0.001)
    }

    @Test func takesBase64IdsSnakeCaseAndNumbers() throws {
        let body = #"""
        {"resource_spans":[{"scope_spans":[{"spans":[{"trace_id":"W47/95gDgQPSabYzgT/GDA==","span_id":"7uGbfsPBsXQ=",
        "name":"x","start_time_unix_nano":1763030000000000000,"end_time_unix_nano":1763030001000000000,
        "status":{"code":2,"message":"boom"}}]}]}]}
        """#
        let span = try #require(OTLPJSON.decode(Data(body.utf8)).spans.first)
        #expect(span.traceID == "5b8efff798038103d269b633813fc60c")
        #expect(span.spanID == "eee19b7ec3c1b174")
        #expect(span.failed)
        #expect(span.statusMessage == "boom")
    }

    @Test func refusesWhatIsNotOTLP() {
        #expect(throws: OTLPError.notJSON) { try OTLPJSON.decode(Data("nope".utf8)) }
        #expect(throws: OTLPError.unknownSignal) { try OTLPJSON.decode(Data(#"{"x":1}"#.utf8)) }
        // An empty export to a signal's path is fine.
        #expect(throws: Never.self) { try OTLPJSON.decode(Data("{}".utf8), signal: .logs) }
    }

    @Test func signalsByPath() {
        #expect(OTLPSignal(path: "/v1/traces") == .traces)
        #expect(OTLPSignal(path: "/v1/logs?x=1") == .logs)
        #expect(OTLPSignal(path: "/metrics") == .metrics)
        #expect(OTLPSignal(path: "/") == nil)
    }

    // MARK: Reading

    @Test func claudeEventsGetTheirNamespace() throws {
        let records = try Self.records("claude-logs")
        #expect(records.prompts.count == 1)
        #expect(records.prompts[0].id == "p-1")
        // Redacted prompts are not text.
        #expect(records.prompts[0].text == nil)
        let model = try #require(records.spans.first { $0.kind == .model })
        #expect(model.cost == 0.0231)
        #expect(model.tokens == TokenCounts(input: 1200, output: 340, cacheRead: 28000))
        #expect(model.fromEvent)
        let tool = try #require(records.spans.first { $0.kind == .tool })
        #expect(tool.name == "bash")
        #expect(abs(tool.duration - 40.2) < 0.001)
        #expect(tool.traceID == "p-1")
    }

    @Test func aSpanAndItsEventCountOnceWithTheEventsCost() throws {
        let records = try Self.records("claude-traces", "claude-logs")
        let context = TelemetryContext.from(sessions: [Self.session])
        let spans = TelemetryResolve.spans(records, context: context)
        let models = spans.filter { $0.kind == .model }
        #expect(models.count == 1)
        #expect(models.first?.cost == 0.0231)
        #expect(models.first?.fromEvent == false)
        // The tool wrapper gives way to the wait for your OK and the run, which takes its name and command.
        let tools = spans.filter { $0.kind == .tool }
        #expect(tools.count == 1)
        #expect(tools.first?.detail == "dotnet test tests/Redirects")
        #expect(tools.first?.name == "bash")
        #expect(abs((tools.first?.duration ?? 0) - 40.2) < 0.01)
        let wait = try #require(spans.first { $0.kind == .permission })
        #expect(wait.detail == "dotnet test tests/Redirects")
        #expect(abs(wait.duration - 30.2) < 0.01)
        // Everything is under the turn, in heed's session.
        let turn = try #require(spans.first { $0.kind == .turn })
        #expect(turn.detail == "turn 2")
        #expect(spans.allSatisfy { $0.heedSession == "s1" })
        #expect(spans.filter { $0.kind != .turn }.allSatisfy { $0.parentID == turn.id })
    }

    @Test func codexEventsBecomeTurnsByTheirPrompts() throws {
        let records = try Self.records("codex-logs")
        let spans = TelemetryResolve.spans(records, context: TelemetryContext.from(sessions: [Self.codex]))
        let tool = try #require(spans.first { $0.kind == .tool })
        #expect(tool.agent == "codex")
        #expect(tool.name == "bash")
        #expect(tool.detail == "go test")
        #expect(tool.status == .error)
        #expect(tool.heedSession == "s3")
        let model = try #require(spans.first { $0.kind == .model })
        // Codex counts cached tokens inside its input.
        #expect(model.tokens == TokenCounts(input: 4000, output: 800, cacheRead: 8000))
        let turn = try #require(spans.first { $0.kind == .turn })
        #expect(tool.traceID == turn.traceID)
        #expect(model.traceID == turn.traceID)
        #expect(turn.start <= model.start)
    }

    @Test func metricsAreUsageOnlyForWhatHasNoRequests() throws {
        let records = try Self.records("claude-metrics")
        #expect(records.usage.count == 3)
        #expect(records.usage.contains { $0.cost == 0.042 && $0.model == "claude-sonnet-4-5" })
        #expect(records.usage.contains { $0.tokens.cacheRead == 9000 })
        let session = Session(
            id: "s9", title: "t", repos: [], branch: "", agent: "claude", state: ObservedState(.working)
        )
        let costs = TelemetryResolve.costs(records, context: .from(sessions: [session]))
        #expect(costs["s9"] == 0.042)
        // A session's requests win over its metric.
        let both = try Self.records("claude-logs") + records
        let costs2 = TelemetryResolve.costs(both, context: .from(sessions: [session, Self.session]))
        #expect(costs2["s1"] == 0.0231)
    }

    @Test func cumulativeSeriesCountTheirLatestTotal() {
        let start = Date(timeIntervalSince1970: 1000)
        let samples = [
            AgentUsageSample(agent: "codex", agentSession: "c", at: start, cost: 0.1, cumulative: true),
            AgentUsageSample(agent: "codex", agentSession: "c", at: start + 60, cost: 0.3, cumulative: true),
            AgentUsageSample(agent: "claude", agentSession: "d", at: start, cost: 0.2),
            AgentUsageSample(agent: "claude", agentSession: "d", at: start + 60, cost: 0.2),
        ]
        let total = AgentUsageSample.summable(samples).compactMap(\.cost).reduce(0, +)
        #expect(abs(total - 0.7) < 1e-9)
    }

    @Test func toolGroups() {
        #expect(TelemetryReader.toolGroup("Bash") == "bash")
        #expect(TelemetryReader.toolGroup("MultiEdit") == "edit")
        #expect(TelemetryReader.toolGroup("Grep") == "read/grep")
        #expect(TelemetryReader.toolGroup("mcp__heed__memory_search") == "mcp heed")
        #expect(TelemetryReader.toolGroup("apply_patch") == "edit")
        #expect(TelemetryReader.toolGroup("Skill") == "skill")
    }

    // MARK: The board

    static let now = Date(timeIntervalSince1970: 1_763_030_100)

    static func span(
        _ kind: SpanKind, _ name: String, _ detail: String = "", at offset: TimeInterval, _ seconds: TimeInterval,
        session: String = "7f3a9c1e-52b4-4e0d-9a61-0c8d3e1f2b77", agent: String = "claude", failed: Bool = false,
        cost: Double? = nil, model: String? = nil, trace: String = "t1"
    ) -> AgentSpan {
        let start = now.addingTimeInterval(offset)
        return AgentSpan(
            id: UUID().uuidString, traceID: trace, agent: agent, agentSession: session, kind: kind, name: name,
            detail: detail, model: model, start: start, end: start.addingTimeInterval(seconds),
            status: failed ? .error : .ok, cost: cost
        )
    }

    @Test func percentiles() {
        let values = (1 ... 20).map(Double.init)
        #expect(TelemetryBoard.percentile(values, 50) == 10)
        #expect(TelemetryBoard.percentile(values, 95) == 19)
        #expect(TelemetryBoard.percentile([], 95) == 0)
        #expect(TelemetryBoard.percentile([4], 95) == 4)
    }

    @Test func boardSumsLatencyErrorsWaitsAndCost() {
        let records = TelemetryRecords(spans: [
            Self.span(.turn, "turn", "fix", at: -600, 100),
            Self.span(.model, "model", at: -600, 5, cost: 0.5, model: "claude-opus-4-5"),
            Self.span(.tool, "bash", "dotnet test", at: -590, 40),
            Self.span(.tool, "bash", "dotnet test", at: -500, 20, failed: true),
            Self.span(.tool, "edit", "a.swift", at: -480, 0.1),
            Self.span(.permission, "permission", "dotnet test", at: -540, 30),
            // Outside the hour.
            Self.span(.tool, "bash", "old", at: -7200, 500),
        ])
        let board = TelemetryBoard.build(
            records: records, context: .from(sessions: [Self.session]), filter: TelemetryFilter(), now: Self.now
        )
        let bash = board.latency.first { $0.tool == "bash" }
        #expect(bash?.count == 2)
        #expect(bash?.p50 == 20)
        #expect(bash?.p95 == 40)
        #expect(board.latency.first?.tool == "bash")
        #expect(board.latency.last?.tool == "model")
        #expect(board.tiles.first { $0.id == "errors" }?.value == "33.3%")
        #expect(board.tiles.first { $0.id == "blocked" }?.value == "30 s")
        #expect(board.tiles.first { $0.id == "cost" }?.value == AgentUsage.dollars(0.5))
        #expect(board.models.first?.model == "claude-opus-4-5")
        #expect(board.rows.allSatisfy { $0.span.start >= Self.now.addingTimeInterval(-3600) })
        #expect(board.rows.first?.title == "Fix broken anchors")
        #expect(board.rows.first?.repo == "docs-toolkit")
        #expect(board.states.first?.states.contains(.blocked) == true)
        #expect(board.states.first?.states.contains(.error) == true)
        #expect(board.noticed.contains { $0.contains("dotnet test") })
    }

    @Test func filtersAndTheSpanQuery() {
        let records = TelemetryRecords(spans: [
            Self.span(.tool, "bash", "cargo test", at: -60, 12, failed: true),
            Self.span(.tool, "bash", "cargo clippy", at: -50, 5),
            Self.span(.tool, "edit", "lib.rs", at: -40, 1),
            Self.span(
                .tool,
                "bash",
                "go test",
                at: -30,
                3,
                session: "91be40d2-7a35-4c68-b2f9-13e5a8d07c46",
                agent: "codex"
            ),
        ])
        let context = TelemetryContext.from(sessions: [Self.session, Self.codex])
        func rows(_ filter: TelemetryFilter) -> [String] {
            TelemetryBoard.build(records: records, context: context, filter: filter, now: Self.now).rows
                .map(\.span.detail)
        }
        #expect(rows(TelemetryFilter(query: "tool:bash status:error")) == ["cargo test"])
        #expect(rows(TelemetryFilter(query: "clippy")) == ["cargo clippy"])
        #expect(rows(TelemetryFilter(agent: "codex")) == ["go test"])
        #expect(rows(TelemetryFilter(repo: "docs-toolkit", kinds: [.tool])).count == 3)
        #expect(rows(TelemetryFilter(query: "repo:ingest")) == ["go test"])
        #expect(rows(TelemetryFilter(kinds: [.tool], query: "over:4s")) == ["cargo clippy", "cargo test"])
        #expect(rows(TelemetryFilter(kinds: [.permission])).isEmpty)
    }

    @Test func aWaitGoingOnNowIsOnTop() {
        var blocked = Self.session
        blocked.state = ObservedState(.blocked, reason: "Bash(dotnet publish)")
        blocked.lastActivity = Self.now.addingTimeInterval(-121)
        let board = TelemetryBoard.build(
            records: TelemetryRecords(spans: [Self.span(.tool, "edit", "a", at: -300, 1)]),
            context: .from(sessions: [blocked]), filter: TelemetryFilter(), now: Self.now
        )
        #expect(board.rows.first?.span.status == .waiting)
        #expect(board.rows.first?.span.detail == "dotnet publish")
        #expect(board.rows.first.map { TelemetryWords.duration($0.wall) } == "2 m 01 s")
        #expect(board.tiles.first { $0.id == "blocked" }?.value == "2 m 01 s")
    }

    @Test func aTraceIsAWaterfall() {
        let turn = Self.span(.turn, "turn", "tests", at: -100, 80)
        var model = Self.span(.model, "model", at: -100, 5)
        model.parentID = turn.id
        var bash = Self.span(.tool, "bash", "dotnet test", at: -60, 40)
        bash.parentID = turn.id
        let board = TelemetryBoard.build(
            records: TelemetryRecords(spans: [bash, model, turn]), context: .from(sessions: [Self.session]),
            filter: TelemetryFilter(), now: Self.now
        )
        let bars = board.trace(of: bash)
        #expect(bars.map(\.span.kind) == [.turn, .model, .tool])
        #expect(bars.map(\.depth) == [0, 1, 1])
        #expect(bars.last?.offset == 40)
    }

    // MARK: A session's trace

    @Test func sessionTraceLaysTurnsEndToEnd() {
        let records = Fixtures.telemetry(now: Self.now)
        let context = TelemetryContext.from(sessions: Fixtures.main.sessions)
        let trace = SessionTrace.build(session: "s1", records: records, context: context)
        #expect(trace.turns.map(\.title) == [
            "turn 3 · ‘fix the lint error’", "turn 4 · ‘tests’", "turn 5 · ‘review comments’",
        ])
        #expect(trace.turns[1].offset == trace.turns[0].span.duration)
        #expect(abs(trace.waited - 30.2) < 0.01)
        #expect(trace.bash > 60)
        #expect(trace.cost ?? 0 > 0)
        #expect(trace.turns[1].segments.map(\.lane) == ["model", "waiting", "bash", "model"])
        let described = trace.describe(turn: 1, index: 2)
        #expect(described?.head.hasPrefix("dotnet test tests/Redirects · 40.2 s · ok") == true)
        #expect(described?.detail == "Waited 30.2 s for your OK first.")
        #expect(trace.noticed.first?.contains("of this session's tool time") == true)
    }

    @Test func fixtureBoardLooksLikeAnHour() {
        let board = TelemetryBoard.build(
            records: Fixtures.telemetry(now: Self.now), context: .from(sessions: Fixtures.main.sessions),
            filter: TelemetryFilter(), now: Self.now
        )
        #expect(board.agents == ["claude", "codex"])
        #expect(board.latency.map(\.tool).contains("bash"))
        #expect(board.models.count >= 2)
        #expect(board.rows.count > 20)
        #expect(board.rows.first?.span.status == .waiting)
        #expect(board.states.count == 2)
    }

    // MARK: Pointing the agents at heed

    @Test func exportsOnlyWhenYouSetNothingYourself() {
        var settings = TelemetrySettings()
        settings.port = 4999
        let plain = TelemetryExport.decide(
            settings: settings, process: [:], shell: [:], claudeSettings: nil, codexConfig: "model = \"x\"\n"
        )
        #expect(plain.exports("claude"))
        #expect(plain.exports("codex"))
        #expect(!plain.exports("opencode"))
        let env = plain.environment(agent: "claude")
        #expect(env["OTEL_EXPORTER_OTLP_ENDPOINT"] == "http://127.0.0.1:4999")
        #expect(env["OTEL_EXPORTER_OTLP_PROTOCOL"] == "http/json")
        #expect(env["CLAUDE_CODE_ENABLE_TELEMETRY"] == "1")
        #expect(env["OTEL_LOG_USER_PROMPTS"] == nil)
        #expect(plain.environment(agent: "codex").isEmpty)
        let args = plain.arguments(agent: "codex")
        #expect(args.contains(#"otel.exporter={otlp-http={endpoint="http://127.0.0.1:4999/v1/logs",protocol="json"}}"#))
        #expect(plain.arguments(agent: "claude").isEmpty)

        let shell = TelemetryExport.decide(
            settings: settings, process: [:], shell: ["OTEL_EXPORTER_OTLP_ENDPOINT": "https://collector.example"],
            claudeSettings: nil, codexConfig: nil
        )
        #expect(!shell.exports("claude"))
        #expect(shell.environment(agent: "claude").isEmpty)
        #expect(shell.summary(agent: "claude") == "left alone: OTEL_EXPORTER_OTLP_ENDPOINT is set in your shell")
        #expect(shell.exports("codex"))

        let files = TelemetryExport.decide(
            settings: settings, process: [:], shell: [:],
            claudeSettings: #"{"env":{"CLAUDE_CODE_ENABLE_TELEMETRY":"1"}}"#,
            codexConfig: "[otel]\nexporter = { otlp-grpc = { endpoint = \"http://x:4317\" } }\n"
        )
        #expect(!files.exports("claude"))
        #expect(!files.exports("codex"))
        #expect(files.leftAlone["codex"] == "otel.exporter is set in ~/.codex/config.toml")
        // An [otel] table without an exporter sends nothing; heed may.
        let quiet = TelemetryExport.decide(
            settings: settings, process: [:], shell: [:], claudeSettings: nil,
            codexConfig: "[otel]\nenvironment = \"x\"\n"
        )
        #expect(quiet.exports("codex"))
    }

    @Test func theAgentsCommandLinesCarryIt() {
        var files = IntegrationFiles(directory: URL(fileURLWithPath: "/tmp/heed"))
        let claude = AgentProfile.builtIn.first { $0.name == "claude" }!
        #expect(AgentIntegration.launchEnvironment(agent: claude, files: files)["CLAUDE_CODE_ENABLE_TELEMETRY"] == nil)
        files.telemetry = TelemetryExport(port: 4318)
        let env = AgentIntegration.launchEnvironment(agent: claude, files: files)
        #expect(env["OTEL_EXPORTER_OTLP_ENDPOINT"] == "http://127.0.0.1:4318")
        let codex = AgentProfile.builtIn.first { $0.name == "codex" }!
        let args = AgentIntegration.launchArguments(agent: codex, sessionID: "s", files: files)
        #expect(args.contains { $0.hasPrefix("otel.trace_exporter=") })
    }

    // MARK: Store

    @Test func storeKeepsPrunesAndReads() async throws {
        let store = try TelemetryStore()
        let old = Self.span(.tool, "bash", "old", at: -10 * 86400, 1)
        let fresh = Self.span(.tool, "bash", "fresh", at: -60, 1)
        await store.insert(TelemetryRecords(
            spans: [old, fresh], prompts: [AgentPrompt(agent: "claude", at: Self.now)],
            usage: [AgentUsageSample(agent: "claude", at: Self.now, cost: 1)]
        ))
        #expect(try await store.count() == 2)
        let removed = await store.prune(now: Self.now, settings: TelemetrySettings())
        #expect(removed == 1)
        let read = try await store.records(since: Self.now.addingTimeInterval(-3600))
        #expect(read.spans.map(\.detail) == ["fresh"])
        #expect(read.spans.first == fresh)
        #expect(read.prompts.count == 1)
        #expect(read.usage.first?.cost == 1)
        var few = TelemetrySettings()
        few.maxRows = 1
        await store.insert(TelemetryRecords(spans: [Self.span(.tool, "bash", "newer", at: -1, 1)]))
        await store.prune(now: Self.now, settings: few)
        #expect(try await store.records(since: .distantPast).spans.map(\.detail) == ["newer"])
    }

    // MARK: HTTP

    @Test func readsRequestsByLengthAndChunked() throws {
        var reader = HTTPRequestReader()
        let body = #"{"resourceLogs":[]}"#
        let first = "POST /v1/logs HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n" + body
        let half = first.utf8.count / 2
        #expect(try reader.feed(Data(first.utf8.prefix(half))).isEmpty)
        var requests = try reader.feed(Data(first.utf8.dropFirst(half)))
        #expect(requests.count == 1)
        #expect(requests[0].path == "/v1/logs")
        #expect(String(decoding: requests[0].body, as: UTF8.self) == body)
        let chunked = "POST /v1/traces HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"re\r\n3\r\nx\":\r\n2\r\n1}\r\n0\r\n\r\n"
            + "GET / HTTP/1.1\r\n\r\n"
        requests = try reader.feed(Data(chunked.utf8))
        #expect(requests.map(\.method) == ["POST", "GET"])
        #expect(String(decoding: requests[0].body, as: UTF8.self) == #"{"rex":1}"#)
        var small = HTTPRequestReader(maxBody: 4)
        #expect(throws: HTTPRequestReader.Failure.tooLarge) {
            try small.feed(Data("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\n".utf8))
        }
    }

    @Test func answersJSONRefusesProtobufAndInflatesGzip() throws {
        let logs = try Self.payload("claude-logs")
        let ok = OTLPHTTP.handle(HTTPRequest(
            method: "POST", path: "/v1/logs", headers: ["content-type": "application/json"], body: logs
        ))
        #expect(ok.status == 200)
        #expect(ok.records?.spans.count == 2)
        let proto = OTLPHTTP.handle(HTTPRequest(
            method: "POST", path: "/v1/logs", headers: ["content-type": "application/x-protobuf"], body: Data([1])
        ))
        #expect(proto.status == 415)
        // `{"resourceLogs":[]}`, gzipped.
        let gzip = Data(base64Encoded: "H4sIAAAAAAAAA6tWKkotzi8tSk71yU8vVrKKjq0FAHCOHGgTAAAA")!
        let inflated = OTLPHTTP.handle(HTTPRequest(
            method: "POST", path: "/v1/logs",
            headers: ["content-type": "application/json", "content-encoding": "gzip"], body: gzip
        ))
        #expect(inflated.status == 200)
    }

    @Test func serverTakesAnExportOnLoopback() async throws {
        let port = Int.random(in: 40000 ... 60000)
        let live = TelemetryServer(port: port)
        try live.start()
        defer { live.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/logs")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.payload("claude-logs")
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        var iterator = live.records.makeAsyncIterator()
        let records = await iterator.next()
        #expect(records?.prompts.count == 1)
    }
}
