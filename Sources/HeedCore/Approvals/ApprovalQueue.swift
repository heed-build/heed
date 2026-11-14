import Foundation

/// Every permission request waiting on you, from every agent, oldest first. Hook asks are kept here until they are
/// answered, time out or the agent moves on; screen asks (blocked sessions heed cannot answer for) are derived from the
/// sessions each time, and helper asks from the live helpers (`helperAsks`). Identical requests are one group, answered
/// together.
public struct ApprovalQueue: Equatable, Sendable {
    public private(set) var asks: [PermissionAsk] = []
    /// What you answered lately, by `PermissionAsk.key`: "asked before and you said no".
    public private(set) var answered: [Answered] = []
    /// Why a session's last hook ask went back to its pane, by session: shown on its screen ask while it is blocked.
    public private(set) var fallbacks: [String: PermissionFallback] = [:]

    public struct Answered: Equatable, Sendable {
        public var key: String
        public var decision: PermissionAnswer.Decision
        public var at: Date
    }

    /// How many answers are remembered.
    public static let memory = 200

    public init(asks: [PermissionAsk] = []) {
        self.asks = asks
    }

    public var isEmpty: Bool { asks.isEmpty }

    /// Adds a hook ask; one with the same id replaces it. A new ask clears its session's last fallback.
    public mutating func add(_ ask: PermissionAsk) {
        fallbacks[ask.session] = nil
        if let index = asks.firstIndex(where: { $0.id == ask.id }) { asks[index] = ask } else { asks.append(ask) }
    }

    /// Takes the asks with these ids out, returning them.
    @discardableResult
    public mutating func remove(_ ids: Set<String>) -> [PermissionAsk] {
        let gone = asks.filter { ids.contains($0.id) }
        asks.removeAll { ids.contains($0.id) }
        return gone
    }

    /// The session's hook ask went back to its pane, for this reason.
    public mutating func fellBack(_ session: String, _ reason: PermissionFallback) {
        fallbacks[session] = reason
    }

    /// Remembers an answer to these asks (a pass is not an answer).
    public mutating func record(_ decision: PermissionAnswer.Decision, for asks: [PermissionAsk], at: Date) {
        guard decision != .pass else { return }
        for key in Set(asks.map(\.key)) {
            answered.removeAll { $0.key == key }
            answered.append(Answered(key: key, decision: decision, at: at))
        }
        if answered.count > Self.memory { answered.removeFirst(answered.count - Self.memory) }
    }

    /// Whether you said no to this request before.
    public func deniedBefore(_ key: String) -> Bool {
        answered.contains { $0.key == key && $0.decision == .deny }
    }

    /// The asks a hook message shows were answered elsewhere: the call ran (its `PostToolUse` arrived), or the turn
    /// moved on (a new prompt, its end, the agent gone). Only that session's.
    public func settled(by kind: HookMessage.Kind, session: String) -> Set<String> {
        let mine = asks.filter { $0.session == session }
        guard !mine.isEmpty else { return [] }
        switch kind {
        case let .toolCall(call):
            return Set(mine.filter { $0.tool == call.tool && $0.callLabel == call.label }.map(\.id))
        case let .state(state, reason):
            switch state {
            case .done, .idle, .exited, .limited: return Set(mine.map(\.id))
            case .working where reason == "prompt": return Set(mine.map(\.id))
            default: return []
            }
        case .lastMessage, .subagentsEnded: return Set(mine.map(\.id))
        default: return []
        }
    }

    /// The asks of blocked sessions heed has no hook ask for: they wait on a prompt in their pane.
    public func screenAsks(_ sessions: [Session], now: Date) -> [PermissionAsk] {
        let hooked = Set(asks.map(\.session))
        return sessions.filter { $0.state.state == .blocked && !hooked.contains($0.id) }
            .map { session in
                var ask = PermissionAsk.screen(session, now: now)
                ask.fellBack = fallbacks[session.id]
                return ask
            }
    }

    /// Everything waiting, as groups, oldest first. `roots` gives a session's worktrees, for the risk tags.
    public func groups(
        screen: [PermissionAsk] = [], helpers: [PermissionAsk] = [], roots: (String) -> [String] = { _ in [] },
        home: String = Paths.home
    ) -> [ApprovalGroup] {
        var order: [String] = []
        var byKey: [String: [PermissionAsk]] = [:]
        for ask in (asks + screen + helpers).sorted(by: { ($0.askedAt, $0.id) < ($1.askedAt, $1.id) }) {
            if byKey[ask.key] == nil { order.append(ask.key) }
            byKey[ask.key, default: []].append(ask)
        }
        return order.map { key in
            let asks = byKey[key]!
            let tags = Set(asks.flatMap { PermissionRisk.tags(for: $0, roots: roots($0.session), home: home) })
            return ApprovalGroup(asks: asks, tags: tags.sorted(), deniedBefore: deniedBefore(key))
        }
    }
}

/// One request, from one or more agents (identical asks merged): what the list shows as a row.
public struct ApprovalGroup: Identifiable, Equatable, Sendable {
    public var asks: [PermissionAsk]
    public var tags: [PermissionRisk]
    public var deniedBefore: Bool

    public init(asks: [PermissionAsk], tags: [PermissionRisk], deniedBefore: Bool = false) {
        self.asks = asks
        self.tags = tags
        self.deniedBefore = deniedBefore
    }

    public var id: String { first.key }
    public var first: PermissionAsk { asks[0] }
    public var askedAt: Date { first.askedAt }
    public var sessions: [String] { asks.map(\.session).uniqued() }

    /// "Edit 2 files outside the worktree", "Run a command (2 agents)".
    public var title: String {
        var title = first.title
        if tags.contains(.outsideWorktree), first.command == nil { title += " outside the worktree" }
        if sessions.count > 1 { title += " (\(sessions.count) agents)" }
        return title
    }

    /// How long it has waited, short: `5 s`, `2 m`, `1 h`.
    public func waited(_ now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(askedAt)))
        return seconds < 60 ? "\(seconds) s" : seconds < 3600 ? "\(seconds / 60) m" : "\(seconds / 3600) h"
    }

    /// heed can answer it: every ask has a hook or a helper waiting.
    public var answerable: Bool { asks.allSatisfy { $0.channel != .screen } }
    /// Read only, and inside the worktree: what `r` allows.
    public var safeRead: Bool { tags.contains(.readOnly) && !tags.contains(.outsideWorktree) }
    /// "Always" can be sent: Claude asks that offered a rule to save, and helper asks whose agent offered allow always.
    public var canAlways: Bool {
        answerable && asks.allSatisfy {
            $0.channel == .helper ? $0.offersAlways : $0.agent == "claude" && !$0.rules.isEmpty
        }
    }

    /// A deny can carry a reason: no ask in it is a helper's, whose agent hears only the option picked.
    public var takesReason: Bool { answerable && !asks.contains { $0.channel == .helper } }
}

/// The title bar's pill: "5 asks from 4 agents".
public struct ApprovalSummary: Equatable, Sendable {
    public var asks: Int
    public var agents: Int
    /// The agents' names, one per session, oldest ask first (for their avatars).
    public var agentNames: [String]

    public init(_ groups: [ApprovalGroup]) {
        asks = groups.count
        var seen: [String] = []
        var names: [String] = []
        for ask in groups.flatMap(\.asks) where !seen.contains(ask.session) {
            seen.append(ask.session)
            names.append(ask.agent)
        }
        agents = seen.count
        agentNames = names
    }

    public var text: String {
        let asks = "\(asks) ask\(asks == 1 ? "" : "s")"
        return "\(asks) from \(agents) agent\(agents == 1 ? "" : "s")"
    }

    /// `cl`, `cx`, `oc`: two letters for an agent's avatar.
    public static func initials(_ agent: String) -> String {
        switch agent {
        case "claude": "cl"
        case "codex": "cx"
        case "opencode": "oc"
        case "cursor": "cu"
        case "gemini": "gm"
        case _ where agent.hasPrefix("helper"): "hp"
        default: String(agent.prefix(2))
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
