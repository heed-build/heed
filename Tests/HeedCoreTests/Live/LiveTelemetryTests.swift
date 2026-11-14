import Foundation
@testable import HeedCore
import Testing

/// OpenTelemetry end to end: heed's receiver on a free port, and one real Claude Code prompt started with the
/// environment heed's launch code builds for it. What arrives is read into heed's spans, prompts and usage, and tied
/// to the heed session by Claude Code's own session id.
@Suite(.enabled(if: Live.enabled, "live: HEED_LIVE=1 calls a model"), .serialized)
struct LiveTelemetryTests {
    @Test(.timeLimit(.minutes(5))) func claudeExportsATurnHeedReads() async throws {
        let folder = try Live.scratch("otel")
        defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try await Live.repo(in: folder, files: ["README.md": "a scratch repo\n"])
        let session = UUID().uuidString.lowercased()

        let port = Live.freePort()
        let server = TelemetryServer(port: port)
        let raw = LiveLog<HTTPRequest>()
        server.tap = { raw.append($0) }
        try server.start()
        defer { server.stop() }
        let records = LiveLog<TelemetryRecords>()
        let reader = Task { for await batch in server.records {
            records.append(batch)
        } }
        defer { reader.cancel() }

        // What the app decides for claude with no telemetry of yours set up: export to heed.
        var settings = TelemetrySettings()
        settings.port = port
        let environment = Live.cleanEnvironment()
        let export = TelemetryExport.decide(
            settings: settings, process: environment, shell: [:], claudeSettings: nil, codexConfig: nil
        )
        #expect(export.mode("claude") == .heed)
        var files = try IntegrationFiles(
            directory: folder.appendingPathComponent("support"),
            heedBinary: Live.heedBinary()
        )
        files.telemetry = export
        try files.write()

        let result = try await Live.claude(
            prompt: "Reply with the single word: ok", repo: repo, session: session, files: files,
            environment: environment
        )
        #expect(result.succeeded, "claude -p ended: \(result.stderr)")
        // Exports flush as it exits; give the last ones a moment.
        _ = await Live.eventually(15) {
            let all = records.all.reduce(TelemetryRecords(), +)
            return all.spans.contains { $0.kind == .turn } && !all.usage.isEmpty
        }
        for (index, request) in raw.all.enumerated() {
            Live.keep(
                "otlp-\(index)-\(request.path.split(separator: "/").last ?? "x").json",
                String(decoding: request.body, as: UTF8.self)
            )
        }

        let paths = Set(raw.all.map(\.path))
        #expect(paths.contains("/v1/traces"), "traces arrived: \(paths)")
        #expect(paths.contains("/v1/logs"), "logs arrived: \(paths)")
        #expect(paths.contains("/v1/metrics"), "metrics arrived: \(paths)")
        #expect(raw.all.allSatisfy { ($0.headers["content-type"] ?? "").contains("json") }, "http/json, as asked")

        let all = records.all.reduce(TelemetryRecords(), +)
        Live.keep(
            "otlp-records.txt",
            "\(all.spans.map { "\($0.kind) \($0.name) \($0.detail) \($0.agentSession ?? "-") tokens=\(String(describing: $0.tokens)) cost=\(String(describing: $0.cost))" }.joined(separator: "\n"))\n\nprompts: \(all.prompts)\n\nusage: \(all.usage)"
        )
        #expect(all.spans.allSatisfy { $0.agent == "claude" })
        #expect(all.spans.contains { $0.kind == .turn }, "a turn")
        let model = all.spans.filter { $0.kind == .model }
        #expect(!model.isEmpty, "a model request")
        #expect(model.contains { ($0.model ?? "").contains("haiku") })
        #expect(model.contains { ($0.tokens?.output ?? 0) > 0 }, "tokens on a model request")
        #expect(model.contains { ($0.cost ?? 0) > 0 }, "the cost of a request")
        #expect(all.prompts.contains { $0.agentSession == session }, "the prompt, under the session")
        #expect(all.usage.contains { $0.cost != nil }, "cost metric")
        #expect(all.usage.contains { $0.tokens.output > 0 }, "token metric")

        // Every span and sample is claude's own session, which is heed's: resolved to it.
        #expect(all.spans.allSatisfy { $0.agentSession == session }, "\(all.spans.map(\.agentSession))")
        #expect(all.usage.allSatisfy { $0.agentSession == session })
        let context = TelemetryContext(
            sessions: [session: .init(title: "live", repo: "live", agent: "claude")], byAgentSession: [session: session]
        )
        let resolved = TelemetryResolve.spans(all, context: context)
        #expect(!resolved.isEmpty)
        #expect(resolved.allSatisfy { $0.heedSession == session })
        // A span and an event about the same request count once.
        let keys = resolved.filter { $0.kind == .model }.compactMap(\.key)
        #expect(keys.count == Set(keys).count, "one model request per key: \(keys)")
    }
}
