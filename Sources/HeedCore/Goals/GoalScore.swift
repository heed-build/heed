import Foundation

/// A number heed shows with what it is based on: a reviewer's happiness, a goal's confidence.
public struct GoalScore: Hashable, Sendable, Codable {
    /// 0–10.
    public var value: Double
    /// What it is made of, in a sentence.
    public var basis: String

    public init(value: Double, basis: String) {
        self.value = value
        self.basis = basis
    }

    /// What a fixed objection gives back, each, up to `fixedCreditCap`.
    public static let fixedCredit = 0.3
    public static let fixedCreditCap = 1.5
    /// What an accepted risk still costs, as a share of its weight: accepted is not fixed.
    public static let acceptedShare = 0.25

    /// A reviewer's score: 10, minus each open objection's weight by severity (high 3, med 1.5, low 0.5), minus a
    /// quarter of that for each accepted risk, plus 0.3 for each fixed one (at most 1.5); clamped to 0–10 and rounded
    /// to a tenth. `ran` and `files` go into the basis.
    public static func reviewer(_ objections: [Objection], ran: Int = 0, files: Int = 0) -> GoalScore {
        let open = objections.filter { $0.state == .open }
        let accepted = objections.filter { $0.state == .acceptedRisk }
        let fixed = objections.count { $0.state == .fixed }
        let openMinus = open.reduce(0) { $0 + $1.severity.weight }
        let acceptedMinus = accepted.reduce(0) { $0 + $1.severity.weight * acceptedShare }
        let credit = min(Double(fixed) * fixedCredit, fixedCreditCap)
        let value = rounded(min(max(10 - openMinus - acceptedMinus + credit, 0), 10))
        var parts = ["10"]
        if !open.isEmpty {
            parts.append("minus \(GoalBarTable.number(rounded(openMinus))) for \(count(open.count, "open"))")
        }
        if !accepted.isEmpty {
            parts.append("minus \(GoalBarTable.number(rounded(acceptedMinus))) for "
                + count(accepted.count, "accepted risk", plural: "accepted risks"))
        }
        if fixed > 0 { parts.append("plus \(GoalBarTable.number(credit)) for \(count(fixed, "fixed"))") }
        var basis = parts.joined(separator: ", ")
        if open.isEmpty, accepted.isEmpty, fixed == 0 { basis = "10: nothing open" }
        var seen: [String] = []
        if files > 0 { seen.append(count(files, "file", plural: "files")) }
        if ran > 0 { seen.append(count(ran, "command run", plural: "commands run")) }
        if !seen.isEmpty { basis += ". Based on " + seen.joined(separator: " and ") }
        return GoalScore(value: value, basis: basis + ".")
    }

    /// One required lens: its bar and its reviewer's score, if it has one yet.
    public struct Lens: Hashable, Sendable, Codable {
        public var lens: GoalLens
        public var bar: Double
        public var score: Double?

        public init(lens: GoalLens, bar: Double, score: Double?) {
            self.lens = lens
            self.bar = bar
            self.score = score
        }

        public var met: Bool { (score ?? -1) >= bar }
        /// How far toward its bar, 0–1.
        public var progress: Double { bar <= 0 ? 1 : min((score ?? 0) / bar, 1) }
    }

    /// A goal's confidence: half how many done-when criteria are met, half how far each required lens is toward its
    /// bar (a lens nobody scored counts 0); either half alone when the other has nothing to count. Nil with neither.
    public static func confidence(met: Int, total: Int, lenses: [Lens]) -> GoalScore? {
        let criteria = total > 0 ? Double(met) / Double(total) : nil
        let quality = lenses.isEmpty ? nil : lenses.reduce(0) { $0 + $1.progress } / Double(lenses.count)
        let blend: Double
        switch (criteria, quality) {
        case let (criteria?, quality?): blend = (criteria + quality) / 2
        case let (criteria?, nil): blend = criteria
        case let (nil, quality?): blend = quality
        case (nil, nil): return nil
        }
        var parts: [String] = []
        if total > 0 { parts.append("\(met)/\(total) criteria met") }
        if !lenses.isEmpty {
            parts.append("\(lenses.count { $0.met }) of \(count(lenses.count, "lens", plural: "lenses")) at their bar")
        }
        let weighting = criteria != nil && quality != nil ? ", weighed half and half" : ""
        return GoalScore(value: rounded(blend * 10), basis: parts.joined(separator: ", ") + weighting + ".")
    }

    /// Whether the goal is done: it has done-when criteria, each met with evidence, and every required lens is at or
    /// over its bar. The reasons it is not, when it is not.
    public static func done(doc: GoalDoc, lenses: [Lens]) -> (done: Bool, missing: [String]) {
        var missing: [String] = []
        if doc.doneWhen.isEmpty { missing.append("no done-when criteria") }
        let open = doc.doneWhen.count { !$0.met || ($0.evidence ?? "").isEmpty }
        if open > 0 { missing.append(count(open, "criterion", plural: "criteria") + " without evidence") }
        for lens in lenses.sorted(by: { $0.lens < $1.lens }) where !lens.met {
            let score = lens.score.map(GoalBarTable.number) ?? "–"
            missing.append("\(lens.lens.title) \(score) under \(GoalBarTable.number(lens.bar))")
        }
        return (missing.isEmpty, missing)
    }

    static func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    static func count(_ number: Int, _ word: String, plural: String? = nil) -> String {
        "\(number) \(number == 1 ? word : plural ?? word)"
    }
}
