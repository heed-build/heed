import Foundation

/// The round trip of a permission hook (`heed hook claude PermissionRequest`, `heed hook codex PermissionRequest`):
/// the hook sends its ask over the control socket and waits on that same connection for heed's answer, up to
/// `ceiling`. No answer (heed not running, closed, a timeout, a pass) prints nothing, so the agent asks in its own
/// pane as it would without heed. The answer goes back only on the connection that asked, so only that hook (that
/// session's agent) gets it.
public enum PermissionHook {
    /// The agents whose permission hook can be answered from heed: both take the same `decision` object.
    public static let agents: Set<String> = ["claude", "codex"]

    /// The hook's own timeout in the agent's config, in seconds: the longest the agent lets it wait.
    public static let hookTimeout = 300
    /// The most this process waits for heed's answer; under the hook timeout, so the agent never kills the hook.
    public static let ceiling: TimeInterval = 290
    /// The most `[approvals] wait_seconds` can say: under the ceiling.
    public static let maxWait = 240

    /// Whether this command line is a permission hook heed can answer.
    public static func handles(_ arguments: [String]) -> Bool {
        arguments.count >= 3 && arguments[0] == "hook" && agents.contains(arguments[1])
            && arguments[2] == "PermissionRequest"
    }

    /// The ask a permission hook's stdin describes, for the session in `environment`; nil when it is not one heed
    /// answers (outside a heed pane, a question tool, no tool).
    public static func ask(
        _ arguments: [String], input: Data, environment: [String: String], now: Date = Date()
    ) -> PermissionAsk? {
        guard handles(arguments),
              let session = environment[HeedEnvironment.sessionID], !session.isEmpty,
              let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
        else { return nil }
        return PermissionAsk.from(
            hook: json, agent: arguments[1], session: session, pane: environment[HeedEnvironment.pane], now: now
        )
    }

    /// How long a hook waits for heed's receipt before it lets the agent ask in its pane: heed is not there or too
    /// busy to take the ask.
    public static let receiptWait: TimeInterval = 2
    /// How long a hook tries to get back to heed when its connection drops after a receipt (heed restarting, a
    /// hiccup), re-sending the same ask, before the agent asks in its pane.
    public static let rejoinWait: TimeInterval = 5

    /// Sends `ask` to heed and waits for the answer; `.pass` on anything but an answer to this ask. When the hook
    /// gives up on its own (no receipt, its ceiling, heed gone), it tells heed why, so heed can show it.
    ///
    /// Every wait (`ceiling`, `receiptWait`, `rejoinWait`) runs out on `clock`, real time unless a test passes its own.
    public static func wait(
        for ask: PermissionAsk, token: String? = nil, socket: String = HeedControl.socketPath(),
        ceiling: TimeInterval = ceiling, receiptWait: TimeInterval = receiptWait, rejoinWait: TimeInterval = rejoinWait,
        clock: any _Concurrency.Clock<Duration> = ContinuousClock()
    ) -> PermissionAnswer {
        let outcome = exchange(
            ask, token: token, socket: socket, ceiling: ceiling, receiptWait: receiptWait, rejoinWait: rejoinWait,
            clock: clock
        )
        if let fallback = outcome.fallback, fallback != .notRunning {
            report(fallback, for: ask, token: token, socket: socket, clock: clock)
        }
        return outcome.answer
    }

    /// The round trip itself, never longer than `ceiling` all told: connect, send the ask, wait for heed's receipt
    /// (up to `receiptWait`), then for the answer. A connection that drops after a receipt is made again and the same
    /// ask re-sent (heed keeps answers by ask id, so it is neither asked twice nor answered twice), for up to
    /// `rejoinWait` after the drop. The waits run out on `clock`; the pauses between tries to reconnect are real time.
    /// `received` hears each receipt as the hook takes it: from then on only the ceiling (or a drop) ends the wait.
    public static func exchange(
        _ ask: PermissionAsk, token: String? = nil, socket: String, ceiling: TimeInterval,
        receiptWait: TimeInterval = receiptWait, rejoinWait: TimeInterval = rejoinWait,
        clock: any _Concurrency.Clock<Duration> = ContinuousClock(), received: (@Sendable () -> Void)? = nil
    ) -> (answer: PermissionAnswer, fallback: PermissionFallback?) {
        exchange(
            ask, token: token, socket: socket, ceiling: ceiling, receiptWait: receiptWait, rejoinWait: rejoinWait,
            on: clock, received: received
        )
    }

    private static func exchange<C: _Concurrency.Clock>(
        _ ask: PermissionAsk, token: String?, socket: String, ceiling: TimeInterval,
        receiptWait: TimeInterval, rejoinWait: TimeInterval, on clock: C, received onReceipt: (@Sendable () -> Void)?
    ) -> (answer: PermissionAnswer, fallback: PermissionFallback?) where C.Duration == Duration {
        let deadline = clock.now.advanced(by: .seconds(ceiling))
        let request = ControlRequest(
            method: .permission, session: ask.session, pane: ask.pane, permission: ask, token: token
        )
        // Set when a connection that had a receipt dropped: the rejoin window runs from then.
        var lostAt: C.Instant?
        while true {
            let window = lostAt.map { $0.advanced(by: .seconds(rejoinWait)) }
                ?? clock.now.advanced(by: .seconds(receiptWait))
            let receiptBy = min(window, deadline)
            guard clock.now < receiptBy else {
                return (.pass, lostAt == nil ? .noReceipt : clock.now >= deadline ? .ceiling : .lostHeed)
            }
            var received = false
            do {
                let client = try ControlClient(path: socket, deadline: Deadline(receiptBy, on: clock))
                let id = try client.send(request)
                while true {
                    let reply = try client.next()
                    if reply.received == ask.id, !received {
                        received = true
                        lostAt = nil
                        client.deadline = Deadline(deadline, on: clock)
                        onReceipt?()
                    }
                    guard reply.id == id else { continue }
                    guard reply.ok, reply.permissionID == ask.id, let answer = reply.permission else { return (
                        .pass,
                        nil
                    ) }
                    return (answer, nil)
                }
            } catch ControlClientError.notRunning {
                // Heed is not there: at once the first time; while rejoining, try again until the window closes.
                guard lostAt != nil else { return (.pass, .notRunning) }
                Thread.sleep(forTimeInterval: 0.1)
            } catch ControlClientError.timedOut {
                if received || clock.now >= deadline { return (.pass, .ceiling) }
                return (.pass, lostAt == nil ? .noReceipt : .lostHeed)
            } catch {
                // The connection dropped. Rejoin when heed had the ask (or already lost it once); before any receipt,
                // heed is not taking asks.
                if received { lostAt = clock.now } else if lostAt == nil { return (.pass, .lostHeed) }
                if !received { Thread.sleep(forTimeInterval: 0.1) }
            }
        }
    }

    /// Tells heed this ask fell back to the agent's pane, and why: one line on a new connection, never waited on for
    /// more than a moment.
    static func report(
        _ fallback: PermissionFallback, for ask: PermissionAsk, token: String?, socket: String,
        clock: any _Concurrency.Clock<Duration>
    ) {
        let deadline = Deadline.after(.milliseconds(500), on: clock)
        guard let client = try? ControlClient(path: socket, deadline: deadline) else { return }
        _ = try? client.send(ControlRequest(
            method: .permission, session: ask.session, pane: ask.pane, permission: ask, fallback: fallback,
            token: token
        ))
    }

    /// What the hook prints for `answer` (the agent's `hookSpecificOutput`); nil for a pass, which prints nothing.
    /// "Always" sends Claude's own offered rules back, saved in the project's `.claude/settings.local.json`; Codex
    /// takes no rules from a hook, so it never gets any.
    public static func output(_ answer: PermissionAnswer, for ask: PermissionAsk) -> Data? {
        var decision: [String: Any]
        switch answer.decision {
        case .pass: return nil
        case .allow:
            decision = ["behavior": "allow"]
            if answer.always, ask.agent == "claude", !ask.rules.isEmpty {
                decision["updatedPermissions"] = [[
                    "type": "addRules", "behavior": "allow", "destination": "localSettings",
                    "rules": ask.rules.map { rule -> [String: Any] in
                        var entry: [String: Any] = ["toolName": rule.toolName]
                        if let content = rule.ruleContent { entry["ruleContent"] = content }
                        return entry
                    },
                ]]
            }
        case .deny:
            decision = ["behavior": "deny", "message": answer.message ?? "Denied in heed."]
        }
        let output = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

/// Why a permission ask went back to the agent's own pane instead of being answered in heed.
public enum PermissionFallback: String, Codable, Sendable, CaseIterable {
    /// Heed was not running.
    case notRunning
    /// Heed did not say it had the ask within `PermissionHook.receiptWait`: it is not taking asks, or too busy.
    case noReceipt
    /// The connection to heed dropped and the hook could not get back within `PermissionHook.rejoinWait`.
    case lostHeed
    /// The hook waited as long as it may (`PermissionHook.ceiling`).
    case ceiling
    /// Nobody answered in heed within `[approvals] wait_seconds`.
    case heedWait
    /// The hook went away without coming back: the agent stopped waiting on it.
    case hookLeft

    /// Why, in words for the approvals and the pane's strip.
    public var text: String {
        switch self {
        case .notRunning: "heed was not running"
        case .noReceipt: "heed did not take the request in time"
        case .lostHeed: "the hook lost heed and could not get back"
        case .ceiling: "the hook waited as long as it may"
        case .heedWait: "nobody answered in heed within wait_seconds"
        case .hookLeft: "the agent stopped waiting on heed"
        }
    }

    /// The hook gave up on its own and says so; the rest heed decides itself.
    public var reportedByHook: Bool { [.notRunning, .noReceipt, .lostHeed, .ceiling].contains(self) }

    /// The call log's row for an ask that fell back.
    public func logged(_ ask: PermissionAsk, at: Date) -> LoggedCall {
        LoggedCall(
            at: at, kind: .decide, caller: "approvals.fallback", command: "ask in the pane", duration: 0,
            operation: "fallback \(rawValue)", agent: ask.agent,
            detail: ["ask": ask.id, "session": ask.session, "tool": ask.tool, "reason": text]
        )
    }
}
