import Foundation
@testable import HeedCore
import Synchronization
import Testing

/// heed between an agent and your own collector: who it stands in front of, what it changes on the agent's command
/// line, how it passes each export on (byte for byte, with your headers, which it never keeps), and what it reads of
/// OTLP protobuf (samples encoded by the official Go protos, Fixtures/otlp/*.pb).
struct TelemetryProxyTests {
    static let settings: TelemetrySettings = {
        var settings = TelemetrySettings()
        settings.port = 4999
        return settings
    }()

    static func decide(shell: [String: String] = [:], codex: String? = nil, claude: String? = nil)
        -> TelemetryExport
    {
        TelemetryExport.decide(
            settings: settings,
            process: [:],
            shell: shell,
            claudeSettings: claude,
            codexConfig: codex
        )
    }

    // MARK: Whom heed stands in front of

    @Test func claudeExportingOverHTTPIsForwardedPerSignal() throws {
        let export = Self.decide(shell: [
            "CLAUDE_CODE_ENABLE_TELEMETRY": "1", "OTEL_METRICS_EXPORTER": "otlp", "OTEL_LOGS_EXPORTER": "otlp,console",
            "OTEL_EXPORTER_OTLP_ENDPOINT": "https://otel.example.com/", "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
            "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": "https://logs.example.com/ingest",
            "OTEL_EXPORTER_OTLP_LOGS_PROTOCOL": "http/json",
        ])
        let upstreams = export.upstreams("claude")
        #expect(upstreams[.metrics]?.url.absoluteString == "https://otel.example.com/v1/metrics")
        #expect(upstreams[.metrics]?.wire == .protobuf)
        #expect(upstreams[.logs]?.url.absoluteString == "https://logs.example.com/ingest")
        #expect(upstreams[.logs]?.wire == .json)
        // No traces exporter, and no beta: traces were never sent anywhere, so they go to heed alone.
        #expect(upstreams[.traces] == nil)
        #expect(export.proxying)
        #expect(export.summary(agent: "claude") == "forwarding to logs.example.com, otel.example.com through heed")

        let env = export.environment(agent: "claude")
        #expect(env["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"] == "http://127.0.0.1:4999/forward/claude/v1/metrics")
        #expect(env["OTEL_EXPORTER_OTLP_METRICS_PROTOCOL"] == "http/protobuf")
        #expect(env["OTEL_EXPORTER_OTLP_LOGS_PROTOCOL"] == "http/json")
        #expect(env["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] == "http://127.0.0.1:4999/v1/traces")
        // Nothing else of yours changes: intervals, what is included, your headers (they stay in your environment).
        #expect(env["OTEL_METRIC_EXPORT_INTERVAL"] == nil)
        #expect(env["OTEL_LOG_TOOL_DETAILS"] == nil)
        #expect(env.keys.allSatisfy { !$0.contains("HEADERS") })
        #expect(export.routes["claude"]?[.logs]?.host == "logs.example.com")
    }

    @Test func whatHeedCannotStandInFrontOfIsLeftAlone() {
        let grpc = Self.decide(shell: [
            "CLAUDE_CODE_ENABLE_TELEMETRY": "1", "OTEL_METRICS_EXPORTER": "otlp",
            "OTEL_EXPORTER_OTLP_ENDPOINT": "http://collector:4317",
        ])
        #expect(!grpc.exports("claude"))
        #expect(grpc.leftAlone["claude"] == "it exports over gRPC to collector, which heed does not forward")
        let settingsFile = Self.decide(claude: #"{"env":{"OTEL_EXPORTER_OTLP_ENDPOINT":"https://x"}}"#)
        #expect(!settingsFile.exports("claude"))
        let codexGRPC = Self.decide(codex: "[otel]\nexporter = { otlp-grpc = { endpoint = \"https://c:4317\" } }\n")
        #expect(codexGRPC.leftAlone["codex"] == "otel.exporter exports over gRPC, which heed does not forward")
        // Telemetry that was off is not yours to forward: heed exports to itself only.
        let off = Self.decide(shell: ["OTEL_EXPORTER_OTLP_ENDPOINT": "https://x"])
        #expect(off.mode("claude") == .heed)
        #expect(!off.proxying)
    }

    @Test func codexKeepsItsProtocolAndHeadersOnlyItsEndpointMoves() {
        let export = Self.decide(codex: """
        [otel]
        exporter = { otlp-http = { endpoint = "https://otel.example.com/v1/logs", protocol = "binary", headers = { "x-api-key" = "secret" } } }
        """)
        #expect(export.upstreams("codex")[.logs]?.wire == .protobuf)
        let args = export.arguments(agent: "codex")
        #expect(args.contains(#"otel.exporter.otlp-http.endpoint="http://127.0.0.1:4999/forward/codex/v1/logs""#))
        #expect(args.contains { $0.hasPrefix("otel.trace_exporter={otlp-http=") })
        #expect(!args.joined().contains("secret"))
        #expect(!args.contains { $0.hasPrefix("otel.exporter=") })
    }

    @Test func forwardPaths() {
        #expect(TelemetryExport.forwardPath(agent: "codex", signal: .traces) == "/forward/codex/v1/traces")
        #expect(TelemetryExport.forwardRoute(path: "/forward/codex/v1/traces")! == ("codex", .traces))
        #expect(TelemetryExport.forwardRoute(path: "/v1/traces") == nil)
        #expect(TelemetryExport.forwardRoute(path: "/forward/codex/v1/spans") == nil)
    }

    @Test func theShellProbeNeverReadsHeaders() {
        #expect(TelemetryExport.shellProbe.contains("grep -v '_HEADERS='"))
        let env = TelemetryExport
            .environment(fromProbe: "OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer x\nOTEL_A=1\n")
        #expect(env == ["OTEL_A": "1"])
    }

    // MARK: Passing it on

    /// What a fake collector saw.
    final class Upstream: Sendable {
        let seen = Mutex<[URLRequest]>([])
        let statuses: Mutex<[Int]>

        init(statuses: [Int] = []) { self.statuses = Mutex(statuses) }

        var send: TelemetryForwarder.Send {
            { request in
                self.seen.withLock { $0.append(request) }
                return self.statuses.withLock { $0.isEmpty ? 200 : $0.removeFirst() }
            }
        }
    }

    @Test func aForwardPathIsPassedOnAsItCameEvenUnread() throws {
        let routes: [String: [OTLPSignal: URL]] = ["codex": [.logs: URL(string: "https://otel.example.com/v1/logs")!]]
        let garbage = Data([0xFF, 0x00, 0x13])
        let reply = OTLPHTTP.handle(
            HTTPRequest(
                method: "POST", path: "/forward/codex/v1/logs", headers: ["content-type": "application/x-protobuf"],
                body: garbage
            ),
            routes: routes
        )
        #expect(reply.status == 200)
        #expect(reply.forward?.absoluteString == "https://otel.example.com/v1/logs")
        #expect(reply.records == nil)
        let unknown = OTLPHTTP.handle(
            HTTPRequest(method: "POST", path: "/forward/claude/v1/logs", headers: [:], body: garbage), routes: routes
        )
        #expect(unknown.status == 404)
    }

    @Test func forwardsByteForByteWithYourHeaders() async throws {
        let upstream = Upstream()
        let forwarder = TelemetryForwarder(send: upstream.send)
        let body = try TelemetryTests.payload("claude-traces", "pb")
        let request = HTTPRequest(
            method: "POST", path: "/forward/claude/v1/traces",
            headers: [
                "content-type": "application/x-protobuf", "content-encoding": "gzip", "authorization": "Bearer secret",
                "host": "127.0.0.1:4999", "content-length": "\(body.count)", "connection": "keep-alive",
            ],
            body: body
        )
        forwarder.enqueue(.from(request, to: URL(string: "https://otel.example.com/v1/traces")!))
        await forwarder.flushed()
        let seen = try #require(upstream.seen.withLock { $0.first })
        #expect(seen.url?.absoluteString == "https://otel.example.com/v1/traces")
        #expect(seen.httpMethod == "POST")
        #expect(seen.httpBody == body)
        #expect(seen.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(seen.value(forHTTPHeaderField: "Content-Type") == "application/x-protobuf")
        #expect(seen.value(forHTTPHeaderField: "Content-Encoding") == "gzip")
        #expect(seen.value(forHTTPHeaderField: "Connection") == nil)
        #expect(seen.value(forHTTPHeaderField: "Host") == nil)
        let stats = forwarder.stats()["otel.example.com"]
        #expect(stats?.forwarded == 1)
        #expect(stats?.pending == 0)
        // What is kept to show is counts and a status, never a header.
        #expect(!"\(forwarder.stats())".contains("secret"))
    }

    @Test func retriesWhileTheCollectorIsDownAndCountsRefusals() async {
        let upstream = Upstream(statuses: [503, 0, 200, 400])
        let forwarder = TelemetryForwarder(send: upstream.send, backoff: { _ in .milliseconds(1) })
        let url = URL(string: "https://otel.example.com/v1/logs")!
        forwarder.enqueue(ForwardedRequest(url: url, body: Data("a".utf8), headers: [:]))
        forwarder.enqueue(ForwardedRequest(url: url, body: Data("b".utf8), headers: [:]))
        await forwarder.flushed()
        #expect(upstream.seen.withLock { $0.compactMap(\.httpBody) } == ["a", "a", "a", "b"].map { Data($0.utf8) })
        let stats = forwarder.stats()["otel.example.com"]
        #expect(stats?.forwarded == 1)
        #expect(stats?.refused == 1)
        #expect(stats?.lastError == "HTTP 400")
    }

    @Test func aFullBufferDropsTheOldestAndCountsIt() async {
        let gate = Mutex(false)
        let forwarder = TelemetryForwarder(capacity: 2, send: { _ in
            // The collector is down until the test lets it up.
            gate.withLock { $0 } ? 200 : 503
        }, backoff: { _ in .milliseconds(2) })
        let url = URL(string: "https://otel.example.com/v1/logs")!
        for index in 0 ..< 5 {
            forwarder.enqueue(ForwardedRequest(url: url, body: Data("\(index)".utf8), headers: [:]))
        }
        #expect(forwarder.stats()["otel.example.com"]?.dropped == 3)
        #expect(forwarder.stats()["otel.example.com"]?.pending == 2)
        gate.withLock { $0 = true }
        await forwarder.flushed()
        #expect(forwarder.stats()["otel.example.com"]?.forwarded == 2)
        #expect(forwarder.stats()["otel.example.com"]?.pending == 0)
    }

    @Test func theReceiverPassesForwardsOnOverLoopback() async throws {
        let upstream = Upstream()
        let port = Int.random(in: 40000 ... 60000)
        let server = TelemetryServer(port: port, forwarder: TelemetryForwarder(send: upstream.send))
        try server.start()
        defer { server.stop() }
        server.setRoutes(["claude": [.logs: URL(string: "https://otel.example.com/v1/logs")!]])
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/forward/claude/v1/logs")!)
        request.httpMethod = "POST"
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let body = try TelemetryTests.payload("claude-logs", "pb")
        request.httpBody = body
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "application/x-protobuf")
        var records = server.records.makeAsyncIterator()
        #expect(await records.next()?.spans.first?.cost == 0.0231)
        await server.forwarder.flushed()
        let seen = try #require(upstream.seen.withLock { $0.first })
        #expect(seen.httpBody == body)
        #expect(seen.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    // MARK: Reading protobuf

    @Test func decodesProtobufTracesAsJSONWould() throws {
        let batch = try OTLPProtobuf.decode(TelemetryTests.payload("claude-traces", "pb"), signal: .traces)
        #expect(batch.spans.count == 3)
        let request = try #require(batch.spans.first { $0.name == "claude_code.llm_request" })
        #expect(request.traceID == "5b8efff798038103d269b633813fc60c")
        #expect(request.parentID == "eee19b7ec3c1b174")
        #expect(request.attributes["input_tokens"] == "1200")
        #expect(request.attributes["success"] == "true")
        #expect(request.attributes["ttft_ms"] == "812.5")
        #expect(request.resource["service.name"] == "claude-code")
        #expect(abs(request.end.timeIntervalSince(request.start) - 4.9) < 0.001)
        let tool = try #require(batch.spans.first { $0.name == "claude_code.tool" })
        #expect(tool.failed)
        #expect(tool.statusMessage == "exit 1")
        #expect(batch.spans.first { $0.name == "claude_code.interaction" }?.parentID == nil)
    }

    @Test func decodesProtobufLogsAndMetrics() throws {
        let logs = try OTLPProtobuf.decode(TelemetryTests.payload("claude-logs", "pb"), signal: .logs)
        #expect(logs.logs.first?.name == "claude_code.api_request")
        #expect(logs.logs.first?.attributes["cost_usd"] == "0.0231")
        let metrics = try OTLPProtobuf.decode(TelemetryTests.payload("codex-metrics", "pb"), signal: .metrics)
        let cost = try #require(metrics.points.first { $0.name == "codex.turn.cost_microusd" })
        #expect(cost.value == 42000)
        #expect(cost.cumulative)
        #expect(cost.attributes["model"] == "gpt-5.1-codex")
        #expect(metrics.points.first { $0.name == "claude_code.cost.usage" }?.value == 0.5)
        #expect(metrics.points.first { $0.name == "codex.tool.call.duration_ms" }?.value == 1500)
        #expect(throws: OTLPError.notProtobuf) { try OTLPProtobuf.decode(Data([0x0A, 0x7F, 1]), signal: .logs) }
    }
}
