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

    /// Sends `ask` to heed and waits for the answer; `.pass` on anything but an answer to this ask.
    public static func wait(
        for ask: PermissionAsk, socket: String = HeedControl.socketPath(), ceiling: TimeInterval = ceiling
    ) -> PermissionAnswer {
        guard let client = try? ControlClient(path: socket) else { return .pass }
        client.readTimeout(ceiling)
        let request = ControlRequest(method: .permission, session: ask.session, pane: ask.pane, permission: ask)
        guard let reply = try? client.call(request), reply.ok, reply.permissionID == ask.id,
              let answer = reply.permission
        else { return .pass }
        return answer
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
