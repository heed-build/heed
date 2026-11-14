import Foundation

/// Before a PR opens: the agent's `gh pr create`, seen through its permission hook (the approvals' round trip), is
/// held for up to `[personas] hold_seconds` while the panel looks. Everyone happy, it goes on at once; a concern, and
/// you choose: let it open, send the concern first, or hold the PR. Nobody choosing, it goes on as it would have
/// (to the approvals, then the agent's own pane): heed never opens or blocks a PR on its own.
public enum PRGate {
    /// What you chose for a held PR.
    public enum Choice: String, Hashable, Sendable, CaseIterable {
        case letOpen, sendConcern, hold
    }

    /// The ask opens a pull request: a shell command that runs `gh pr create`, or GitHub's MCP tool.
    public static func opensPR(_ ask: PermissionAsk) -> Bool {
        if ask.tool.lowercased().hasSuffix("create_pull_request") { return true }
        guard let command = ask.command else { return false }
        return isCreate(command)
    }

    /// `gh pr create …` anywhere in a command line: after `&&`, `;`, `|` or a newline, with gh's own flags before `pr`
    /// (`gh -R acme/site pr create`), behind `env` or a variable. Never in quotes or a comment: `echo "gh pr create"`
    /// is not one.
    public static func isCreate(_ command: String) -> Bool {
        for part in commands(in: command) {
            var words = part.split(whereSeparator: \.isWhitespace).map(String.init)
            // Leading assignments and `env`, `command`, `exec`.
            while let first = words.first, first.contains("=") || ["env", "command", "exec", "sudo"].contains(first) {
                words.removeFirst()
            }
            guard let first = words.first, first == "gh" || first.hasSuffix("/gh") else { continue }
            var index = 1
            // gh's own flags: `-R owner/repo`, `--repo owner/repo`, `--hostname h`.
            while index < words.count, words[index].hasPrefix("-") {
                let flag = words[index]
                index += flag.contains("=") ? 1 : 2
            }
            if index + 1 < words.count, words[index] == "pr", words[index + 1] == "create" { return true }
        }
        return false
    }

    /// The command line's simple commands, split at `&&`, `||`, `;`, `|` and newlines, outside quotes; a comment
    /// ends a line.
    static func commands(in line: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var comment = false
        var previous: Character?
        for character in line {
            if comment {
                if character == "\n" { comment = false } else { continue }
            }
            if let open = quote {
                if character == open { quote = nil }
                current.append(" ")
                previous = character
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
                current.append(" ")
            case "#" where previous == nil || previous?.isWhitespace == true:
                comment = true
            case ";", "|", "&", "\n":
                parts.append(current)
                current = ""
            default:
                current.append(character)
            }
            previous = character
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// What the agent's hook hears for your choice. Letting it open allows this one call; sending the concern first
    /// and holding say no, with a message the agent reads (the concern, or that the PR waits for you).
    public static func answer(_ choice: Choice, look: SessionLook?) -> PermissionAnswer {
        switch choice {
        case .letOpen:
            return PermissionAnswer(.allow)
        case .sendConcern:
            let concern = look?.message ?? "From heed, the panel has a concern about this PR."
            return PermissionAnswer(
                .deny, message: concern + "\nAddress this first, then open the PR again."
            )
        case .hold:
            return PermissionAnswer(
                .deny,
                message: "From heed: hold the PR. Don't open it yet; the developer will tell you when."
            )
        }
    }

    /// Whether a look holds the PR for your choice: someone has a concern. Everyone happy, it goes on at once.
    public static func holds(_ look: SessionLook?) -> Bool { look?.worried == true }
}

/// A PR held for the panel: the ask, until when, and the look once it is in.
public struct PRHold: Hashable, Sendable {
    public var ask: PermissionAsk
    public var since: Date
    public var until: Date
    public var look: SessionLook?

    public init(ask: PermissionAsk, since: Date, until: Date, look: SessionLook? = nil) {
        self.ask = ask
        self.since = since
        self.until = until
        self.look = look
    }

    /// Whole seconds left, never below zero.
    public func remaining(_ now: Date) -> Int { max(0, Int(until.timeIntervalSince(now).rounded(.up))) }

    /// How long the approvals may still wait after the hold, inside the hook's own ceiling (a few seconds spare).
    public func approvalsWait(_ configured: Int, now: Date) -> Int {
        let left = Int(PermissionHook.ceiling - now.timeIntervalSince(since)) - 5
        return max(0, min(configured, left))
    }
}

/// The lines at the foot of a session's panes, most urgent first: helpers (#243), the panel, and growing into a goal
/// (#246). They stack; none replaces another.
public enum SessionFoot {
    public enum Line: Hashable, Sendable {
        case helpers, panel, growth
    }

    /// How urgent the panel's line is: a held PR or a worried verdict needs you; an offer or a happy verdict can wait.
    public enum PanelUrgency: Int, Sendable, Comparable {
        case needsYou = 0, waits = 2

        public static func < (lhs: PanelUrgency, rhs: PanelUrgency) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The order to stack them in: what needs you first (a helper or the panel), then what works, then offers, then
    /// growing into a goal last. Ties keep helpers before the panel.
    public static func order(helpers: SessionHelperLine?, panel: PanelUrgency?, growth: Bool) -> [Line] {
        var ranked: [(Line, Int)] = []
        if let helpers { ranked.append((.helpers, helpers.needsYou ? 0 : 1)) }
        if let panel { ranked.append((.panel, panel.rawValue)) }
        if growth { ranked.append((.growth, 3)) }
        return ranked.enumerated().sorted { lhs, rhs in
            lhs.element.1 == rhs.element.1 ? lhs.offset < rhs.offset : lhs.element.1 < rhs.element.1
        }.map(\.element.0)
    }
}

/// What the panel's line at the session's foot shows.
public enum SessionPanelLine: Hashable, Sendable {
    /// Ask N personas for a look?
    case offer(SessionMilestone)
    /// The panel is reading.
    case looking(SessionMilestone)
    /// The panel's verdict: ✓n ?n ⇄n and the top concern.
    case verdict(SessionLook)
    /// A PR held while the panel looks, or for your choice.
    case holding(PRHold)

    /// The line for a session: a held PR first, then a look under way, the offer, the last verdict.
    public static func of(record: SessionPanelRecord?, looking: SessionMilestone?, hold: PRHold?) -> SessionPanelLine? {
        if let hold { return .holding(hold) }
        if let looking { return .looking(looking) }
        if let offer = record?.offer { return .offer(offer) }
        if let look = record?.look { return .verdict(look) }
        return nil
    }

    public var urgency: SessionFoot.PanelUrgency {
        switch self {
        case .holding: .needsYou
        case let .verdict(look): look.worried && !look.sent ? .needsYou : .waits
        case .offer, .looking: .waits
        }
    }
}
