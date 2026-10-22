import Foundation

/// What a rule does to the items it matches.
public struct AttentionAction: Hashable, Sendable {
    /// `boost n` (1–3): higher in "weight, then recent", and 3 notifies.
    public var boost = 0
    /// `lower`: dimmed, below the normal ones, never notifies.
    public var lower = false
    /// `ignore`: out of the feed, listed under Muted (and kept 30 days).
    public var ignore = false
    /// `pin`: at the top of the feed.
    public var pin = false
    /// `notify`: a notification when it arrives (as `boost 3` implies).
    public var notify = false

    public init(boost: Int = 0, lower: Bool = false, ignore: Bool = false, pin: Bool = false, notify: Bool = false) {
        self.boost = boost
        self.lower = lower
        self.ignore = ignore
        self.pin = pin
        self.notify = notify
    }

    /// The weight it gives: boost n is n, lower is -1, otherwise 0.
    public var weight: Int { lower ? -1 : boost }
    public var notifies: Bool { notify || boost >= 3 }

    /// `boost 2`, `lower`, `ignore`, `pin notify`.
    public var text: String {
        var words: [String] = []
        if boost > 0 { words.append("boost \(boost)") }
        if lower { words.append("lower") }
        if ignore { words.append("ignore") }
        if pin { words.append("pin") }
        if notify { words.append("notify") }
        return words.joined(separator: " ")
    }
}

/// One condition of a rule; all of a rule's conditions must hold.
public enum AttentionCondition: Hashable, Sendable {
    /// Any of these reasons.
    case reasons(Set<AttentionReason>)
    /// You were mentioned yourself (`mention user:me`).
    case mentionedDirectly
    /// One of the teams it came through matches the glob (`team:acme/docs-*`).
    case team(String)
    /// A team mention whose team is not known (`team:?`).
    case teamUnknown
    /// A review asked of you yourself (`requested:me`), or of one of your teams (`requested:team`).
    case requestedDirectly
    case requestedOfTeam
    /// `author dependabot`, `author me`; `author bot`, `author bot:dependabot`, `author human`.
    case author(String)
    case bot(String?)
    case human
    case label(String)
    case repo(String)
    case branch(String)
    case agent(Set<AgentState>)
    case draft(Bool)
    /// Lines changed: more than (`size >500`) or fewer than (`size <50`).
    case size(greater: Bool, Int)
    /// Since its last update: older than (`age >7d`) or newer than (`age <2h`), in seconds.
    case age(greater: Bool, TimeInterval)
    /// Whose turn: `turn mine` (someone else spoke last), `turn theirs` (you did).
    case yourTurn(Bool)
    case kind(Set<AttentionItem.Kind>)
    /// `any`: every item.
    case any
}

/// One line of `[attention] rules`: conditions, then what to do.
public struct AttentionRule: Hashable, Sendable {
    public var conditions: [AttentionCondition]
    public var action: AttentionAction
    /// 1-based, among the configured lines.
    public var line: Int
    public var text: String

    public init(conditions: [AttentionCondition], action: AttentionAction, line: Int, text: String) {
        self.conditions = conditions
        self.action = action
        self.line = line
        self.text = text
    }

    /// The rule as written, without its action: `mention team:acme/docs-eng`.
    public var match: String {
        let words = AttentionRules.words(text)
        let actionStart = words.firstIndex { AttentionRules.actionWords.contains($0.lowercased()) } ?? words.count
        return words[..<actionStart].joined(separator: " ")
    }

    public func matches(_ item: AttentionItem, viewer: String?, now: Date) -> Bool {
        conditions.allSatisfy { holds($0, item, viewer: viewer, now: now) }
    }

    private func holds(_ condition: AttentionCondition, _ item: AttentionItem, viewer: String?, now: Date) -> Bool {
        let me = viewer?.lowercased()
        switch condition {
        case let .reasons(reasons): return !item.reasons.isDisjoint(with: reasons)
        case .mentionedDirectly: return item.reasons.contains(.mentioned)
        case let .team(glob): return item.teams.contains { Glob.matches(glob, $0) }
        case .teamUnknown: return item.reasons.contains(.teamMention) && item.teams.isEmpty
        case .requestedDirectly: return item.reasons.contains(.reviewRequested) && item.teams.isEmpty
        case .requestedOfTeam: return item.reasons.contains(.reviewRequested) && !item.teams.isEmpty
        case let .author(glob):
            guard let author = item.author?.lowercased() else { return false }
            return glob == "me" ? author == me : Glob.matches(glob, Self.login(author))
        case let .bot(glob):
            guard item.authorIsBot || item.author?.hasSuffix("[bot]") == true else { return false }
            return glob.map { Glob.matches($0, Self.login(item.author ?? "")) } ?? true
        case .human: return item.author != nil && !item.authorIsBot && item.author?.hasSuffix("[bot]") != true
        case let .label(glob): return item.labels.contains { Glob.matches(glob, $0) }
        case let .repo(glob): return item.repo.map { Glob.matches(glob, $0.slug) } ?? false
        case let .branch(glob): return item.branch.map { Glob.matches(glob, $0) } ?? false
        case let .agent(states): return item.agentState.map { states.isEmpty || states.contains($0) } ?? false
        case let .draft(draft): return item.isDraft == draft
        case let .size(greater, lines):
            guard let size = item.size else { return false }
            return greater ? size > lines : size < lines
        case let .age(greater, seconds):
            let age = now.timeIntervalSince(item.updatedAt)
            return greater ? age > seconds : age < seconds
        case let .yourTurn(mine):
            guard let last = item.lastCommenter?.lowercased(), let me else { return false }
            return mine ? last != me : last == me
        case let .kind(kinds): return kinds.contains(item.kind)
        case .any: return true
        }
    }

    /// `dependabot[bot]` → `dependabot`, so `bot:dependabot` matches either.
    static func login(_ author: String) -> String {
        author.hasSuffix("[bot]") ? String(author.dropLast(5)) : author
    }
}

/// A line that did not parse: shown in the editor and with the config's problems; the line is left out, the rest
/// apply.
public struct AttentionRuleProblem: Error, Hashable, Sendable, CustomStringConvertible {
    public var line: Int
    public var message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }

    public var description: String { "line \(line): \(message)" }
}

/// What the rules make of one item: the first rule that matched, if any, and its action.
public struct AttentionOutcome: Hashable, Sendable {
    public var rule: AttentionRule?
    public var action: AttentionAction { rule?.action ?? AttentionAction() }

    public init(rule: AttentionRule? = nil) {
        self.rule = rule
    }
}

/// `[attention] rules`: an ordered list of lines, first match wins. Each line is conditions, then an action:
///
/// ```
/// mention user:me              boost 3
/// review requested:me          boost 2
/// mention team:acme/docs-eng   boost 2
/// mention team:acme/everyone   ignore
/// author bot:dependabot        ignore
/// label "blocker"              pin
/// repo acme/*-archive          ignore
/// agent blocked|asking         boost 3
/// ci branch:main               lower
/// ```
public struct AttentionRules: Hashable, Sendable {
    public var rules: [AttentionRule]
    public var problems: [AttentionRuleProblem]

    public init(rules: [AttentionRule] = [], problems: [AttentionRuleProblem] = []) {
        self.rules = rules
        self.problems = problems
    }

    /// Parses the configured lines. Blank lines and `#` comments are skipped (and keep their numbers).
    public init(lines: [String]) {
        var rules: [AttentionRule] = []
        var problems: [AttentionRuleProblem] = []
        for (index, text) in lines.enumerated() {
            switch Self.parse(text, line: index + 1) {
            case let .success(rule?): rules.append(rule)
            case .success(nil): continue
            case let .failure(problem): problems.append(problem)
            }
        }
        self.init(rules: rules, problems: problems)
    }

    /// The first rule that matches `item`.
    public func outcome(for item: AttentionItem, viewer: String?, now: Date) -> AttentionOutcome {
        AttentionOutcome(rule: rules.first { $0.matches(item, viewer: viewer, now: now) })
    }

    // MARK: Parsing

    /// Why a part of a line did not parse.
    struct RuleMessage: Error, ExpressibleByStringInterpolation {
        let text: String
        init(_ text: String) { self.text = text }
        init(stringLiteral value: String) { text = value }
        init(stringInterpolation: DefaultStringInterpolation) { text = stringInterpolation.description }
    }

    static let actionWords: Set<String> = ["boost", "lower", "ignore", "pin", "notify"]

    static let reasonWords: [String: Set<AttentionReason>] = [
        "mention": [.mentioned, .teamMention],
        "review": [.reviewRequested],
        "assigned": [.assigned],
        "ci": [.ciFailed],
        "mine": [.yourPR, .author],
        "changes": [.changesRequested],
        "threads": [.unresolvedThreads],
        "comment": [.comment],
        "subscribed": [.subscribed],
        "watching": [.watching],
    ]

    static let notYet: [String: String] = [
        "codeowner": "CODEOWNER is not a rule input yet",
        "quiet": "quiet hours are a setting, not a rule: [attention] quiet = \"22:00-08:00\"",
    ]

    static func parse(_ text: String, line: Int) -> Result<AttentionRule?, AttentionRuleProblem> {
        let words = words(text)
        guard !words.isEmpty else { return .success(nil) }
        func fail(_ message: String) -> Result<AttentionRule?, AttentionRuleProblem> {
            .failure(AttentionRuleProblem(line: line, message: message))
        }
        guard let actionStart = words.firstIndex(where: { actionWords.contains($0.lowercased()) }) else {
            if let note = notYet[words.last!.lowercased()] { return fail(note) }
            return fail("no action: end it with boost n, lower, ignore, pin or notify")
        }
        guard actionStart > 0 else { return fail("nothing to match before \(words[0]): add a condition, or any") }
        let action: AttentionAction
        switch parseAction(Array(words[actionStart...])) {
        case let .success(parsed): action = parsed
        case let .failure(message): return fail(message.text)
        }
        switch parseConditions(Array(words[..<actionStart])) {
        case let .success(conditions):
            return .success(AttentionRule(conditions: conditions, action: action, line: line, text: text))
        case let .failure(message): return fail(message.text)
        }
    }

    static func parseAction(_ words: [String]) -> Result<AttentionAction, RuleMessage> {
        var action = AttentionAction()
        var index = 0
        while index < words.count {
            let word = words[index].lowercased()
            index += 1
            switch word {
            case "boost":
                if index < words.count, let number = Int(words[index]) {
                    guard (1 ... 3).contains(number) else { return .failure("boost takes 1, 2 or 3") }
                    action.boost = number
                    index += 1
                } else {
                    action.boost = 1
                }
            case "lower": action.lower = true
            case "ignore": action.ignore = true
            case "pin": action.pin = true
            case "notify": action.notify = true
            default: return .failure("\(words[index - 1]) after the action: conditions come first")
            }
        }
        if action.ignore, action.boost > 0 || action.pin || action.notify || action.lower {
            return .failure("ignore hides the item: it takes no other action")
        }
        if action.lower, action.boost > 0 { return .failure("boost and lower together cancel out") }
        return .success(action)
    }

    static func parseConditions(_ words: [String]) -> Result<[AttentionCondition], RuleMessage> {
        var conditions: [AttentionCondition] = []
        var index = 0
        /// The next word, as the value of the keyword just read. An optional value (`agent`'s states) is not taken
        /// when the next word is a keyword of its own.
        func value(optional: Bool = false) -> String? {
            guard index < words.count else { return nil }
            let word = words[index]
            if optional, reasonWords[word.lowercased()] != nil || keywords.contains(word.lowercased()) { return nil }
            index += 1
            return word
        }
        while index < words.count {
            let word = words[index]
            let lower = word.lowercased()
            index += 1
            if let note = notYet[lower] { return .failure(RuleMessage(note)) }
            if let colon = word.firstIndex(of: ":"), !word.hasPrefix("\"") {
                switch qualifier(String(word[..<colon]).lowercased(), String(word[word.index(after: colon)...])) {
                case let .success(condition): conditions.append(condition)
                case let .failure(message): return .failure(message)
                }
                continue
            }
            if let reasons = reasonWords[lower] {
                conditions.append(.reasons(reasons))
                continue
            }
            switch lower {
            case "any", "*": conditions.append(.any)
            case "draft": conditions.append(.draft(true))
            case "ready": conditions.append(.draft(false))
            case "agent":
                var states: Set<AgentState> = []
                if let text = value(optional: true) {
                    for name in text.lowercased().split(separator: "|") {
                        guard let state = AgentState(rawValue: String(name)) else {
                            return .failure("agent \(name): expected blocked, asking, limited (or several with |)")
                        }
                        states.insert(state)
                    }
                }
                conditions.append(.agent(states))
            case "author":
                guard let text = value() else { return .failure("author needs a login, me, bot or human") }
                switch text.lowercased() {
                case "bot": conditions.append(.bot(nil))
                case "human": conditions.append(.human)
                case "team": return .failure("author team (the author is on your team) is not a rule input yet")
                default:
                    if text.contains(":") {
                        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
                        switch qualifier(parts[0].lowercased(), parts.count > 1 ? parts[1] : "") {
                        case let .success(condition): conditions.append(condition)
                        case let .failure(message): return .failure(message)
                        }
                    } else {
                        conditions.append(.author(unquoted(text).lowercased()))
                    }
                }
            case "label", "repo", "branch", "team", "kind", "size", "age", "turn", "reason", "user", "requested",
                 "bot":
                guard let text = value() else { return .failure("\(lower) needs a value") }
                switch qualifier(lower, text) {
                case let .success(condition): conditions.append(condition)
                case let .failure(message): return .failure(message)
                }
            default:
                return .failure("\(word) is not a rule input")
            }
        }
        return .success(conditions)
    }

    static let keywords: Set<String> = [
        "any", "draft", "ready", "agent", "author", "label", "repo", "branch", "team", "kind", "size", "age", "turn",
        "reason", "user", "requested", "bot",
    ]

    /// `key:value` (or `key value`).
    static func qualifier(_ key: String, _ raw: String) -> Result<AttentionCondition, RuleMessage> {
        let text = unquoted(raw)
        guard !text.isEmpty else { return .failure("\(key) needs a value") }
        switch key {
        case "user":
            guard text.lowercased() == "me" else { return .failure("user: takes me (a mention of you yourself)") }
            return .success(.mentionedDirectly)
        case "requested":
            switch text.lowercased() {
            case "me": return .success(.requestedDirectly)
            case "team": return .success(.requestedOfTeam)
            default: return .failure("requested: takes me or team")
            }
        case "team": return .success(text == "?" ? .teamUnknown : .team(text.lowercased()))
        case "author": return .success(.author(text.lowercased()))
        case "bot": return .success(.bot(text.lowercased()))
        case "label": return .success(.label(text))
        case "repo": return .success(.repo(text))
        case "branch": return .success(.branch(text))
        case "kind":
            var kinds: Set<AttentionItem.Kind> = []
            for name in text.lowercased().split(separator: "|") {
                guard let kind = AttentionItem.Kind(rawValue: String(name)) else {
                    return .failure("kind \(name): expected pr, issue, ci, release, discussion or agent")
                }
                kinds.insert(kind)
            }
            return .success(.kind(kinds))
        case "reason":
            var reasons: Set<AttentionReason> = []
            for name in text.split(separator: "|") {
                guard let reason = AttentionReason.allCases.first(where: {
                    $0.rawValue.lowercased() == name.lowercased()
                }) else {
                    return .failure("reason \(name) is not one heed knows")
                }
                reasons.insert(reason)
            }
            return .success(.reasons(reasons))
        case "size":
            guard let (greater, number) = comparison(text), let lines = Int(number) else {
                return .failure("size takes >n or <n (lines changed)")
            }
            return .success(.size(greater: greater, lines))
        case "age":
            guard let (greater, amount) = comparison(text), let seconds = duration(amount) else {
                return .failure("age takes >n or <n with m, h or d (age >7d)")
            }
            return .success(.age(greater: greater, seconds))
        case "turn":
            switch text.lowercased() {
            case "mine": return .success(.yourTurn(true))
            case "theirs": return .success(.yourTurn(false))
            default: return .failure("turn takes mine or theirs")
            }
        default:
            return .failure("\(key): is not a rule input")
        }
    }

    static func comparison(_ text: String) -> (Bool, String)? {
        guard let first = text.first, first == ">" || first == "<" else { return nil }
        return (first == ">", String(text.dropFirst()))
    }

    static func duration(_ text: String) -> TimeInterval? {
        guard let unit = text.last, let number = Double(text.dropLast()) else { return nil }
        return switch unit {
        case "m": number * 60
        case "h": number * 3600
        case "d": number * 86400
        default: nil
        }
    }

    static func unquoted(_ text: String) -> String {
        text.count >= 2 && text.hasPrefix("\"") && text.hasSuffix("\"") ? String(text.dropFirst().dropLast()) : text
    }

    /// The words of a line: split on spaces, a quoted string is one word (quotes kept), `#` starts a comment.
    static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quoted = false
        for char in text {
            if char == "\"" {
                quoted.toggle()
                current.append(char)
            } else if char == "#", !quoted {
                break
            } else if char.isWhitespace, !quoted {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}

/// Shell-style globs, case-insensitive: `*` any run, `?` one character, `a|b` either.
public enum Glob {
    public static func matches(_ pattern: String, _ text: String) -> Bool {
        pattern.split(separator: "|").contains { one(Array($0.lowercased()), Array(text.lowercased())) }
    }

    private static func one(_ pattern: [Character], _ text: [Character]) -> Bool {
        var (p, t) = (0, 0)
        var star: Int?
        var mark = 0
        while t < text.count {
            if p < pattern.count, pattern[p] == "?" || pattern[p] == text[t] {
                p += 1
                t += 1
            } else if p < pattern.count, pattern[p] == "*" {
                star = p
                mark = t
                p += 1
            } else if let star {
                p = star + 1
                mark += 1
                t = mark
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" {
            p += 1
        }
        return p == pattern.count
    }
}
