import Foundation
@testable import HeedCore
import Synchronization
import Testing

/// A fake agent CLI: a shell script that answers like claude (`-p`, `auth status`) or cursor-agent (`-p`, `status`,
/// `models`), as files next to it say. Every call it answers appends the prompt's last line to `calls`. Only the tests
/// that prove the process path use it (stdin, the timeout, detection rows); the rest use `FakeAgent`.
private struct FakeCLI {
    let folder: URL
    let path: String

    init() throws {
        folder = try Scratch.folder("heed-fake-llm")
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
        esac
        input="$(cat)"
        if [ -z "$input" ]; then for last; do :; done; input="$last"; fi
        first="$(printf '%s\n' "$input" | tail -n 1)"
        echo "$first" >> "$dir/calls"
        case "$mode" in
          fail) echo "boom" >&2; exit 1 ;;
          sleep) sleep 120; echo woke > "$dir/woke"; exit 1 ;;
        esac
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

/// An agent answered in-process, as `FakeCLI` answers from a script: claude's and cursor's `-p`, codex's `exec`,
/// their login checks and model listings. Every call appends the prompt's last line to `calls`, then waits while the
/// agent is held.
private final class FakeAgent: Sendable {
    enum Mode: Sendable {
        case ok, fail, prose
        /// Says it hit its session limit, which resets at 6pm UTC.
        case limit
    }

    private struct State {
        var mode = Mode.ok
        var loggedIn = true
        var calls: [String] = []
        var held = false
        var holding: [CheckedContinuation<Void, Never>] = []
        var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        var running = 0
        var mostAtOnce = 0
    }

    let path = "/fake/agent-\(UUID().uuidString)"
    private let state = Mutex(State())

    func agent(_ name: String) -> AgentProfile { AgentProfile(name: name, command: path) }

    var calls: [String] { state.withLock { $0.calls } }
    /// The most calls it was answering at one time.
    var mostAtOnce: Int { state.withLock { $0.mostAtOnce } }
    func set(_ mode: Mode) { state.withLock { $0.mode = mode } }
    func logIn(_ loggedIn: Bool) { state.withLock { $0.loggedIn = loggedIn } }

    /// Calls wait, once they are recorded, until `release`.
    func hold() { state.withLock { $0.held = true } }

    func release() {
        let waiting = state.withLock { state in
            state.held = false
            defer { state.holding = [] }
            return state.holding
        }
        for continuation in waiting {
            continuation.resume()
        }
    }

    /// Returns once `count` calls have been made.
    func waitForCalls(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let reached = state.withLock { state in
                guard state.calls.count < count else { return true }
                state.callWaiters.append((count, continuation))
                return false
            }
            if reached { continuation.resume() }
        }
    }

    /// Answers the runner's commands for these agents.
    static func execute(_ fakes: [FakeAgent]) -> LLMRunner.Execute {
        { command in
            guard let fake = fakes.first(where: { $0.path == command.path }) else {
                throw ProcessError(command: command.path, result: nil, reason: "could not start")
            }
            return await fake.answer(command)
        }
    }

    private func answer(_ command: LLMRunner.Command) async -> ProcessResult {
        switch command.arguments.first {
        case "auth", "status", "login":
            return state.withLock { $0.loggedIn }
                ? ProcessResult(status: 0, stdout: #"{"loggedIn": true}"# + "\n", stderr: "")
                : ProcessResult(status: 1, stdout: "Not logged in\n", stderr: "")
        case "models": return ProcessResult(status: 0, stdout: "fake-mini - Fake Mini\n", stderr: "")
        case "debug":
            return ProcessResult(
                status: 0,
                stdout: #"{"models":[{"slug":"big","description":"Frontier","visibility":"list","priority":1},{"slug":"small-fast","description":"Fast and affordable model","visibility":"list","priority":4}]}"# +
                    "\n",
                stderr: ""
            )
        default: break
        }
        let stdin = command.input.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let input = stdin.isEmpty ? command.arguments.last ?? "" : stdin
        let last = input.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let (mode, mustWait, reached) = state.withLock { state in
            state.calls.append(last)
            state.running += 1
            state.mostAtOnce = max(state.mostAtOnce, state.running)
            let count = state.calls.count
            let reached = state.callWaiters.filter { $0.count <= count }.map(\.continuation)
            state.callWaiters.removeAll { $0.count <= count }
            return (state.mode, state.held, reached)
        }
        for continuation in reached {
            continuation.resume()
        }
        if mustWait {
            await withCheckedContinuation { continuation in
                let released = state.withLock { state in
                    guard state.held else { return true }
                    state.holding.append(continuation)
                    return false
                }
                if released { continuation.resume() }
            }
        }
        state.withLock { $0.running -= 1 }
        switch mode {
        case .fail: return ProcessResult(status: 1, stdout: "", stderr: "boom\n")
        case .limit:
            let text = #"{"type":"result","is_error":true,"result":"You have hit your session limit · resets 6pm (UTC)"}"#
            return ProcessResult(status: 1, stdout: text + "\n", stderr: "")
        case .prose:
            let text = #"{"type":"result","is_error":false,"result":"I would rather not","total_cost_usd":0.001}"#
            return ProcessResult(status: 0, stdout: text + "\n", stderr: "")
        case .ok: break
        }
        if command.arguments.first == "exec" {
            return ProcessResult(status: 0, stdout: """
            {"type":"thread.started"}
            {"type":"item.completed","item":{"type":"agent_message","text":"{\\"answer\\":\\"codex\\"}"}}
            {"type":"turn.completed","usage":{"input_tokens":120,"cached_input_tokens":20,"output_tokens":7}}

            """, stderr: "")
        }
        return ProcessResult(
            status: 0,
            stdout: #"{"type":"result","is_error":false,"result":"echo \#(last)","structured_output":{"answer":"\#(last)"},"total_cost_usd":0.001,"usage":{"input_tokens":3,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":100},"modelUsage":{"fake-model":{}}}"# +
                "\n",
            stderr: ""
        )
    }
}

private final class TestClock: Sendable {
    private let value: Mutex<Date>
    init(_ date: Date) { value = Mutex(date) }
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
}

@Suite(.scratch)
struct LLMRunnerTests {
    private static let start = ISO8601DateFormatter().date(from: "2026-10-22T09:00:00Z")!

    private func utc() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// A runner whose calls `fakes` answer in-process; with none, they run as processes (`FakeCLI`).
    private func runner(
        _ agents: [AgentProfile], answeredBy fakes: [FakeAgent]? = nil, settings: LLMSettings = LLMSettings(),
        clock: TestClock = TestClock(start), prices: UsagePrices = UsagePrices()
    ) -> LLMRunner {
        LLMRunner(
            agents: agents, settings: settings, prices: prices, resolve: { name in (name, "/usr/bin:/bin") },
            execute: fakes.map(FakeAgent.execute) ?? LLMRunner.process, calendar: utc(), now: { clock.now }
        )
    }

    private func log() throws -> CallLog {
        let folder = try Scratch.folder("heed-llm-log")
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
        let fakes = [FakeAgent(), FakeAgent(), FakeAgent()]
        let runner = runner(
            [fakes[0].agent("claude"), fakes[1].agent("cursor"), fakes[2].agent("codex")], answeredBy: fakes
        )
        var picked: [String] = []
        for index in 0 ..< 4 {
            try await picked.append(runner.run(ask("q\(index)")).agent)
        }
        #expect(picked == ["claude", "cursor", "codex", "claude"])
        #expect(fakes[0].calls == ["q0", "q3"] && fakes[1].calls == ["q1"])
    }

    /// Attention's "summarizing… claude haiku" hears which agent took the call as it starts; a cached answer is not a
    /// start.
    @Test func theCallerHearsWhichAgentStarted() async throws {
        let fake = FakeAgent()
        var settings = LLMSettings()
        settings.agents["claude"] = LLMSettings.Agent(model: "haiku")
        let runner = runner([fake.agent("claude")], answeredBy: [fake], settings: settings)
        let started = Mutex<[String]>([])
        var request = ask("q", cached: true)
        request.onStart = { agent, model in started.withLock { $0.append("\(agent) \(model ?? "-")") } }
        _ = try await runner.run(request)
        _ = try await runner.run(request)
        #expect(started.withLock { $0 } == ["claude haiku"])
    }

    @Test func oneAgentChosenTakesEveryCall() async throws {
        let fakes = [FakeAgent(), FakeAgent()]
        var settings = LLMSettings()
        settings.agent = "cursor"
        let runner = runner([fakes[0].agent("claude"), fakes[1].agent("cursor")], answeredBy: fakes, settings: settings)
        for index in 0 ..< 3 {
            #expect(try await runner.run(ask("q\(index)")).agent == "cursor")
        }
        #expect(fakes[0].calls.isEmpty && fakes[1].calls == ["q0", "q1", "q2"])
        // Its test of another agent still goes to that one.
        #expect(try await runner.run(ask("t", agent: "claude")).agent == "claude")
    }

    @Test func autoTakesTurnsAndAChosenAgentDownFailsTheCall() async throws {
        let fakes = [FakeAgent(), FakeAgent()]
        let agents = [fakes[0].agent("claude"), fakes[1].agent("cursor")]
        var settings = LLMSettings()
        settings.agent = "auto"
        let both = runner(agents, answeredBy: fakes, settings: settings)
        #expect(try await [both.run(ask("a")).agent, both.run(ask("b")).agent] == ["claude", "cursor"])
        fakes[1].logIn(false)
        settings.agent = "cursor"
        let one = runner(agents, answeredBy: fakes, settings: settings)
        await #expect(throws: LLMError.noAgent(reasons: ["cursor: not logged in"])) { try await one.run(ask("c")) }
        settings.agent = "gemini"
        let missing = runner([fakes[0].agent("claude")], answeredBy: fakes, settings: settings)
        await #expect(throws: LLMError.noAgent(reasons: ["gemini: no such agent"])) {
            try await missing.run(ask("d"))
        }
    }

    @Test func anAgentTurnedOffIsNeverPicked() async throws {
        let fakes = [FakeAgent(), FakeAgent()]
        var settings = LLMSettings()
        settings.agents["claude"] = LLMSettings.Agent(enabled: false)
        let runner = runner([fakes[0].agent("claude"), fakes[1].agent("cursor")], answeredBy: fakes, settings: settings)
        let log = try log()
        for index in 0 ..< 3 {
            let response = try await CallLog.$current.withValue(log) { try await runner.run(ask("q\(index)")) }
            #expect(response.agent == "cursor")
        }
        #expect(fakes[0].calls.isEmpty)
        let logged = try await rows(log)
        #expect(logged.count == 3)
        #expect(logged.allSatisfy { $0.detail["skipped"] == "claude: off" })
    }

    @Test func customAgentsTakeNoPart() async throws {
        let fake = FakeAgent()
        let runner = runner([fake.agent("mytool")], answeredBy: [fake])
        await #expect(throws: LLMError.noAgent(reasons: ["no agent heed can call is configured"])) {
            try await runner.run(ask("q"))
        }
    }

    /// Through real processes: the login checks run.
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
        let fakes = [FakeAgent(), FakeAgent()]
        let clock = TestClock(Self.start)
        let runner = runner([fakes[0].agent("claude"), fakes[1].agent("cursor")], answeredBy: fakes, clock: clock)
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
        let fakes = [FakeAgent(), FakeAgent()]
        fakes[0].set(.fail)
        let clock = TestClock(Self.start)
        var settings = LLMSettings()
        settings.backoffMinutes = 10
        let runner = runner(
            [fakes[0].agent("claude"), fakes[1].agent("cursor")], answeredBy: fakes, settings: settings, clock: clock
        )
        let log = try log()
        let response = try await CallLog.$current.withValue(log) { try await runner.run(ask("a")) }
        #expect(response.agent == "cursor")
        let calls = try await rows(log)
        #expect(calls.count == 2)
        #expect(calls.contains { $0.agent == "claude" && $0.failed && $0.stderr?.contains("boom") == true })
        fakes[0].set(.ok)
        // Within the back-off claude is skipped, though it would work now.
        clock.advance(9 * 60)
        #expect(try await runner.run(ask("b")).agent == "cursor")
        #expect(fakes[0].calls == ["a"])
        clock.advance(2 * 60)
        #expect(try await runner.run(ask("c")).agent == "claude")
    }

    @Test func aCallThatSaysItIsRateLimitedSkipsTheAgentUntilTheReset() async throws {
        let fakes = [FakeAgent(), FakeAgent()]
        fakes[0].set(.limit)
        let clock = TestClock(Self.start)
        var settings = LLMSettings()
        settings.backoffMinutes = 1
        let runner = runner(
            [fakes[0].agent("claude"), fakes[1].agent("cursor")], answeredBy: fakes, settings: settings, clock: clock
        )
        #expect(try await runner.run(ask("a")).agent == "cursor")
        fakes[0].set(.ok)
        // Past the back-off but before 18:00 UTC, the reset it named.
        clock.advance(3600)
        #expect(try await runner.run(ask("b")).agent == "cursor")
        clock.advance(8 * 3600)
        #expect(try await runner.run(ask("c")).agent == "claude")
    }

    /// Through real processes: what a failing CLI printed on stderr is the reason.
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

    /// Through a real process, which the timeout ends.
    @Test func aCallThatHangsIsStoppedAtTheTimeout() async throws {
        let fakes = try [FakeCLI(), FakeCLI()]
        try fakes[0].set("mode", "sleep")
        var settings = LLMSettings()
        settings.timeoutSeconds = 1
        let runner = runner([fakes[0].agent("claude"), fakes[1].agent("cursor")], settings: settings)
        let response = try await runner.run(ask("a"))
        #expect(response.agent == "cursor")
        // The hanging call was ended, not waited out: it never woke from its sleep.
        #expect(!FileManager.default.fileExists(atPath: fakes[0].folder.appendingPathComponent("woke").path))
    }

    // MARK: Cache

    @Test func theSameCallRunsOnce() async throws {
        let fake = FakeAgent()
        let runner = runner([fake.agent("claude")], answeredBy: [fake])
        let first = try await runner.run(ask("same", cached: true))
        let second = try await runner.run(ask("same", cached: true))
        #expect(!first.fromCache && second.fromCache && second.text == first.text)
        #expect(fake.calls == ["same"])
        _ = try await runner.run(ask("other", cached: true))
        _ = try await runner.run(ask("same", cached: false))
        #expect(fake.calls == ["same", "other", "same"])
    }

    @Test(.timeLimit(.minutes(1))) func theSameCallAskedTwiceAtOnceRunsOnce() async throws {
        let fake = FakeAgent()
        fake.hold()
        defer { fake.release() }
        let runner = runner([fake.agent("claude")], answeredBy: [fake])
        let first = Task { try await runner.run(ask("same", cached: true)) }
        await fake.waitForCalls(1)
        // Asked while the first is still being answered.
        let second = Task { try await runner.run(ask("same", cached: true)) }
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        fake.release()
        let answers = try await [first.value, second.value]
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

    @Test func theCacheKeyIncludesTheTier() {
        let call = LLMCall(system: "a", prompt: "b")
        #expect(LLMRunner.key(call, tier: .cheap) == LLMRunner.key(call))
        #expect(LLMRunner.key(call, tier: .cheap) != LLMRunner.key(call, tier: .standard))
        #expect(LLMRunner.key(call, tier: .standard) != LLMRunner.key(call, tier: .strong))
    }

    @Test func theSameCallAtAnotherTierIsNotAnsweredFromTheCache() async throws {
        let fake = FakeAgent()
        let runner = runner([fake.agent("claude")], answeredBy: [fake])
        var standard = ask("same", cached: true)
        standard.tier = .standard
        _ = try await runner.run(ask("same", cached: true))
        _ = try await runner.run(standard)
        let again = try await runner.run(standard)
        #expect(fake.calls == ["same", "same"])
        #expect(again.fromCache)
    }

    @Test func aTierPicksTheModelAndTheCallLogSaysWhat() async throws {
        let fakes = [FakeAgent(), FakeAgent()]
        let log = try log()
        let claude = runner([fakes[0].agent("claude")], answeredBy: fakes)
        var request = ask("q")
        for (tier, model) in [(LLMTier.cheap, "haiku"), (.standard, "sonnet"), (.strong, "opus")] {
            request.tier = tier
            _ = try await CallLog.$current.withValue(log) { try await claude.run(request) }
            let row = try #require(try await rows(log).first { $0.detail["tier"]?.hasPrefix(tier.rawValue) == true })
            #expect(row.command.contains("--model \(model)"))
            #expect(row.detail["tier"] == "\(tier.rawValue): \(model)")
        }
        // codex has no standard model heed knows: its own default, and the log says so.
        let codex = runner([fakes[1].agent("codex")], answeredBy: fakes)
        request.tier = .standard
        _ = try await CallLog.$current.withValue(log) { try await codex.run(request) }
        let row = try #require(try await rows(log)
            .first { $0.agent == "codex" && $0.detail["tier"]?.hasPrefix("standard") == true })
        #expect(!row.command.contains(" -m "))
        #expect(row.detail["tier"] == "standard: no standard model known for codex, its own default")
    }

    // MARK: The daily cap

    @Test func backgroundCallsStopAtTheDailyCallCapUntilTomorrow() async throws {
        let fake = FakeAgent()
        let clock = TestClock(Self.start)
        var settings = LLMSettings()
        settings.dailyCalls = 2
        settings.dailyDollars = 0
        let runner = runner([fake.agent("claude")], answeredBy: [fake], settings: settings, clock: clock)
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
        let fake = FakeAgent()
        var settings = LLMSettings()
        settings.dailyCalls = 0
        settings.dailyDollars = 0.0015
        let runner = runner([fake.agent("claude")], answeredBy: [fake], settings: settings)
        _ = try await runner.run(ask("a"))
        _ = try await runner.run(ask("b"))
        await #expect(throws: LLMError.self) { try await runner.run(ask("c")) }
        #expect(fake.calls == ["a", "b"])
        let spent = await runner.spentToday()["claude"]
        #expect(spent?.calls == 2 && abs((spent?.dollars ?? 0) - 0.002) < 0.000001)
    }

    @Test func anAgentAtItsCapPassesTheCallOn() async throws {
        let fakes = [FakeAgent(), FakeAgent()]
        var settings = LLMSettings()
        settings.dailyCalls = 1
        let runner = runner([fakes[0].agent("claude"), fakes[1].agent("cursor")], answeredBy: fakes, settings: settings)
        let picked = try await [runner.run(ask("a")).agent, runner.run(ask("b")).agent]
        #expect(picked == ["claude", "cursor"])
        await #expect(throws: LLMError.self) { try await runner.run(ask("c")) }
    }

    @Test func todaysSpendSurvivesARestart() async throws {
        let fake = FakeAgent()
        var settings = LLMSettings()
        settings.dailyCalls = 2
        let runner = runner([fake.agent("claude")], answeredBy: [fake], settings: settings)
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
        let fake = FakeAgent()
        let runner = runner(
            [fake.agent("codex")], answeredBy: [fake],
            prices: UsagePrices(["small-fast": UsagePrices.Price(input: 1, output: 10)])
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
        let fake = FakeAgent()
        fake.set(.prose)
        let runner = runner([fake.agent("claude")], answeredBy: [fake])
        await #expect(throws: LLMError.unparseable(agent: "claude", text: "the answer is not the JSON asked for")) {
            try await runner.run(ask("a", schema: true))
        }
        fake.set(.ok)
        let response = try await runner.run(ask("b", schema: true))
        #expect(response.agent == "claude")
        let json = try #require(response.json)
        #expect(try JSONSerialization.jsonObject(with: json) as? [String: String] == ["answer": "b"])
    }

    // MARK: The queue

    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) func interactiveCallsGoFirst(cached: Bool) async throws {
        let fake = FakeAgent()
        fake.hold()
        // A failing test must not leave its calls parked.
        defer { fake.release() }
        var settings = LLMSettings()
        settings.concurrency = 1
        let runner = runner([fake.agent("claude")], answeredBy: [fake], settings: settings)
        // The first call holds the only slot until both others are queued. Each call made is answering or queued:
        // counting both waits as long for a runner that lets too many through, which then fails the order.
        let first = Task { try await runner.run(ask("first", cached: cached)) }
        await fake.waitForCalls(1)
        let background = Task { try await runner.run(ask("background", cached: cached)) }
        try await until { await fake.calls.count + runner.queuedCount == 2 }
        let interactive = Task { try await runner.run(ask("interactive", priority: .interactive, cached: cached)) }
        try await until { await fake.calls.count + runner.queuedCount == 3 }
        fake.release()
        _ = try await [first.value, background.value, interactive.value]
        #expect(fake.calls == ["first", "interactive", "background"])
    }

    /// Waits for `condition`; the test's time limit ends a wait that never ends.
    private func until(_ condition: () async -> Bool) async throws {
        while await !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test(.timeLimit(.minutes(1))) func noMoreThanTheConcurrencyRunAtOnce() async throws {
        let fake = FakeAgent()
        fake.hold()
        defer { fake.release() }
        var settings = LLMSettings()
        settings.concurrency = 2
        let runner = runner([fake.agent("claude")], answeredBy: [fake], settings: settings)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 4 {
                group.addTask { _ = try await runner.run(ask("q\(index)")) }
            }
            // Every call is answering or waiting for a slot.
            try await until { await fake.calls.count + runner.queuedCount == 4 }
            fake.release()
            try await group.waitForAll()
        }
        #expect(fake.calls.count == 4)
        #expect(fake.mostAtOnce == 2)
    }

    // MARK: The log

    /// Through real processes: the prompt on stdin, the answer parsed, detection logged as shell rows.
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
        let fake = FakeAgent()
        var settings = LLMSettings()
        settings.enabled = false
        let runner = runner([fake.agent("claude")], answeredBy: [fake], settings: settings)
        await #expect(throws: LLMError.disabled) { try await runner.run(ask("a")) }
        #expect(fake.calls.isEmpty)
    }
}
