import CryptoKit
import Foundation

/// A model call heed wants made.
public struct LLMRequest: Sendable {
    /// Interactive calls (you pressed something) go before background ones and are not stopped by the daily cap.
    public enum Priority: Int, Sendable, Comparable {
        case background, interactive

        public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var call: LLMCall
    public var priority: Priority
    /// Which part of heed asks (`summary.session`, `settings.test`), for the call log.
    public var caller: String
    /// What was asked for, in a few words, for the call log.
    public var operation: String?
    /// Only this agent (Settings' Test); nil: round-robin over every usable agent.
    public var agent: String?
    /// Answer an identical earlier call from the cache, and keep this answer for the next.
    public var cached: Bool

    public init(
        call: LLMCall, priority: Priority = .background, caller: String, operation: String? = nil,
        agent: String? = nil, cached: Bool = true
    ) {
        self.call = call
        self.priority = priority
        self.caller = caller
        self.operation = operation
        self.agent = agent
        self.cached = cached
    }
}

public struct LLMResponse: Equatable, Sendable {
    public var text: String
    /// The answer as a JSON object, when the call had a schema.
    public var json: Data?
    public var agent: String
    public var model: String?
    public var tokens: TokenCounts?
    /// Reported by the agent, else estimated from `[usage.prices]` (`costEstimated`); nil when neither.
    public var cost: Double?
    public var costEstimated: Bool
    public var duration: TimeInterval
    /// Answered from the cache: nothing ran.
    public var fromCache: Bool

    public init(
        text: String, json: Data? = nil, agent: String, model: String? = nil, tokens: TokenCounts? = nil,
        cost: Double? = nil, costEstimated: Bool = false, duration: TimeInterval = 0, fromCache: Bool = false
    ) {
        self.text = text
        self.json = json
        self.agent = agent
        self.model = model
        self.tokens = tokens
        self.cost = cost
        self.costEstimated = costEstimated
        self.duration = duration
        self.fromCache = fromCache
    }
}

public enum LLMError: Error, Equatable, Sendable, CustomStringConvertible {
    /// `[llm] enabled = false`.
    case disabled
    /// No agent could take the call; why each was skipped.
    case noAgent(reasons: [String])
    /// Every agent that could take it reached its daily cap: background work waits until `until`.
    case overBudget(until: Date, reasons: [String])
    /// The call ran (on every agent tried) and failed.
    case failed(reasons: [String])
    /// It answered, but not with the JSON asked for.
    case unparseable(agent: String, text: String)

    public var description: String {
        switch self {
        case .disabled: "model calls are off ([llm] enabled = false)"
        case let .noAgent(reasons): "no agent to call: " + reasons.joined(separator: "; ")
        case let .overBudget(until, reasons):
            "daily cap reached, background calls wait until \(AgentUsage.clock(until)): "
                + reasons.joined(separator: "; ")
        case let .failed(reasons): "the call failed: " + reasons.joined(separator: "; ")
        case let .unparseable(agent, _): "\(agent) did not answer with the JSON asked for"
        }
    }
}

/// What detection found for one agent, for Settings and for picking.
public struct LLMAgentStatus: Equatable, Sendable, Identifiable {
    public enum Login: Equatable, Sendable {
        case loggedIn, loggedOut
        /// No free check (gemini): a failed call says it.
        case unknown
        case notInstalled
    }

    public var id: String { name }
    public var name: String
    public var command: String
    public var path: String?
    public var login: Login
    /// The cheap model heed picked; nil: the agent's own default.
    public var detectedModel: String?
    /// Checked when.
    public var checkedAt: Date

    public init(
        name: String, command: String, path: String?, login: Login, detectedModel: String?, checkedAt: Date
    ) {
        self.name = name
        self.command = command
        self.path = path
        self.login = login
        self.detectedModel = detectedModel
        self.checkedAt = checkedAt
    }

    public var usable: Bool { login == .loggedIn || login == .unknown }
}

/// Makes heed's own model calls through the agent CLIs you are logged in to: round-robin over the usable ones, skipping
/// an agent that is rate limited (until it resets), failed a moment ago (back-off) or used up its daily cap. Each call
/// runs headless in an empty scratch directory, tools off and nothing saved, with a timeout; a few at a time,
/// interactive first. An identical call is answered from a cache. Every call writes an `llm` row to the call log, with
/// which agent took it and why the others were skipped.
public actor LLMRunner {
    /// How a bare command name becomes an executable, and the PATH to run it with.
    public typealias Resolve = @Sendable (String) async -> (path: String?, pathVariable: String)

    private var agents: [AgentProfile]
    private var settings: LLMSettings
    private var prices: UsagePrices
    private let resolve: Resolve
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    /// Agents rate limited in a session, until when (nil: until that session says otherwise).
    private var limited: [String: Date?] = [:]
    /// Agents whose own call said they are rate limited, until the reset it named.
    private var limitedByCall: [String: Date] = [:]
    /// An agent whose call failed, until when it is skipped.
    private var backedOff: [String: Date] = [:]
    private var lastPicked: String?
    private var statuses: [String: LLMAgentStatus] = [:]
    /// Calls and dollars per agent, for the day `spendDay` starts.
    private var spend: [String: (calls: Int, dollars: Double)] = [:]
    private var spendDay: Date?
    private var cache: [String: LLMResponse] = [:]
    private var cacheOrder: [String] = []
    private var inFlight: [String: Task<LLMResponse, Error>] = [:]
    private var running = 0
    private var waiting: [(priority: LLMRequest.Priority, continuation: CheckedContinuation<Void, Never>)] = []

    /// How long a detection result is trusted.
    public static let detectionTTL: TimeInterval = 10 * 60
    public static let cacheLimit = 256

    public init(
        agents: [AgentProfile] = AgentProfile.builtIn, settings: LLMSettings = LLMSettings(),
        prices: UsagePrices = UsagePrices(),
        resolve: Resolve? = nil,
        calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.agents = agents
        self.settings = settings
        self.prices = prices
        self.resolve = resolve ?? { name in await ToolLocator.shared.executable(name) }
        self.calendar = calendar
        self.now = now
    }

    // MARK: State from outside

    /// The config changed. Detection runs again for an agent whose command changed.
    public func configure(agents: [AgentProfile], settings: LLMSettings, prices: UsagePrices) {
        for agent in agents where statuses[agent.name]?.command != agent.command {
            statuses[agent.name] = nil
        }
        self.agents = agents
        self.settings = settings
        self.prices = prices
    }

    /// The agents rate limited in some session now, with when their limit lifts when known. Replaces what was known.
    public func setLimited(_ agents: [String: Date?]) {
        limited = agents
    }

    /// Today's spend so far from the call log's `llm` rows, so a restart does not reset the daily cap.
    public func seedSpend(from calls: [LoggedCall]) {
        rollDay()
        for call in calls where call.kind == .llm && call.agent != nil && call.exitCode != nil {
            guard let spendDay, call.at >= spendDay else { continue }
            add(spend: call.agent!, cost: call.cost)
        }
    }

    /// Calls and known dollars per agent today.
    public func spentToday() -> [String: (calls: Int, dollars: Double)] {
        rollDay()
        return spend
    }

    // MARK: Detection

    /// Every configured agent heed can call, detected (or from the last detection while it is fresh).
    public func statuses(force: Bool = false) async -> [LLMAgentStatus] {
        var result: [LLMAgentStatus] = []
        for agent in agents where LLMDialect.of(agent) != nil {
            await result.append(status(agent, force: force))
        }
        return result
    }

    func status(_ agent: AgentProfile, force: Bool = false) async -> LLMAgentStatus {
        if !force, let known = statuses[agent.name], known.command == agent.command,
           now().timeIntervalSince(known.checkedAt) < Self.detectionTTL
        {
            return known
        }
        let found = await detect(agent)
        statuses[agent.name] = found
        return found
    }

    /// The executable is the first word of the agent's command; its fixed arguments are for panes, not headless calls.
    private func executable(_ agent: AgentProfile) -> String {
        agent.command.split(separator: " ").first.map(String.init) ?? agent.command
    }

    private func detect(_ agent: AgentProfile) async -> LLMAgentStatus {
        let checked = now()
        guard let dialect = LLMDialect.of(agent) else {
            return LLMAgentStatus(
                name: agent.name, command: agent.command, path: nil, login: .notInstalled, detectedModel: nil,
                checkedAt: checked
            )
        }
        let (path, pathVariable) = await resolve(executable(agent))
        guard let path else {
            return LLMAgentStatus(
                name: agent.name, command: agent.command, path: nil, login: .notInstalled, detectedModel: nil,
                checkedAt: checked
            )
        }
        func run(_ arguments: [String]) async -> ProcessResult? {
            try? await ProcessRunner.run(
                path, arguments, in: NSTemporaryDirectory(), environment: ["PATH": pathVariable],
                timeout: .seconds(20), caller: "llm.detect"
            )
        }
        var login = LLMAgentStatus.Login.unknown
        var loginOutput = ""
        if let check = dialect.loginCheck {
            let result = await run(check)
            login = result.map { dialect.loggedIn($0) ? .loggedIn : .loggedOut } ?? .loggedOut
            loginOutput = result?.stdout ?? ""
        }
        var model = dialect.fixedModel
        if login != .loggedOut, let listing = dialect.modelListing {
            let output = listing == dialect.loginCheck ? loginOutput : await run(listing)?.stdout ?? ""
            model = dialect.cheapModel(listing: output, login: loginOutput)
        }
        return LLMAgentStatus(
            name: agent.name, command: agent.command, path: path, login: login, detectedModel: model,
            checkedAt: checked
        )
    }

    // MARK: Calls

    /// Makes the call, or answers it from the cache.
    public func run(_ request: LLMRequest) async throws -> LLMResponse {
        guard settings.enabled else { throw LLMError.disabled }
        guard request.cached else { return try await queued(request) }
        let key = Self.key(request.call)
        if var hit = cache[key] {
            hit.fromCache = true
            return hit
        }
        if let running = inFlight[key] {
            var response = try await running.value
            response.fromCache = true
            return response
        }
        let task = Task { try await self.queued(request) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let response = try await task.value
        remember(response, key)
        return response
    }

    /// The cache key: everything that shapes the answer.
    static func key(_ call: LLMCall) -> String {
        let text = [call.system, call.prompt, call.schema ?? ""].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func remember(_ response: LLMResponse, _ key: String) {
        if cache.updateValue(response, forKey: key) == nil { cacheOrder.append(key) }
        while cacheOrder.count > Self.cacheLimit {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    private func queued(_ request: LLMRequest) async throws -> LLMResponse {
        await acquire(request.priority)
        defer { release() }
        return try await pickAndRun(request)
    }

    private func acquire(_ priority: LLMRequest.Priority) async {
        if running < max(1, settings.concurrency) {
            running += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiting.append((priority, continuation))
        }
    }

    /// Hands the slot to the longest-waiting interactive call, else the longest-waiting background one.
    private func release() {
        let next = waiting.firstIndex { $0.priority == .interactive } ?? waiting.indices.first
        if let next {
            waiting.remove(at: next).continuation.resume()
        } else {
            running -= 1
        }
    }

    /// Why `agent` cannot take a call now, or nil when it can.
    private func skipReason(_ agent: AgentProfile, priority: LLMRequest.Priority) async -> (String, budget: Bool)? {
        let name = agent.name
        if !settings.isEnabled(name) { return ("\(name): off", false) }
        let time = now()
        if let entry = limited[name] {
            if let until = entry {
                if until > time { return ("\(name): rate limited until \(AgentUsage.clock(until))", false) }
            } else {
                return ("\(name): rate limited", false)
            }
        }
        if let until = limitedByCall[name], until > time {
            return ("\(name): rate limited until \(AgentUsage.clock(until))", false)
        }
        if let until = backedOff[name], until > time {
            return ("\(name): failed recently, backing off until \(AgentUsage.clock(until))", false)
        }
        if priority == .background, let reason = overCap(name) { return ("\(name): \(reason)", true) }
        let status = await status(agent)
        switch status.login {
        case .notInstalled: return ("\(name): \(executable(agent)) not found", false)
        case .loggedOut: return ("\(name): not logged in", false)
        case .loggedIn, .unknown: return nil
        }
    }

    /// The daily cap this agent reached, if it reached one.
    private func overCap(_ name: String) -> String? {
        rollDay()
        let used = spend[name] ?? (0, 0)
        if settings.dailyCalls > 0, used.calls >= settings.dailyCalls {
            return "daily cap of \(settings.dailyCalls) calls reached"
        }
        if settings.dailyDollars > 0, used.dollars >= settings.dailyDollars {
            return "daily cap of \(AgentUsage.dollars(settings.dailyDollars)) reached"
        }
        return nil
    }

    /// The candidates in round-robin order: starting after the agent picked last.
    private func rotation(_ request: LLMRequest) -> [AgentProfile] {
        let callable = agents.filter { LLMDialect.of($0) != nil && (request.agent == nil || $0.name == request.agent) }
        guard let last = lastPicked, let index = callable.firstIndex(where: { $0.name == last }) else {
            return callable
        }
        return Array(callable[(index + 1)...] + callable[...index])
    }

    private func pickAndRun(_ request: LLMRequest) async throws -> LLMResponse {
        var reasons: [String] = []
        var budgetOnly = true
        var ranAny = false
        if request.agent != nil, !agents.contains(where: { $0.name == request.agent }) {
            reasons.append("\(request.agent!): no such agent")
        }
        for agent in rotation(request) {
            if let skip = await skipReason(agent, priority: request.priority) {
                reasons.append(skip.0)
                budgetOnly = budgetOnly && skip.budget
                continue
            }
            budgetOnly = false
            ranAny = true
            lastPicked = agent.name
            do {
                return try await call(agent, request, skipped: reasons)
            } catch let error as AttemptError {
                reasons.append("\(agent.name): \(error.message)")
                if case .unparseable = error.kind { throw LLMError.unparseable(agent: agent.name, text: error.message) }
            }
        }
        if ranAny { throw LLMError.failed(reasons: reasons) }
        let error: LLMError = budgetOnly && !reasons.isEmpty
            ? .overBudget(until: tomorrow(), reasons: reasons)
            : .noAgent(reasons: reasons.isEmpty ? ["no agent heed can call is configured"] : reasons)
        // Nothing ran: the row says why, so :log shows why background work is waiting.
        CallLog.record(LoggedCall(
            at: now(), kind: .llm, caller: request.caller, command: "(not run)", duration: 0, failed: true,
            stderr: error.description, operation: request.operation,
            detail: ["skipped": reasons.joined(separator: "; "), "priority": "\(request.priority)"]
        ))
        throw error
    }

    private struct AttemptError: Error {
        enum Kind { case failed, unparseable }
        var kind: Kind
        var message: String
    }

    /// One attempt on one agent, logged.
    private func call(_ agent: AgentProfile, _ request: LLMRequest, skipped: [String]) async throws -> LLMResponse {
        let dialect = LLMDialect.of(agent)!
        let status = await status(agent)
        let model = settings.model(for: agent.name) ?? status.detectedModel
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("heed-llm-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let invocation = dialect.invocation(request.call, model: model, scratch: scratch.path)
        for (name, content) in invocation.files {
            try? content.write(to: scratch.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        var input: URL?
        if let stdin = invocation.stdin {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("heed-llm-\(UUID().uuidString).in")
            try? stdin.write(to: file, atomically: true, encoding: .utf8)
            input = file
        }
        defer { if let input { try? FileManager.default.removeItem(at: input) } }
        let (resolved, pathVariable) = await resolve(executable(agent))
        let path = status.path ?? resolved ?? executable(agent)

        let started = now()
        let clock = ContinuousClock()
        let start = clock.now
        add(spend: agent.name, cost: nil)
        var result: ProcessResult?
        var failure: String?
        do {
            result = try await ProcessRunner.execute(
                path, invocation.arguments, in: scratch.path, environment: ["PATH": pathVariable],
                timeout: .seconds(settings.timeoutSeconds), input: input
            )
        } catch let error as ProcessError {
            result = error.result
            failure = error.reason
        } catch {
            failure = "\(error)"
        }
        let elapsed = clock.now - start
        let duration = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        var output: LLMOutput?
        if failure == nil, let result {
            var parseError: String?
            do {
                output = try dialect.parse(result.stdout, schema: request.call.schema != nil)
            } catch {
                parseError = "\(error)"
            }
            if !result.succeeded {
                let said = result.stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? parseError
                failure = "exit \(result.status)" + (said.map { ": \($0)" } ?? "")
            } else if let parseError {
                failure = parseError
            }
        }
        var unparseable = false
        if failure == nil, request.call.schema != nil, output?.json == nil {
            unparseable = true
            failure = "the answer is not the JSON asked for"
        }

        let tokens = output?.tokens
        let usedModel = output?.model ?? model
        var cost = output?.cost
        var estimated = false
        if cost == nil, let tokens, let usedModel {
            cost = prices.estimate(AgentUsage(model: usedModel, tokens: tokens))
            estimated = cost != nil
        }
        if let cost { add(spend: agent.name, cost: cost, countCall: false) }

        if let failure, !unparseable {
            let message = [failure, result?.stderr, output?.text].compactMap(\.self).joined(separator: " ")
            let limit = LLMDialect.rateLimit(in: message, now: started)
            if limit.limited, let resets = limit.resetsAt {
                limitedByCall[agent.name] = resets
            } else {
                backedOff[agent.name] = started.addingTimeInterval(Double(settings.backoffMinutes) * 60)
            }
        }

        var detail = ["prompt": LoggedCall.truncated(request.call.prompt) ?? "", "priority": "\(request.priority)"]
        if !skipped.isEmpty { detail["skipped"] = skipped.joined(separator: "; ") }
        if let text = output?.text { detail["response"] = LoggedCall.truncated(text) }
        CallLog.record(LoggedCall(
            at: started, kind: .llm, caller: request.caller, command: Self.display(path, invocation.arguments),
            cwd: scratch.path, duration: duration, exitCode: result.map { Int($0.status) }, failed: failure != nil,
            stdout: failure != nil ? LoggedCall.truncated(result?.stdout) : nil,
            stderr: LoggedCall.truncated(failure.map { [$0, result?.stderr ?? ""].joined(separator: "\n") }
                ?? result?.stderr),
            operation: request.operation, agent: agent.name, model: usedModel, tokens: tokens, cost: cost,
            costEstimated: estimated, detail: detail
        ))

        if let failure {
            throw AttemptError(kind: unparseable ? .unparseable : .failed, message: failure)
        }
        return LLMResponse(
            text: output?.text ?? "", json: output?.json, agent: agent.name, model: usedModel, tokens: tokens,
            cost: cost, costEstimated: estimated, duration: duration
        )
    }

    /// The command as it could be typed, long arguments (a system prompt, a schema) cut short.
    static func display(_ path: String, _ arguments: [String]) -> String {
        ([ShellQuote.quote(path)] + arguments.map { argument in
            ShellQuote.quote(argument.count > 80 ? String(argument.prefix(77)) + "…" : argument)
        }).joined(separator: " ")
    }

    // MARK: The daily cap

    private func rollDay() {
        let today = calendar.startOfDay(for: now())
        if spendDay != today {
            spendDay = today
            spend = [:]
        }
    }

    private func add(spend agent: String, cost: Double?, countCall: Bool = true) {
        rollDay()
        var entry = spend[agent] ?? (0, 0)
        if countCall { entry.calls += 1 }
        if let cost { entry.dollars += cost }
        spend[agent] = entry
    }

    private func tomorrow() -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now())) ?? now().addingTimeInterval(86400)
    }
}
