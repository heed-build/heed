import CryptoKit
import Foundation

/// A kind of reviewer: an agent run that reads the goal and its work, never edits it, and writes what it objects to.
public enum ReviewerKind: String, Hashable, Sendable, Codable, CaseIterable {
    case planCritic = "plan-critic"
    case implementation
    case perfProber = "perf-prober"
    case security
    case testArchitect = "test-architect"
    case docsReader = "docs-reader"
    /// Stranger walks: a fresh clone, the README only, a friction log (`EvaluationLens`, `EvaluationRun`).
    case uxEvaluator = "ux-evaluator"
    case dxEvaluator = "dx-evaluator"
    /// Your own instructions; required by no lens.
    case custom

    public var title: String {
        switch self {
        case .planCritic: "Plan critic"
        case .implementation: "Implementation reviewer"
        case .perfProber: "Performance prober"
        case .security: "Security reviewer"
        case .testArchitect: "Test architect"
        case .docsReader: "Docs reader"
        case .uxEvaluator: "UX evaluator"
        case .dxEvaluator: "DX evaluator"
        case .custom: "Custom reviewer"
        }
    }

    /// The chip in the spawn panel.
    public var short: String {
        switch self {
        case .planCritic: "Plan critic"
        case .implementation: "Implementation"
        case .perfProber: "Perf prober"
        case .security: "Security"
        case .testArchitect: "Test architect"
        case .docsReader: "Docs reader"
        case .uxEvaluator: "UX evaluator"
        case .dxEvaluator: "DX evaluator"
        case .custom: "Custom…"
        }
    }

    /// The lens its score counts for.
    public var lens: GoalLens? {
        switch self {
        case .planCritic: .plan
        case .implementation: .code
        case .perfProber: .perf
        case .security: .security
        case .testArchitect: .tests
        case .docsReader: .docs
        case .uxEvaluator: .ux
        case .dxEvaluator: .dx
        case .custom: nil
        }
    }

    /// The kind that scores a lens.
    public static func of(_ lens: GoalLens) -> ReviewerKind {
        allCases.first { $0.lens == lens }!
    }

    /// Kinds whose runs are stranger walks (the docs reader walks too when spawned for a docs walk).
    public var isEvaluator: Bool { self == .uxEvaluator || self == .dxEvaluator }

    /// The model it runs on unless `[goals.reviewers]` says otherwise: judgement calls on the best one.
    public var defaultTier: ModelTier {
        switch self {
        case .planCritic, .implementation, .security, .custom: .best
        case .perfProber, .testArchitect, .docsReader, .uxEvaluator, .dxEvaluator: .cheap
        }
    }

    /// What it is asked to do.
    public var brief: String {
        switch self {
        case .planCritic:
            "Critique the plan: is the goal the right one, are the done-when criteria checkable, what is missing or "
                + "risky in the approach the work takes, and which open questions block it."
        case .implementation:
            "Review the implementation against the goal: correctness, edge cases, structure, and whether it does what "
                + "the done-when criteria ask. Run the tests if you can."
        case .perfProber:
            "Probe performance: find hot paths the change touches, measure what you can (benchmarks, timings), and say "
                + "where it is slow or grows without bound. Say when a baseline is missing."
        case .security:
            "Review security: input from outside, secrets, permissions, injection, code that runs other code."
        case .testArchitect:
            "Review the tests: do they cover the done-when criteria, would they fail if the code broke, what is "
                + "untested. Run them."
        case .docsReader:
            "Read the docs as a newcomer would: is what changed documented, is it right, can someone follow it."
        case .uxEvaluator:
            "Review the user experience of what changed as someone new would meet it: what is confusing, slow or "
                + "inconsistent. Read the code and docs for the screens it touches."
        case .dxEvaluator:
            "Review the developer experience of a first run as a stranger: from the README, could you install, "
                + "configure and use what changed? Where would you get stuck?"
        case .custom: "Review the work as the instructions below say."
        }
    }
}

/// Which model a reviewer runs on: the agent's default (best) or its cheap one.
public enum ModelTier: String, Hashable, Sendable, Codable, CaseIterable {
    case best, cheap
}

/// When a reviewer looks again on its own.
public enum ReviewPolicy: String, Hashable, Sendable, Codable, CaseIterable {
    /// When the work changes: a PR on the goal opened, updated or merged, a new GOAL.md version; and the nightly sweep.
    case onChange = "on-change"
    case nightly
    /// Only when you press re-check.
    case manual

    public var text: String {
        switch self {
        case .onChange: "when the work changes"
        case .nightly: "nightly"
        case .manual: "only when I ask"
        }
    }
}

/// How bad an objection is.
public enum Severity: String, Hashable, Sendable, Codable, CaseIterable, Comparable {
    case high, med, low

    /// How much an open one takes off a reviewer's score.
    public var weight: Double {
        switch self {
        case .high: 3
        case .med: 1.5
        case .low: 0.5
        }
    }

    public var label: String { rawValue.uppercased() }

    public init?(loose text: String) {
        switch text.lowercased() {
        case "high", "critical", "blocker", "major": self = .high
        case "med", "medium", "moderate": self = .med
        case "low", "minor", "nit", "info": self = .low
        default: return nil
        }
    }

    public static func < (lhs: Severity, rhs: Severity) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// One thing a reviewer is unhappy about, kept across its re-checks.
public struct Objection: Hashable, Sendable, Codable, Identifiable {
    public enum State: String, Hashable, Sendable, Codable, CaseIterable {
        case open, fixed
        case acceptedRisk = "accepted-risk"

        public var text: String {
            switch self {
            case .open: "open"
            case .fixed: "fixed"
            case .acceptedRisk: "you accepted the risk"
            }
        }
    }

    /// Stable across re-checks (`ObjectionMatch.id`).
    public var id: String
    public var severity: Severity
    public var text: String
    public var evidence: String?
    public var file: String?
    public var state: State
    public var firstSeen: Date
    public var lastSeen: Date
    /// When a re-check no longer raised it.
    public var fixedAt: Date?

    public init(
        id: String, severity: Severity, text: String, evidence: String? = nil, file: String? = nil,
        state: State = .open, firstSeen: Date, lastSeen: Date? = nil, fixedAt: Date? = nil
    ) {
        self.id = id
        self.severity = severity
        self.text = text
        self.evidence = evidence
        self.file = file
        self.state = state
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen ?? firstSeen
        self.fixedAt = fixedAt
    }
}

/// What a reviewer run wrote: `review.json`.
public struct ReviewReport: Hashable, Sendable, Codable {
    public struct Raised: Hashable, Sendable, Codable {
        public var severity: Severity
        public var text: String
        public var evidence: String?
        public var file: String?

        public init(severity: Severity, text: String, evidence: String? = nil, file: String? = nil) {
            self.severity = severity
            self.text = text
            self.evidence = evidence
            self.file = file
        }
    }

    /// A line or two: how happy it is and why.
    public var summary: String
    public var objections: [Raised]
    /// Commands it ran (tests, benchmarks).
    public var ran: [String]
    /// Files it read.
    public var files: Int
    /// An evaluator's walk: its steps, their times and its friction log (whose entries are `objections`).
    public var walk: EvaluationWalk?

    public init(
        summary: String, objections: [Raised], ran: [String] = [], files: Int = 0, walk: EvaluationWalk? = nil
    ) {
        self.summary = summary
        self.objections = objections
        self.ran = ran
        self.files = files
        self.walk = walk
    }

    /// A walk as its evaluator's review: its summary, and its friction as the objections.
    public init(walk: EvaluationWalk) {
        self.init(summary: walk.summary, objections: walk.raised, walk: walk)
    }

    /// The file's name, in the run's worktree under `.heed/`.
    public static let fileName = "review.json"

    /// `review.json`, read leniently: severities in other words (`medium`, `critical`), `objections` or `findings`,
    /// `ran` as strings or as objects with a `command`; objections without text are dropped. Nil when it is not a JSON
    /// object.
    public static func parse(_ data: Data) -> ReviewReport? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func text(_ value: Any?) -> String? {
            guard let string = value as? String else { return nil }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let list = (object["objections"] ?? object["findings"]) as? [[String: Any]] ?? []
        let raised = list.compactMap { entry -> Raised? in
            guard let body = text(entry["text"] ?? entry["title"] ?? entry["message"]) else { return nil }
            let severity = text(entry["severity"]).flatMap(Severity.init(loose:)) ?? .med
            return Raised(
                severity: severity, text: body, evidence: text(entry["evidence"]), file: text(entry["file"])
            )
        }
        let ran: [String] = (object["ran"] as? [Any] ?? []).compactMap { item in
            text(item) ?? text((item as? [String: Any])?["command"])
        }
        let files = (object["files"] as? Int) ?? (object["files"] as? [Any])?.count ?? 0
        return ReviewReport(
            summary: text(object["summary"]) ?? "", objections: raised, ran: ran, files: files
        )
    }
}

/// Telling objections apart across re-checks: the same complaint worded the same way keeps its id; reworded, a close
/// one is matched by its words; what is left a model may match (`ObjectionMatch.ask`).
public enum ObjectionMatch {
    /// Words that say little about which objection it is.
    static let filler: Set<String> = [
        "a", "an", "the", "is", "are", "be", "it", "its", "of", "to", "in", "on", "and", "or", "not", "no", "for",
        "with", "by", "this", "that", "there", "as", "at", "from", "does", "do", "has", "have",
    ]

    /// The words that carry it: lowercased, letters and digits only, filler dropped.
    public static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init).filter { !filler.contains($0) }
    }

    /// A stable id from the normalized text: the same words in the same order are the same objection.
    public static func id(_ text: String) -> String {
        let normalized = words(text).joined(separator: " ")
        return SHA256.hash(data: Data(normalized.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// How alike two objections are: shared words over all words (0–1).
    public static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Set(words(lhs))
        let right = Set(words(rhs))
        let all = left.union(right)
        return all.isEmpty ? 0 : Double(left.intersection(right).count) / Double(all.count)
    }

    /// Close enough to be the same, reworded.
    public static let threshold = 0.6

    /// Lays a re-check over what was known: a raised objection that matches a known one (by id, by `pairs`, or by
    /// words) keeps its id, first sighting and accepted risk (a fixed one is open again); a known one that was not
    /// raised (open, or accepted) is fixed; the rest are new and open. `pairs` maps a raised index to a known id (a
    /// model's match).
    public static func merge(
        known: [Objection], raised: [ReviewReport.Raised], pairs: [Int: String] = [:], at: Date
    ) -> [Objection] {
        var result: [Objection] = []
        var used: Set<String> = []
        for (index, item) in raised.enumerated() {
            let exact = id(item.text)
            let match = known.first { $0.id == exact && !used.contains($0.id) }
                ?? pairs[index].flatMap { paired in known.first { $0.id == paired && !used.contains($0.id) } }
                ?? known.filter { !used.contains($0.id) }
                .map { ($0, similarity($0.text, item.text)) }
                .filter { $0.1 >= threshold }
                .max { $0.1 < $1.1 }?.0
            if let match {
                used.insert(match.id)
                var kept = match
                kept.severity = item.severity
                kept.text = item.text
                kept.evidence = item.evidence ?? match.evidence
                kept.file = item.file ?? match.file
                kept.lastSeen = at
                kept.fixedAt = nil
                if kept.state == .fixed { kept.state = .open }
                result.append(kept)
            } else {
                // Two raised with the same words are one.
                guard !result.contains(where: { $0.id == exact }) else { continue }
                result.append(Objection(
                    id: exact, severity: item.severity, text: item.text, evidence: item.evidence, file: item.file,
                    firstSeen: at
                ))
            }
        }
        for old in known where !used.contains(old.id) {
            var gone = old
            if gone.state != .fixed {
                gone.state = .fixed
                gone.fixedAt = at
            }
            result.append(gone)
        }
        return result
    }

    /// Which raised objections have no match by id or words, and which known open ones are left: what a model is
    /// asked about.
    public static func unmatched(known: [Objection], raised: [ReviewReport.Raised])
        -> (raised: [Int], known: [Objection])
    {
        var used: Set<String> = []
        var left: [Int] = []
        for (index, item) in raised.enumerated() {
            let exact = id(item.text)
            if let match = known.first(where: { $0.id == exact && !used.contains($0.id) })
                ?? known.filter({ !used.contains($0.id) }).map({ ($0, similarity($0.text, item.text)) })
                .filter({ $0.1 >= threshold }).max(by: { $0.1 < $1.1 })?.0
            {
                used.insert(match.id)
            } else {
                left.append(index)
            }
        }
        return (left, known.filter { !used.contains($0.id) && $0.state != .fixed })
    }

    /// Asks a model which known objection each unmatched raised one restates, if any; nothing when there is nothing
    /// to ask or it could not answer.
    public static func ask(
        known: [Objection], raised: [ReviewReport.Raised], decider: any Decider, subject: String
    ) async -> [Int: String] {
        let (left, open) = unmatched(known: known, raised: raised)
        guard !left.isEmpty, !open.isEmpty else { return [:] }
        let options = open.map(\.id) + ["new"]
        var questions: [String: Question] = [:]
        for index in left {
            questions["r\(index)"] = .choice(
                instructions: "Which earlier objection does this one restate, if any? \"\(raised[index].text)\"",
                options: options
            )
        }
        let state = "Earlier objections:\n" + open.map { "- \($0.id): \($0.text)" }.joined(separator: "\n")
        guard let answers = try? await decider.decide(subject: subject, state: state, questions: questions) else {
            return [:]
        }
        var pairs: [Int: String] = [:]
        for index in left {
            guard let answer = answers["r\(index)"], let choice = answer.choice, choice != "new",
                  (answer.probabilities[choice] ?? 0) >= 0.6, !pairs.values.contains(choice)
            else { continue }
            pairs[index] = choice
        }
        return pairs
    }
}
