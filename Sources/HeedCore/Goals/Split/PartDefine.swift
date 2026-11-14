import Foundation

/// What an agent proposes a part becomes, once it read the repo and talked it through with you: its done-when lines,
/// a new estimate, more context (a decision becomes `decision: …`).
public struct PartDraft: Hashable, Sendable, Codable {
    public var doneWhen: [String]
    /// Minutes; nil: the estimate stands.
    public var estimate: Int?
    public var context: [String]

    public init(doneWhen: [String] = [], estimate: Int? = nil, context: [String] = []) {
        self.doneWhen = doneWhen
        self.estimate = estimate
        self.context = context
    }
}

/// Defining a part with an agent (`d`): an ACP session with the part's agent in the part's repo that reads and writes
/// nothing, its conversation with you, and the part as it would be defined. Nothing changes on the board until you use
/// the definition.
public struct PartDefinition: Hashable, Sendable, Codable {
    public struct Turn: Hashable, Sendable, Codable {
        public enum Role: String, Hashable, Sendable, Codable {
            case agent, you
        }

        public var role: Role
        public var text: String
        /// The agent's choices for you, when it asked.
        public var options: [String]
        /// The option you took (0-based).
        public var picked: Int?

        public init(role: Role, text: String, options: [String] = [], picked: Int? = nil) {
            self.role = role
            self.text = text
            self.options = options
            self.picked = picked
        }
    }

    public var part: String
    public var agent: String
    /// `codex via ACP`.
    public var via: String
    public var turns: [Turn]
    /// The part as the agent would define it now; nil until it proposed one.
    public var draft: PartDraft?
    /// What it read: `store/ · 14 files`.
    public var reads: [String]
    public var startedAt: Date
    /// Seconds it worked, turns summed.
    public var seconds: Double
    /// What it reported it cost; nil when it did not say.
    public var cost: Double?
    /// It is working on a turn now.
    public var working: Bool
    /// Why it stopped, when it could not go on.
    public var problem: String?

    public init(part: String, agent: String, via: String, at: Date) {
        self.part = part
        self.agent = agent
        self.via = via
        turns = []
        reads = []
        startedAt = at
        seconds = 0
        working = false
    }

    /// The agent's question waiting for you: its last turn, when it offered options none of which you took.
    public var openQuestion: Turn? {
        guard let last = turns.last, last.role == .agent, !last.options.isEmpty, last.picked == nil else { return nil }
        return last
    }

    /// An agent's reply: what it says, its options, and the part as it would define it, read from the JSON line it
    /// ends with (`PartDefinition.system` asks for one). A reply without one is all text.
    public static func read(_ reply: String) -> (text: String, options: [String], draft: PartDraft?) {
        let lines = reply.components(separatedBy: "\n")
        guard let index = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }),
              let data = LLMDialect.jsonObject(in: lines[index...].joined(separator: "\n")),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return (reply.trimmingCharacters(in: .whitespacesAndNewlines), [], nil) }
        var text = lines[..<index].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("```json") || text.hasSuffix("```") {
            text = String(text.dropLast(text.hasSuffix("```json") ? 7 : 3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let question = (object["question"] as? String).map(GoalDoc.oneLine), !question.isEmpty,
           !text.contains(question)
        {
            text += (text.isEmpty ? "" : "\n\n") + question
        }
        let options = SwarmPlanInput.strings(object["options"]).map(GoalDoc.oneLine).filter { !$0.isEmpty }
        let done = SwarmPlanInput.strings(object["doneWhen"] ?? object["done_when"]).map(GoalDoc.oneLine)
            .filter { !$0.isEmpty }
        let estimate: Int? = if let minutes = object["estimate"] as? Double {
            minutes > 0 ? Int(minutes.rounded()) : nil
        } else {
            (object["estimate"] as? String).flatMap(SwarmEstimate.minutes)
        }
        var context = SwarmPlanInput.strings(object["context"]).map(GoalDoc.oneLine).filter { !$0.isEmpty }
        if let decision = (object["decision"] as? String).map(GoalDoc.oneLine), !decision.isEmpty {
            context.append("decision: " + decision)
        }
        let draft = done.isEmpty && estimate == nil && context.isEmpty
            ? nil : PartDraft(doneWhen: done, estimate: estimate, context: context)
        return (text, options, draft)
    }

    /// The agent's reply in: its turn, and its draft when it gave one (else the last one stands).
    public mutating func received(_ reply: String) {
        let (text, options, draft) = Self.read(reply)
        turns.append(Turn(role: .agent, text: text, options: options))
        if let draft { self.draft = draft }
    }

    /// You took option `index` of its question: the choice is marked and sent as your answer.
    @discardableResult
    public mutating func pick(_ index: Int) -> String? {
        guard let last = turns.indices.last, turns[last].role == .agent, turns[last].options.indices.contains(index)
        else { return nil }
        turns[last].picked = index
        let answer = turns[last].options[index]
        turns.append(Turn(role: .you, text: answer))
        return answer
    }

    public mutating func say(_ text: String) {
        turns.append(Turn(role: .you, text: text))
    }

    // MARK: What it changes

    /// The part as defined beside the part as it is: kept and new done-when lines, the estimate before and after,
    /// new context.
    public struct Diff: Hashable, Sendable {
        public var kept: [String]
        public var added: [String]
        public var estimate: (old: Int, new: Int)?
        public var size: (old: PartSize, new: PartSize)?
        public var keptContext: [String]
        public var addedContext: [String]

        public static func == (lhs: Diff, rhs: Diff) -> Bool {
            lhs.kept == rhs.kept && lhs.added == rhs.added && lhs.estimate?.old == rhs.estimate?.old
                && lhs.estimate?.new == rhs.estimate?.new && lhs.size?.new == rhs.size?.new
                && lhs.keptContext == rhs.keptContext && lhs.addedContext == rhs.addedContext
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(added)
            hasher.combine(addedContext)
        }
    }

    public static func diff(_ part: SplitPart, _ draft: PartDraft) -> Diff {
        let added = draft.doneWhen.filter { line in !part.task.doneWhen.contains { GoalEdits.same($0, line) } }
        let estimate = draft.estimate.flatMap { $0 == part.minutes ? nil : (part.minutes, $0) }
        let newSize = draft.estimate.map(PartSize.init(minutes:)) ?? part.size
        let addedContext = draft.context.filter { line in !part.context.contains { GoalEdits.same($0, line) } }
        return Diff(
            kept: part.task.doneWhen, added: added, estimate: estimate,
            size: newSize == part.size ? nil : (part.size, newSize), keptContext: part.context,
            addedContext: addedContext
        )
    }

    /// The part with the definition in it: its done-when lines added to, its estimate (and size) replaced, its context
    /// added to.
    public static func apply(_ draft: PartDraft, to part: SplitPart) -> SplitPart {
        var part = part
        let diff = diff(part, draft)
        part.task.doneWhen += diff.added
        if let minutes = draft.estimate {
            part.task.estimate = minutes
            part.size = PartSize(minutes: minutes)
        }
        part.context += diff.addedContext
        return part
    }

    /// What using a definition does to the rest of the plan: how much longer or shorter the goal gets, which parts
    /// move.
    public struct KnockOn: Hashable, Sendable {
        /// Hours the goal's end moves (positive: later).
        public var delta: Double
        /// Parts that start at another time, by number.
        public var moved: [Int]
        public var makespan: Double

        public var text: String {
            let parts = moved.isEmpty ? "" : (moved.count == 1 ? "part " : "parts ")
                + SplitAssign.list(moved.map(String.init))
            let end = "the goal ends at \(SplitSchedule.text(makespan))"
            if abs(delta) < 1 / 120 {
                return moved.isEmpty ? "Nothing else moves; \(end)." : "\(parts) move; \(end), as before."
            }
            let longer = delta > 0
            let what = (longer ? "Longer by " : "Shorter by ") + SplitSchedule.text(abs(delta))
            return what + (moved.isEmpty ? "" : ": \(parts) move \(longer ? "right" : "left")") + "; \(end)."
        }
    }

    public static func knockOn(_ draft: PartDraft, part id: String, in split: SplitDraft) -> KnockOn? {
        guard let part = split.part(id) else { return nil }
        var changed = split
        changed.update(id) { $0 = apply(draft, to: part) }
        let numbers = Dictionary(split.parts.enumerated().map { ($0.element.id, $0.offset + 1) }) { first, _ in first }
        let before = SplitSchedule.make(split.parts, numbers: numbers)
        let after = SplitSchedule.make(changed.parts, numbers: numbers)
        let moved = after.slots.values.filter { slot in
            slot.id != id && abs((before.slots[slot.id]?.start ?? slot.start) - slot.start) > 1e-6
        }
        .compactMap { numbers[$0.id] }.sorted()
        return KnockOn(delta: after.makespan - before.makespan, moved: moved, makespan: after.makespan)
    }

    // MARK: Talking to the agent

    /// What the agent is told first: read, write nothing, ask one question at a time, end with the JSON line.
    public static let system = """
    You help define one part of a software plan before an agent starts on it. Read the repository as much as you \
    need (read and search only: do not edit, create or delete files, and run nothing). Then ask the developer one \
    question at a time about what matters for this part, with two or three short options. When you know enough, \
    propose how the part is done. End every reply with one line of JSON and nothing after it: {"question": "..." \
    or null, "options": ["..."], "doneWhen": ["checkable line, at most twelve words"], "estimate": "4h 30m", \
    "context": ["folder/ or file or PR"], "decision": "what was decided" or null}.
    """

    public static func prompt(
        part: SplitPart, number: Int, goal: String, plan: WizardPlan?, criteria: [String], others: [String]
    ) -> String {
        var lines = [system, "", "# The goal", goal]
        if let plan { lines += ["", "# The agreed plan", PlanTalk.render(plan)] }
        if !criteria.isEmpty { lines += ["", "# The goal is done when"] + criteria.map { "- \($0)" } }
        if !others.isEmpty { lines += ["", "# The other parts"] + others.map { "- \($0)" } }
        lines += [
            "", "# This part (\(number))", part.title,
            "repo: \(part.repo ?? "any") · size \(part.size.rawValue) · estimate \(SwarmEstimate.text(part.minutes))",
        ]
        lines += part.task.doneWhen.map { "done when: \($0)" }
        lines += part.context.map { "context: \($0)" }
        if let note = part.note { lines.append("the developer says: \(note)") }
        return lines.joined(separator: "\n")
    }

    /// What it read, by folder: `store/ · 14 files`, `README.md`. At most `limit` folders, most read first.
    public static func reads(_ paths: [String], root: String?, limit: Int = 3) -> [String] {
        var byFolder: [String: Set<String>] = [:]
        for path in paths {
            var relative = path
            if let root, relative.hasPrefix(root) {
                relative = String(relative.dropFirst(root.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            let parts = relative.split(separator: "/")
            let folder = parts.count > 1 ? String(parts[0]) + "/" : relative
            byFolder[folder, default: []].insert(relative)
        }
        return byFolder.sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }
            .prefix(limit)
            .map { folder, files in
                folder.hasSuffix("/") ? "\(folder) · \(files.count) file\(files.count == 1 ? "" : "s")" : folder
            }
    }
}

/// The answer to a defining agent's permission ask: reading, searching and thinking go ahead once; anything that
/// would change something (edits, deletes, moves, commands) is refused. With heed refusing `fs/*` and `terminal/*`
/// already, the session reads the repo and writes nothing.
public enum DefinePolicy {
    public static let allowed: Set<ACPToolKind> = [.read, .search, .think, .fetch]

    public static func answer(_ request: ACPPermissionRequest) -> String? {
        let kind = request.toolCall.kind ?? .other
        if allowed.contains(kind) {
            return (request.option(.allowOnce) ?? request.option(.allowAlways))?.id
        }
        return (request.option(.rejectOnce) ?? request.option(.rejectAlways))?.id
    }
}
