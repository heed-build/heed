import Foundation

/// What a sentence became: the tokens, and what was left out and why. Nothing is hidden behind the sentence: the
/// card shows both.
public struct BrowseUnderstanding: Equatable, Sendable {
    public var tokens: [BrowseToken]
    /// What the answer asked for that heed does not run, each with the reason.
    public var dropped: [String]

    public init(tokens: [BrowseToken] = [], dropped: [String] = []) {
        self.tokens = tokens
        self.dropped = dropped
    }
}

/// Words to tokens. The cheap model answers in a constrained JSON shape (`SummaryKind.browseWords`); `understand`
/// reads that shape into typed tokens, and only tokens go on: a field heed does not know, a value out of range or one
/// that is not shaped like what its field takes is dropped and reported, never run. Model output is never joined
/// into a GitHub query as text; `.text` words are held to plain words, so they cannot carry a qualifier.
public enum BrowseWords {
    public static let caller = "browse.words"
    /// The longest sentence sent, and the most tokens read back.
    public static let maxWords = 300
    public static let maxTokens = 12

    /// The model's input: the typed sentence, which is the owner's own words.
    public static func inputs(_ sentence: String) -> SummaryInputs {
        SummaryInputs(title: String(sentence.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxWords)))
    }

    /// Local fields wait for classification (milestone 3): asked for, they are reported, not run.
    static let local: Set<String> = ["class", "size", "agent_ready", "agent-ready"]

    public static func understand(_ answer: String, viewer: String? = nil) -> BrowseUnderstanding {
        guard let object = json(answer) else {
            return BrowseUnderstanding(dropped: ["the answer was not the JSON heed asked for"])
        }
        var result = BrowseUnderstanding()
        func drop(_ why: String) { result.dropped.append(why) }
        func add(_ token: BrowseToken) {
            guard result.tokens.count < maxTokens else { return drop("more than \(maxTokens) filters") }
            guard !result.tokens.contains(where: { sameKind($0, token) }) else {
                return drop("a second \(kindName(token)) filter")
            }
            result.tokens.append(token)
        }
        for case let filter as [String: Any] in object["filters"] as? [Any] ?? [] {
            guard let field = (filter["field"] as? String)?.lowercased()
            else { drop("a filter with no field"); continue }
            switch field {
            case "type":
                switch (filter["value"] as? String)?.lowercased() {
                case "issues", "issue": add(.type(.issues))
                case "pulls", "pull", "prs", "pr": add(.type(.pulls))
                default: drop("type: not issues or pulls")
                }
            case "state":
                if let value = (filter["value"] as? String).flatMap({ BrowseStateFilter(rawValue: $0.lowercased()) }) {
                    add(.state(value))
                } else { drop("state: not open, closed or merged") }
            case "label":
                let mode = (filter["mode"] as? String).flatMap { BrowseLabelMode(rawValue: $0.lowercased()) } ?? .any
                let names = (filter["values"] as? [Any] ?? []).compactMap { $0 as? String }.compactMap(clean)
                if names.isEmpty { drop("label: no usable names") } else { add(.label(mode, Array(names.prefix(10)))) }
            case "repo":
                if let value = clean(filter["value"]), value.range(
                    of: #"^[\w.-]+/[\w.-]+$"#,
                    options: .regularExpression
                ) != nil {
                    add(.repo(value))
                } else { drop("repo: not shaped org/name") }
            case "assignee", "author":
                if let value = clean(filter["value"]),
                   value.range(of: #"^(@me|[A-Za-z0-9][A-Za-z0-9\-_\[\]]{0,38})$"#, options: .regularExpression) != nil
                {
                    add(field == "assignee" ? .assignee(value) : .author(value))
                } else { drop("\(field): not a login") }
            case "milestone":
                guard let value = clean(filter["value"]) else { drop("milestone: no usable name"); continue }
                add(.milestone(value))
            case "project":
                if let value = clean(filter["value"]) { add(.project(value)) } else { drop("project: no usable name") }
            case "created", "updated", "activity", "age":
                let op = (filter["op"] as? String)?.lowercased()
                guard let days = (filter["days"] as? Int) ?? (filter["days"] as? Double).map({ Int($0) }),
                      (1 ... 3650).contains(days), op == "newer" || op == "older"
                else { drop("\(field): days must be 1 to 3650 and the op newer or older"); continue }
                let span: BrowseSpan = op == "newer" ? .newerThan(days) : .olderThan(days)
                add(field == "created" || field == "age" ? .created(span) : .activity(span))
            case "linked_pr", "linked":
                guard let value = filter["value"] as? Bool else { drop("linked_pr: not true or false"); continue }
                add(.linkedPull(value))
            case _ where local.contains(field):
                drop("\(field): heed's own read of items is not there yet")
            default:
                drop("\(field): not a filter heed knows")
            }
        }
        if let text = object["text"] as? String { applyText(text, &result) }
        if let me = viewer {
            result.tokens = result.tokens.map { token in
                switch token {
                case .assignee("@me"): .assignee(me)
                case .author("@me"): .author(me)
                default: token
                }
            }
        }
        return result
    }

    /// Plain words only: a word with a `:` (a qualifier) or a leading `-` (a negation) is dropped, as are control
    /// characters; the rest joins into one `text` token.
    static func applyText(_ text: String, _ result: inout BrowseUnderstanding) {
        let words = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined().split(separator: " ").map(String.init)
        var kept: [String] = []
        for word in words.prefix(20) {
            if word.contains(":") || word.hasPrefix("-") || word.contains("\"") {
                result.dropped.append("the word “\(word.prefix(30))” looks like a qualifier")
            } else { kept.append(String(word.prefix(40))) }
        }
        if !kept.isEmpty, result.tokens.count < maxTokens { result.tokens.append(.text(kept.joined(separator: " "))) }
    }

    /// A value: trimmed, at most 80 characters, no control characters.
    static func clean(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              text.count <= 80, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return text
    }

    /// The first JSON object in the answer, fenced or not.
    static func json(_ answer: String) -> [String: Any]? {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"),
              start < end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(answer[start ... end].utf8))) as? [String: Any]
    }

    static func sameKind(_ left: BrowseToken, _ right: BrowseToken) -> Bool { kindName(left) == kindName(right) }

    static func kindName(_ token: BrowseToken) -> String {
        switch token {
        case .type: "type"
        case .state: "state"
        case .label: "label"
        case .repo: "repo"
        case .org: "org"
        case .assignee: "assignee"
        case .author: "author"
        case .milestone: "milestone"
        case .project: "project"
        case .created: "age"
        case .activity: "activity"
        case .linkedPull: "linked PR"
        case .topic: "topic"
        case .team: "team"
        case .language: "language"
        case .archived: "archived"
        case .text: "text"
        case .raw: "raw"
        }
    }
}
