import Foundation

/// What a session's agent hands over when its work becomes a goal: what the work is, what is done, what was decided
/// and why, what is open, the risks, and the parts it would do next. The agent writes short markdown with fixed
/// headings (`headings`), so heed can read it; a model never has to guess what is where.
///
/// It is kept in the goal's `GOAL.md` as a `## Handoff` section (its own headings as bold lines), so it is visible and
/// editable like the rest of the goal, every agent on the goal reads it, and the Plan step's planner starts from it.
public struct SessionHandoff: Hashable, Sendable, Codable {
    /// One fixed heading, and the other words an agent is likely to use for it.
    public enum Section: String, CaseIterable, Sendable, Codable {
        case work, done, decisions, open, risks, next

        /// The heading heed asks for.
        public var heading: String {
            switch self {
            case .work: "Work"
            case .done: "Done"
            case .decisions: "Decisions"
            case .open: "Open"
            case .risks: "Risks"
            case .next: "Next"
            }
        }

        /// What the heading covers, as the ask words it.
        public var asks: String {
            switch self {
            case .work: "what the work is and its goal, in a few sentences"
            case .done: "what is done, one bullet each, with its PR where there is one (org/repo#123)"
            case .decisions: "decisions taken and why, one bullet each"
            case .open: "what is open or found but not started, one bullet each"
            case .risks: "what could go wrong, one bullet each"
            case .next: "the parts you would do next, in order, one bullet each"
            }
        }

        /// Headings that name the same section (lowercase, no punctuation).
        static let aliases: [String: Section] = [
            "work": .work, "the work": .work, "what": .work, "what it is": .work, "goal": .work, "the goal": .work,
            "summary": .work, "overview": .work, "context": .work,
            "done": .done, "done so far": .done, "completed": .done, "shipped": .done, "what is done": .done,
            "decisions": .decisions, "decisions taken": .decisions, "decisions and why": .decisions,
            "decided": .decisions,
            "open": .open, "open items": .open, "open questions": .open, "found": .open, "not started": .open,
            "open or found": .open, "found but not started": .open, "left": .open, "todo": .open,
            "risks": .risks, "risk": .risks, "risks and unknowns": .risks,
            "next": .next, "next parts": .next, "next steps": .next, "suggested next parts": .next,
            "suggested next": .next, "next up": .next,
        ]
    }

    /// The section bodies, markdown, trimmed; empty when the agent left one out.
    public var work: String
    public var done: String
    public var decisions: String
    public var open: String
    public var risks: String
    public var next: String

    public init(
        work: String = "", done: String = "", decisions: String = "", open: String = "", risks: String = "",
        next: String = ""
    ) {
        self.work = work
        self.done = done
        self.decisions = decisions
        self.open = open
        self.risks = risks
        self.next = next
    }

    public subscript(section: Section) -> String {
        get {
            switch section {
            case .work: work
            case .done: done
            case .decisions: decisions
            case .open: open
            case .risks: risks
            case .next: next
            }
        }
        set {
            switch section {
            case .work: work = newValue
            case .done: done = newValue
            case .decisions: decisions = newValue
            case .open: open = newValue
            case .risks: risks = newValue
            case .next: next = newValue
            }
        }
    }

    /// The sections that have something in them, in the fixed order.
    public var filled: [Section] { Section.allCases.filter { !self[$0].isEmpty } }

    /// The most a handoff keeps: what a pasted transcript would exceed. A longer one is cut at a line.
    public static let maxLength = 12000

    /// Why a handoff could not be read.
    public enum Problem: Error, Equatable, Sendable, CustomStringConvertible {
        case empty
        /// No `Work` section, or nothing else beside it.
        case missing(String)

        public var description: String {
            switch self {
            case .empty: "the handoff is empty"
            case let .missing(what): what
            }
        }
    }

    /// The handoff in `text`: markdown with the fixed headings (any level, any case, a few other names for each, in
    /// any order). Words before the first heading are dropped; a heading heed does not know stays as a line of the
    /// section it falls in, so nothing is lost. It needs a `Work` section and one more with something in it.
    public static func read(_ text: String) -> Result<SessionHandoff, Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        var handoff = SessionHandoff()
        var current: Section?
        var body: [String] = []
        var inFence = false

        func flush() {
            guard let section = current else { return }
            let block = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            handoff[section] = [handoff[section], block].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }

        for line in cut(trimmed).components(separatedBy: .newlines) {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("```") || stripped.hasPrefix("~~~") { inFence.toggle() }
            if !inFence, let heading = Self.heading(of: stripped) {
                if let section = Section.aliases[heading] {
                    flush()
                    current = section
                    body = []
                } else if current != nil {
                    body.append("**\(stripped.drop { $0 == "#" || $0 == " " })**")
                }
                continue
            }
            if current != nil { body.append(line) }
        }
        flush()

        guard !handoff.work.isEmpty else {
            return .failure(.missing(
                "no Work section: start with a \"## Work\" heading, then "
                    + Section.allCases.dropFirst().map { "\"## \($0.heading)\"" }.joined(separator: ", ")
            ))
        }
        guard handoff.filled.count >= 2 else {
            return .failure(.missing(
                "only Work: add what is done, decided, open, risky or next, each under its heading ("
                    + Section.allCases.map(\.heading).joined(separator: ", ") + ")"
            ))
        }
        return .success(handoff)
    }

    /// `read`, or nil.
    public static func parse(_ text: String) -> SessionHandoff? { try? read(text).get() }

    /// The text of a markdown heading (`## Done so far:` is `done so far`) or of a line that is only bold
    /// (`**Done**`, how `GOAL.md` keeps them), nil for any other line.
    static func heading(of line: String) -> String? {
        if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 {
            let inner = line.dropFirst(2).dropLast(2)
            if !inner.contains("**") {
                return inner.trimmingCharacters(in: CharacterSet(charactersIn: " :")).lowercased()
                    .replacingOccurrences(of: "&", with: "and")
            }
        }
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes <= 6 else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return rest.trimmingCharacters(in: CharacterSet(charactersIn: " :#*_`"))
            .lowercased().replacingOccurrences(of: "&", with: "and")
    }

    static func cut(_ text: String) -> String {
        guard text.count > maxLength else { return text }
        let head = String(text.prefix(maxLength))
        return head.lastIndex(of: "\n").map { String(head[..<$0]) } ?? head
    }

    /// The bullets of a section's body (`- x`, `* x`, `1. x`), else its non-empty lines.
    public static func items(_ body: String) -> [String] {
        let lines = body.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let bullets = lines.compactMap { line -> String? in
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            guard let dot = line.firstIndex(of: "."), dot != line.startIndex,
                  line[..<dot].allSatisfy(\.isNumber), line[line.index(after: dot)...].first == " "
            else { return nil }
            return String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
        }
        return bullets.isEmpty ? lines : bullets
    }

    /// How many things are done, and how many are open or next.
    public var doneCount: Int { Self.items(done).count }
    public var openCount: Int { Self.items(open).count }

    // MARK: In GOAL.md

    /// The heading of the section in `GOAL.md`.
    public static let extraHeading = "Handoff"

    /// The markdown with its `## ` headings, as the agent writes it.
    public var markdown: String {
        filled.map { "## \($0.heading)\n\n\(self[$0])" }.joined(separator: "\n\n")
    }

    /// The markdown as `GOAL.md` keeps it: each heading a bold line, because `GOAL.md` reads every heading of any level
    /// as a section of its own (a `### Decisions` would become the goal's Decisions).
    public var goalMarkdown: String {
        filled.map { "**\($0.heading)**\n\n\(self[$0])" }.joined(separator: "\n\n")
    }

    /// The `## Handoff` section for `GOAL.md`.
    public var extra: GoalDoc.Extra { GoalDoc.Extra(heading: Self.extraHeading, body: goalMarkdown) }

    /// The handoff a goal's `GOAL.md` holds (as heed put it, or as you edited it); nil when it has none or an edit left
    /// it unreadable.
    public static func read(from doc: GoalDoc?) -> SessionHandoff? {
        doc?.extras.first { $0.heading.lowercased() == extraHeading.lowercased() }.flatMap { parse($0.body) }
    }

    /// The doc with this handoff in it, replacing an earlier one.
    public func apply(to doc: GoalDoc) -> GoalDoc {
        var doc = doc
        doc.extras.removeAll { $0.heading.lowercased() == Self.extraHeading.lowercased() }
        doc.extras.insert(extra, at: 0)
        return doc
    }

    /// The text the planner reads: the handoff as heed saved it.
    public var promptText: String { goalMarkdown }

    // MARK: The ask

    /// What heed says to the agent: one paragraph (it may be typed into a pane), the fixed headings, and the one
    /// command that hands it back. The agent does the work it was already doing; this only asks for the writing.
    public static var ask: Prompt {
        let sections = Section.allCases.map { "\"## \($0.heading)\" (\($0.asks))" }.joined(separator: "; ")
        return .owner("""
        Your user is turning this session's work into a goal, and the agent that plans it has not seen what you did. \
        Please write a short handoff: markdown, under 400 words, with exactly these headings in this order: \
        \(sections). Leave a section out if it is empty; be concrete (files, PRs, numbers), no preamble. Then hand it \
        to heed by running `heed goal handoff` in your shell with the markdown on its standard input, for example \
        with a quoted heredoc (`heed goal handoff <<'HANDOFF'` ... `HANDOFF`). heed reads it from there, so do not \
        also paste it here, and do not change any file for this.
        """)
    }
}
