import Foundation

/// One thing heed learned from you: a question about a state, and the answer your action gave it. Kept in the models
/// folder (`learning/examples.jsonl`), never anywhere else.
public struct HunchExample: Codable, Hashable, Sendable, Identifiable {
    /// Where it came from, so a newer label of the same thing replaces it: `attention:<item>`,
    /// `attach:<decision>:<goal>`, `screen:<session>:<time>`.
    public var id: String
    public var family: HunchFamily
    public var state: String
    public var question: Question
    /// The right option: a choice's option, a score's level, or "true"/"false".
    public var answer: String
    /// How much it counts: a direct correction 1, a weak hint less.
    public var weight: Double
    public var at: Date

    public init(
        id: String, family: HunchFamily, state: String, question: Question, answer: String, weight: Double, at: Date
    ) {
        self.id = id
        self.family = family
        self.state = state
        self.question = question
        self.answer = answer
        self.weight = weight
        self.at = at
    }

    /// One in five examples is held out, by its id, so it stays held out as the set grows: what a new head is judged
    /// on and never trained on.
    public var heldOut: Bool { HunchTrainingSet.hash(id) % 5 == 0 }
}

/// The kinds of thing heed learns, each from one of your actions.
public enum HunchFamily: String, Codable, CaseIterable, Sendable {
    /// What you did with an Attention item (done, snooze, mute, boost): its suggested weight.
    case attention
    /// Your answers to a goal's attach proposals, and your moves and undos: whether a thing belongs to a goal.
    case attach
    /// Screen snapshots with the state an agent's hooks reported: whether it is waiting for you.
    case screens

    public var title: String {
        switch self {
        case .attention: "Attention"
        case .attach: "Goal attach"
        case .screens: "Agent waiting"
        }
    }
}

/// Builds and keeps the training set from what heed already records: Attention's `label` rows (with the `decide`
/// rows of the same items), goal attach decisions you answered, moved or undid, and labelled screen snapshots
/// (`[local] record_screens`). Nothing here is asked of you: each example is something you did anyway.
public enum HunchTrainingSet {
    /// Examples kept at most, newest first, and at most per family, so one kind cannot crowd out the others.
    public static let maxExamples = 4000
    public static let maxPerFamily = 2000
    /// A state is cut to this many characters (a checkpoint reads 512 tokens at most).
    public static let maxStateLength = 4000
    /// A screen keeps its last lines: the spike found the last 20 decide "is it waiting" best.
    public static let screenLines = 20

    // MARK: The questions

    /// Whether a thing belongs to a goal, as Hunch is asked it.
    public static func attachQuestion(goal: String) -> Question {
        .noul(instructions: "This work belongs to the goal \"\(goal)\".")
    }

    /// Whether an agent's screen waits for you.
    public static let waitingQuestion = Question.noul(
        instructions: "The last lines ask the user to answer a question or approve something before the agent goes on."
    )

    // MARK: Attention

    /// Your Attention actions as levels of `AttentionDecide`'s weight: mute says ignore, snooze lower, done normal,
    /// boost boost 1. Done and snooze are weaker hints than mute and boost, so they count half.
    public static let attentionLevels: [String: (level: String, weight: Double)] = [
        "mute": ("ignore", 1), "snooze": ("lower", 0.5), "done": ("normal", 0.5), "boost": ("boost 1", 1),
    ]

    /// `labels`: Attention's `label` rows; `decisions`: `decide` rows that may hold the same items' state (a label
    /// without its own state takes the newest one asked before it). The newest label of an item wins.
    public static func attention(labels: [LoggedCall], decisions: [LoggedCall]) -> [HunchExample] {
        var stateBySubject: [String: [(Date, String)]] = [:]
        for row in decisions where row.kind == .decide && row.command == "decide" {
            guard let subject = row.detail["subject"], let state = row.detail["state"], !state.isEmpty else {
                continue
            }
            stateBySubject[subject, default: []].append((row.at, state))
        }
        var newest: [String: HunchExample] = [:]
        for row in labels where row.kind == .decide && row.command == "label" {
            guard let subject = row.detail["subject"], let label = row.detail["label"],
                  let mapped = attentionLevels[label]
            else { continue }
            let state = row.detail["state"].flatMap { $0.isEmpty ? nil : $0 }
                ?? stateBySubject[subject]?.filter { $0.0 <= row.at }.max { $0.0 < $1.0 }?.1
            guard let state else { continue }
            let example = HunchExample(
                id: "attention:\(subject)", family: .attention, state: trimmed(state, keepEnd: false),
                question: AttentionDecide.questions["weight"]!, answer: mapped.level, weight: mapped.weight, at: row.at
            )
            if let other = newest[example.id], other.at > example.at { continue }
            newest[example.id] = example
        }
        return Array(newest.values)
    }

    // MARK: Goal attach

    /// What a thing looked like to the attach decision.
    public static func attachState(_ subject: AttachSubject) -> String {
        let kind = switch subject.kind {
        case .session: "Session"
        case .chat: "Chat"
        case .pr: "Pull request"
        case .run: "Run"
        case .review: "Review"
        }
        var lines = ["\(kind): \(subject.title)"]
        if !subject.prompt.isEmpty { lines.append("Asked: \(subject.prompt)") }
        if !subject.repos.isEmpty { lines.append("Repos: \(subject.repos.joined(separator: ", "))") }
        if !subject.branch.isEmpty { lines.append("Branch: \(subject.branch)") }
        if !subject.files.isEmpty { lines.append("Files: \(subject.files.prefix(20).joined(separator: ", "))") }
        let links = subject.pulls + subject.issues
        if !links.isEmpty { lines.append("Links: \(links.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }

    /// Your corrections of goal attach: yes says the proposed goal was right, no and undo that it was wrong, a move
    /// that the goal you picked is right (and the proposed one wrong). Ignores and untouched decisions teach nothing
    /// about a goal. `goalTitles`: slug → title, for the question's wording.
    public static func attach(_ decisions: [AttachDecision], goalTitles: [String: String]) -> [HunchExample] {
        var examples: [HunchExample] = []
        for decision in decisions {
            let state = trimmed(attachState(decision.subject), keepEnd: false)
            let at = decision.resolvedAt ?? decision.at
            func example(_ goal: String, _ belongs: Bool) -> HunchExample {
                HunchExample(
                    id: "attach:\(decision.id):\(goal)", family: .attach, state: state,
                    question: attachQuestion(goal: goalTitles[goal] ?? goal), answer: belongs ? "true" : "false",
                    weight: 1, at: at
                )
            }
            let proposed = decision.verdict.goal
            switch decision.state {
            case .accepted:
                if let goal = decision.goal ?? proposed { examples.append(example(goal, true)) }
            case .declined, .undone:
                if let proposed { examples.append(example(proposed, false)) }
            case .moved:
                if let proposed, proposed != decision.goal { examples.append(example(proposed, false)) }
                if let goal = decision.goal { examples.append(example(goal, true)) }
            case .settled, .open, .ignored, .clustered, .superseded:
                break
            }
        }
        return examples
    }

    // MARK: Screens

    /// Labelled snapshots: asking or blocked (the hooks said it waits for you) is true, working is false. Done, idle,
    /// limited and exited say nothing about a question on screen, and guessed states are not labels.
    public static func screens(_ snapshots: [ScreenSnapshot]) -> [HunchExample] {
        snapshots.compactMap { snapshot in
            guard snapshot.source.labelled, !snapshot.text.isEmpty else { return nil }
            let answer: String
            switch snapshot.state {
            case .asking, .blocked: answer = "true"
            case .working: answer = "false"
            case .idle, .done, .limited, .exited: return nil
            }
            let id = "screen:\(snapshot.session ?? snapshot.agent):\(Int(snapshot.at.timeIntervalSince1970 * 1000))"
            return HunchExample(
                id: id, family: .screens,
                state: trimmed(
                    snapshot.text.split(separator: "\n", omittingEmptySubsequences: false).suffix(screenLines)
                        .joined(separator: "\n"),
                    keepEnd: true
                ),
                question: waitingQuestion,
                answer: answer, weight: 1, at: snapshot.at
            )
        }
    }

    // MARK: Keeping it

    /// `existing` with `new` added: a new example replaces one with its id, then the newest are kept within the caps.
    public static func merge(_ existing: [HunchExample], _ new: [HunchExample]) -> [HunchExample] {
        var byID: [String: HunchExample] = [:]
        for example in existing + new {
            if let other = byID[example.id], other.at > example.at { continue }
            byID[example.id] = example
        }
        var perFamily: [HunchFamily: Int] = [:]
        var kept: [HunchExample] = []
        for example in byID.values.sorted(by: newestFirst) {
            guard kept.count < maxExamples, perFamily[example.family, default: 0] < maxPerFamily else { continue }
            perFamily[example.family, default: 0] += 1
            kept.append(example)
        }
        return kept
    }

    /// Newest first, then by id, so the order never depends on a dictionary's.
    static func newestFirst(_ lhs: HunchExample, _ rhs: HunchExample) -> Bool {
        lhs.at != rhs.at ? lhs.at > rhs.at : lhs.id < rhs.id
    }

    /// The training and held-out parts.
    public static func split(_ examples: [HunchExample]) -> (train: [HunchExample], heldOut: [HunchExample]) {
        let sorted = examples.sorted(by: newestFirst)
        return (sorted.filter { !$0.heldOut }, sorted.filter(\.heldOut))
    }

    /// Counts per family, for the pane.
    public static func counts(_ examples: [HunchExample]) -> [HunchFamily: Int] {
        examples.reduce(into: [:]) { $0[$1.family, default: 0] += 1 }
    }

    /// One example per line, sorted, so the file only changes when the set does.
    public static func encode(_ examples: [HunchExample]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        var data = Data()
        for example in examples.sorted(by: newestFirst) {
            guard let line = try? encoder.encode(example) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        return data
    }

    /// The lines that decode; a damaged one is skipped rather than losing the set.
    public static func decode(_ data: Data) -> [HunchExample] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(HunchExample.self, from: Data($0)) }
    }

    static func trimmed(_ text: String, keepEnd: Bool) -> String {
        guard text.count > maxStateLength else { return text }
        return String(keepEnd ? text.suffix(maxStateLength) : text.prefix(maxStateLength))
    }

    /// FNV-1a over the id's UTF-8: stable across launches and machines, unlike `hashValue`.
    static func hash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
