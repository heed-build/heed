import Foundation
@testable import HeedCore
import Synchronization
import Testing

/// A fake agent CLI: a shell script that answers like claude (`-p`), cursor-agent (`-p`, `status`) or codex (`exec`),
/// as files next to it say. Every call it answers appends the prompt's last line to `calls`.
private struct FakeCLI {
    let folder: URL
    let path: String

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("heed-fake-llm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        path = folder.appendingPathComponent("agent").path
        let script = #"""
        #!/bin/sh
        dir="$(cd "$(dirname "$0")" && pwd)"
        mode="$(cat "$dir/mode" 2>/dev/null || echo ok)"
        case "$1" in
          auth|status|login)
            [ "$(cat "$dir/login" 2>/dev/null || echo in)" = in ] && { echo '{"loggedIn": true}'; exit 0; }
            echo 'Not logged in'; exit 1 ;;
          models) echo "fake-mini - Fake Mini"; exit 0 ;;
          debug) echo '{"models":[{"slug":"big","description":"Frontier","visibility":"list","priority":1},{"slug":"small-fast","description":"Fast and affordable model","visibility":"list","priority":4}]}'; exit 0 ;;
        esac
        input="$(cat)"
        if [ -z "$input" ]; then for last; do :; done; input="$last"; fi
        first="$(printf '%s\n' "$input" | tail -n 1)"
        echo "$first" >> "$dir/calls"
        [ -f "$dir/delay" ] && sleep "$(cat "$dir/delay")"
        case "$mode" in
          fail) echo "boom" >&2; exit 1 ;;
          sleep) sleep 30 ;;
          limit) echo '{"type":"result","is_error":true,"result":"You have hit your session limit · resets 6pm (UTC)"}'; exit 1 ;;
          prose) echo '{"type":"result","is_error":false,"result":"I would rather not","total_cost_usd":0.001}'; exit 0 ;;
        esac
        if [ "$1" = exec ]; then
          echo '{"type":"thread.started"}'
          echo "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"{\\\"answer\\\":\\\"codex\\\"}\"}}"
          echo '{"type":"turn.completed","usage":{"input_tokens":120,"cached_input_tokens":20,"output_tokens":7}}'
          exit 0
        fi
        printf '{"type":"result","is_error":false,"result":"echo %s","structured_output":{"answer":"%s"},"total_cost_usd":0.001,"usage":{"input_tokens":3,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":100},"modelUsage":{"fake-model":{}}}\n' "$first" "$first"
        """#
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    func set(_ name: String, _ value: String?) throws {
        let file = folder.appendingPathComponent(name)
        if let value { try value.write(to: file, atomically: true, encoding: .utf8) } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    var calls: [String] {
        ((try? String(contentsOf: folder.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func agent(_ name: String) -> AgentProfile { AgentProfile(name: name, command: path) }
}

private final class TestClock: Sendable {
    private let value: Mutex<Date>
    init(_ date: Date) { value = Mutex(date) }
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
}

struct LLMRunnerTests {
    private static let start = ISO8601DateFormatter().date(from: "2026-10-22T09:00:00Z")!

    private func utc() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func runner(
        _ agents: [AgentProfile], settings: LLMSettings = LLMSettings(), clock: TestClock = TestClock(start),
        prices: UsagePrices = UsagePrices()
    ) -> LLMRunner {
        LLMRunner(
            agents: agents, settings: settings, prices: prices, resolve: { name in (name, "/usr/bin:/bin") },
            calendar: utc(), now: { clock.now }
        )
    }

    private func log() throws -> CallLog {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("heed-llm-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try CallLog(
            store: CallStore(path: folder.appendingPathComponent("log.sqlite").path),
            delay: .seconds(60)
        )
    }

    private func rows(_ log: CallLog, _ kind: CallKind = .llm) async throws -> [LoggedCall] {
        await log.flush()
        var filter = CallFilter()
        filter.kinds = [kind]
        return try await log.store.calls(filter)
    }

    private func ask(
        _ text: String, schema: Bool = false, priority: LLMRequest.Priority = .background, agent: String? = nil,
        cached: Bool = false
    ) -> LLMRequest {
        LLMRequest(
            call: LLMCall(system: "Be brief.", prompt: text, schema: schema ? #"{"type":"object"}"# : nil),
            priority: priority, caller: "test", operation: "test", agent: agent, cached: cached
        )
    }

    // MARK: Round-robin

    @Test func agentsTakeTurns() async throws {
        let fakes = try [FakeCLI(), FakeCLI(), FakeCLI()]
        let runner = runner([fakes[0].agent("claude"), fakes[1].agent("cursor"), fakes[2].agent("codex")])
        var picked: [String] = []
        for index in 0 ..< 4 {
            try await picked.append(runner.run(ask("q\(index)")).agent)
        }
        #expect(picked == ["claude", "cursor", "codex", "claude"])
        #expect(fakes[0].calls == ["q0", "q3"] && fakes[1].calls == ["q1"])
    }

    @Test func anAgentTurnedOffIsNeverPicked() async throws {
        let fakes = try [FakeCLI(), FakeCLI()]
        var settings = LLMSettings()
        settings.agents["claude"] = LLMSettings.Agent(enabled: false)
        let runner = runner([fakes[0].agent("claude"), fakes[1].agent("cursor")], settings: settings)
        let log = try log()
        for index in 0 ..< 3 {
            let response = try await CallLog.$current.withValue(log) { try await runner.run(ask("q\(index)")) }
            #expect(response.agent == "cursor")
        }
        #expect(fakes[0].calls.isEmpty)
        #expect(try await rows(log).allSatisfy { $0.detail["skipped"] == "claude: off" })
    }

    @Test func customAgentsTakeNoPart() async throws {
        let fake = try FakeCLI()
        let runner = runner([fake.agent("mytool")])
        await #expect(throws: LLMError.noAgent(reasons: ["no agent heed can call is configured"])) {
            try await runner.run(ask("q"))
        }
    }

    @Test func anAgentNotLoggedInIsSkipped() async throws {
        let fakes = try [FakeCLI(), FakeCLI()]
        try fakes[0].set("login", "out")
        let runner = runner([fakes[0].agent("claude"), fakes[1].agent("cursor")])
        let log = try log()
        let response = try await CallLog.$current.withValue(log) { try await runner.run(ask("q")) }
        #expect(response.agent == "cursor")
        #expect(try await rows(log).first?.detail["skipped"] == "claude: not logged in")
        let statuses = await runner.statuses()
        #expect(statuses.map(\.login) == [.loggedOut, .loggedIn])
        #expect(statuses.first?.detectedModel == "haiku")
    }

    @Test func aMissingCommandIsReported() async throws {
        let runner = LLMRunner(
            agents: [AgentProfile(name: "claude", command: "claude")], resolve: { _ in (nil, "") },
            now: { Self.start }
        )
        await #expect(throws: LLMError.noAgent(reasons: ["claude: claude not found"])) {
            try await runner.run(ask("q"))
        }
    }

    // MARK: Rate limits and back-off

    @Test func aRateLimitedAgentIsSkippedUntilItResets() async throws {
        let fakes = try [FakeCLI(), FakeCLI()]
        let clock = TestClock(Self.start)
        let runner = runner([fakes[0].agent("claude"), fakes[1].agent("cursor")], clock: clock)
        await runner.setLimited(["claude": Self.start.addingTimeInterval(600)])
        let log = try log()
        let first = try await CallLog.$current.withValue(log) { try await runner.run(ask("a")) }
        #expect(first.agent == "cursor")
        #expect(try await rows(log).first?.detail["skipped"]?.hasPrefix("claude: rate limited until") == true)
        clock.advance(601)
        #expect(try await runner.run(ask("b")).agent == "claude")
        // Limited with no known reset: skipped until the session says otherwise.
        await runner.setLimited(["claude": Date?.none])
        #expect(try await runner.run(ask("c")).agent == "cursor")
        #expect(try await runner.run(ask("d")).agent == "cursor")
        await runner.setLimited([:])
        #expect(try await runner.run(ask("e")).agent == "claude")
    }

    @Test func sessionsSayWhichAgentsAreLimited() {
        func session(_ id: String, _ agent: String, _ state: AgentState, resets: Date?) -> Session {
            var session = Session(
                id: id, title: id, repos: [], branch: id, agent: agent, state: ObservedState(state)
            )
            session.usage = AgentUsage(rateLimitResetsAt: resets)
            return session
        }
        let soon = Self.start.addingTimeInterval(600)
        let later = Self.start.addingTimeInterval(3600)
        let limits = LLMRunner.limits(of: [
            session("a", "claude", .limited, resets: soon), session("b", "claude", .limited, resets: later),
            session("c", "codex", .limited, resets: later), session("d", "codex", .limited, resets: nil),
            session("e", "pi", .working, resets: later), session("f", "gemini", .limited, resets: nil),
        ])
        #expect(limits.count == 3)
        #expect(limits["claude"] == .some(later))
        #expect(limits["codex"] == .some(nil) && limits["gemini"] == .some(nil) && limits["pi"] == nil)
    }

    @Test func aFailedAgentBacksOffAndTheCallMovesOn() async throws {
        let fakes = try [FakeCLI(), FakeCLI()]
        try fakes[0].set("mode", "fail")
        let clock = TestClock(Self.start)
        var settings = LLMSettings()
        settings.backoffMinutes = 10
        let runner = runner([fakes[0].agent("claude"), fakes[1].agent("cursor")], settings: settings, clock: clock)
        let log = try log()
        let response = try await CallLog.$current.withValue(log) { try await runner.run(ask("a")) }
        #expect(response.agent == "cursor")
        let calls = try await rows(log)
        #expect(calls.count == 2)
        #expect(calls.contains { $0.agent == "claude" && $0.failed && $0.stderr?.contains("boom") == true })
        try fakes[0].set("mode", nil)
        // Within the back-off claude is skipped, though it would work now.
        clock.advance(9 * 60)
        #expect(try await runner.run(ask("b")).agent == "cursor")
        #expect(fakes[0].calls == ["a"])
        clock.advance(2 * 60)
        #expect(try await runner.run(ask("c")).agent == "claude")
    }

    @Test func aCallThatSaysItIsRateLimitedSkipsTheAgentUntilTheReset() async throws {
        let fakes = try [FakeCLI(), FakeCLI()]
        try fakes[0].set("mode", "limit")
        let clock = TestClock(Self.start)
        var settings = LLMSettings()
        settings.backoffMinutes = 1
        let runner = runner([fakes[0].agent("claude"), fakes[1].agent("cursor")], settings: settings, clock: clock)
        #expect(try await runner.run(ask("a")).agent == "cursor")
        try fakes[0].set("mode", nil)
        // Past the back-off but before 18:00 UTC, the reset it named.
        clock.advance(3600)
        #expect(try await runner.run(ask("b")).agent == "cursor")
        clock.advance(8 * 3600)
        #expect(try await runner.run(ask("c")).agent == "claude")
    }

    @Test func everyAgentFailingFailsTheCall() async throws {
        let fakes = try [FakeCLI(), FakeCLI()]
        for fake in fakes {
            try fake.set("mode", "fail")
        }
        let runner = runner([fakes[0].agent("claude"), fakes[1].agent("cursor")])
        await #expect(throws: LLMError.failed(reasons: ["claude: exit 1: boom", "cursor: exit 1: boom"])) {
            try await runner.run(ask("a"))
        }
    }

    @Test func aCallThatHangsIsStoppedAtTheTimeout() async throws {
        let fakes = try [FakeCLI(), FakeCLI()]
        try fakes[0].set("mode", "sleep")
        var settings = LLMSettings()
        settings.timeoutSeconds = 1
        let runner = runner([fakes[0].agent("claude"), fakes[1].agent("cursor")], settings: settings)
        let clock = ContinuousClock()
        let started = clock.now
        let response = try await runner.run(ask("a"))
        #expect(response.agent == "cursor")
        #expect(clock.now - started < .seconds(10))
    }

    // MARK: Cache

    @Test func theSameCallRunsOnce() async throws {
        let fake = try FakeCLI()
        let runner = runner([fake.agent("claude")])
        let first = try await runner.run(ask("same", cached: true))
        let second = try await runner.run(ask("same", cached: true))
        #expect(!first.fromCache && second.fromCache && second.text == first.text)
        #expect(fake.calls == ["same"])
        _ = try await runner.run(ask("other", cached: true))
        _ = try await runner.run(ask("same", cached: false))
        #expect(fake.calls == ["same", "other", "same"])
    }

    @Test func theSameCallAskedTwiceAtOnceRunsOnce() async throws {
        let fake = try FakeCLI()
        try fake.set("delay", "1")
        let runner = runner([fake.agent("claude")])
        async let first = runner.run(ask("same", cached: true))
        async let second = runner.run(ask("same", cached: true))
        let answers = try await [first, second]
        #expect(answers.filter(\.fromCache).count == 1)
        #expect(fake.calls == ["same"])
    }

    @Test func theCacheKeyCoversInstructionsAndSchema() {
        let base = LLMCall(system: "a", prompt: "b")
        #expect(LLMRunner.key(base) == LLMRunner.key(LLMCall(system: "a", prompt: "b")))
        #expect(LLMRunner.key(base) != LLMRunner.key(LLMCall(system: "a2", prompt: "b")))
        #expect(LLMRunner.key(base) != LLMRunner.key(LLMCall(system: "a", prompt: "b", schema: "{}")))
        #expect(LLMRunner.key(LLMCall(system: "ab", prompt: "")) != LLMRunner.key(LLMCall(system: "a", prompt: "b")))
    }

    // MARK: The daily cap

    @Test func backgroundCallsStopAtTheDailyCallCapUntilTomorrow() async throws {
        let fake = try FakeCLI()
        let clock = TestClock(Self.start)
        var settings = LLMSettings()
        settings.dailyCalls = 2
        settings.dailyDollars = 0
        let runner = runner([fake.agent("claude")], settings: settings, clock: clock)
        let log = try log()
        _ = try await runner.run(ask("a"))
        _ = try await runner.run(ask("b"))
        let tomorrow = ISO8601DateFormatter().date(from: "2026-10-23T00:00:00Z")!
        await #expect(throws: LLMError.overBudget(until: tomorrow, reasons: ["claude: daily cap of 2 calls reached"])) {
            try await CallLog.$current.withValue(log) { try await runner.run(ask("c")) }
        }
        // :log says why.
        let row = try #require(try await rows(log).first)
        #expect(row.failed && row.exitCode == nil && row.stderr?.contains("daily cap of 2 calls") == true)
        // What you ask for yourself still runs.
        #expect(try await runner.run(ask("d", priority: .interactive)).agent == "claude")
        clock.advance(15 * 3600)
        #expect(try await runner.run(ask("e")).agent == "claude")
        #expect(fake.calls == ["a", "b", "d", "e"])
    }

    @Test func theDollarCapCountsReportedCosts() async throws {
        let fake = try FakeCLI()
        var settings = LLMSettings()
        settings.dailyCalls = 0
        settings.dailyDollars = 0.0015
        let runner = runner([fake.agent("claude")], settings: settings)
        _ = try await runner.run(ask("a"))
        _ = try await runner.run(ask("b"))
        await #expect(throws: LLMError.self) { try await runner.run(ask("c")) }
        #expect(fake.calls == ["a", "b"])
        let spent = await runner.spentToday()["claude"]
        #expect(spent?.calls == 2 && abs((spent?.dollars ?? 0) - 0.002) < 0.000001)
    }

    @Test func anAgentAtItsCapPassesTheCallOn() async throws {
        let fakes = try [FakeCLI(), FakeCLI()]
        var settings = LLMSettings()
        settings.dailyCalls = 1
        let runner = runner([fakes[0].agent("claude"), fakes[1].agent("cursor")], settings: settings)
        let picked = try await [runner.run(ask("a")).agent, runner.run(ask("b")).agent]
        #expect(picked == ["claude", "cursor"])
        await #expect(throws: LLMError.self) { try await runner.run(ask("c")) }
    }

    @Test func todaysSpendSurvivesARestart() async throws {
        let fake = try FakeCLI()
        var settings = LLMSettings()
        settings.dailyCalls = 2
        let runner = runner([fake.agent("claude")], settings: settings)
        let earlier = [
            LoggedCall(
                at: Self.start.addingTimeInterval(-60),
                kind: .llm,
                caller: "x",
                command: "c",
                duration: 1,
                exitCode: 0,
                agent: "claude",
                cost: 0.1
            ),
            // Yesterday's, and one that never ran, do not count.
            LoggedCall(
                at: Self.start.addingTimeInterval(-86400),
                kind: .llm,
                caller: "x",
                command: "c",
                duration: 1,
                exitCode: 0,
                agent: "claude"
            ),
            LoggedCall(at: Self.start, kind: .llm, caller: "x", command: "(not run)", duration: 0, failed: true),
        ]
        await runner.seedSpend(from: earlier)
        _ = try await runner.run(ask("a"))
        await #expect(throws: LLMError.self) { try await runner.run(ask("b")) }
    }

    @Test func costsAreEstimatedFromPricesWhenNotReported() async throws {
        let fake = try FakeCLI()
        let runner = runner(
            [fake.agent("codex")], prices: UsagePrices(["small-fast": UsagePrices.Price(input: 1, output: 10)])
        )
        let response = try await runner.run(ask("a", schema: true))
        #expect(response.agent == "codex" && response.model == "small-fast")
        #expect(response.tokens == TokenCounts(input: 100, output: 7, cacheRead: 20))
        #expect(response.costEstimated)
        // 100 × 1 + 7 × 10 + 20 × 0.1, per million.
        #expect(abs((response.cost ?? 0) - 0.000172) < 1e-9)
    }

    // MARK: Schemas

    @Test func anAnswerWithoutTheJSONAskedForFailsWithoutBackingOff() async throws {
        let fake = try FakeCLI()
        try fake.set("mode", "prose")
        let runner = runner([fake.agent("claude")])
        await #expect(throws: LLMError.unparseable(agent: "claude", text: "the answer is not the JSON asked for")) {
            try await runner.run(ask("a", schema: true))
        }
        try fake.set("mode", nil)
        let response = try await runner.run(ask("b", schema: true))
        #expect(response.agent == "claude")
        let json = try #require(response.json)
        #expect(try JSONSerialization.jsonObject(with: json) as? [String: String] == ["answer": "b"])
    }

    // MARK: The queue

    @Test func interactiveCallsGoFirst() async throws {
        let fake = try FakeCLI()
        try fake.set("delay", "1")
        var settings = LLMSettings()
        settings.concurrency = 1
        let runner = runner([fake.agent("claude")], settings: settings)
        let first = Task { try await runner.run(ask("first")) }
        try await Task.sleep(for: .milliseconds(300))
        let background = Task { try await runner.run(ask("background")) }
        try await Task.sleep(for: .milliseconds(100))
        let interactive = Task { try await runner.run(ask("interactive", priority: .interactive)) }
        _ = try await [first.value, background.value, interactive.value]
        #expect(fake.calls == ["first", "interactive", "background"])
    }

    @Test func noMoreThanTheConcurrencyRunAtOnce() async throws {
        let fake = try FakeCLI()
        try fake.set("delay", "1")
        var settings = LLMSettings()
        settings.concurrency = 2
        let runner = runner([fake.agent("claude")], settings: settings)
        // Detected before the clock starts, so only the calls are timed.
        _ = await runner.statuses()
        let clock = ContinuousClock()
        let started = clock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 4 {
                group.addTask { _ = try await runner.run(ask("q\(index)")) }
            }
            try await group.waitForAll()
        }
        // Four one-second calls, two at a time: at least two seconds.
        #expect(clock.now - started >= .seconds(2))
    }

    // MARK: The log

    @Test func aCallWritesAnLLMRow() async throws {
        let fakes = try [FakeCLI(), FakeCLI()]
        try fakes[0].set("login", "out")
        let runner = runner([fakes[0].agent("claude"), fakes[1].agent("cursor")])
        let log = try log()
        _ = try await CallLog.$current.withValue(log) { try await runner.run(ask("hello")) }
        let row = try #require(try await rows(log).first)
        #expect(row.kind == .llm && row.caller == "test" && row.operation == "test" && !row.failed)
        #expect(row.agent == "cursor" && row.model == "fake-model" && row.cost == 0.001 && !row.costEstimated)
        #expect(row.tokens == TokenCounts(input: 3, output: 5, cacheRead: 0, cacheWrite: 100))
        #expect(row.detail["prompt"] == "hello" && row.detail["response"] == "echo hello")
        #expect(row.detail["skipped"] == "claude: not logged in" && row.detail["priority"] == "background")
        #expect(row.command.hasPrefix(fakes[1].path + " -p --output-format json --mode ask"), "\(row.command)")
        // Detection runs are shell rows.
        #expect(try await rows(log, .shell).contains { $0.caller == "llm.detect" })
    }

    @Test func turnedOffMakesNoCalls() async throws {
        let fake = try FakeCLI()
        var settings = LLMSettings()
        settings.enabled = false
        let runner = runner([fake.agent("claude")], settings: settings)
        await #expect(throws: LLMError.disabled) { try await runner.run(ask("a")) }
        #expect(fake.calls.isEmpty)
    }
}
