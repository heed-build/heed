import Foundation

/// How big a part is, as the board's pips show it: XS and S one pip, M two, L three.
public enum PartSize: String, Hashable, Sendable, Codable, CaseIterable, Comparable {
    case xs = "XS"
    case s = "S"
    case m = "M"
    case l = "L"

    /// Filled pips of three.
    public var pips: Int {
        switch self {
        case .xs, .s: 1
        case .m: 2
        case .l: 3
        }
    }

    /// The estimate a part of this size gets when nothing gave one, in minutes.
    public var typicalMinutes: Int {
        switch self {
        case .xs: 35
        case .s: 70
        case .m: 150
        case .l: 240
        }
    }

    /// The size an estimate reads as: up to 45 minutes XS, 1½ hours S, 3 hours M, longer L.
    public init(minutes: Int) {
        switch minutes {
        case ..<46: self = .xs
        case ..<91: self = .s
        case ..<181: self = .m
        default: self = .l
        }
    }

    public init?(word: String) {
        switch word.uppercased().trimmingCharacters(in: .whitespaces) {
        case "XS", "TINY": self = .xs
        case "S", "SMALL": self = .s
        case "M", "MEDIUM": self = .m
        case "L", "LARGE", "XL": self = .l
        default: return nil
        }
    }

    /// The next size up, round to XS after L (`z`).
    public var next: PartSize {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    public static func < (lhs: PartSize, rhs: PartSize) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// One part of a split goal: a swarm task (title, estimate, what it waits for, done when, and the agent it is on as its
/// owner) with what the board needs beside it: its repo, size, context, and your say on it.
public struct SplitPart: Hashable, Sendable, Codable, Identifiable {
    public var task: SwarmTask
    /// `org/name`, or a repo's short name, as the split call wrote it; nil: no repo in particular.
    public var repo: String?
    public var size: PartSize
    /// What its agent starts from: folders, files, PRs, decisions (`store/`, `#2790 v1 reader`, `decision: …`).
    public var context: [String]
    /// Put off with Later (`p`): kept, but off the board's timeline until you bring it back.
    public var later: Bool
    /// What you told its agent before it starts (`i`).
    public var note: String?
    /// You chose its agent (a drag, `a`, `J` `K`): assignment keeps it there.
    public var pinned: Bool

    public init(
        task: SwarmTask, repo: String? = nil, size: PartSize? = nil, context: [String] = [], later: Bool = false,
        note: String? = nil, pinned: Bool = false
    ) {
        var task = task
        let size = size ?? task.estimate.map(PartSize.init(minutes:)) ?? .m
        if task.estimate == nil { task.estimate = size.typicalMinutes }
        self.task = task
        self.repo = repo?.isEmpty == true ? nil : repo
        self.size = size
        self.context = context
        self.later = later
        self.note = note
        self.pinned = pinned
    }

    public var id: String { task.id }
    public var title: String { task.title }
    /// Minutes; every part has one (its size's typical estimate when none was given).
    public var minutes: Int { task.estimate ?? size.typicalMinutes }
    public var hours: Double { Double(minutes) / 60 }
    /// The agent it is on (`codex`), nil until assignment ran.
    public var agent: String? { task.owner?.agent }
    /// The repo's short name for the block: `engine` from `org/engine`.
    public var repoName: String? { repo.map { $0.split(separator: "/").last.map(String.init) ?? $0 } }
}

/// What the Balance for buttons trade: use the credits you have spare, finish soonest, or use the fewest agents.
public enum SplitBalance: String, Hashable, Sendable, Codable, CaseIterable {
    case credits, speed, fewest

    public var title: String {
        switch self {
        case .credits: "credits I have"
        case .speed: "speed"
        case .fewest: "fewest agents"
        }
    }

    /// The next one, round (`b`).
    public var next: SplitBalance {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Step 4's state: the parts the split call made of the agreed plan, which agent each is on, and what you changed.
/// Kept with the wizard (`GoalWizard.split`). Its parts become the swarm's plan (`swarmTasks`) when the goal goes.
public struct SplitDraft: Hashable, Sendable, Codable {
    public var parts: [SplitPart]
    public var balance: SplitBalance
    /// Who leads: plans the moves on the spine, checks and gates.
    public var lead: GoalItem.Owner?
    /// The plan version and done-when it was split from, so a changed plan asks for a new split.
    public var fromPlan: Int?

    public init(
        parts: [SplitPart] = [], balance: SplitBalance = .credits, lead: GoalItem.Owner? = nil, fromPlan: Int? = nil
    ) {
        self.parts = parts
        self.balance = balance
        self.lead = lead
        self.fromPlan = fromPlan
    }

    public var drafted: Bool { !parts.isEmpty }
    /// The parts on the timeline: all but those put off with Later.
    public var active: [SplitPart] { parts.filter { !$0.later } }

    /// `1`…, in the order the split made them.
    public func number(of id: String) -> Int? { parts.firstIndex { $0.id == id }.map { $0 + 1 } }

    public func part(_ id: String) -> SplitPart? { parts.first { $0.id == id } }

    public mutating func update(_ id: String, _ edit: (inout SplitPart) -> Void) {
        guard let index = parts.firstIndex(where: { $0.id == id }) else { return }
        edit(&parts[index])
    }

    /// The parts as the swarm's plan: one task each, owned by its agent, waiting only for parts still on the board.
    /// The seam for Go: approving the goal proposes these as the swarm's first plan version.
    public var swarmTasks: [SwarmTask] {
        let kept = Set(active.map(\.id))
        return active.map { part in
            var task = part.task
            task.after = task.after.filter { kept.contains($0) || !parts.map(\.id).contains($0) }
            return task
        }
    }

    // MARK: Reading the split call's answer

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// The split call's JSON: `{"lead": {"agent", "model"}, "parts": [{"id", "title", "repo", "size", "estimate",
    /// "after", "doneWhen", "context"}]}`, the swarm plan's task JSON (`SwarmPlanInput`) with a part's repo, size and
    /// context beside it. Text around the JSON is ignored, as models add it.
    public static func parse(_ text: String, goal: String, fromPlan: Int? = nil) throws -> SplitDraft {
        guard let data = LLMDialect.jsonObject(in: text),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw ParseError(description: "the split is not JSON") }
        guard let raw = (object["parts"] ?? object["tasks"]) as? [Any], !raw.isEmpty else {
            throw ParseError(description: "the split has no parts")
        }
        let entries = raw.compactMap { $0 as? [String: Any] }
        var tasks = entries.map { entry -> [String: Any] in
            var entry = entry
            if entry["phase"] == nil { entry["phase"] = "Build" }
            // Owners come from assignment, not from the model.
            entry["owner"] = nil
            return entry
        }
        tasks = tasks.filter { JSONSerialization.isValidJSONObject($0) }
        let json = try JSONSerialization.data(withJSONObject: ["tasks": tasks])
        let input: SwarmPlanInput
        do {
            input = try SwarmPlanInput.parse(String(decoding: json, as: UTF8.self), goal: goal)
        } catch let error as SwarmPlanInput.ParseError {
            throw ParseError(description: error.description)
        }
        let ids = Set(input.tasks.map(\.id))
        let parts = zip(input.tasks, entries).map { task, entry -> SplitPart in
            var task = task
            // A part waits only for other parts: an unknown name is dropped rather than failing the split.
            task.after = task.after.filter { ids.contains($0) && $0 != task.id }
            let size = (entry["size"] as? String).flatMap(PartSize.init(word:))
            let context = SwarmPlanInput.strings(entry["context"]).map(GoalDoc.oneLine).filter { !$0.isEmpty }
            return SplitPart(task: task, repo: entry["repo"] as? String, size: size, context: context)
        }
        var lead: GoalItem.Owner?
        if let value = object["lead"] {
            lead = try? SwarmPlanInput.owner(value, index: 0)
        }
        var draft = SplitDraft(parts: parts, lead: lead, fromPlan: fromPlan)
        if SwarmPlan.cycle(draft.parts.map(\.task)) != nil {
            // A circle cannot be scheduled: keep the parts, drop what they wait for.
            for index in draft.parts.indices {
                draft.parts[index].task.after = []
            }
        }
        return draft
    }

    /// A part split in two (`s`): the halves the split call made, in its place, the second after the first; what
    /// waited for the part waits for the second half.
    public mutating func replace(_ id: String, with halves: [SplitPart]) {
        guard let index = parts.firstIndex(where: { $0.id == id }), !halves.isEmpty else { return }
        let old = parts[index]
        var halves = halves
        let taken = Set(parts.map(\.id))
        for offset in halves.indices {
            if taken.contains(halves[offset].id), halves[offset].id != id {
                halves[offset].task.id = "\(old.id)-\(offset + 1)"
            }
            if halves[offset].id == id { halves[offset].task.id = "\(old.id)-\(offset + 1)" }
            halves[offset].task.after = offset == 0 ? old.task.after : [halves[offset - 1].id]
            halves[offset].task.owner = old.task.owner
            halves[offset].pinned = old.pinned
            if halves[offset].repo == nil { halves[offset].repo = old.repo }
        }
        parts.replaceSubrange(index ... index, with: halves)
        let last = halves.last!.id
        for other in parts.indices where parts[other].task.after.contains(id) {
            parts[other].task.after = parts[other].task.after.map { $0 == id ? last : $0 }
        }
    }
}
