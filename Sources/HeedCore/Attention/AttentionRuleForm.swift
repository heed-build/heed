import Foundation

/// A reason word of the rule grammar (`mention`, `review`, `ci`, ...): the reasons it stands for, and a few words.
public enum AttentionReasonWord: String, CaseIterable, Hashable, Sendable {
    case mention, review, assigned, ci, mine, changes, threads, mergeable, comment, subscribed, watching, proposals
    case attach

    public var reasons: Set<AttentionReason> { AttentionRules.reasonWords[rawValue] ?? [] }

    /// What the picker shows.
    public var title: String {
        switch self {
        case .mention: "You or a team mentioned"
        case .review: "Review requested"
        case .assigned: "Assigned to you"
        case .ci: "CI failed"
        case .mine: "Your PR or thread"
        case .changes: "Changes requested"
        case .threads: "Unresolved threads"
        case .mergeable: "Ready to merge"
        case .comment: "New comments"
        case .subscribed: "Subscribed"
        case .watching: "Watched repo's issues"
        case .proposals: "Goal proposals"
        case .attach: "Which goal? questions"
        }
    }

    /// The items it picks, as a sentence names them.
    var noun: String {
        switch self {
        case .mention: "mentions of you or your teams"
        case .review: "review requests"
        case .assigned: "items assigned to you"
        case .ci: "CI failures"
        case .mine: "your PRs and threads"
        case .changes: "PRs with changes requested"
        case .threads: "PRs with unresolved threads"
        case .mergeable: "PRs ready to merge"
        case .comment: "new comments"
        case .subscribed: "threads you are subscribed to"
        case .watching: "issues in repos you watch"
        case .proposals: "goal proposals"
        case .attach: "which-goal questions"
        }
    }
}

/// One condition of a rule as the editor builds it: a choice per part of the grammar, a value only where the grammar
/// needs one. Each renders to the rule syntax and reads back from what the parser makes of a line.
public enum AttentionClause: Hashable, Sendable {
    public enum Author: Hashable, Sendable {
        case me, login(String), anyBot, bot(String), human
    }

    public enum AgeUnit: String, CaseIterable, Hashable, Sendable {
        case m, h, d

        public var seconds: TimeInterval {
            switch self {
            case .m: 60
            case .h: 3600
            case .d: 86400
            }
        }

        public var title: String {
            switch self {
            case .m: "minutes"
            case .h: "hours"
            case .d: "days"
            }
        }
    }

    case reason(AttentionReasonWord)
    /// `reason a|b`: heed's reasons by name.
    case reasons(Set<AttentionReason>)
    /// `user:me`
    case mentionedMe
    /// `team:glob`
    case team(String)
    /// `team:?`
    case teamUnknown
    /// `requested:me` (true) or `requested:team` (false).
    case requestedOfMe(Bool)
    case author(Author)
    case label(String)
    case repo(String)
    case branch(String)
    /// Empty: any agent.
    case agent(Set<AgentState>)
    case kind(Set<AttentionItem.Kind>)
    /// `draft` (true) or `ready` (false).
    case draft(Bool)
    case size(greater: Bool, lines: Int)
    case age(greater: Bool, amount: Int, unit: AgeUnit)
    /// `turn mine` (true) or `turn theirs` (false).
    case turn(mine: Bool)

    /// The kinds of condition, in the order the "add a condition" menu lists them.
    public enum Category: String, CaseIterable, Hashable, Sendable {
        case reason, repo, author, label, team, requested, mentionedMe, agent, kind, draft, size, age, turn, branch
        case reasons

        public var title: String {
            switch self {
            case .reason: "Why it is there"
            case .repo: "Repo"
            case .author: "Opened by"
            case .label: "Label"
            case .team: "Team"
            case .requested: "Review asked of"
            case .mentionedMe: "You yourself mentioned"
            case .agent: "Agent state"
            case .kind: "What it is"
            case .draft: "Draft or ready"
            case .size: "Lines changed"
            case .age: "Last update"
            case .turn: "Whose turn"
            case .branch: "CI branch"
            case .reasons: "heed reason (by name)"
            }
        }

        /// A clause of this kind to start from; values to fill in are empty.
        public var initial: AttentionClause {
            switch self {
            case .reason: .reason(.mention)
            case .repo: .repo("")
            case .author: .author(.anyBot)
            case .label: .label("")
            case .team: .team("")
            case .requested: .requestedOfMe(true)
            case .mentionedMe: .mentionedMe
            case .agent: .agent([.blocked, .asking])
            case .kind: .kind([.pr])
            case .draft: .draft(true)
            case .size: .size(greater: true, lines: 500)
            case .age: .age(greater: true, amount: 7, unit: .d)
            case .turn: .turn(mine: true)
            case .branch: .branch("main")
            case .reasons: .reasons([])
            }
        }
    }

    public var category: Category {
        switch self {
        case .reason: .reason
        case .reasons: .reasons
        case .mentionedMe: .mentionedMe
        case .team, .teamUnknown: .team
        case .requestedOfMe: .requested
        case .author: .author
        case .label: .label
        case .repo: .repo
        case .branch: .branch
        case .agent: .agent
        case .kind: .kind
        case .draft: .draft
        case .size: .size
        case .age: .age
        case .turn: .turn
        }
    }

    /// The clause in the rule syntax: `team:acme/docs-eng`, `label "needs review"`, `age >7d`.
    public var text: String {
        switch self {
        case let .reason(word): word.rawValue
        case let .reasons(reasons): "reason " + reasons.sorted().map(\.rawValue).joined(separator: "|")
        case .mentionedMe: "user:me"
        case let .team(glob): "team:\(glob)"
        case .teamUnknown: "team:?"
        case let .requestedOfMe(me): me ? "requested:me" : "requested:team"
        case let .author(author):
            switch author {
            case .me: "author me"
            case let .login(login): "author \(login)"
            case .anyBot: "author bot"
            case let .bot(name): "author bot:\(name)"
            case .human: "author human"
            }
        case let .label(label): "label \(Self.quotedIfNeeded(label))"
        case let .repo(glob): "repo \(glob)"
        case let .branch(glob): "branch:\(glob)"
        case let .agent(states):
            states.isEmpty ? "agent"
                : "agent " + AgentState.allCases.filter(states.contains).map(\.rawValue).joined(separator: "|")
        case let .kind(kinds): "kind " + Self.kindOrder.filter(kinds.contains).map(\.rawValue).joined(separator: "|")
        case let .draft(draft): draft ? "draft" : "ready"
        case let .size(greater, lines): "size \(greater ? ">" : "<")\(lines)"
        case let .age(greater, amount, unit): "age \(greater ? ">" : "<")\(amount)\(unit.rawValue)"
        case let .turn(mine): mine ? "turn mine" : "turn theirs"
        }
    }

    /// The kinds of item a rule can name, in the order the grammar lists them.
    public static let kindOrder: [AttentionItem.Kind] = [.pr, .issue, .ci, .release, .discussion, .agent, .goal]

    static func quotedIfNeeded(_ text: String) -> String {
        let plain = !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber || "-_./*?|".contains($0) }
        return plain ? text : "\"\(text)\""
    }

    /// The clause the parser's condition came from, or nil when the editor has none for it (`any` is no clause: a
    /// rule with no clauses matches everything).
    init?(_ condition: AttentionCondition) {
        switch condition {
        case let .reasons(reasons):
            self = AttentionReasonWord.allCases.first { $0.reasons == reasons }.map { .reason($0) } ?? .reasons(reasons)
        case .mentionedDirectly: self = .mentionedMe
        case let .team(glob): self = .team(glob)
        case .teamUnknown: self = .teamUnknown
        case .requestedDirectly: self = .requestedOfMe(true)
        case .requestedOfTeam: self = .requestedOfMe(false)
        case let .author(login): self = .author(login == "me" ? .me : .login(login))
        case let .bot(name): self = .author(name.map { .bot($0) } ?? .anyBot)
        case .human: self = .author(.human)
        case let .label(glob): self = .label(glob)
        case let .repo(glob): self = .repo(glob)
        case let .branch(glob): self = .branch(glob)
        case let .agent(states): self = .agent(states)
        case let .kind(kinds): self = .kind(kinds)
        case let .draft(draft): self = .draft(draft)
        case let .size(greater, lines): self = .size(greater: greater, lines: lines)
        case let .age(greater, seconds):
            guard let unit = AgeUnit.allCases.reversed().first(where: {
                seconds >= 0 && seconds.truncatingRemainder(dividingBy: $0.seconds) == 0
            }), let amount = Int(exactly: seconds / unit.seconds) else { return nil }
            self = .age(greater: greater, amount: amount, unit: unit)
        case let .yourTurn(mine): self = .turn(mine: mine)
        case .any: return nil
        }
    }

    /// What is wrong with the clause's own value, as a short sentence; nil when it is fine.
    public var problem: String? {
        switch self {
        case .reason, .mentionedMe, .teamUnknown, .requestedOfMe, .agent, .draft, .turn: nil
        case let .reasons(reasons): reasons.isEmpty ? "Pick at least one reason." : nil
        case let .kind(kinds): kinds.isEmpty ? "Pick at least one kind." : nil
        case let .team(glob): Self.globProblem(glob, what: "A team", slashed: "acme/docs-eng, acme/docs-*")
        case let .repo(glob): Self.globProblem(glob, what: "A repo", slashed: "acme/api, acme/*")
        case let .branch(glob): Self.globProblem(glob, what: "A branch")
        case let .label(label):
            switch true {
            case label.trimmingCharacters(in: .whitespaces).isEmpty: "A label needs a name."
            case label.contains("\""): "A label cannot contain a quote (\")."
            case label != label.trimmingCharacters(in: .whitespaces): "No spaces around the label."
            default: Self.alternativesProblem(label)
            }
        case let .author(author):
            switch author {
            case .me, .anyBot, .human: nil
            case let .login(login):
                if ["me", "bot", "human", "team"].contains(login.lowercased()) {
                    "\(login) means something else here: pick it from the menu."
                } else {
                    Self.globProblem(login, what: "A login", colon: false)
                }
            case let .bot(name): Self.globProblem(name, what: "A bot's login", colon: false)
            }
        case let .size(greater, lines):
            switch true {
            case lines < 0: "Lines changed cannot be negative."
            case !greater && lines == 0: "Nothing has fewer than 0 lines changed."
            default: nil
            }
        case let .age(_, amount, _): amount < 1 ? "Give an age of at least 1." : nil
        }
    }

    /// A glob value: one word, no quotes, no comment mark, no empty alternative; with `slashed` an example, each
    /// alternative is `org/name` shaped (or a `*` that can stand for the slash).
    static func globProblem(_ text: String, what: String, slashed: String? = nil, colon: Bool = true) -> String? {
        if text.isEmpty { return "\(what) needs a value." }
        if text.contains(where: \.isWhitespace) { return "\(what) has no spaces." }
        if text.contains("\"") { return "\(what) cannot contain a quote (\")." }
        if text.contains("#") { return "\(what) cannot contain # (it starts a comment)." }
        if !colon, text.contains(":") { return "\(what) cannot contain :." }
        if let problem = alternativesProblem(text) { return problem }
        if let slashed, text.split(separator: "|").contains(where: { !$0.contains("/") && !$0.contains("*") }) {
            return "\(what) is org/name (\(slashed)); * matches any part."
        }
        return nil
    }

    static func alternativesProblem(_ text: String) -> String? {
        text.split(separator: "|", omittingEmptySubsequences: false).contains { $0.isEmpty }
            ? "An empty choice around |: write a|b." : nil
    }
}

/// A rule as the editor builds it: clauses that must all hold (none: everything), then an action made of a weight and
/// two switches, so every combination the editor offers is one the grammar accepts.
public struct AttentionRuleForm: Hashable, Sendable {
    public enum Weight: String, CaseIterable, Hashable, Sendable {
        case boost3, boost2, boost1, unchanged, lower, ignore

        public var title: String {
            switch self {
            case .boost3: "Boost 3"
            case .boost2: "Boost 2"
            case .boost1: "Boost 1"
            case .unchanged: "Keep weight"
            case .lower: "Lower"
            case .ignore: "Mute (ignore)"
            }
        }

        var boost: Int {
            switch self {
            case .boost3: 3
            case .boost2: 2
            case .boost1: 1
            default: 0
            }
        }
    }

    public var clauses: [AttentionClause]
    public var weight: Weight
    public var pin: Bool
    public var notify: Bool
    /// A `# comment` the line ended with, kept when the rule is edited.
    public var comment: String?

    public init(
        clauses: [AttentionClause] = [], weight: Weight = .boost1, pin: Bool = false, notify: Bool = false,
        comment: String? = nil
    ) {
        self.clauses = clauses
        self.weight = weight
        self.pin = pin
        self.notify = notify
        self.comment = comment
    }

    public var action: AttentionAction {
        AttentionAction(
            boost: weight.boost, lower: weight == .lower, ignore: weight == .ignore, pin: pin && weight != .ignore,
            notify: notify && weight != .ignore
        )
    }

    /// The rule in the config's syntax: `mention team:acme/docs-eng boost 2`, `any lower`.
    public var line: String {
        let match = clauses.isEmpty ? "any" : clauses.map(\.text).joined(separator: " ")
        let action = action.text
        let body = action.isEmpty ? match : "\(match) \(action)"
        return comment.map { "\(body)  # \($0)" } ?? body
    }

    /// The parser's reading of `line`.
    public var rule: AttentionRule? {
        if case let .success(rule?) = AttentionRules.parse(line, line: 1) { return rule }
        return nil
    }

    // MARK: Validation

    /// A problem, with the clause it is about (nil: the rule as a whole).
    public struct Problem: Hashable, Sendable {
        public var clause: Int?
        public var message: String
    }

    /// Everything wrong with the rule; empty when it can be saved.
    public var problems: [Problem] {
        var problems = clauses.enumerated().compactMap { index, clause in
            clause.problem.map { Problem(clause: index, message: $0) }
        }
        if weight == .unchanged, !pin, !notify {
            problems.append(Problem(clause: nil, message: "Pick what to do: a weight, pin or notify."))
        }
        for (index, clause) in clauses.enumerated() {
            if clauses[..<index].contains(clause) {
                problems.append(Problem(clause: index, message: "This condition is there already."))
            } else if let earlier = clauses[..<index].first(where: { Self.contradicts($0, clause) }) {
                problems.append(Problem(
                    clause: index, message: "Nothing can be \(earlier.text) and \(clause.text): it would never match."
                ))
            }
        }
        if problems.isEmpty, rule == nil {
            problems.append(Problem(clause: nil, message: "heed cannot read this rule back: \(line)"))
        }
        return problems
    }

    public var isValid: Bool { problems.isEmpty }

    /// Two clauses no item can meet at once.
    static func contradicts(_ lhs: AttentionClause, _ rhs: AttentionClause) -> Bool {
        switch (lhs, rhs) {
        case let (.draft(a), .draft(b)): a != b
        case let (.turn(a), .turn(b)): a != b
        case let (.requestedOfMe(a), .requestedOfMe(b)): a != b
        case let (.kind(a), .kind(b)): a.isDisjoint(with: b)
        case let (.author(a), .author(b)):
            switch (a, b) {
            case (.human, .anyBot), (.anyBot, .human), (.human, .bot), (.bot, .human): true
            default: false
            }
        case let (.size(g1, n1), .size(g2, n2)) where g1 != g2:
            g1 ? n2 <= n1 + 1 : n1 <= n2 + 1
        case let (.age(g1, a1, u1), .age(g2, a2, u2)) where g1 != g2:
            g1 ? Double(a2) * u2.seconds <= Double(a1) * u1.seconds
                : Double(a1) * u1.seconds <= Double(a2) * u2.seconds
        default: false
        }
    }

    // MARK: Reading a line

    /// What the editor makes of one configured line.
    public enum Reading: Hashable, Sendable {
        /// A rule the editor can show and edit.
        case form(AttentionRuleForm)
        /// A `# comment` line, kept as it is.
        case comment(String)
        case blank
        /// A line the editor cannot build: shown as written, edited only in config.toml.
        case readOnly(String)
    }

    /// Reads a configured line. A line reads as a form only if the form writes it back to a rule that does exactly
    /// what the line does; anything else is read-only, never dropped.
    public static func read(_ text: String) -> Reading {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .blank }
        if AttentionRules.words(trimmed).isEmpty { return .comment(trimmed) }
        switch AttentionRules.parse(trimmed, line: 1) {
        case let .failure(problem): return .readOnly(problem.message)
        case .success(nil): return .blank
        case let .success(rule?):
            var clauses: [AttentionClause] = []
            for condition in rule.conditions where condition != .any {
                guard let clause = AttentionClause(condition) else {
                    return .readOnly("the editor has no control for \(rule.match)")
                }
                clauses.append(clause)
            }
            let action = rule.action
            let weight: Weight = action.ignore ? .ignore : action.lower ? .lower
                : action.boost == 3 ? .boost3 : action.boost == 2 ? .boost2 : action.boost == 1 ? .boost1 : .unchanged
            let form = AttentionRuleForm(
                clauses: clauses, weight: weight, pin: action.pin, notify: action.notify, comment: comment(of: trimmed)
            )
            guard let back = form.rule, Self.same(back, rule) else {
                return .readOnly("the editor cannot write \(rule.match) back exactly")
            }
            return .form(form)
        }
    }

    /// Two rules that match the same items and do the same to them (`any` and order of conditions aside).
    public static func same(_ lhs: AttentionRule, _ rhs: AttentionRule) -> Bool {
        lhs.action == rhs.action && conditionSet(lhs) == conditionSet(rhs)
    }

    static func conditionSet(_ rule: AttentionRule) -> Set<AttentionCondition> {
        Set(rule.conditions.filter { $0 != .any })
    }

    /// The text after an unquoted `#`, trimmed; nil when there is none.
    static func comment(of text: String) -> String? {
        var quoted = false
        for index in text.indices {
            if text[index] == "\"" { quoted.toggle() }
            if text[index] == "#", !quoted {
                let rest = text[text.index(after: index)...].trimmingCharacters(in: .whitespaces)
                return rest.isEmpty ? nil : rest
            }
        }
        return nil
    }

    // MARK: In plain words

    /// What the rule does, as a sentence: "Mute review requests in acme/api."
    public var summary: String {
        var subject: [String] = []
        var qualifiers: [String] = []
        for clause in clauses {
            switch clause {
            case let .reason(word):
                subject.append(word == .mention && clauses.contains(.mentionedMe) ? "mentions of you" : word.noun)
            case let .reasons(reasons):
                qualifiers.append("there because of " + Self.or(reasons.sorted().map(\.text)))
            case .mentionedMe:
                if !clauses.contains(.reason(.mention)) { qualifiers.append("where you yourself were mentioned") }
            case let .team(glob): qualifiers.append("through team \(Self.or(glob))")
            case .teamUnknown: qualifiers.append("through a team heed could not work out")
            case let .requestedOfMe(me): qualifiers.append(me ? "asked of you" : "asked of one of your teams")
            case let .author(author):
                switch author {
                case .me: qualifiers.append("opened by you")
                case let .login(login): qualifiers.append("opened by \(Self.or(login))")
                case .anyBot: qualifiers.append("opened by a bot")
                case let .bot(name): qualifiers.append("opened by the bot \(Self.or(name))")
                case .human: qualifiers.append("opened by a person")
                }
            case let .label(label): qualifiers.append("labelled \(Self.or(label))")
            case let .repo(glob): qualifiers.append("in \(Self.or(glob))")
            case let .branch(glob): qualifiers.append("on branch \(Self.or(glob))")
            case let .agent(states):
                subject.append(states.isEmpty ? "agents"
                    : "agents that are " + Self.or(AgentState.allCases.filter(states.contains).map(\.rawValue)))
            case let .kind(kinds):
                subject.append(Self.or(AttentionClause.kindOrder.filter(kinds.contains).map(Self.plural)))
            case let .draft(draft): qualifiers.append(draft ? "that are drafts" : "that are ready for review")
            case let .size(greater, lines):
                qualifiers.append("with \(greater ? "more" : "fewer") than \(lines) lines changed")
            case let .age(greater, amount, unit):
                let span = "\(amount) \(amount == 1 ? String(unit.title.dropLast()) : unit.title)"
                qualifiers.append(greater ? "not updated for over \(span)" : "updated in the last \(span)")
            case let .turn(mine): qualifiers.append(mine ? "where it is your turn" : "waiting on someone else")
            }
        }
        let noun = subject.isEmpty ? (clauses.isEmpty ? "everything" : "items") : subject
            .joined(separator: " that are also ")
        let verb: String
        var tail: [String] = []
        switch weight {
        case .ignore: verb = "Mute"
        case .lower: verb = "Lower"
        case .boost3, .boost2, .boost1: verb = "Boost"
            tail.append("by \(weight.boost)")
        case .unchanged: verb = pin ? "Pin" : "Notify about"
        }
        var sentence = ([verb, noun] + qualifiers).joined(separator: " ")
        if !tail.isEmpty { sentence += " " + tail.joined(separator: " ") }
        if weight != .ignore {
            if pin, weight != .unchanged { sentence += ", pinned to the top" }
            if notify, weight != .unchanged || pin {
                sentence += ", and notify me"
            } else if weight == .boost3, !notify {
                sentence += " (boost 3 notifies)"
            }
        }
        return sentence + "."
    }

    static func plural(_ kind: AttentionItem.Kind) -> String {
        switch kind {
        case .pr: "PRs"
        case .issue: "issues"
        case .ci: "CI runs"
        case .release: "releases"
        case .discussion: "discussions"
        case .agent: "agents"
        case .goal: "goals"
        case .other: "other items"
        }
    }

    /// `a|b|c` → `a, b or c`.
    static func or(_ glob: String) -> String { or(glob.split(separator: "|").map(String.init)) }

    static func or(_ words: [String]) -> String {
        guard words.count > 1 else { return words.first ?? "" }
        return words.dropLast().joined(separator: ", ") + " or " + words.last!
    }

    // MARK: Against the items

    /// How many of `items` the rule matches on its own, whatever comes before it.
    public func matchCount(in items: [AttentionItem], viewer: String?, now: Date) -> Int {
        guard let rule else { return 0 }
        return items.count(where: { rule.matches($0, viewer: viewer, now: now) })
    }
}

/// Values the editor offers for its text fields: what heed has seen, so a value is picked rather than typed.
public struct AttentionRuleSuggestions: Hashable, Sendable {
    public var repos: [String]
    public var teams: [String]
    public var labels: [String]
    public var authors: [String]
    public var bots: [String]
    public var branches: [String]

    public init(
        repos: [String] = [], teams: [String] = [], labels: [String] = [], authors: [String] = [],
        bots: [String] = [], branches: [String] = []
    ) {
        self.repos = repos
        self.teams = teams
        self.labels = labels
        self.authors = authors
        self.bots = bots
        self.branches = branches
    }

    /// From the items of the last 30 days and the repos heed knows: each list sorted and without repeats; repos
    /// also offer `org/*` per org.
    public static func from(items: [AttentionItem], repos: [Repo]) -> AttentionRuleSuggestions {
        func sorted(_ values: some Sequence<String>) -> [String] {
            Array(Set(values.filter { !$0.isEmpty })).sorted { $0.lowercased() < $1.lowercased() }
        }
        let slugs = repos.map(\.slug) + items.compactMap(\.repo?.slug)
        let orgs = Set(slugs.compactMap { $0.split(separator: "/").first.map { "\($0)/*" } })
        let isBot = { (item: AttentionItem) in item.authorIsBot || item.author?.hasSuffix("[bot]") == true }
        return AttentionRuleSuggestions(
            repos: sorted(slugs) + orgs.sorted(),
            teams: sorted(items.flatMap(\.teams)),
            labels: sorted(items.flatMap(\.labels)),
            authors: sorted(items.filter { !isBot($0) }.compactMap(\.author)),
            bots: sorted(items.filter(isBot).compactMap(\.author).map(AttentionRule.login)),
            branches: sorted(items.compactMap(\.branch))
        )
    }
}
