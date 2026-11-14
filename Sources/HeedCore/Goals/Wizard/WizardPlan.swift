import Foundation

/// One turn of step 1's conversation: heed's question with the options it offers, or your answer.
public struct PlanTurn: Hashable, Sendable, Codable {
    public enum Role: String, Hashable, Sendable, Codable {
        case heed, you
    }

    public var role: Role
    public var text: String
    /// heed's options for the question (`1 2 3` pick one); empty for an answer.
    public var options: [String]
    /// On heed's question: the options your answer picked (indexes); empty when you typed one.
    public var picked: [Int]
    /// The model that asked.
    public var model: String?

    public init(role: Role, text: String, options: [String] = [], picked: [Int] = [], model: String? = nil) {
        self.role = role
        self.text = text
        self.options = options
        self.picked = picked
        self.model = model
    }
}

/// The plan as the conversation builds it. Every version is also saved as a `GOAL.md` version (`apply(to:)`): the goal,
/// what it is not and the decisions in heed's sections, the steps, constraints, risks and who it is for in sections of
/// their own that agents read.
public struct WizardPlan: Hashable, Sendable, Codable {
    public var title: String
    public var summary: String
    public var steps: [String]
    public var constraints: [String]
    public var risks: [String]
    public var audience: String
    public var outOfScope: [String]
    public var decisions: [String]

    public init(
        title: String, summary: String = "", steps: [String] = [], constraints: [String] = [], risks: [String] = [],
        audience: String = "", outOfScope: [String] = [], decisions: [String] = []
    ) {
        self.title = title
        self.summary = summary
        self.steps = steps
        self.constraints = constraints
        self.risks = risks
        self.audience = audience
        self.outOfScope = outOfScope
        self.decisions = decisions
    }

    /// The headings of the plan's own sections in `GOAL.md`.
    public static let stepsHeading = "Plan"
    public static let constraintsHeading = "Constraints"
    public static let risksHeading = "Risks"
    public static let audienceHeading = "Who it is for"

    /// The doc with this plan in it: what you wrote by hand elsewhere stays; the plan's sections are replaced.
    public func apply(to doc: GoalDoc) -> GoalDoc {
        var doc = doc
        if !title.isEmpty { doc.title = title }
        if !summary.isEmpty { doc.goal = summary }
        if !outOfScope.isEmpty { doc.notTheGoal = outOfScope }
        for decision in decisions where !doc.decisions.contains(where: { $0.text == decision }) {
            doc.decisions.append(GoalDoc.Decision(decision, source: "plan"))
        }
        let own: [(String, String)] = [
            (Self.stepsHeading, steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")),
            (Self.constraintsHeading, constraints.map { "- \($0)" }.joined(separator: "\n")),
            (Self.risksHeading, risks.map { "- \($0)" }.joined(separator: "\n")),
            (Self.audienceHeading, audience),
        ]
        let headings = Set(own.map { $0.0.lowercased() })
        doc.extras.removeAll { headings.contains($0.heading.lowercased()) }
        doc.extras = own.filter { !$0.1.isEmpty }.map { GoalDoc.Extra(heading: $0.0, body: $0.1) } + doc.extras
        return doc
    }

    /// The plan a `GOAL.md` holds: what `apply` wrote, read back; a goal made by hand reads as its title and goal.
    public static func read(_ doc: GoalDoc) -> WizardPlan {
        func extra(_ heading: String) -> String? {
            doc.extras.first { $0.heading.lowercased() == heading.lowercased() }?.body
        }
        func list(_ heading: String) -> [String] {
            extra(heading).map { GoalDoc.bullets($0.components(separatedBy: "\n")).map(\.text) } ?? []
        }
        return WizardPlan(
            title: doc.title, summary: doc.goal, steps: list(stepsHeading), constraints: list(constraintsHeading),
            risks: list(risksHeading), audience: extra(audienceHeading) ?? "", outOfScope: doc.notTheGoal,
            decisions: doc.decisions.filter { $0.source == "plan" }.map(\.text)
        )
    }

    /// Read leniently from a model's JSON object.
    static func from(_ object: [String: Any], fallbackTitle: String) -> WizardPlan {
        func list(_ key: String) -> [String] {
            if let items = object[key] as? [Any] {
                return items.compactMap { ($0 as? String).map(GoalDoc.oneLine) }.filter { !$0.isEmpty }
            }
            if let text = object[key] as? String, !text.isEmpty { return [GoalDoc.oneLine(text)] }
            return []
        }
        func text(_ key: String) -> String {
            if let text = object[key] as? String { return GoalDoc.oneLine(text) }
            return list(key).joined(separator: "; ")
        }
        let title = text("title")
        return WizardPlan(
            title: title.isEmpty ? fallbackTitle : title, summary: text("summary"), steps: list("steps"),
            constraints: list("constraints"), risks: list("risks"),
            audience: text(object["audience"] != nil ? "audience" : "who"),
            outOfScope: list(object["outOfScope"] != nil ? "outOfScope" : "out_of_scope"), decisions: list("decisions")
        )
    }
}

/// How complete the plan is for agents to take on: five meters, 0–100, scored by a cheap model each turn.
public struct Completeness: Hashable, Sendable, Codable {
    public enum Dimension: String, Hashable, Sendable, Codable, CaseIterable {
        case scope, constraints, risks, audience, outOfScope

        public var label: String {
            switch self {
            case .scope: "scope"
            case .constraints: "constraints"
            case .risks: "risks"
            case .audience: "who it's for"
            case .outOfScope: "out of scope"
            }
        }

        /// What heed asks about next when this is the weakest.
        public var gap: String {
            switch self {
            case .scope: "what exactly changes"
            case .constraints: "what it must keep working or must not change"
            case .risks: "what could go wrong"
            case .audience: "who it is for"
            case .outOfScope: "what it is not"
            }
        }
    }

    /// By the dimension's raw value, so it encodes as a JSON object and the same every time.
    public var scores: [String: Int]

    public init(_ scores: [Dimension: Int] = [:]) {
        self.scores = Dictionary(uniqueKeysWithValues: scores.map { ($0.key.rawValue, min(max($0.value, 0), 100)) })
    }

    public subscript(_ dimension: Dimension) -> Int { scores[dimension.rawValue] ?? 0 }

    /// The mean of the five.
    public var overall: Int {
        Dimension.allCases.map { self[$0] }.reduce(0, +) / Dimension.allCases.count
    }

    /// The meter that is furthest behind.
    public var weakest: Dimension {
        Dimension.allCases.min { self[$0] < self[$1] } ?? .scope
    }

    /// Complete enough for agents: no meter under 40, scope at least 70, and 65 on average. "Good enough" moves on
    /// whatever the meters say; this is when heed stops asking on its own.
    public var enough: Bool {
        Dimension.allCases.allSatisfy { self[$0] >= 40 } && self[.scope] >= 70 && overall >= 65
    }

    /// Read from a model's answer: `{"scope": 90, "constraints": 75, …}`, keys in any of the usual spellings, values as
    /// numbers or strings, 0–1 read as a fraction. Nil when it names none of the five.
    public static func parse(_ text: String) -> Completeness? {
        guard let data = LLMDialect.jsonObject(in: text),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let source = object["completeness"] as? [String: Any] ?? object
        var scores: [Dimension: Int] = [:]
        for (key, value) in source {
            let normalized = key.lowercased().filter(\.isLetter)
            let dimension: Dimension? = switch normalized {
            case "scope": .scope
            case "constraints", "constraint": .constraints
            case "risks", "risk": .risks
            case "audience", "whoitsfor", "who", "users", "whoitisfor": .audience
            case "outofscope", "nongoals", "notthegoal": .outOfScope
            default: nil
            }
            guard let dimension else { continue }
            var number = (value as? NSNumber)?.doubleValue ?? Double("\(value)".filter { $0.isNumber || $0 == "." })
            if let fraction = number, fraction > 0, fraction <= 1, !"\(value)".contains("100") {
                number = fraction * 100
            }
            if let number { scores[dimension] = Int(number.rounded()) }
        }
        return scores.isEmpty ? nil : Completeness(scores)
    }
}

/// Step 1: the conversation, the plan's versions (each one also a `GOAL.md` version) and the meters.
public struct PlanConversation: Hashable, Sendable, Codable {
    public var turns: [PlanTurn]
    public var versions: [PlanVersion]
    public var completeness: Completeness?

    public init(turns: [PlanTurn] = [], versions: [PlanVersion] = [], completeness: Completeness? = nil) {
        self.turns = turns
        self.versions = versions
        self.completeness = completeness
    }

    /// The plan now: its latest version.
    public var current: WizardPlan? { versions.last?.plan }

    /// heed's question still waiting for an answer.
    public var open: PlanTurn? {
        guard let last = turns.last, last.role == .heed else { return nil }
        return last
    }

    /// Answers you gave.
    public var answers: Int { turns.count { $0.role == .you } }

    /// Your answer to heed's open question with its option `index` (0-based): the question marks what was picked.
    /// Nil when nothing is open or there is no such option.
    public mutating func pick(_ index: Int) -> String? {
        guard let last = turns.indices.last, turns[last].role == .heed,
              turns[last].options.indices.contains(index)
        else { return nil }
        turns[last].picked = [index]
        let text = turns[last].options[index]
        turns.append(PlanTurn(role: .you, text: text))
        return text
    }

    public mutating func answer(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        turns.append(PlanTurn(role: .you, text: text))
    }

    /// A new version when the plan changed; its number.
    @discardableResult
    public mutating func add(_ plan: WizardPlan, goalVersion: Int?) -> Int? {
        guard plan != current else { return nil }
        let number = (versions.last?.number ?? 0) + 1
        versions.append(PlanVersion(number: number, plan: plan, goalVersion: goalVersion))
        return number
    }
}

/// A version of the plan, and the `GOAL.md` version it was saved as.
public struct PlanVersion: Hashable, Sendable, Codable {
    public var number: Int
    public var plan: WizardPlan
    public var goalVersion: Int?

    public init(number: Int, plan: WizardPlan, goalVersion: Int?) {
        self.number = number
        self.plan = plan
        self.goalVersion = goalVersion
    }
}
