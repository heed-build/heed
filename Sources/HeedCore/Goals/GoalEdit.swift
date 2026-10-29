import Foundation

/// A change to a goal's `GOAL.md` that the work suggested: a decision taken, a question raised or answered, a criterion
/// met, a new non-goal. Edits that only record what happened apply themselves (each a new version, undoable); edits
/// that
/// change what the goal is wait for you (`GoalEdits.classify`).
public struct GoalEdit: Hashable, Sendable, Codable, Identifiable {
    public enum Section: String, Hashable, Sendable, Codable, CaseIterable {
        case goal, notTheGoal, doneWhen, openQuestions, decisions

        public var title: String {
            switch self {
            case .goal: "Goal"
            case .notTheGoal: "Not the goal"
            case .doneWhen: "Done when"
            case .openQuestions: "Open question"
            case .decisions: "Decision"
            }
        }
    }

    public enum Op: String, Hashable, Sendable, Codable, CaseIterable {
        /// A line added to the section (the goal statement: replaced).
        case add
        /// A line taken out (an open question: answered).
        case remove
        /// A line reworded: `target` becomes `text`.
        case replace
        /// A done-when criterion met, with `evidence`.
        case check
    }

    /// `record`: says what happened, applies itself. `scope`: changes what the goal is, waits for you.
    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        case record, scope
    }

    public enum State: String, Hashable, Sendable, Codable, CaseIterable {
        /// Waiting for you (scope).
        case proposed
        /// In GOAL.md, as version `version`.
        case applied
        /// You said no.
        case rejected
        /// Applied, then undone.
        case undone
        /// Nothing to change by the time it came (already there, or what it changes is gone).
        case moot
    }

    /// Its row in `goals.sqlite`; nil until stored.
    public var id: Int64?
    public var goal: String
    public var section: Section
    public var op: Op
    public var text: String
    /// The line a remove, replace or check is about.
    public var target: String?
    /// What showed it: a PR, a session's words, a review.
    public var evidence: String?
    /// Where it came from, for the card: `Fix broken anchors`, `perf prober`, `chat How do includes…`.
    public var from: String
    /// Why, in a sentence.
    public var reason: String?
    public var kind: Kind
    public var state: State
    public var at: Date
    /// The version it was applied as.
    public var version: Int?

    public init(
        id: Int64? = nil, goal: String, section: Section, op: Op, text: String, target: String? = nil,
        evidence: String? = nil, from: String, reason: String? = nil, kind: Kind? = nil, state: State = .proposed,
        at: Date, version: Int? = nil
    ) {
        self.id = id
        self.goal = goal
        self.section = section
        self.op = op
        self.text = text
        self.target = target
        self.evidence = evidence
        self.from = from
        self.reason = reason
        self.kind = .scope
        self.state = state
        self.at = at
        self.version = version
        self.kind = kind ?? GoalEdits.classify(self)
    }

    /// The edit as one line for the card: `+ Not the goal: ranking across languages`.
    public var line: String {
        switch op {
        case .add: "+ \(section.title): \(text)"
        case .remove: "− \(section.title): \(target ?? text)"
        case .replace: "~ \(section.title): \(text)"
        case .check: "✓ Done when: \(target ?? text)" + (evidence.map { " (\($0))" } ?? "")
        }
    }
}

public enum GoalEdits {
    /// The change a yes or no answers: the first waiting one whose answer is not on its way already (`answering`), so a
    /// key pressed twice before the store answers takes the next change, never the same one twice.
    public static func next(_ proposals: [GoalEdit], answering: Set<Int64>) -> GoalEdit? {
        proposals.first { $0.id.map { !answering.contains($0) } ?? false }
    }

    /// Record or scope, by what the edit does, never by what a model said it was: a decision taken, a question answered
    /// and a criterion met with evidence only record; a new criterion, a non-goal, a new question, a reworded goal or
    /// anything taken out of scope changes it.
    public static func classify(_ edit: GoalEdit) -> GoalEdit.Kind {
        switch (edit.section, edit.op) {
        case (.decisions, .add): .record
        case (.openQuestions, .remove): .record
        case (.doneWhen, .check): edit.evidence?.trimmingCharacters(in: .whitespaces)
            .isEmpty == false ? .record : .scope
        default: .scope
        }
    }

    /// The doc with the edit made; nil when it changes nothing (the line is there already, or what it is about is not).
    public static func apply(_ edit: GoalEdit, to doc: GoalDoc) -> GoalDoc? {
        var doc = doc
        let text = GoalDoc.oneLine(edit.text)
        let target = edit.target.map(GoalDoc.oneLine)
        func find(_ lines: [String], _ line: String?) -> Int? {
            guard let line else { return nil }
            return lines.firstIndex { same($0, line) }
        }
        switch (edit.section, edit.op) {
        case (.goal, .add), (.goal, .replace):
            guard !text.isEmpty,
                  doc.goal != edit.text.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            doc.goal = edit.text.trimmingCharacters(in: .whitespacesAndNewlines)
        case (.goal, _):
            return nil
        case (.notTheGoal, _):
            guard let lines = edited(doc.notTheGoal, edit.op, text: text, target: target) else { return nil }
            doc.notTheGoal = lines
        case (.openQuestions, _):
            guard let lines = edited(doc.openQuestions, edit.op, text: text, target: target ?? text) else { return nil }
            doc.openQuestions = lines
        case (.decisions, .add):
            guard !text.isEmpty, !doc.decisions.contains(where: { same($0.text, text) }) else { return nil }
            doc.decisions.append(GoalDoc.Decision(text, source: edit.evidence ?? edit.from))
        case (.decisions, _):
            let texts = doc.decisions.map(\.text)
            guard let index = find(texts, target ?? text) else { return nil }
            if edit.op == .remove { doc.decisions.remove(at: index) } else if edit.op == .replace {
                guard !text.isEmpty else { return nil }
                doc.decisions[index].text = text
            } else { return nil }
        case (.doneWhen, .add):
            guard !text.isEmpty, !doc.doneWhen.contains(where: { same($0.text, text) }) else { return nil }
            doc.doneWhen.append(GoalDoc.Criterion(text))
        case (.doneWhen, .check):
            guard let index = find(doc.doneWhen.map(\.text), target ?? text), !doc.doneWhen[index].met else {
                return nil
            }
            doc.doneWhen[index].met = true
            doc.doneWhen[index].evidence = edit.evidence.map(GoalDoc.oneLine)
        case (.doneWhen, .remove):
            guard let index = find(doc.doneWhen.map(\.text), target ?? text) else { return nil }
            doc.doneWhen.remove(at: index)
        case (.doneWhen, .replace):
            guard !text.isEmpty, let index = find(doc.doneWhen.map(\.text), target) else { return nil }
            doc.doneWhen[index].text = text
        }
        return doc
    }

    /// The doc with an applied edit taken back out, for undo; nil when it is not there to take out any more.
    public static func revert(_ edit: GoalEdit, in doc: GoalDoc) -> GoalDoc? {
        var doc = doc
        let text = GoalDoc.oneLine(edit.text)
        switch (edit.section, edit.op) {
        case (.decisions, .add):
            guard let index = doc.decisions.firstIndex(where: { same($0.text, text) }) else { return nil }
            doc.decisions.remove(at: index)
        case (.openQuestions, .remove):
            let question = GoalDoc.oneLine(edit.target ?? edit.text)
            guard !doc.openQuestions.contains(where: { same($0, question) }) else { return nil }
            doc.openQuestions.append(question)
        case (.openQuestions, .add):
            guard let index = doc.openQuestions.firstIndex(where: { same($0, text) }) else { return nil }
            doc.openQuestions.remove(at: index)
        case (.notTheGoal, .add):
            guard let index = doc.notTheGoal.firstIndex(where: { same($0, text) }) else { return nil }
            doc.notTheGoal.remove(at: index)
        case (.doneWhen, .add):
            guard let index = doc.doneWhen.firstIndex(where: { same($0.text, text) }) else { return nil }
            doc.doneWhen.remove(at: index)
        case (.doneWhen, .check):
            let line = GoalDoc.oneLine(edit.target ?? edit.text)
            guard let index = doc.doneWhen.firstIndex(where: { same($0.text, line) }), doc.doneWhen[index].met
            else { return nil }
            doc.doneWhen[index].met = false
            doc.doneWhen[index].evidence = nil
        default:
            return nil
        }
        return doc
    }

    private static func edited(_ lines: [String], _ op: GoalEdit.Op, text: String, target: String?) -> [String]? {
        var lines = lines
        switch op {
        case .add:
            guard !text.isEmpty, !lines.contains(where: { same($0, text) }) else { return nil }
            lines.append(text)
        case .remove:
            guard let target, let index = lines.firstIndex(where: { same($0, target) }) else { return nil }
            lines.remove(at: index)
        case .replace:
            guard !text.isEmpty, let target, let index = lines.firstIndex(where: { same($0, target) }) else {
                return nil
            }
            lines[index] = text
        case .check:
            return nil
        }
        return lines
    }

    /// Lines that are the same apart from case, spacing and a closing full stop.
    static func same(_ one: String, _ other: String) -> Bool { key(one) == key(other) }

    static func key(_ text: String) -> String {
        GoalDoc.oneLine(text).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ?!"))
    }

    /// The version note for an edit applied: `decision: hashes live in .artifacts`.
    public static func note(_ edit: GoalEdit) -> String {
        let what = switch (edit.section, edit.op) {
        case (.decisions, .add): "decision"
        case (.openQuestions, .remove): "answered"
        case (.openQuestions, .add): "question"
        case (.doneWhen, .check): "criterion met"
        case (.doneWhen, .add): "criterion"
        case (.notTheGoal, .add): "not the goal"
        case (.goal, _): "the goal"
        default: "\(edit.section.title.lowercased()) \(edit.op.rawValue)"
        }
        let line = GoalDoc.oneLine(edit.target ?? edit.text)
        return "\(what): " + (line.count > 48 ? String(line.prefix(47)) + "…" : line)
    }
}

/// A goal with scope edits waiting for you: one Attention item, however many there are.
public struct GoalNotice: Hashable, Sendable {
    public var goal: String
    public var title: String
    public var proposals: Int
    /// When the newest one came.
    public var at: Date

    public init(goal: String, title: String, proposals: Int, at: Date) {
        self.goal = goal
        self.title = title
        self.proposals = proposals
        self.at = at
    }

    /// The goals (not archived) with proposals waiting, newest first.
    public static func of(_ snapshot: GoalSnapshot) -> [GoalNotice] {
        snapshot.goals.filter { $0.status != .archived }.compactMap { goal in
            let waiting = snapshot.proposals(of: goal.id)
            guard let last = waiting.map(\.at).max() else { return nil }
            return GoalNotice(goal: goal.id, title: goal.title, proposals: waiting.count, at: last)
        }
        .sorted { $0.at != $1.at ? $0.at > $1.at : $0.goal < $1.goal }
    }
}

/// What one GOAL.md version changed from the one before: the lines taken out and the lines put in, in file order.
public enum GoalVersionDiff {
    public struct Line: Hashable, Sendable {
        public var added: Bool
        public var text: String
    }

    /// Blank lines and headings aside, list markers off; a first version adds everything.
    public static func of(old: String?, new: String) -> [Line] {
        func lines(_ text: String?) -> [String] {
            (text ?? "").components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                .map { line in
                    for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
                        return String(line.dropFirst(2))
                    }
                    return line
                }
        }
        let before = lines(old)
        let after = lines(new)
        var remaining = after
        var removed: [Line] = []
        for line in before {
            if let index = remaining.firstIndex(of: line) { remaining.remove(at: index) } else {
                removed.append(Line(added: false, text: line))
            }
        }
        var left = before
        var added: [Line] = []
        for line in after {
            if let index = left.firstIndex(of: line) { left.remove(at: index) } else {
                added.append(Line(added: true, text: line))
            }
        }
        return removed + added
    }
}
