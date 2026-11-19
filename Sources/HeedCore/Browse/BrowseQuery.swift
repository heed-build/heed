import Foundation

public enum BrowseType: String, Hashable, Sendable, Codable { case issues, pulls }
public enum BrowseStateFilter: String, Hashable, Sendable, Codable { case open, closed, merged }

/// How a label token reads its names: an item has any of them, all of them, or none.
public enum BrowseLabelMode: String, Hashable, Sendable, Codable { case any, all, none }

/// A span counted back from now, in days.
public enum BrowseSpan: Hashable, Sendable, Codable {
    case newerThan(Int)
    case olderThan(Int)
}

/// One filter of a query. Each renders to a GitHub search qualifier, so the raw string is always the whole truth.
public enum BrowseToken: Hashable, Sendable, Codable {
    case type(BrowseType)
    case state(BrowseStateFilter)
    case label(BrowseLabelMode, [String])
    case repo(String)
    case org(String)
    case assignee(String)
    case author(String)
    case milestone(String)
    case project(String)
    /// How long ago it was opened.
    case created(BrowseSpan)
    /// How long ago it last changed.
    case activity(BrowseSpan)
    /// Whether a pull request is linked to it (`linked:pr`).
    case linkedPull(Bool)
    /// The repo-level filters of an org view (`BrowseOrgView`): `language:` and `archived:` are qualifiers GitHub's
    /// issue search evaluates itself on every fetch.
    case language(String)
    case archived(Bool)
    /// heed's own read of an item (`BrowseRead`), kept on this Mac: these never go to GitHub, they narrow what GitHub
    /// answered. An item heed has not read yet matches none of them.
    case heedClass([BrowseClass])
    case heedSize([BrowseSize])
    /// Agent-ready at least this much (0 to 100).
    case heedReady(Int)
    /// Words searched for in titles and bodies.
    case text(String)
    /// A qualifier heed does not model (`sort:`, `no:assignee`…), kept as written so nothing is lost.
    case raw(String)
}

public extension BrowseToken {
    /// A chip's name and value for heed's own filters: `heed: class` `bug, feature`; nil for the rest.
    var heedChip: (String, String)? {
        switch self {
        case let .heedClass(classes): ("heed: class", classes.map(\.rawValue).joined(separator: ", "))
        case let .heedSize(sizes): ("heed: size", sizes.map(\.rawValue).joined(separator: ", "))
        case let .heedReady(least): ("heed: agent-ready", "≥ \(least)%")
        default: nil
        }
    }

    /// Whether it narrows by heed's read, which GitHub knows nothing of.
    var isLocal: Bool {
        switch self {
        case .heedClass, .heedSize, .heedReady: true
        default: false
        }
    }
}

/// A Browse query: a scope and a list of tokens. `rendered` turns it into the GitHub search string, `parse` reads one
/// back. The scope renders as a leading qualifier and so parses back as an ordinary `org`/`repo` token.
public struct BrowseQuery: Hashable, Sendable, Codable {
    public var scope: BrowseScope?
    public var tokens: [BrowseToken]
    /// Whether the age cap is lifted ("Show older").
    public var showOlder: Bool

    public init(scope: BrowseScope? = nil, tokens: [BrowseToken] = [], showOlder: Bool = false) {
        self.scope = scope
        self.tokens = tokens
        self.showOlder = showOlder
    }

    /// Reads a query stored by an earlier build: a token that is no longer one of heed's (a topic or a team filter of
    /// an old org view) is dropped and the rest kept.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scope = try container.decodeIfPresent(BrowseScope.self, forKey: .scope)
        tokens = try container.decodeIfPresent([LossyToken].self, forKey: .tokens)?.compactMap(\.token) ?? []
        showOlder = try container.decodeIfPresent(Bool.self, forKey: .showOlder) ?? false
    }

    private enum CodingKeys: String, CodingKey { case scope, tokens, showOlder }

    /// The tokens GitHub is asked, and the ones heed applies to what it answered.
    public var githubTokens: [BrowseToken] { tokens.filter { !$0.isLocal } }
    public var localTokens: [BrowseToken] { tokens.filter(\.isLocal) }

    /// Raw qualifiers that name a place.
    private static let placeQualifiers: Set<String> = ["org", "repo", "project", "user"]

    /// The place a raw token names (`repo:a/b`, `org:a`, `user:a`, `project:a/3`); nil for any other, a negated one
    /// (it excludes) and an empty value.
    static func rawPlace(_ text: String) -> BrowsePlace? {
        guard !text.hasPrefix("-"), let colon = text.firstIndex(of: ":") else { return nil }
        let key = text[..<colon].lowercased()
        let value = unquote(String(text[text.index(after: colon)...]))
        guard !value.isEmpty, placeQualifiers.contains(key) else { return nil }
        return BrowsePlace.parse(value, isRepo: key == "repo")
    }

    /// Every place the query names: its scope and any org, repo, Project or raw place token.
    public var places: [BrowsePlace] {
        var found: [BrowsePlace] = []
        switch scope {
        case let .org(org): found.append(BrowsePlace(owner: org))
        case let .repo(repo): found.append(BrowsePlace(owner: repo.org, repo: repo.slug))
        case let .project(owner, _, _): found.append(BrowsePlace(owner: owner))
        case let .view(view): found.append(BrowsePlace(owner: view.owner))
        // Its org: the repos are the org's checked-out ones by construction, so the gate has nothing more to ask.
        case let .ownRepos(org): found.append(BrowsePlace(owner: org))
        case nil: break
        }
        for token in tokens {
            switch token {
            case let .repo(value) where !value.isEmpty: found.append(.parse(value, isRepo: true))
            case let .org(value) where !value.isEmpty: found.append(.parse(value, isRepo: false))
            case let .project(value) where !value.isEmpty: found.append(.parse(value, isRepo: false))
            case let .raw(text): if let place = Self.rawPlace(text) { found.append(place) }
            default: break
            }
        }
        return found
    }

    /// Whether the query names a place of its own, so the default scope does not apply and no scope is added to it.
    public var hasOwnPlace: Bool { !places.isEmpty }

    /// Whether the query says where to look. One that does not runs inside what is checked out (the default scope).
    public var isBounded: Bool { hasOwnPlace }

    /// Whether the query carries its own `updated:` token, so the cap does not apply.
    public var hasOwnActivity: Bool {
        tokens.contains { if case .activity = $0 { true } else { false } }
    }

    /// Whether the age cap goes into the search at `maxAgeDays` (0 is no cap).
    public func isCapped(maxAgeDays: Int) -> Bool { !showOlder && maxAgeDays > 0 && !hasOwnActivity }

    /// The GitHub search string, with `updated:>=` capped at `maxAgeDays` unless the query shows older items.
    /// An org's own repos scope renders as the `repo:` qualifiers of `checkouts` (all of them: `BrowseFetch` splits them
    /// into searches that fit); without checkouts it names nothing.
    public func rendered(maxAgeDays: Int, now: Date, checkouts: BrowseCheckouts? = nil) -> String {
        var parts: [String] = []
        if case let .ownRepos(org)? = scope {
            parts += checkouts?.repoQualifiers(of: org) ?? []
        } else if let scope { parts.append(scope.qualifier) }
        var words: [String] = []
        for token in tokens {
            if case let .text(text) = token { words.append(text) } else { parts += Self.render(token, now: now) }
        }
        if isCapped(maxAgeDays: maxAgeDays), let cap = AttentionAge.qualifier(days: maxAgeDays, now: now) {
            parts.append(cap)
        }
        return (parts + words).joined(separator: " ")
    }

    static func render(_ token: BrowseToken, now: Date) -> [String] {
        func day(_ days: Int) -> String { AttentionAge.day(now.addingTimeInterval(-TimeInterval(days) * 86400)) }
        func span(_ key: String, _ span: BrowseSpan) -> String {
            switch span {
            case let .newerThan(days): "\(key):>=\(day(days))"
            case let .olderThan(days): "\(key):<\(day(days))"
            }
        }
        switch token {
        case let .type(type): return [type == .issues ? "is:issue" : "is:pr"]
        case let .state(state): return ["is:\(state.rawValue)"]
        case let .label(mode, names):
            switch mode {
            case .any: return names.isEmpty ? [] : ["label:" + names.map(quote).joined(separator: ",")]
            case .all: return names.map { "label:" + quote($0) }
            case .none: return names.map { "-label:" + quote($0) }
            }
        case let .repo(value): return ["repo:" + quote(value)]
        case let .org(value): return ["org:" + quote(value)]
        case let .assignee(value): return ["assignee:" + quote(value)]
        case let .author(value): return ["author:" + quote(value)]
        case let .milestone(value): return ["milestone:" + quote(value)]
        case let .project(value): return ["project:" + quote(value)]
        case let .created(value): return [span("created", value)]
        case let .activity(value): return [span("updated", value)]
        case let .linkedPull(linked): return [linked ? "linked:pr" : "-linked:pr"]
        case let .language(value): return ["language:" + quote(value)]
        case let .archived(value): return ["archived:\(value)"]
        case let .text(text): return [text]
        case let .raw(text): return [text]
        case .heedClass, .heedSize, .heedReady: return []
        }
    }

    static func quote(_ value: String) -> String {
        guard value.contains(where: { $0 == " " || $0 == "," || $0 == "\"" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Parsing

    /// Reads a GitHub search string. What it does not model stays as `raw` tokens; words become one `text` token. The
    /// cap's own `updated:>=` day (for `maxAgeDays` at `now`) reads back as "not showing older", and a string with no
    /// `updated:` at all reads back as showing older.
    public static func parse(_ text: String, maxAgeDays: Int, now: Date) -> BrowseQuery {
        let capDay = AttentionAge.qualifier(days: maxAgeDays, now: now)
        var tokens: [BrowseToken] = []
        var words: [String] = []
        var allLabels: [String] = []
        var labelsAt = 0
        var capped = false
        func days(_ day: Substring) -> Int? {
            let parts = day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3, day.count == 10 else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
            else { return nil }
            return max(0, Int(floor(now.timeIntervalSince(date) / 86400)))
        }
        for word in split(text) {
            if let capDay, word == capDay { capped = true; continue }
            let negated = word.hasPrefix("-")
            let body = negated ? String(word.dropFirst()) : word
            guard let colon = body.firstIndex(of: ":"), colon != body.startIndex,
                  body[..<colon].allSatisfy({ $0.isLetter || $0 == "-" })
            else { words.append(word); continue }
            let key = String(body[..<colon]).lowercased()
            let raw = String(body[body.index(after: colon)...])
            let value = unquote(raw)
            switch (key, negated) {
            case ("is", false) where value == "issue": tokens.append(.type(.issues))
            case ("is", false) where value == "pr": tokens.append(.type(.pulls))
            case ("is", false) where BrowseStateFilter(rawValue: value) != nil:
                tokens.append(.state(BrowseStateFilter(rawValue: value)!))
            case ("label", true): tokens.append(.label(.none, [value]))
            case ("label", false):
                let names = splitList(raw)
                if names.count > 1 { tokens.append(.label(.any, names)) } else {
                    if allLabels.isEmpty { labelsAt = tokens.count }
                    allLabels.append(value)
                }
            case ("repo", false): tokens.append(.repo(value))
            case ("org", false): tokens.append(.org(value))
            case ("assignee", false): tokens.append(.assignee(value))
            case ("author", false): tokens.append(.author(value))
            case ("language", false): tokens.append(.language(value))
            case ("archived", false)
                where value == "true" || value == "false": tokens.append(.archived(value == "true"))
            case ("milestone", false): tokens.append(.milestone(value))
            case ("project", false): tokens.append(.project(value))
            case ("linked", _) where value == "pr": tokens.append(.linkedPull(!negated))
            case ("created", false) where value.hasPrefix(">="):
                if let count = days(value.dropFirst(2)) { tokens.append(.created(.newerThan(count))) } else {
                    tokens.append(.raw(word))
                }
            case ("created", false) where value.hasPrefix("<"):
                if let count = days(value.dropFirst()) { tokens.append(.created(.olderThan(count))) } else {
                    tokens.append(.raw(word))
                }
            case ("updated", false) where value.hasPrefix(">="):
                if let count = days(value.dropFirst(2)) { tokens.append(.activity(.newerThan(count))) } else {
                    tokens.append(.raw(word))
                }
            case ("updated", false) where value.hasPrefix("<"):
                if let count = days(value.dropFirst()) { tokens.append(.activity(.olderThan(count))) } else {
                    tokens.append(.raw(word))
                }
            default: tokens.append(.raw(word))
            }
        }
        if !allLabels.isEmpty {
            tokens.insert(.label(allLabels.count == 1 ? .any : .all, allLabels), at: labelsAt)
        }
        if !words.isEmpty { tokens.append(.text(words.joined(separator: " "))) }
        var query = BrowseQuery(tokens: tokens)
        query.showOlder = !capped && !query.hasOwnActivity
        return query
    }

    /// Splits on spaces outside double quotes.
    static func split(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in text {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\", quoted { current.append(character); escaped = true; continue }
            if character == "\"" { quoted.toggle() }
            if character == " ", !quoted {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// Splits on commas outside double quotes, unquoting each.
    static func splitList(_ text: String) -> [String] {
        var items: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" { quoted.toggle() }
            if character == ",",
               !quoted { items.append(unquote(current)); current = "" } else { current.append(character) }
        }
        items.append(unquote(current))
        return items.filter { !$0.isEmpty }
    }

    static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
    }
}
