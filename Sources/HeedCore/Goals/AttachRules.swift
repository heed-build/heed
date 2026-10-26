import Foundation

/// A line of `goals/attach.rules` that heed could not read, by its number. A bad line is skipped; the others apply.
public struct AttachRuleProblem: Error, Hashable, Sendable, CustomStringConvertible {
    public var line: Int
    public var message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }

    public var description: String { "line \(line): \(message)" }
}

/// One rule: a verb, conditions that must all hold, and the goal it is about (`always`, `never`).
public struct AttachRule: Hashable, Sendable {
    public enum Verb: String, Hashable, Sendable, CaseIterable {
        /// Things like this go on the goal, without asking.
        case always
        /// Things like this never go on the goal.
        case never
        /// Things like this are left alone: no goal, no ask, not in Unassigned's suggestions.
        case ignore
    }

    /// What a condition looks at.
    public enum Field: String, Hashable, Sendable, CaseIterable {
        /// Any of its worktree folders (the full path).
        case worktree
        case branch
        /// Any of its repos, `org/name`.
        case repo
        /// A chat, by its title.
        case chat
        /// A session (not a chat), by its title.
        case session
        /// Either, by its title.
        case title
        /// Its first prompt.
        case prompt
    }

    public struct Condition: Hashable, Sendable {
        public var field: Field
        /// A glob: `*` any run of characters, `?` one, `a|b` either; case does not matter.
        public var pattern: String

        public init(_ field: Field, _ pattern: String) {
            self.field = field
            self.pattern = pattern
        }

        public func matches(_ subject: AttachSubject) -> Bool {
            switch field {
            case .worktree: subject.worktreePaths.contains { Glob.matches(pattern, $0) }
            case .branch: !subject.branch.isEmpty && Glob.matches(pattern, subject.branch)
            case .repo: subject.repos.contains { Glob.matches(pattern, $0) }
            case .chat: subject.kind == .chat && Glob.matches(pattern, subject.title)
            case .session: subject.kind != .chat && Glob.matches(pattern, subject.title)
            case .title: Glob.matches(pattern, subject.title)
            case .prompt: Glob.matches(pattern, subject.prompt)
            }
        }

        public var text: String { "\(field.rawValue):\(RuleWords.quote(pattern))" }
    }

    public var verb: Verb
    public var conditions: [Condition]
    public var goal: String?
    public var line: Int

    public init(_ verb: Verb, _ conditions: [Condition], goal: String? = nil, line: Int = 0) {
        self.verb = verb
        self.conditions = conditions
        self.goal = goal
        self.line = line
    }

    public func matches(_ subject: AttachSubject) -> Bool { conditions.allSatisfy { $0.matches(subject) } }

    /// The rule as a line of the file.
    public var text: String {
        ([verb.rawValue] + conditions.map(\.text) + (goal.map { ["->", $0] } ?? [])).joined(separator: " ")
    }
}

/// What the rules make of a thing, before any signal is looked at.
public struct AttachRuling: Hashable, Sendable {
    /// An `always` rule put it on this goal.
    public var goal: String?
    /// An `ignore` rule matched: leave it alone.
    public var ignored: Bool
    /// Goals `never` rules keep it off.
    public var excluded: Set<String>
    /// The rule that settled it (`always`, `ignore`).
    public var rule: AttachRule?

    public init(goal: String? = nil, ignored: Bool = false, excluded: Set<String> = [], rule: AttachRule? = nil) {
        self.goal = goal
        self.ignored = ignored
        self.excluded = excluded
        self.rule = rule
    }
}

/// `goals/attach.rules`: plain lines heed writes when you correct it (undo, n, a move, i) and you can edit. One rule
/// a line, `#` comments and blank lines skipped:
///
/// ```
/// never worktree:*/docs-nav* -> one-docs-nav-model
/// always branch:feature/anchors-* -> anchors-survive-page-moves
/// ignore chat:*
/// ignore repo:acme/sandbox title:"try *"
/// ```
///
/// Conditions are `field:glob`, all of them must hold; the goal is its slug, after `->`. Rules apply before signals,
/// in file order: the first `ignore` or `always` that matches settles it; every `never` that matches keeps its goal
/// out. A line heed cannot read is reported with its number and skipped, so a typo never stops attachment.
public struct AttachRules: Hashable, Sendable {
    public var rules: [AttachRule]
    public var problems: [AttachRuleProblem]

    public init(rules: [AttachRule] = [], problems: [AttachRuleProblem] = []) {
        self.rules = rules
        self.problems = problems
    }

    public init(text: String) {
        var rules: [AttachRule] = []
        var problems: [AttachRuleProblem] = []
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            switch Self.parse(line, line: index + 1) {
            case let .success(rule?): rules.append(rule)
            case .success(nil): continue
            case let .failure(problem): problems.append(problem)
            }
        }
        self.init(rules: rules, problems: problems)
    }

    /// The rules' ruling on `subject`. `goals` are the slugs that exist: a rule about a goal that is gone does nothing.
    public func ruling(_ subject: AttachSubject, goals: Set<String>? = nil) -> AttachRuling {
        var ruling = AttachRuling()
        for rule in rules where rule.matches(subject) {
            if let goal = rule.goal, let goals, !goals.contains(goal) { continue }
            switch rule.verb {
            case .never:
                if let goal = rule.goal { ruling.excluded.insert(goal) }
            case .ignore:
                ruling.ignored = true
                ruling.rule = rule
                return ruling
            case .always:
                guard let goal = rule.goal, !ruling.excluded.contains(goal) else { continue }
                ruling.goal = goal
                ruling.rule = rule
                return ruling
            }
        }
        return ruling
    }

    static func parse(_ raw: String, line: Int) -> Result<AttachRule?, AttachRuleProblem> {
        var text = raw
        if let hash = RuleWords.unquotedHash(in: text) { text = String(text[..<hash]) }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return .success(nil) }
        func problem(_ message: String) -> Result<AttachRule?, AttachRuleProblem> {
            .failure(AttachRuleProblem(line: line, message: message))
        }
        var goal: String?
        if let arrow = text.range(of: "->", options: .backwards) {
            goal = text[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            text = text[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            guard let name = goal, !name.isEmpty, !name.contains(" ") else {
                return problem("after -> comes one goal's slug")
            }
        }
        let words = RuleWords.words(text)
        guard let first = words.first else { return problem("a rule starts with always, never or ignore") }
        guard let verb = AttachRule.Verb(rawValue: first.lowercased()) else {
            return problem("\(first): a rule starts with always, never or ignore")
        }
        if verb == .ignore, goal != nil { return problem("ignore takes no goal") }
        if verb != .ignore, goal == nil { return problem("\(verb.rawValue) needs a goal: … -> <goal>") }
        var conditions: [AttachRule.Condition] = []
        for word in words.dropFirst() {
            guard let colon = word.firstIndex(of: ":") else {
                return problem("\(word): expected field:pattern, like branch:feature/x-*")
            }
            let name = word[..<colon].lowercased()
            guard let field = AttachRule.Field(rawValue: name) else {
                return problem("\(name): fields are " + AttachRule.Field.allCases.map(\.rawValue)
                    .joined(separator: ", "))
            }
            let pattern = RuleWords.unquote(String(word[word.index(after: colon)...]))
            guard !pattern.isEmpty else { return problem("\(name): has no pattern") }
            conditions.append(AttachRule.Condition(field, pattern))
        }
        guard !conditions.isEmpty else { return problem("\(verb.rawValue) needs at least one field:pattern") }
        return .success(AttachRule(verb, conditions, goal: goal, line: line))
    }

    // MARK: Learning from corrections

    /// The conditions that say "things like this one": its worktree's family, else its branch's, else, for a chat,
    /// chats (in its repo, when it has one), else its title.
    public static func likeThis(_ subject: AttachSubject) -> [AttachRule.Condition] {
        if subject.kind == .chat {
            return [AttachRule.Condition(.chat, "*")] + subject.repos.prefix(1).map { AttachRule.Condition(.repo, $0) }
        }
        if let name = subject.worktreeNames.first, let prefix = BranchFamily.prefix(name) {
            return [AttachRule.Condition(.worktree, "*/" + prefix + "*")]
        }
        if !AttachSignals.defaultBranches.contains(subject.branch.lowercased()),
           let prefix = BranchFamily.prefix(subject.branch)
        {
            return [AttachRule.Condition(.branch, prefix + "*")]
        }
        return [AttachRule.Condition(.title, subject.title)]
    }

    /// `never <like this> -> goal`: after an undo, an n, or moving it off `goal`.
    public static func never(_ subject: AttachSubject, goal: String) -> AttachRule {
        AttachRule(.never, likeThis(subject), goal: goal)
    }

    /// `ignore <like this>`: after an i.
    public static func ignore(_ subject: AttachSubject) -> AttachRule {
        AttachRule(.ignore, likeThis(subject))
    }
}

/// Words of a rule line, and the quoting its patterns may have. Matching is `Glob`'s (Attention rules' too).
enum RuleWords {
    /// Words split on spaces, except inside `"…"`.
    static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" { quoted.toggle() }
            if character == " " || character == "\t", !quoted {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    static func unquote(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        return String(text.dropFirst().dropLast())
    }

    /// A pattern as a rule writes it: quoted when it has a space, a `#` or `->`.
    static func quote(_ pattern: String) -> String {
        let clean = pattern.replacingOccurrences(of: "\"", with: "")
        return clean.contains(" ") || clean.contains("#") || clean.contains("->") ? "\"\(clean)\"" : clean
    }

    /// The first `#` outside quotes: where a comment starts.
    static func unquotedHash(in text: String) -> String.Index? {
        var quoted = false
        for index in text.indices {
            if text[index] == "\"" { quoted.toggle() }
            if text[index] == "#", !quoted { return index }
        }
        return nil
    }
}
