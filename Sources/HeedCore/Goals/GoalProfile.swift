import Foundation

/// What a goal is checked for, and how good each part has to be: a quality lens per reviewer kind, and a bar (0–10)
/// per lens the goal requires. Not every goal needs a 10: a spike needs its code to make sense, a public API needs its
/// docs, its first run and its security looked at too.
public enum GoalLens: String, Hashable, Sendable, Codable, CaseIterable, Comparable {
    case plan, code, tests, perf, security, docs, ux, dx

    public var title: String {
        switch self {
        case .plan: "plan"
        case .code: "code review"
        case .tests: "tests"
        case .perf: "performance"
        case .security: "security"
        case .docs: "docs"
        case .ux: "UX"
        case .dx: "DX first run"
        }
    }

    public static func < (lhs: GoalLens, rhs: GoalLens) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// How much is riding on a goal, and what kind of work it is: decided by a cheap model call from the goal's GOAL.md,
/// its repos and the paths its sessions touched (`GoalProfile.decide`), again on each new GOAL.md version.
public struct GoalProfile: Hashable, Sendable, Codable {
    public enum Stakes: String, Hashable, Sendable, Codable, CaseIterable {
        /// Finding out: thrown away or rewritten.
        case spike
        /// For the team: tools, refactors, internals.
        case `internal`
        /// Something people use.
        case product
        /// Something other code depends on: a CLI, an API, a file format.
        case publicAPI = "public-api"
    }

    public var stakes: Stakes
    public var userFacing: Bool
    public var perfSensitive: Bool
    public var securitySensitive: Bool

    public init(
        stakes: Stakes, userFacing: Bool = false, perfSensitive: Bool = false, securitySensitive: Bool = false
    ) {
        self.stakes = stakes
        self.userFacing = userFacing
        self.perfSensitive = perfSensitive
        self.securitySensitive = securitySensitive
    }

    /// Until a model has looked: internal work, nothing special.
    public static let unknown = GoalProfile(stakes: .internal)

    /// The rows of the bars table that apply: the stakes, then each flag that is set.
    public var rows: [String] {
        var rows = [stakes.rawValue]
        if userFacing { rows.append("user-facing") }
        if perfSensitive { rows.append("perf-sensitive") }
        if securitySensitive { rows.append("security-sensitive") }
        return rows
    }

    /// In words: `public-api · user-facing · security-sensitive`.
    public var text: String { rows.joined(separator: " · ") }

    /// The required lenses and their bars, from the table, with the goal's pins laid over: the highest bar of every
    /// row that applies; a pin replaces it, and a pin of 0 takes the lens off.
    public func bars(_ table: GoalBarTable = .defaults, pins: [GoalLens: Double] = [:]) -> [GoalLens: Double] {
        var bars: [GoalLens: Double] = [:]
        for row in rows {
            for (lens, bar) in table.rows[row] ?? [:] {
                bars[lens] = max(bars[lens] ?? 0, bar)
            }
        }
        for (lens, bar) in pins {
            bars[lens] = min(bar, 10)
        }
        return bars.filter { $0.value > 0 }
    }

    // MARK: Deciding

    /// The questions a model answers about a goal.
    public static let questions: [String: Question] = [
        "stakes": .choice(
            instructions: "How much rides on this goal? spike: an experiment to find out, thrown away or rewritten; "
                + "internal: tooling, refactors or internals only the team sees; product: something people use; "
                + "public-api: something other code depends on (a CLI, a library API, a file format, a protocol).",
            options: Stakes.allCases.map(\.rawValue)
        ),
        "user_facing": .noul(instructions: "People use what this goal changes through a screen or a page."),
        "perf_sensitive": .noul(
            instructions: "The goal is about speed, memory or scale, or its paths are hot ones where a regression "
                + "would hurt."
        ),
        "security_sensitive": .noul(
            instructions: "The goal touches authentication, secrets, permissions, input from outside, or code that "
                + "runs other code."
        ),
    ]

    /// What the model is shown: the GOAL.md, the repos and the paths the goal's work touched, each cut short.
    public static func state(doc: String, repos: [String], paths: [String]) -> String {
        var lines = ["GOAL.md:", String(doc.prefix(6000))]
        if !repos.isEmpty { lines += ["", "Repos: " + repos.joined(separator: ", ")] }
        if !paths.isEmpty {
            lines += ["", "Paths the work touched:"] + paths.prefix(80).map { "- " + $0 }
        }
        return lines.joined(separator: "\n")
    }

    /// The profile from the model's answers: a flag is set when its probability is at least one half.
    public static func from(_ answers: [String: Answer]) -> GoalProfile? {
        guard let stakes = answers["stakes"]?.choice.flatMap(Stakes.init(rawValue:)) else { return nil }
        func flag(_ id: String) -> Bool { (answers[id]?.probability ?? 0) >= 0.5 }
        return GoalProfile(
            stakes: stakes, userFacing: flag("user_facing"), perfSensitive: flag("perf_sensitive"),
            securitySensitive: flag("security_sensitive")
        )
    }

    /// Asks `decider`; nil when it could not answer.
    public static func decide(
        goal: String, doc: String, repos: [String], paths: [String], decider: any Decider
    ) async -> GoalProfile? {
        let answers = try? await decider.decide(
            subject: "goal:\(goal)", state: state(doc: doc, repos: repos, paths: paths), questions: questions
        )
        return answers.flatMap(from)
    }
}

/// `[goals.bars]`: per row (a stakes or a flag), the lenses it requires and their bars, as editable lines:
/// `public-api = "plan 7, code 8, tests 7.5, docs 7, dx 8, security 7"`. A row in config replaces the default row.
public struct GoalBarTable: Hashable, Sendable {
    public var rows: [String: [GoalLens: Double]]

    public init(rows: [String: [GoalLens: Double]]) {
        self.rows = rows
    }

    /// The row names a table may have.
    public static let rowNames = GoalProfile.Stakes.allCases.map(\.rawValue)
        + ["user-facing", "perf-sensitive", "security-sensitive"]

    public static let defaults = GoalBarTable(rows: [
        "spike": [.plan: 5, .code: 6],
        "internal": [.plan: 6, .code: 7, .tests: 6],
        "product": [.plan: 7, .code: 7.5, .tests: 7, .docs: 6],
        "public-api": [.plan: 7, .code: 8, .tests: 7.5, .docs: 7, .dx: 8, .security: 7],
        "user-facing": [.ux: 7],
        "perf-sensitive": [.perf: 7],
        "security-sensitive": [.security: 8],
    ])

    /// `"plan 7, code 8"`; nil when a part is not `<lens> <0–10>`.
    public static func parse(_ text: String) -> [GoalLens: Double]? {
        var row: [GoalLens: Double] = [:]
        for part in text.split(separator: ",") {
            let words = part.split(separator: " ")
            guard words.count == 2, let lens = GoalLens(rawValue: String(words[0]).lowercased()),
                  let bar = Double(words[1]), (0 ... 10).contains(bar)
            else { return nil }
            row[lens] = bar
        }
        return row
    }

    /// A row as config writes it, lenses in their order.
    public static func render(_ row: [GoalLens: Double]) -> String {
        row.sorted { $0.key < $1.key }.map { "\($0.key.rawValue) \(GoalBarTable.number($0.value))" }
            .joined(separator: ", ")
    }

    /// `7`, `7.5`.
    public static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// One lens's bar moving between two profiles: up, down, on or off. Raises and lowerings both apply at once; each is
/// written down with why, and shown.
public struct BarChange: Hashable, Sendable, Codable {
    public var lens: GoalLens
    /// nil: the lens was not required.
    public var from: Double?
    public var to: Double?

    public init(lens: GoalLens, from: Double?, to: Double?) {
        self.lens = lens
        self.from = from
        self.to = to
    }

    public var raised: Bool { (to ?? 0) > (from ?? 0) }

    /// `DX first run now 8 (was –)`.
    public var text: String {
        let was = from.map(GoalBarTable.number) ?? "–"
        guard let to else { return "\(lens.title) no longer required (was \(was))" }
        return "\(lens.title) now \(GoalBarTable.number(to)) (was \(was))"
    }

    /// What moved from `old` to `new`, lenses in order.
    public static func between(_ old: [GoalLens: Double], _ new: [GoalLens: Double]) -> [BarChange] {
        Set(old.keys).union(new.keys).sorted().compactMap { lens in
            old[lens] == new[lens] ? nil : BarChange(lens: lens, from: old[lens], to: new[lens])
        }
    }

    /// The note a profile change is written with: what the profile is now, then each change.
    public static func note(profile: GoalProfile, changes: [BarChange]) -> String {
        guard !changes.isEmpty else { return profile.text }
        return profile.text + " → " + changes.map(\.text).joined(separator: "; ")
    }
}
