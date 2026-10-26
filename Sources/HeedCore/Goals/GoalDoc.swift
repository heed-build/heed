import Foundation

/// A goal's `GOAL.md`, read into its sections: the goal, what it is not, when it is done (criteria, each with the
/// evidence that met it), the open questions and the decisions taken (each with where it came from).
///
/// The file is plain markdown that agents read and people edit, so parsing is forgiving: headings at any level and in
/// any case, `-`, `*` or `+` bullets, `[x]` or `[X]`, CRLF, and lines that wrap under a bullet all read. What heed does
/// not know (a preamble, a section of your own) is kept and written back where it was. `render` writes the canonical
/// form: reading it back gives the same doc, and any file reads and writes stable after one pass (`GoalDocTests`).
public struct GoalDoc: Hashable, Sendable, Codable {
    /// A done-when line: checked once it is met, with what showed it (`(evidence: …)` at the end of the line).
    public struct Criterion: Hashable, Sendable, Codable {
        public var text: String
        public var met: Bool
        public var evidence: String?

        public init(_ text: String, met: Bool = false, evidence: String? = nil) {
            self.text = text
            self.met = met
            self.evidence = evidence
        }
    }

    /// A decision and where it was taken (`(source: …)` at the end of the line): you, a chat, a session, a review.
    public struct Decision: Hashable, Sendable, Codable {
        public var text: String
        public var source: String?

        public init(_ text: String, source: String? = nil) {
            self.text = text
            self.source = source
        }
    }

    /// A section heed does not read, kept as written.
    public struct Extra: Hashable, Sendable, Codable {
        public var heading: String
        public var body: String

        public init(heading: String, body: String) {
            self.heading = heading
            self.body = body
        }
    }

    /// The `# ` line.
    public var title: String
    /// What the goal is, in a sentence or a paragraph or two.
    public var goal: String
    public var notTheGoal: [String]
    public var doneWhen: [Criterion]
    public var openQuestions: [String]
    public var decisions: [Decision]
    /// Text between the title and the first section.
    public var preamble: String
    /// Sections of your own, after heed's, in the order they were written.
    public var extras: [Extra]

    public init(
        title: String, goal: String = "", notTheGoal: [String] = [], doneWhen: [Criterion] = [],
        openQuestions: [String] = [], decisions: [Decision] = [], preamble: String = "", extras: [Extra] = []
    ) {
        self.title = title
        self.goal = goal
        self.notTheGoal = notTheGoal
        self.doneWhen = doneWhen
        self.openQuestions = openQuestions
        self.decisions = decisions
        self.preamble = preamble
        self.extras = extras
    }

    /// Done-when criteria met, and how many there are.
    public var criteriaMet: (met: Int, total: Int) { (doneWhen.count { $0.met }, doneWhen.count) }

    /// The sections heed reads, by the heading it writes.
    enum Section: String, CaseIterable {
        case goal = "Goal"
        case notTheGoal = "Not the goal"
        case doneWhen = "Done when"
        case openQuestions = "Open questions"
        case decisions = "Decisions"

        /// A heading as written, to the section it names; nil for one of your own.
        static func named(_ heading: String) -> Section? {
            let key = heading.lowercased().filter { $0.isLetter || $0 == " " }
                .split(separator: " ").joined(separator: " ")
            return switch key {
            case "goal", "the goal": .goal
            case "not the goal", "non goals", "nongoals", "not goals", "out of scope": .notTheGoal
            case "done when", "definition of done", "done": .doneWhen
            case "open questions", "questions": .openQuestions
            case "decisions", "decisions so far": .decisions
            default: nil
            }
        }
    }

    // MARK: Parse

    public static func parse(_ text: String) -> GoalDoc {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var doc = GoalDoc(title: "")
        var preamble: [String] = []
        // The section being read: a known one, or the heading of one of your own; nil before the first.
        var current: (known: Section?, heading: String)?
        var body: [String] = []

        func flush() {
            guard let section = current else {
                doc.preamble = trimmedBlock(preamble)
                return
            }
            if let known = section.known {
                doc.read(known, body)
            } else {
                doc.extras.append(Extra(heading: section.heading, body: trimmedBlock(body)))
            }
        }

        var inFence = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            if !inFence, let (level, heading) = heading(trimmed) {
                if level == 1, doc.title.isEmpty, current == nil {
                    doc.title = heading
                    continue
                }
                flush()
                current = (Section.named(heading), heading)
                body = []
                continue
            }
            if current == nil { preamble.append(line) } else { body.append(line) }
        }
        flush()
        return doc
    }

    /// `## Heading` (any level) to its level and text.
    private static func heading(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("#") else { return nil }
        let level = line.prefix { $0 == "#" }.count
        let rest = line.dropFirst(level)
        guard level <= 6, rest.isEmpty || rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (level, text)
    }

    private mutating func read(_ section: Section, _ body: [String]) {
        switch section {
        case .goal:
            goal = Self.trimmedBlock(body)
        case .notTheGoal:
            notTheGoal += Self.bullets(body).map(\.text)
        case .openQuestions:
            openQuestions += Self.bullets(body).map(\.text)
        case .doneWhen:
            doneWhen += Self.bullets(body).map { bullet in
                let (text, evidence) = Self.trailing("evidence", of: bullet.text)
                return Criterion(text, met: bullet.checked ?? false, evidence: evidence)
            }
        case .decisions:
            decisions += Self.bullets(body).map { bullet in
                let (text, source) = Self.trailing("source", of: bullet.text)
                return Decision(text, source: source)
            }
        }
    }

    /// A section's list: each bullet with the lines wrapped under it joined by a space, and its checkbox when it has
    /// one. Lines that are not bullets and do not follow one (a sentence under the heading) are a bullet each.
    static func bullets(_ body: [String]) -> [(text: String, checked: Bool?)] {
        var items: [(text: String, checked: Bool?)] = []
        var open = false
        for raw in body {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                open = false
                continue
            }
            if let marker = line.first, "-*+".contains(marker), line.dropFirst().first == " " || line.count == 1 {
                var text = line.dropFirst().trimmingCharacters(in: .whitespaces)
                var checked: Bool?
                if text.count >= 3, text.hasPrefix("["), text.dropFirst(2).hasPrefix("]") {
                    let mark = text.dropFirst().first!
                    if mark == " " || mark == "x" || mark == "X" {
                        checked = mark != " "
                        text = text.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    }
                }
                items.append((text, checked))
                open = true
            } else if let numbered = numberedItem(line) {
                items.append((numbered, nil))
                open = true
            } else if open, raw.first == " " || raw.first == "\t", !items.isEmpty {
                items[items.count - 1].text += " " + line
            } else {
                items.append((line, nil))
                open = true
            }
        }
        return items.filter { !$0.text.isEmpty }
    }

    /// `1. text` or `1) text` to its text.
    private static func numberedItem(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " else { return nil }
        return rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
    }

    /// `text (label: value)` to the text and the value; the text alone when the line does not end that way.
    static func trailing(_ label: String, of line: String) -> (String, String?) {
        let opener = " (\(label):"
        guard line.hasSuffix(")"), let range = line.range(of: opener, options: [.backwards, .caseInsensitive])
        else { return (line, nil) }
        let value = line[range.upperBound...].dropLast().trimmingCharacters(in: .whitespaces)
        let text = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? (text, nil) : (text, value)
    }

    /// Lines without the blank ones at either end, and each without trailing spaces.
    static func trimmedBlock(_ lines: [String]) -> String {
        var lines = lines.map { String($0.reversed().drop { $0 == " " || $0 == "\t" }.reversed()) }
        while lines.first?.isEmpty == true {
            lines.removeFirst()
        }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Render

    /// The canonical `GOAL.md`: every section of heed's, even an empty one, so a reader sees where things go.
    public func render() -> String {
        var out = ["# \(title.isEmpty ? "Untitled goal" : Self.oneLine(title))"]
        if !preamble.isEmpty { out += ["", preamble] }
        out += ["", "## \(Section.goal.rawValue)", ""]
        if !goal.isEmpty { out += [goal, ""] }
        out += ["## \(Section.notTheGoal.rawValue)", ""]
        out += notTheGoal.map { "- \(Self.oneLine($0))" }
        if !notTheGoal.isEmpty { out.append("") }
        out += ["## \(Section.doneWhen.rawValue)", ""]
        out += doneWhen.map { criterion in
            "- [\(criterion.met ? "x" : " ")] \(Self.oneLine(criterion.text))"
                + (criterion.evidence.map { " (evidence: \(Self.oneLine($0)))" } ?? "")
        }
        if !doneWhen.isEmpty { out.append("") }
        out += ["## \(Section.openQuestions.rawValue)", ""]
        out += openQuestions.map { "- \(Self.oneLine($0))" }
        if !openQuestions.isEmpty { out.append("") }
        out += ["## \(Section.decisions.rawValue)", ""]
        out += decisions.map { decision in
            "- \(Self.oneLine(decision.text))" + (decision.source.map { " (source: \(Self.oneLine($0)))" } ?? "")
        }
        if !decisions.isEmpty { out.append("") }
        for extra in extras {
            out += ["## \(Self.oneLine(extra.heading))", ""]
            if !extra.body.isEmpty { out += [extra.body, ""] }
        }
        while out.last?.isEmpty == true {
            out.removeLast()
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// A list item is one line: newlines in it become spaces.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// A new goal's file: its title and statement, and empty sections to fill in.
    public static func new(title: String, statement: String) -> GoalDoc {
        GoalDoc(title: title, goal: statement.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The statement's first sentence or line, for lists and the goal pointer.
    public var summary: String {
        let first = goal.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return first.trimmingCharacters(in: .whitespaces)
    }
}
