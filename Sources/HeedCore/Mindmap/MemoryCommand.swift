import Foundation

/// `heed memory`, from a heed session's shell: what heed's Mindmap keeps about the work this session continues, from
/// that session's own org (or personal) Mindmap and never another.
///
/// - `show`: the session's campaign: what it is for, its synopsis, the decisions that stand, what is open, its PRs.
/// - `search <words>`: campaigns, decisions and open follow-ups that mention every word, in this Mindmap only.
/// - `note <text>`: a decision, kept on the session's campaign (and its source is this session).
public enum MemoryCommandLine {
    public static let verbs = ["show", "search", "note"]

    public static let usage = """
    usage: heed memory show                what heed keeps about the work this session continues
           heed memory search <words>      decisions, follow-ups and campaigns that mention all of the words
           heed memory note <decision>     keep a decision on this session's campaign
    Run it from a heed session's shell: it reads that session's own Mindmap (its org's, or personal).
    """

    public struct UsageError: Error, CustomStringConvertible {
        public var description: String
    }

    public static func request(_ arguments: [String], environment: [String: String]) throws -> ControlRequest {
        let words = Array(arguments.dropFirst())
        guard let verb = words.first, verbs.contains(verb) else { throw UsageError(description: usage) }
        guard let session = environment[HeedEnvironment.sessionID], !session.isEmpty else {
            throw UsageError(description: "heed memory: run it from a heed session's shell (no HEED_SESSION_ID)")
        }
        if verb != "show", words.count < 2 { throw UsageError(description: usage) }
        return ControlRequest(method: .memory, session: session, arguments: words)
    }
}

/// What `heed memory` answers, worked out from one Mindmap.
public enum MemoryQuery {
    public static let maxResults = 20

    /// The campaign in full, as lines.
    public static func show(_ id: String, in tree: MindmapTree, ledger: [String: LedgerEntry], instance: String)
        -> String
    {
        guard let node = MemoryBrief.anchor(of: id, in: tree) else { return "nothing kept for this work yet" }
        var lines = ["\(node.title) (\(MindmapInstance.title(instance)), \(node.kind.rawValue))"]
        if let intent = node.intent { lines.append("For: \(intent)") }
        if let synopsis = node.synopsis { lines += ["", synopsis] }
        let decided = tree.decisions(of: node.id).shown + tree.descendants(of: node.id).flatMap(\.decisions)
        var seen: Set<String> = []
        let decisions = decided.filter { seen.insert($0.text.lowercased()).inserted }
        if !decisions.isEmpty {
            lines += ["", "Decisions:"] + decisions.map { decision in
                "- " + decision.text + (decision.supersededBy.map { " (superseded by: \($0))" } ?? "")
                    + " [" + (ledger[decision.source]?.title ?? decision.source) + "]"
            }
        }
        let open = tree.stillOpen(under: node.id)
        if !open.isEmpty {
            lines += ["", "Still open:"] + open.map { "- \($0.text) [\(ledger[$0.source]?.title ?? $0.source)]" }
        }
        let work = tree.entries(under: node.id).compactMap { ledger[$0] }.sorted { $0.updatedAt > $1.updatedAt }
        if !work.isEmpty {
            lines += ["", "Work:"] + work.map { entry in
                "- \(entry.title) (\(entry.outcome))" + (entry.pulls.isEmpty ? ""
                    : " " + entry.pulls.map { "\($0.repo.slug)#\($0.number)" }.joined(separator: " "))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Campaigns, decisions and open follow-ups that mention every word, newest first.
    public static func search(_ text: String, in tree: MindmapTree, ledger _: [String: LedgerEntry]) -> String {
        let words = text.lowercased().split(separator: " ").map(String.init)
        func matches(_ value: String) -> Bool {
            let lower = value.lowercased()
            return words.allSatisfy { lower.contains($0) }
        }
        var lines: [String] = []
        let nodes = tree.nodes.values.sorted { $0.updatedAt > $1.updatedAt }
        for node in nodes where node.kind != .work && (matches(node.title) || matches(node.synopsis ?? "")) {
            lines.append("\(node.kind.rawValue): \(node.title)")
        }
        for node in nodes {
            let place = node.kind == .work ? (MemoryBrief.anchor(of: node.id, in: tree)?.title ?? node.title) : node
                .title
            for decision in node.decisions where matches(decision.text) {
                lines.append("decision: \(decision.text)" + (decision.supersededBy == nil ? "" : " (superseded)")
                    + " [\(place)]")
            }
            for item in node.stillOpen where matches(item.text) {
                lines.append("open: \(item.text) [\(place)]")
            }
        }
        guard !lines.isEmpty else { return "nothing in this Mindmap mentions \(text)" }
        return lines.prefix(maxResults).joined(separator: "\n")
    }

    /// `note`: the decision kept on the campaign, its source the session.
    public static func note(_ text: String, on id: String, session: String, in tree: inout MindmapTree, now: Date)
        -> String
    {
        guard var node = MemoryBrief.anchor(of: id, in: tree) else { return "nothing kept for this work yet" }
        guard !node.decisions.contains(where: { $0.text == text }) else { return "already kept on \(node.title)" }
        node.decisions.append(MindNode.Decision(text: text, source: session))
        node.updatedAt = now
        tree.upsert(node)
        return "kept on \(node.title)"
    }
}
