import Foundation

/// The fake world's OpenTelemetry: an hour of the main fixture's sessions as their agents would export it. Claude
/// sessions send traces (turns, model requests, tool calls, waits for your OK); the codex session sends events only,
/// which heed turns into spans by its prompts. Fix broken anchors (`s1`) has the three turns the trace view shows.
public extension Fixtures {
    static func telemetry(now: Date = Clock.now) -> TelemetryRecords {
        var world = TelemetryWorld(now: now)
        world.anchors()
        world.busy(
            session: "s2",
            own: "2c81d6aa-9e17-4b3f-8d05-6a4e7b9c0d12",
            seed: 7,
            model: "claude-opus-4-5",
            commands: ["dotnet test", "dotnet build", "dotnet publish"],
            turns: 9
        )
        world.busy(
            session: "s4",
            own: "e0457f3b-18c2-4d9a-a6b1-5f2d9c8e3a04",
            seed: 11,
            model: "claude-sonnet-4-5",
            commands: ["cargo test", "cargo clippy", "cargo test"],
            turns: 11,
            failing: "cargo test"
        )
        world.busy(
            session: "s5",
            own: "s5",
            seed: 3,
            model: "claude-sonnet-4-5",
            commands: ["npm test", "npm run fixtures"],
            turns: 5,
            endingAgo: 50 * 60
        )
        world.codex()
        return world.records
    }
}

/// Builds the fixture's records, deterministically.
struct TelemetryWorld {
    let now: Date
    var records = TelemetryRecords()
    private var seed: UInt64 = 42
    private var counter = 0

    init(now: Date) { self.now = now }

    private mutating func random() -> Double {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(seed >> 33) / Double(1 << 31)
    }

    private mutating func id(_ prefix: String) -> String {
        counter += 1
        return String(format: "%@%012x", prefix, counter * 2_654_435_761 % 0xFFFF_FFFF_FFFF)
    }

    private mutating func span(
        _ kind: SpanKind, _ name: String, _ detail: String, trace: String, parent: String?, agent: String = "claude",
        own: String, start: Date, seconds: TimeInterval, model: String? = nil, failed: Bool = false
    ) -> AgentSpan {
        var span = AgentSpan(
            id: id("5a"), traceID: trace, parentID: parent, agent: agent, agentSession: own, kind: kind, name: name,
            detail: detail, model: model, start: start, end: start.addingTimeInterval(seconds),
            status: failed ? .error : .ok, error: failed ? "exit 101" : nil
        )
        if kind == .model {
            let input = 600 + Int(random() * 3000)
            let cached = 9000 + Int(random() * 30000)
            let output = 200 + Int(random() * 1600)
            span.tokens = TokenCounts(input: input, output: output, cacheRead: cached, cacheWrite: Int(random() * 800))
            let opus = (model ?? "").contains("opus")
            let price = opus ? (input: 5.0, output: 25.0) : (input: 3.0, output: 15.0)
            span.cost = (Double(input) * price.input + Double(output) * price.output
                + Double(cached) * price.input * 0.1) / 1_000_000
        }
        records.spans.append(span)
        return span
    }

    /// One turn: its span, then `steps` (kind, name, detail, seconds, failed) end to end, a model request first.
    @discardableResult
    private mutating func turn(
        own: String, prompt: String, at start: Date, model: String,
        steps: [(SpanKind, String, String, TimeInterval, Bool)]
    ) -> Date {
        let trace = id("7e") + id("")
        let turnID = id("1b")
        var clock = start
        for step in steps {
            let gap = 0.2 + random() * 0.6
            _ = span(
                step.0, step.1, step.2, trace: trace, parent: turnID, own: own, start: clock, seconds: step.3,
                model: step.0 == .model ? model : nil, failed: step.4
            )
            clock = clock.addingTimeInterval(step.3 + gap)
        }
        records.spans.append(AgentSpan(
            id: turnID, traceID: trace, agent: "claude", agentSession: own, kind: .turn, name: "turn", detail: prompt,
            start: start, end: clock
        ))
        return clock
    }

    /// Fix broken anchors: the turns trace.png shows, the last ending a few minutes ago, two older before them.
    mutating func anchors() {
        let own = "7f3a9c1e-52b4-4e0d-9a61-0c8d3e1f2b77"
        let model = "claude-opus-4-5"
        var at = now.addingTimeInterval(-41 * 60)
        for prompt in ["read the redirects file", "map the moved pages"] {
            at = turn(own: own, prompt: prompt, at: at, model: model, steps: [
                (.model, "model", model, 6.2, false), (.tool, "read/grep", "redirects.yml", 0.12, false),
                (.model, "model", model, 4.4, false), (.tool, "read/grep", "grep -r anchor", 0.3, false),
                (.model, "model", model, 3.1, false),
            ]).addingTimeInterval(240)
        }
        at = now.addingTimeInterval(-16 * 60)
        at = turn(own: own, prompt: "fix the lint error", at: at, model: model, steps: [
            (.model, "model", model, 7.6, false), (.tool, "read/grep", "Redirects.cs", 3.4, false),
            (.model, "model", model, 6.1, false), (.tool, "edit", "Redirects.cs", 4.8, false),
            (.tool, "bash", "dotnet build", 27.4, false),
        ]).addingTimeInterval(95)
        at = turn(own: own, prompt: "tests", at: at, model: model, steps: [
            (.model, "model", model, 4.9, false), (.permission, "permission", "dotnet test", 30.2, false),
            (.tool, "bash", "dotnet test tests/Redirects", 40.2, false), (.model, "model", model, 5.8, false),
        ]).addingTimeInterval(130)
        _ = turn(own: own, prompt: "review comments", at: at, model: model, steps: [
            (.model, "model", model, 7.8, false), (.tool, "read/grep", "review comments", 3.6, false),
            (.tool, "edit", "Redirects.cs", 4.9, false), (.tool, "edit", "RedirectTests.cs", 4.6, false),
            (.model, "model", model, 4.8, false), (.tool, "mcp heed", "memory.search", 0.18, false),
            (.model, "model", model, 10.9, false),
        ])
    }

    /// A session at work for the last hour (or ending `endingAgo` back): turns of reads, edits and its commands, a
    /// wait for your OK now and then, `failing` failing a few times.
    mutating func busy(
        session _: String, own: String, seed: UInt64, model: String, commands: [String], turns: Int,
        endingAgo: TimeInterval = 0, failing: String? = nil
    ) {
        self.seed = seed
        let end = now.addingTimeInterval(-endingAgo - 30)
        var at = end.addingTimeInterval(-3300)
        let spacing = 3200 / Double(turns)
        let prompts = [
            "update fixtures",
            "fix the failing case",
            "tidy the helper",
            "run the tests",
            "address review",
            "write the docs line",
            "check the edge case",
            "rename the option",
            "one more test",
            "rebase on main",
            "split the function",
        ]
        for index in 0 ..< turns {
            var steps: [(SpanKind, String, String, TimeInterval, Bool)] = [(
                .model,
                "model",
                model,
                2 + random() * 6,
                false
            )]
            for _ in 0 ..< 1 + Int(random() * 3) {
                steps.append((.tool, "read/grep", "src", 0.04 + random() * 0.2, false))
            }
            steps.append((.model, "model", model, 1.5 + random() * 5, false))
            steps.append((.tool, "edit", "src", 0.06 + random() * 0.3, false))
            let command = commands[index % commands.count]
            if random() < 0.35 { steps.append((.permission, "permission", command, 8 + random() * 70, false)) }
            let fails = failing == command && random() < 0.5
            steps.append((.tool, "bash", command, 3 + random() * 30, fails))
            if random() < 0.4 { steps.append((.tool, "mcp heed", "memory.search", 0.1 + random() * 0.4, false)) }
            steps.append((.model, "model", model, 1.5 + random() * 4, false))
            turn(own: own, prompt: prompts[index % prompts.count], at: at, model: model, steps: steps)
            at = at.addingTimeInterval(spacing * (0.7 + random() * 0.6))
            if at > end { break }
        }
    }

    /// Codex in ingest: events only, as Codex sends them by default, and its prompts.
    mutating func codex() {
        seed = 5
        let own = "91be40d2-7a35-4c68-b2f9-13e5a8d07c46"
        var at = now.addingTimeInterval(-52 * 60)
        for index in 0 ..< 7 {
            records.prompts.append(AgentPrompt(agent: "codex", agentSession: own, at: at))
            var clock = at.addingTimeInterval(1)
            let steps: [(SpanKind, String, String, TimeInterval)] = [
                (.model, "model", "gpt-5.1-codex", 3 + random() * 6),
                (.tool, "read/grep", "rg backpressure", 0.2 + random()),
                (.tool, "edit", "apply_patch", 0.3 + random()),
                (.tool, "bash", index % 2 == 0 ? "go test ./stage/..." : "go vet ./...", 4 + random() * 20),
                (.model, "model", "gpt-5.1-codex", 2 + random() * 5),
            ]
            for step in steps {
                var span = AgentSpan(
                    id: id("event:"), agent: "codex", agentSession: own, kind: step.0, name: step.1, detail: step.2,
                    model: step.0 == .model ? step.2 : nil, start: clock, end: clock.addingTimeInterval(step.3),
                    fromEvent: true
                )
                if step.0 == .model {
                    let input = 4000 + Int(random() * 12000)
                    span.tokens = TokenCounts(
                        input: input / 3, output: 300 + Int(random() * 900), cacheRead: input * 2 / 3
                    )
                    span.cost = Double(input) * 1.25 / 3_000_000 + Double(span.tokens?.output ?? 0) * 10 / 1_000_000
                }
                records.spans.append(span)
                clock = clock.addingTimeInterval(step.3 + 0.4)
            }
            at = at.addingTimeInterval(380 + random() * 120)
        }
    }
}
