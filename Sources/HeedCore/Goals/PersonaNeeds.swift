import CryptoKit
import Foundation

/// What asked for a persona: a card on the board, a reviewer's objection, a done-when criterion or an open question
/// in GOAL.md.
public struct PersonaRef: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        case item, objection, criterion, question
    }

    public var kind: Kind
    /// The item's id, `reviewer/objection`, or the criterion's or question's number (from 1).
    public var id: String
    /// What it says, short.
    public var label: String

    public init(_ kind: Kind, _ id: String, label: String) {
        self.kind = kind
        self.id = id
        self.label = label
    }

    /// The handle the model is shown and answers with: `item:<slug>`, `objection:<reviewer>/<id>`, `criterion:2`.
    public var handle: String {
        switch kind {
        case .item: "item:" + (id.split(separator: "/", maxSplits: 1).last.map(String.init) ?? id)
        default: "\(kind.rawValue):\(id)"
        }
    }

    /// `card “Does the cache survive…”`, `objection “…”`, `criterion 4`, `question 2`.
    public var text: String {
        let short = label.count > 32 ? String(label.prefix(31)) + "…" : label
        return switch kind {
        case .item: "card “\(short)”"
        case .objection: "objection “\(short)”"
        case .criterion: "criterion \(id)"
        case .question: "question \(id)"
        }
    }
}

/// A persona the goal needs, worked out from its board: who, when, why now, and the evidence that asked for it.
public struct PersonaNeed: Hashable, Sendable, Codable, Identifiable {
    public enum When: String, Hashable, Sendable, Codable, CaseIterable, Comparable {
        case now, soon, later

        public var text: String { self == .now ? "needed now" : rawValue }

        public static func < (lhs: When, rhs: When) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    /// Its persona as the model drafted it: the file written when the goal has none of that name yet.
    public var persona: Persona
    public var when: When
    public var why: String
    public var evidence: [PersonaRef]
    /// The reviewer kind whose reviews count as this persona's (a perf prober for a performance engineer), if any.
    public var reviewer: ReviewerKind?

    public init(persona: Persona, when: When, why: String, evidence: [PersonaRef], reviewer: ReviewerKind? = nil) {
        self.persona = persona
        self.when = when
        self.why = why
        self.evidence = evidence
        self.reviewer = reviewer
    }

    public var id: String { persona.id }
    public var name: String { persona.name }

    /// The items it is about: what its coverage counts.
    public var items: [String] { evidence.filter { $0.kind == .item }.map(\.id) }
}

/// One derivation of a goal's personas (a `goal_reviews` entry): the needs, and the board it was made from.
public struct PersonaDerivation: Hashable, Sendable, Codable {
    public var needs: [PersonaNeed]
    /// `PersonaDerivation.signature` of the board it read.
    public var signature: String
    public var goalVersion: Int

    public init(needs: [PersonaNeed], signature: String, goalVersion: Int) {
        self.needs = needs
        self.signature = signature
        self.goalVersion = goalVersion
    }

    /// The handles the model may cite, each to its reference: the goal's items that are not done, the open objections
    /// of its live reviewers, the criteria not met and the open questions.
    public static func refs(doc: GoalDoc?, items: [GoalItem], evidence: [GoalEvidence], quality: GoalQuality?)
        -> [String: PersonaRef]
    {
        var refs: [String: PersonaRef] = [:]
        for item in items where Board.column(item, evidence: evidence) != .done {
            let ref = PersonaRef(.item, item.id, label: item.title)
            refs[ref.handle] = ref
        }
        for reviewer in quality?.live ?? [] {
            for objection in reviewer.open {
                let ref = PersonaRef(.objection, "\(reviewer.id)/\(objection.id)", label: objection.text)
                refs[ref.handle] = ref
            }
        }
        for (index, criterion) in (doc?.doneWhen ?? []).enumerated() where !criterion.met {
            let ref = PersonaRef(.criterion, String(index + 1), label: criterion.text)
            refs[ref.handle] = ref
        }
        for (index, question) in (doc?.openQuestions ?? []).enumerated() {
            let ref = PersonaRef(.question, String(index + 1), label: question)
            refs[ref.handle] = ref
        }
        return refs
    }

    /// What the board says that would change who is needed: what is left to do, what reviewers object to, what is
    /// unmet or unanswered, and what is failing. Cards moving between columns short of Done, rewording, and new
    /// evidence that passes do not count.
    public static func signature(doc: GoalDoc?, items: [GoalItem], evidence: [GoalEvidence], quality: GoalQuality?)
        -> String
    {
        var lines = refs(doc: doc, items: items, evidence: evidence, quality: quality).keys.sorted()
        lines += evidence.filter { $0.state == .issue }.map { "issue:\($0.item ?? "-"):\($0.kind.rawValue)" }
        let joined = Set(lines).sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether to ask again: the board changed materially since the last derivation (`signature` differs), it has
    /// been still for `quiet` (debounced: a burst of changes is one ask), and the last ask is `gap` old. A goal with
    /// nothing on its board is not asked about.
    public static func due(
        last: (signature: String, at: Date)?, signature: String, changedAt: Date, now: Date, empty: Bool,
        quiet: TimeInterval = 120, gap: TimeInterval = 15 * 60
    ) -> Bool {
        guard !empty, now.timeIntervalSince(changedAt) >= quiet else { return false }
        guard let last else { return true }
        return last.signature != signature && now.timeIntervalSince(last.at) >= gap
    }

    /// What the model reads: GOAL.md, every handle with what it says, what is failing, and the personas the goal and
    /// the library have already (so it reuses their names).
    public static func inputs(
        title: String, doc: String, refs: [String: PersonaRef], evidence: [GoalEvidence], known: [String]
    ) -> SummaryInputs {
        var lines = refs.keys.sorted().map { handle in "\(handle): \(refs[handle]!.label)" }
        let failing = evidence.filter { $0.state == .issue }.map { entry in
            let handle = entry.item
                .map { "item:" + ($0.split(separator: "/", maxSplits: 1).last.map(String.init) ?? $0) }
            return "failing \(entry.kind.rawValue)" + (handle.map { " on \($0)" } ?? "") + ": \(entry.text) (\(entry.source))"
        }
        lines += failing
        return SummaryInputs(
            title: "Who \(title) needs", timeline: lines, goal: doc, known: known.map { "persona: " + $0 }
        )
    }

    /// The model's `{"personas": [...]}` into needs: at most eight, one per name, evidence only from `refs` (a need
    /// with none left keeps its why but cites nothing), lists as arrays or comma-separated text, `when` read loosely.
    public static func parse(_ answer: String, refs: [String: PersonaRef]) -> [PersonaNeed] {
        guard let data = LLMDialect.jsonObject(in: answer),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["personas"] as? [[String: Any]]
        else { return [] }
        var seen: Set<String> = []
        var needs: [PersonaNeed] = []
        for entry in list {
            func string(_ keys: String...) -> String? {
                for key in keys {
                    if let value = entry[key] as? String {
                        let line = GoalDoc.oneLine(value)
                        if !line.isEmpty { return line }
                    }
                }
                return nil
            }
            func strings(_ keys: String...) -> [String] {
                for key in keys {
                    if let array = entry[key] as? [Any] {
                        return array.compactMap { ($0 as? String).map(GoalDoc.oneLine) }.filter { !$0.isEmpty }
                    }
                    if let text = entry[key] as? String {
                        return key.lowercased().contains("ask") ? Persona.questions(text) : Persona.items(text)
                    }
                }
                return []
            }
            guard let name = string("name"), !seen.contains(Persona.slug(name)) else { continue }
            seen.insert(Persona.slug(name))
            let when = string("when").map(Self.when) ?? .soon
            let cited = strings("evidence", "refs").compactMap { refs[$0.trimmingCharacters(in: .whitespaces)] }
            var unique: [PersonaRef] = []
            for ref in cited where !unique.contains(ref) {
                unique.append(ref)
            }
            var may = strings("may")
            var mayNot = strings("mayNot", "may_not", "may not")
            if may.isEmpty { may = Persona.readOnly }
            if mayNot.isEmpty { mayNot = Persona.noEdits }
            let persona = Persona(
                name: name, knows: strings("knows"),
                skepticalAbout: strings("skepticalAbout", "skeptical_about", "skeptical about"),
                asksFirst: strings("asksFirst", "asks_first", "asks first"), may: may, mayNot: mayNot
            )
            needs.append(PersonaNeed(
                persona: persona, when: when, why: string("why", "whyNow", "why_now") ?? "", evidence: unique,
                reviewer: string("reviewer").flatMap { ReviewerKind(rawValue: $0.lowercased()) }
            ))
            if needs.count == 8 { break }
        }
        return needs
    }

    static func when(_ text: String) -> PersonaNeed.When {
        let word = text.lowercased()
        if word.contains("now") || word.contains("immediate") { return .now }
        if word.contains("later") || word.contains("eventual") { return .later }
        return .soon
    }
}

/// A persona put to work on a goal: as a reviewer, a chat or a session (a `goal_reviews` entry).
public struct PersonaSpawn: Hashable, Sendable, Codable {
    public enum Mode: String, Hashable, Sendable, Codable, CaseIterable {
        case reviewer, chat, session
    }

    /// The persona's id (its slug).
    public var persona: String
    public var mode: Mode
    /// The reviewer's id, or the session's or chat's.
    public var target: String
    /// heed spawned it on its own (a strong gap).
    public var auto: Bool

    public init(persona: String, mode: Mode, target: String, auto: Bool = false) {
        self.persona = persona
        self.mode = mode
        self.target = target
        self.auto = auto
    }
}
