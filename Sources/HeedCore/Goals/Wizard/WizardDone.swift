import Foundation

/// How a done-when criterion is checked: a test, a CI step, a command, or nothing yet.
public struct CriterionCheck: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        case test, ci, command, none

        public init?(word: String) {
            switch word.lowercased().trimmingCharacters(in: .whitespaces) {
            case "test", "tests", "unit", "unit test": self = .test
            case "ci", "ci step", "workflow", "check", "build": self = .ci
            case "command", "cmd", "script", "run", "drill", "make": self = .command
            case "none", "", "manual", "nothing": self = .none
            default: return nil
            }
        }
    }

    public var kind: Kind
    /// What runs it: a test's name, a CI step, a command line.
    public var target: String
    /// Proposed, not there yet (a test to write): it counts for half.
    public var proposed: Bool

    public init(_ kind: Kind, _ target: String = "", proposed: Bool = false) {
        self.kind = kind
        self.target = target
        self.proposed = proposed
    }

    public static let none = CriterionCheck(.none)

    /// `test RedirectTargetsTests`, `ci docs build · anchors`, `command make check`; proposed ones say so.
    public var label: String {
        guard kind != .none else { return "nothing checks this yet" }
        return (proposed ? "proposed: " : "") + (target.isEmpty ? kind.rawValue : target)
    }

    /// As written after a criterion in GOAL.md: `(check: test RedirectTargetsTests)`.
    var written: String {
        "\(kind.rawValue)\(proposed ? " proposed" : "")\(target.isEmpty ? "" : " " + target)"
    }

    /// Reads `test proposed BackfillResumeTests` back.
    static func read(_ text: String) -> CriterionCheck {
        var words = text.split(separator: " ").map(String.init)
        guard let first = words.first, let kind = Kind(word: first) else { return CriterionCheck(.command, text) }
        words.removeFirst()
        let proposed = words.first == "proposed"
        if proposed { words.removeFirst() }
        return CriterionCheck(kind, words.joined(separator: " "), proposed: proposed)
    }
}

/// A done-when criterion as step 3 drafts it: the line, and how it is checked.
public struct DoneCriterion: Hashable, Sendable, Codable {
    public var text: String
    public var check: CriterionCheck

    public init(_ text: String, check: CriterionCheck = .none) {
        self.text = text
        self.check = check
    }

    /// 0–1: how surely an agent can tell it is met (`Checkability`).
    public var checkability: Double { Checkability.score(self) }
    public var vague: Bool { Checkability.vague(text) && check.kind == .none }
}

/// How checkable a criterion is. A real check counts in full, a proposed one half; a line with no check scores on its
/// words: a number or a named thing to look at scores some, words like "fast" or "nice" score nothing.
public enum Checkability {
    /// Words that cannot be checked as they stand.
    static let vagueWords: Set<String> = [
        "fast", "faster", "quick", "quickly", "nice", "nicer", "better", "easy", "easier", "clean", "cleaner",
        "intuitive", "robust", "feel", "feels", "smooth", "simple", "simpler", "good", "properly", "seamless",
        "seamlessly", "friendly", "snappy", "reliable", "polished", "modern", "elegant", "well", "great",
    ]

    /// The line has a word that cannot be checked and no number to pin it down.
    public static func vague(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let hasNumber = text.contains { $0.isNumber }
        return !hasNumber && words.contains { vagueWords.contains($0) }
    }

    public static func score(_ criterion: DoneCriterion) -> Double {
        switch criterion.check.kind {
        case .test, .ci, .command:
            let base = criterion.check.proposed ? 0.5 : 1.0
            return vague(criterion.text) ? base * 0.5 : base
        case .none:
            if vague(criterion.text) { return 0 }
            return criterion.text.contains { $0.isNumber } ? 0.25 : 0.1
        }
    }

    /// Checked, proposed and vague-or-unchecked counts, for the header's `✓ 3 ? 1 ? 1`.
    public static func tally(_ criteria: [DoneCriterion]) -> (checked: Int, proposed: Int, unchecked: Int) {
        var checked = 0
        var proposed = 0
        var unchecked = 0
        for criterion in criteria {
            switch criterion.check.kind {
            case .none: unchecked += 1
            default: if criterion.check.proposed { proposed += 1 } else { checked += 1 }
            }
        }
        return (checked, proposed, unchecked)
    }

    /// `3 tests · 1 CI step · 1 command`, for the TL;DR.
    public static func kinds(_ criteria: [DoneCriterion]) -> String {
        var parts: [String] = []
        for (kind, one, many) in [
            (CriterionCheck.Kind.test, "test", "tests"), (.ci, "CI step", "CI steps"), (
                .command,
                "command",
                "commands"
            ),
        ] {
            let count = criteria.count { $0.check.kind == kind }
            if count > 0 { parts.append("\(count) \(count == 1 ? one : many)") }
        }
        return parts.joined(separator: " · ")
    }
}

/// Step 3: the statement and criteria drafted from the agreed plan, with measurable replacements for vague ones.
public struct DoneDraft: Hashable, Sendable, Codable {
    public var statement: String
    public var criteria: [DoneCriterion]
    public var notTheGoal: [String]
    /// Measurable replacements for a criterion, by its index as text (so it encodes the same every time), once asked
    /// for. `replacements(for:)` reads them.
    public var replacements: [String: [String]]
    /// The plan version it was drafted from.
    public var fromPlan: Int?

    public init(
        statement: String = "", criteria: [DoneCriterion] = [], notTheGoal: [String] = [],
        replacements: [String: [String]] = [:], fromPlan: Int? = nil
    ) {
        self.statement = statement
        self.criteria = criteria
        self.notTheGoal = notTheGoal
        self.replacements = replacements
        self.fromPlan = fromPlan
    }

    public func replacements(for index: Int) -> [String]? { replacements[String(index)] }

    public mutating func set(replacements: [String], for index: Int) {
        byIndex[index] = replacements
    }

    private var byIndex: [Int: [String]] {
        get { Dictionary(uniqueKeysWithValues: replacements.compactMap { key, value in Int(key).map { ($0, value) } }) }
        set { replacements = Dictionary(uniqueKeysWithValues: newValue.map { (String($0.key), $0.value) }) }
    }

    public var drafted: Bool { !criteria.isEmpty }

    /// Every criterion has a check (proposed counts).
    public var allCheckable: Bool { !criteria.isEmpty && criteria.allSatisfy { $0.check.kind != .none } }

    /// The first criterion nothing checks yet.
    public var firstVague: Int? { criteria.firstIndex { $0.check.kind == .none } }

    /// The criterion at `index` replaced by `text`, its check kept only when it had one.
    public mutating func replace(_ index: Int, with text: String) {
        guard criteria.indices.contains(index) else { return }
        criteria[index].text = text
        replacements[String(index)] = nil
    }

    public mutating func drop(_ index: Int) {
        guard criteria.indices.contains(index) else { return }
        criteria.remove(at: index)
        var moved: [Int: [String]] = [:]
        for (key, value) in byIndex where key != index {
            moved[key > index ? key - 1 : key] = value
        }
        byIndex = moved
    }

    /// The doc with these as its Done when (in the existing format, the check after each line as `(check: …)`), its
    /// goal statement and what it is not. Criteria already met keep their mark and evidence.
    public func apply(to doc: GoalDoc) -> GoalDoc {
        var doc = doc
        if !statement.isEmpty { doc.goal = statement }
        if !notTheGoal.isEmpty { doc.notTheGoal = notTheGoal }
        let before = doc.doneWhen
        doc.doneWhen = criteria.map { criterion in
            let text = criterion.check.kind == .none ? criterion.text
                : "\(criterion.text) (check: \(criterion.check.written))"
            let old = before.first { Self.read($0).text == criterion.text }
            return GoalDoc.Criterion(text, met: old?.met ?? false, evidence: old?.evidence)
        }
        return doc
    }

    /// A Done when line read back as text and check.
    public static func read(_ criterion: GoalDoc.Criterion) -> DoneCriterion {
        let (text, check) = GoalDoc.trailing("check", of: criterion.text)
        return DoneCriterion(text, check: check.map(CriterionCheck.read) ?? .none)
    }

    /// The draft a model wrote: `{"statement": "...", "criteria": [{"text": "...", "check": "test", "target": "...",
    /// "proposed": false}], "notTheGoal": ["..."]}`. Nil without criteria.
    public static func parse(_ text: String, fromPlan: Int?) -> DoneDraft? {
        guard let data = LLMDialect.jsonObject(in: text),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let rows = (object["criteria"] ?? object["doneWhen"]) as? [Any] ?? []
        let criteria: [DoneCriterion] = rows.compactMap { row in
            if let line = row as? String { return DoneCriterion(GoalDoc.oneLine(line)) }
            guard let dict = row as? [String: Any], let line = dict["text"] as? String else { return nil }
            var check = CriterionCheck.none
            if let checkObject = dict["check"] as? [String: Any] {
                check = CriterionCheck(
                    CriterionCheck.Kind(word: checkObject["kind"] as? String ?? "") ?? .none,
                    GoalDoc.oneLine(checkObject["target"] as? String ?? ""),
                    proposed: checkObject["proposed"] as? Bool ?? false
                )
            } else if let kind = CriterionCheck.Kind(word: dict["check"] as? String ?? "") {
                check = CriterionCheck(
                    kind, GoalDoc.oneLine(dict["target"] as? String ?? ""), proposed: dict["proposed"] as? Bool ?? false
                )
            }
            return DoneCriterion(GoalDoc.oneLine(line), check: check)
        }
        .filter { !$0.text.isEmpty }
        guard !criteria.isEmpty else { return nil }
        let notTheGoal = ((object["notTheGoal"] ?? object["outOfScope"]) as? [Any] ?? [])
            .compactMap { ($0 as? String).map(GoalDoc.oneLine) }.filter { !$0.isEmpty }
        return DoneDraft(
            statement: GoalDoc.oneLine(object["statement"] as? String ?? ""), criteria: criteria,
            notTheGoal: notTheGoal, fromPlan: fromPlan
        )
    }

    /// Replacements a model suggested: `{"replacements": ["..."]}`, at most three, the vague ones left out.
    public static func parseReplacements(_ text: String) -> [String] {
        guard let data = LLMDialect.jsonObject(in: text),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }
        let rows = (object["replacements"] ?? object["options"]) as? [Any] ?? []
        return Array(rows.compactMap { ($0 as? String).map(GoalDoc.oneLine) }
            .filter { !$0.isEmpty && !Checkability.vague($0) }.prefix(3))
    }
}
