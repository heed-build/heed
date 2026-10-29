import Foundation

/// Questions you answered before, so the controller can answer a repeat for you and mark it so. Exact repeats are found
/// here: the same words once normalised, and the same set of options. Near ones are only candidates: a decider says
/// whether two questions ask the same thing (`sameQuestion`, a yes/no statement Hunch answers on this Mac), and only a
/// clear yes counts.
///
/// What counts as your answer: answers and overrules by you, in any swarm run on the goal, and the rules you made with
/// "same answer for similar questions" (`A` in Needs you), which reach further (their option sets need not match).
public enum SwarmRepeat {
    /// A question you answered, and the answer.
    public struct Answered: Hashable, Sendable {
        /// The question's row id; for a rule, the rule's.
        public var id: Int64
        public var question: String
        public var options: [String]
        public var answer: String
        public var at: Date
        /// A rule you made (`A`), rather than a single answer.
        public var rule: Bool

        public init(id: Int64, question: String, options: [String], answer: String, at: Date, rule: Bool = false) {
            self.id = id
            self.question = question
            self.options = options
            self.answer = answer
            self.at = at
            self.rule = rule
        }
    }

    /// A near candidate needs more than this much of its words in common with the question (a rule, `ruleOverlap`).
    public static let nearOverlap = 0.6
    public static let ruleOverlap = 0.3
    /// At most this many near candidates go to a decider.
    public static let maxCandidates = 3
    /// The decider's P(same question) a near repeat needs.
    public static let sameThreshold = 0.8

    /// Words that do not change what a question asks.
    static let filler: Set<String> = [
        "a", "an", "the", "should", "shall", "we", "i", "you", "do", "does", "please", "or", "it", "is", "be", "to",
        "for", "of", "this", "that", "here", "now", "just", "ok", "okay",
    ]

    /// Lowercase words of letters and digits, one space between: `Fail the build?` → `fail the build`.
    public static func normalised(_ text: String) -> String {
        var words: [String] = []
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.joined(separator: " ")
    }

    /// The words that carry the question: normalised, without filler.
    public static func key(_ text: String) -> [String] {
        normalised(text).split(separator: " ").map(String.init).filter { !filler.contains($0) }
    }

    public static func optionSet(_ options: [String]) -> Set<String> { Set(options.map(normalised)) }

    /// Words in common over words in either (0…1).
    public static func overlap(_ lhs: String, _ rhs: String) -> Double {
        let (left, right) = (Set(key(lhs)), Set(key(rhs)))
        guard !left.isEmpty || !right.isEmpty else { return 1 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    /// Your answers (and overrules) to questions, and your rules, newest first, from the steering rows of the goal's
    /// swarm runs.
    public static func answered(_ rows: [SwarmSteer]) -> [Answered] {
        var found: [Answered] = []
        let questions = Dictionary(
            rows.filter { $0.kind == .question && $0.id != nil }.map { ($0.id!, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen: Set<Int64> = []
        let deleted = Set(rows.filter { $0.kind == .unrule }.compactMap(\.about))
        for row in rows.reversed() {
            if row.kind == .rule, let id = row.id, let answer = row.answer {
                guard !deleted.contains(id) else { continue }
                found.append(Answered(
                    id: id, question: row.text, options: row.options, answer: answer, at: row.at, rule: true
                ))
                continue
            }
            guard row.actor == .you, row.kind == .answer || row.kind == .overrule, let about = row.about,
                  let question = questions[about], !seen.contains(about)
            else { continue }
            seen.insert(about)
            found.append(Answered(
                id: about, question: question.text, options: question.options, answer: row.text, at: row.at
            ))
        }
        return found
    }

    /// Your repeat rules standing (not deleted), newest first.
    public static func rules(_ rows: [SwarmSteer]) -> [SwarmSteer] {
        let deleted = Set(rows.filter { $0.kind == .unrule }.compactMap(\.about))
        return rows.filter { $0.kind == .rule && $0.id.map { !deleted.contains($0) } ?? false }.reversed()
    }

    /// The answer `earlier` gives a question with `options`: its words, when the question has no options; else the
    /// option it names (an earlier answer that is none of the options repeats nothing).
    public static func answer(_ earlier: Answered, options: [String]) -> String? {
        guard !options.isEmpty else { return earlier.answer }
        let wanted = normalised(earlier.answer)
        return options.first { normalised($0) == wanted }
    }

    /// The same question asked before: the same words once normalised and the same options (a rule: the same words,
    /// and its answer one of the options).
    public static func exact(_ text: String, options: [String], among answered: [Answered]) -> Answered? {
        let words = key(text)
        let set = optionSet(options)
        return answered.first { earlier in
            guard key(earlier.question) == words, answer(earlier, options: options) != nil else { return false }
            return earlier.rule || optionSet(earlier.options) == set
        }
    }

    /// Questions like this one you answered: worth asking a decider whether they ask the same thing. Single answers
    /// need the same options and half the words; rules a third of the words and their answer among the options. The
    /// closest first, at most `maxCandidates`.
    public static func near(_ text: String, options: [String], among answered: [Answered]) -> [Answered] {
        let set = optionSet(options)
        let scored = answered.compactMap { earlier -> (Answered, Double)? in
            guard answer(earlier, options: options) != nil else { return nil }
            let score = overlap(text, earlier.question)
            if earlier.rule { return score >= ruleOverlap ? (earlier, score) : nil }
            return optionSet(earlier.options) == set && score >= nearOverlap ? (earlier, score) : nil
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.at > $1.0.at }.prefix(maxCandidates).map(\.0)
    }

    /// The yes/no statement a decider answers for a near candidate.
    public static func sameQuestion(_ text: String, _ earlier: Answered) -> Question {
        .noul(instructions: "These two questions from agents ask the same thing, so one answer fits both. "
            + "First: \"\(earlier.question)\". Second: \"\(text)\".")
    }
}
