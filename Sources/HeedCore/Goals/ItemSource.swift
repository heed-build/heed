import Foundation

/// A GitHub query a goal's items come from: open PRs in a repo, issues with a label, PRs that ask for your review, a
/// milestone, any search. heed keeps one item per PR or issue that matches, adds the new ones, gives the ones that
/// closed or merged their evidence, and marks the ones that stopped matching; it never deletes one. What done means
/// for each item is the source's `Rule`.
public struct ItemSource: Hashable, Sendable, Codable, Identifiable {
    /// What an item of the source must show to be done. PRs: merged, closed (merged or not), reviewed by you
    /// (approved, changes requested or commented), green (every check passing). Issues: closed, whatever the rule.
    /// Whatever the rule, a PR or issue that closed has nothing left to do: its card goes to Done too.
    public enum Rule: String, Hashable, Sendable, Codable, CaseIterable {
        case merged, closed, reviewed, green

        /// `reviewed by you`, for the done-when line and the overview.
        public var phrase: String {
            switch self {
            case .merged: "merged"
            case .closed: "closed"
            case .reviewed: "reviewed by you"
            case .green: "green"
            }
        }

        /// `reviewed`, for the progress count (`7 of 12 reviewed`).
        public var word: String { self == .reviewed ? "reviewed" : rawValue }

        /// Whether the rule means something for what the source finds: PR rules need PRs.
        public func fits(_ what: What) -> Bool { what != .issues || self == .closed }
    }

    /// What the query finds.
    public enum What: String, Hashable, Sendable, Codable {
        case pulls, issues, both

        /// `PR`, `issue`, `PR or issue`.
        public var noun: String {
            switch self {
            case .pulls: "PR"
            case .issues: "issue"
            case .both: "PR or issue"
            }
        }
    }

    /// Who added it: you (the overview, `:goal.source.add`), heed's proposal you said yes to, or an agent through
    /// `heed goal source add`.
    public enum Origin: String, Hashable, Sendable, Codable {
        case you, proposal, agent
    }

    /// `s1`, `s2`…: unique in its goal, never reused.
    public var id: String
    /// The GitHub search it runs (`is:pr is:open repo:acme/web`).
    public var query: String
    /// What it is, in words (`open PRs in acme/web`).
    public var label: String
    public var rule: Rule
    public var origin: Origin
    public var addedAt: Date

    public init(id: String = "", query: String, label: String, rule: Rule, origin: Origin = .you, addedAt: Date) {
        self.id = id
        self.query = query
        self.label = label
        self.rule = rule
        self.origin = origin
        self.addedAt = addedAt
    }

    public var what: What { ItemSourceQuery.what(query) }

    /// Its line in GOAL.md's Done when: `All open PRs in acme/web reviewed by you`.
    public var criterion: String { Self.criterion(label: label, what: what, rule: rule) }

    static func criterion(label: String, what: What, rule: Rule) -> String {
        "All \(label) \(what == .issues ? Rule.closed.phrase : rule.phrase)"
    }
}

/// A goal's sources and what heed proposes, kept per goal in `goal_sources`.
public struct GoalSourceState: Hashable, Sendable, Codable {
    public var sources: [ItemSource]
    /// A source heed read in the goal and proposes, waiting for a yes (`goal.source.accept`) or a no.
    public var proposal: SourceProposal?
    /// Queries said no to: heed does not propose them again.
    public var dismissed: [String]
    /// The GOAL.md version heed last looked at for a source to propose.
    public var checked: Int?
    public var syncedAt: Date?
    /// What went wrong on the last sync, in a line; nil when it went well.
    public var error: String?
    /// The number the next source's id takes.
    public var next: Int

    public init(
        sources: [ItemSource] = [], proposal: SourceProposal? = nil, dismissed: [String] = [], checked: Int? = nil,
        syncedAt: Date? = nil, error: String? = nil, next: Int = 1
    ) {
        self.sources = sources
        self.proposal = proposal
        self.dismissed = dismissed
        self.checked = checked
        self.syncedAt = syncedAt
        self.error = error
        self.next = next
    }

    public static let empty = GoalSourceState()

    public func source(_ id: String) -> ItemSource? { sources.first { $0.id == id } }
}

/// A source heed proposes for a goal that reads like a set over GitHub ("review all open PRs in acme/web"): why, and
/// whether a model or the words alone found it.
public struct SourceProposal: Hashable, Sendable, Codable {
    public enum By: String, Hashable, Sendable, Codable {
        case model, words
    }

    public var source: ItemSource
    /// The goal's words it came from (`review all open PRs in acme/web`).
    public var because: String
    public var by: By

    public init(source: ItemSource, because: String, by: By) {
        self.source = source
        self.because = because
        self.by = by
    }
}

/// What a source's items are on the goal, for its line in the overview: `7 of 12 reviewed · 1 left`.
public struct SourceProgress: Hashable, Sendable {
    /// Items still in the source, and the done ones of them (a PR that merged or closed counts, whatever the rule).
    public var done: Int
    public var total: Int
    /// Items that stopped matching while still open: kept on the goal, marked, not counted.
    public var left: Int

    public var complete: Bool { total > 0 && done == total }

    /// `7 of 12 reviewed · 1 left`, `none yet`.
    public func text(_ rule: ItemSource.Rule, what: ItemSource.What) -> String {
        guard total > 0 || left > 0 else { return "nothing matches yet" }
        let word = what == .issues ? ItemSource.Rule.closed.word : rule.word
        return "\(done) of \(total) \(word)" + (left > 0 ? " · \(left) left the source" : "")
    }

    public static func of(_ source: ItemSource, items: [GoalItem], evidence: [GoalEvidence]) -> SourceProgress {
        let mine = items.filter { $0.sourced?.source == source.id }
        let open = mine.filter { $0.sourced?.left == nil }
        return SourceProgress(
            done: open.count { Board.column($0, evidence: evidence) == .done }, total: open.count,
            left: mine.count - open.count
        )
    }
}

/// `:goal.source.add` and `heed goal source add` read a source from a few words or a GitHub search.
public enum ItemSourceQuery {
    public struct Parsed: Hashable, Sendable {
        public var query: String
        public var label: String
        /// The rule a source like this is done by unless you say otherwise.
        public var rule: ItemSource.Rule
    }

    public struct Problem: Error, Hashable, Sendable, CustomStringConvertible {
        public var description: String
    }

    public static let usage = "prs <org/repo>, issues <org/repo>, label <name> [org/repo], reviews [org/repo], "
        + "milestone <title> <org/repo>, or a GitHub search (is:pr is:open repo:org/repo)"

    /// A source from `prs acme/web`, `issues acme/web`, `label "good first issue" acme/web`, `reviews`,
    /// `milestone v2 acme/web`, a repo's PRs or issues URL, or a GitHub search with a qualifier in it. `repo` fills in
    /// for words that name none (the goal's sessions' repo).
    public static func parse(_ text: String, repo fallback: String? = nil) throws -> Parsed {
        let words = tokens(text)
        guard let first = words.first else { throw Problem(description: "a source needs words: \(usage)") }
        if let url = fromURL(first), words.count == 1 { return url }
        let repo = words.dropFirst().last(where: { TrackerCheck.slug($0) != nil })
        let rest = words.dropFirst().filter { $0 != repo }
        func needRepo(_ kind: String) throws -> String {
            guard let found = repo ?? fallback else {
                throw Problem(description: "\(kind) needs a repo: \(kind) <org/repo>")
            }
            return found
        }
        switch first.lowercased() {
        case "prs", "pulls", "pull-requests", "pr":
            guard rest.isEmpty else { break }
            let repo = try needRepo(first)
            return Parsed(query: "is:pr is:open repo:\(repo)", label: "open PRs in \(repo)", rule: .merged)
        case "issues", "issue":
            guard rest.isEmpty else { break }
            let repo = try needRepo(first)
            return Parsed(query: "is:issue is:open repo:\(repo)", label: "open issues in \(repo)", rule: .closed)
        case "label", "labelled", "labeled":
            guard !rest.isEmpty else { throw Problem(description: "label needs a name: label <name> [org/repo]") }
            let name = rest.joined(separator: " ")
            let scope = (repo ?? fallback).map { " repo:\($0)" } ?? ""
            return Parsed(
                query: "is:open label:\(quoted(name))\(scope)",
                label: "open items labelled \(name)" + ((repo ?? fallback).map { " in \($0)" } ?? ""), rule: .closed
            )
        case "reviews", "review-requests", "review-requested", "requests":
            guard rest.isEmpty else { break }
            let scope = repo.map { " repo:\($0)" } ?? ""
            return Parsed(
                query: "is:pr is:open review-requested:@me\(scope)",
                label: "PRs that ask for your review" + (repo.map { " in \($0)" } ?? ""), rule: .reviewed
            )
        case "milestone":
            guard !rest.isEmpty else {
                throw Problem(description: "milestone needs a title: milestone <title> <org/repo>")
            }
            let name = rest.joined(separator: " ")
            let repo = try needRepo("milestone")
            return Parsed(
                query: "is:open milestone:\(quoted(name)) repo:\(repo)",
                label: "open items in milestone \(name) of \(repo)", rule: .closed
            )
        default:
            break
        }
        return try search(text)
    }

    /// A GitHub search as it is typed: it needs a qualifier, and gets `is:open` unless it says which state.
    static func search(_ text: String) throws -> Parsed {
        let query = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard query.contains(":") else {
            throw Problem(description: "not a source: \(query.isEmpty ? "nothing" : query) (\(usage))")
        }
        let lower = query.lowercased()
        let states = ["is:open", "is:closed", "is:merged", "is:unmerged", "state:"]
        let full = states.contains { lower.contains($0) } ? query : "is:open " + query
        let what = what(full)
        let rule: ItemSource.Rule = lower.contains("review-requested:") || lower.contains("user-review-requested:")
            ? .reviewed : what == .pulls ? .merged : .closed
        return Parsed(query: full, label: query, rule: rule)
    }

    /// `https://github.com/acme/web/pulls` and `…/issues`.
    static func fromURL(_ word: String) -> Parsed? {
        guard word.hasPrefix("https://github.com/") || word.hasPrefix("github.com/") else { return nil }
        let parts = word.split(separator: "/").map(String.init).filter { $0 != "https:" && $0 != "github.com" }
        guard parts.count == 3, let repo = TrackerCheck.slug("\(parts[0])/\(parts[1])") else { return nil }
        switch parts[2] {
        case "pulls": return Parsed(query: "is:pr is:open repo:\(repo)", label: "open PRs in \(repo)", rule: .merged)
        case "issues":
            return Parsed(query: "is:issue is:open repo:\(repo)", label: "open issues in \(repo)", rule: .closed)
        default: return nil
        }
    }

    /// What a search finds: PRs (`is:pr`, `type:pr`, `review-requested:`), issues (`is:issue`), or both.
    public static func what(_ query: String) -> ItemSource.What {
        let lower = query.lowercased()
        if lower.contains("is:pr") || lower.contains("type:pr") || lower.contains("review-requested:")
            || lower.contains("reviewed-by:") || lower.contains("is:merged")
        {
            return .pulls
        }
        if lower.contains("is:issue") || lower.contains("type:issue") { return .issues }
        return .both
    }

    /// Words, with `"…"` (or `“…”`) kept together.
    static func tokens(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if let open = quote {
                if character == open || (open == "“" && character == "”") {
                    words.append(current)
                    current = ""
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "“" {
                if !current.isEmpty { words.append(current) }
                current = ""
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// A qualifier's value, in quotes when it has a space.
    static func quoted(_ value: String) -> String { value.contains(" ") ? "\"\(value)\"" : value }
}
