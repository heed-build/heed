import Foundation

/// What an item is, as heed reads it.
public enum BrowseClass: String, CaseIterable, Hashable, Sendable, Codable {
    case bug, feature, docs, question, chore

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// Reads a word as a class: the class itself or the plain synonyms of the filter field and the model.
    public init?(word: String) {
        switch word.trimmingCharacters(in: .whitespaces).lowercased() {
        case "bug", "bugs", "fix": self = .bug
        case "feature", "features", "enhancement": self = .feature
        case "docs", "doc", "documentation": self = .docs
        case "question", "questions": self = .question
        case "chore", "chores", "maintenance": self = .chore
        default: return nil
        }
    }
}

/// How much work an item is: a rough size, not an estimate.
public enum BrowseSize: String, CaseIterable, Hashable, Sendable, Codable {
    case s = "S", m = "M", l = "L"

    /// Pips drawn of three.
    public var pips: Int {
        switch self {
        case .s: 1
        case .m: 2
        case .l: 3
        }
    }

    public var title: String {
        switch self {
        case .s: "Small"
        case .m: "Medium"
        case .l: "Large"
        }
    }

    public init?(word: String) {
        switch word.trimmingCharacters(in: .whitespaces).lowercased() {
        case "s", "small": self = .s
        case "m", "medium": self = .m
        case "l", "large": self = .l
        default: return nil
        }
    }
}

/// heed's read of one issue or pull request: its class, size, how ready an agent could take it, a line on what it
/// is, and the other items of the repo it may duplicate. Kept in `browse.sqlite` on this Mac, keyed by the item and
/// the `updatedAt` it was read at, and never written to GitHub.
public struct BrowseRead: Hashable, Sendable, Codable {
    public var itemID: String
    public var kind: BrowseClass
    public var size: BrowseSize
    /// 0 to 100: a clear repro or acceptance, bounded, no design decision pending.
    public var agentReady: Int
    public var tldr: String
    /// Ids (`org/repo#12`) of items that look like the same thing, from titles, not from the model.
    public var duplicates: [String]
    public var readAt: Date
    /// The item's `updatedAt` when it was read: a later one makes the read stale.
    public var itemUpdatedAt: Date
    public var agent: String?
    public var model: String?

    public init(
        itemID: String, kind: BrowseClass, size: BrowseSize, agentReady: Int, tldr: String, duplicates: [String] = [],
        readAt: Date, itemUpdatedAt: Date, agent: String? = nil, model: String? = nil
    ) {
        self.itemID = itemID
        self.kind = kind
        self.size = size
        self.agentReady = min(max(agentReady, 0), 100)
        self.tldr = tldr
        self.duplicates = duplicates
        self.readAt = readAt
        self.itemUpdatedAt = itemUpdatedAt
        self.agent = agent
        self.model = model
    }

    /// Whether the item changed after it was read.
    public func isStale(for item: BrowseItem) -> Bool { item.updatedAt > itemUpdatedAt }

    /// `claude haiku`, when it is known who wrote it.
    public var writer: String? { CatchUp.writer(agent: agent, model: model) }

    /// Ready enough for an agent to take as it is: the "Agent-ready" starter's line.
    public static let readyLine = 70
}

/// The reads by item id, with what a list needs of them.
public typealias BrowseReads = [String: BrowseRead]

/// Words to a read: the cheap model answers in a constrained JSON shape (`SummaryKind.browseRead`) and `parse`
/// turns it into a `BrowseRead` or nothing. The model's text is never trusted: a class or size heed does not know,
/// or a readiness that is not a number, drops the whole read; a number out of range is clamped; the TL;DR is plain
/// text of one paragraph, cut.
public enum BrowseReadParser {
    public static let caller = "browse.read"
    public static let maxTLDR = 360

    public static func parse(
        _ answer: String, item: BrowseItem, duplicates: [String] = [], now: Date, agent: String? = nil,
        model: String? = nil
    ) -> BrowseRead? {
        guard let object = BrowseWords.json(answer),
              let kind = (object["class"] as? String).flatMap({ BrowseClass(rawValue: $0.lowercased()) }),
              let size = (object["size"] as? String).flatMap({ BrowseSize(rawValue: $0.uppercased()) }),
              let ready = number(object["agent_ready"]) ?? number(object["agentReady"])
        else { return nil }
        let tldr = plain(object["tldr"] as? String ?? "")
        guard !tldr.isEmpty else { return nil }
        return BrowseRead(
            itemID: item.id, kind: kind, size: size, agentReady: Int(min(max(ready.rounded(), 0), 100)), tldr: tldr,
            duplicates: duplicates, readAt: now, itemUpdatedAt: item.updatedAt, agent: agent, model: model
        )
    }

    static func number(_ value: Any?) -> Double? {
        if let int = value as? Int { return Double(int) }
        if let double = value as? Double, double.isFinite { return double }
        return nil
    }

    /// One paragraph of plain text: control characters become spaces, runs of space one, cut at `maxTLDR`.
    static func plain(_ text: String) -> String {
        let spaced = text.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) || $0 == "\u{2028}" ? " " : String($0) }.joined()
        let words = spaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard words.count > maxTLDR else { return words }
        return String(words.prefix(maxTLDR - 1)) + "…"
    }
}

/// What the model reads: the item's title, labels, a cut of its description and its last comments, with other
/// people's words kept apart as `ExternalText`.
public enum BrowseReadInputs {
    public static let bodyLimit = 1800
    public static let commentLimit = 400
    public static let comments = 3

    public static func inputs(_ item: BrowseItem, conversation: ThreadConversation?) -> SummaryInputs {
        var header: [Prompt] = [
            "\(item.kind == .pull ? "Pull request" : "Issue") #\(item.number), \(name: item.state.rawValue)",
        ]
        if !item.labels.isEmpty {
            header.append("Labels: \(name: item.labels.prefix(10).joined(separator: ", "))")
        }
        if item.kind == .issue {
            header.append(item.hasLinkedPull ? "A pull request is linked to it." : "No pull request is linked to it.")
        } else {
            if let checks = item.checks { header.append("Checks: \(name: checks.rawValue)") }
            if item.isDraft { header.append("It is a draft.") }
        }
        header.append("\(item.comments) comment\(item.comments == 1 ? "" : "s").")
        var timeline: [Prompt] = []
        if let conversation {
            let by = conversation.author?.author ?? .unknown
            let body = String(ThreadText.plain(conversation.bodyHTML).prefix(bodyLimit))
            if !body.isEmpty {
                let text = ExternalText(body, source: item.kind == .pull ? .pullBody : .issueBody, author: by)
                header.append("\nDescription:\n\(text)")
            }
            for comment in conversation.comments.suffix(comments) {
                let said = ExternalText(
                    String(ThreadText.plain(comment.bodyHTML).prefix(commentLimit)), source: .comment,
                    author: comment.author?.author ?? .unknown
                )
                timeline.append("\(name: comment.author?.login ?? "ghost"): \(said)")
            }
        }
        return SummaryInputs(
            quoting: Prompt(item.title), repo: item.place, pullRequest: header.joined(separator: "\n"),
            timeline: timeline
        )
    }
}

/// Possible duplicates, by title: the other items of the same repo that share most of the shorter title's words.
/// Computed here, never by the model.
public enum BrowseDuplicates {
    static let stop: Set<String> = [
        "the", "and", "for", "with", "when", "not", "are", "was", "has", "have", "from", "that", "this", "into",
        "after", "before", "under", "over", "does", "doesn", "can", "cannot", "should", "add", "support", "use",
        "using", "fix", "bug", "error", "issue", "update", "allow", "make", "page",
    ]

    /// The significant words of a title, lowercased and lightly stemmed.
    public static func words(_ title: String) -> Set<String> {
        var result: Set<String> = []
        var current = ""
        func flush() {
            defer { current = "" }
            guard current.count >= 3, !stop.contains(current) else { return }
            result.insert(stem(current))
        }
        for character in title.lowercased() {
            if character.isLetter || character.isNumber { current.append(character) } else { flush() }
        }
        flush()
        return result
    }

    static func stem(_ word: String) -> String {
        for suffix in ["ing", "ed", "es", "s"] where word.count > suffix.count + 3 && word.hasSuffix(suffix) {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    /// How alike two titles are, 0 to 1: shared words over the shorter title's words, and at least two shared.
    public static func similarity(_ left: String, _ right: String) -> Double {
        let a = words(left), b = words(right)
        let shared = a.intersection(b).count
        guard shared >= 2, !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(shared) / Double(min(a.count, b.count))
    }

    /// Ids of the items of `item`'s repo that look like it, most alike first, at most `limit`.
    public static func candidates(
        for item: BrowseItem, in items: [BrowseItem], limit: Int = 3, threshold: Double = 0.6
    ) -> [String] {
        let title = item.title.display
        return items
            .filter { $0.id != item.id && $0.repo == item.repo && $0.kind == item.kind }
            .map { (item: $0, score: similarity(title, $0.title.display)) }
            .filter { $0.score >= threshold }
            .sorted { ($0.score, $0.item.updatedAt, $1.item.id) > ($1.score, $1.item.updatedAt, $0.item.id) }
            .prefix(limit).map(\.item.id)
    }
}
