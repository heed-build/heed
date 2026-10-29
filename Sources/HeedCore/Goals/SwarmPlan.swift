import Foundation

/// A swarm's plan as a list of tasks: its phases and numbers, the order dependencies allow, what is wrong with it, what
/// changed from one version to the next, and whether that change is small (it applies) or structural (it waits).
public enum SwarmPlan {
    /// What is wrong with a plan, in words the lead and you can act on.
    public enum Problem: Hashable, Sendable, CustomStringConvertible {
        case empty
        case noTitle(index: Int)
        case duplicate(String)
        case unknownAfter(task: String, after: String)
        case waitsForItself(String)
        case cycle([String])

        public var description: String {
            switch self {
            case .empty: "the plan has no tasks"
            case let .noTitle(index): "task \(index + 1) has no title"
            case let .duplicate(id): "two tasks are \(id)"
            case let .unknownAfter(task, after): "\(task) waits for \(after), which is no task or item on the goal"
            case let .waitsForItself(id): "\(id) waits for itself"
            case let .cycle(ids): "the tasks wait for each other in a circle: " + (ids + [ids[0]])
                .joined(separator: " → ")
            }
        }
    }

    /// The phases in the order they first appear, each with its tasks in plan order.
    public static func phases(_ tasks: [SwarmTask]) -> [(name: String, tasks: [SwarmTask])] {
        var order: [String] = []
        var byPhase: [String: [SwarmTask]] = [:]
        for task in tasks {
            if byPhase[task.phase] == nil { order.append(task.phase) }
            byPhase[task.phase, default: []].append(task)
        }
        return order.map { ($0, byPhase[$0] ?? []) }
    }

    /// Each task's number, `phase.task` (`2.3`), by id.
    public static func numbers(_ tasks: [SwarmTask]) -> [String: String] {
        var numbers: [String: String] = [:]
        for (phase, entry) in phases(tasks).enumerated() {
            for (index, task) in entry.tasks.enumerated() {
                numbers[task.id] = "\(phase + 1).\(index + 1)"
            }
        }
        return numbers
    }

    /// Everything wrong with `tasks`; `known` are the goal's other items, which tasks may wait for too.
    public static func problems(_ tasks: [SwarmTask], known: Set<String> = []) -> [Problem] {
        guard !tasks.isEmpty else { return [.empty] }
        var problems: [Problem] = []
        var seen: Set<String> = []
        for (index, task) in tasks.enumerated() {
            if task.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty { problems.append(.noTitle(index: index)) }
            if !seen.insert(task.id).inserted { problems.append(.duplicate(task.id)) }
        }
        let ids = Set(tasks.map(\.id))
        for task in tasks {
            for after in task.after {
                if after == task.id {
                    problems.append(.waitsForItself(task.id))
                } else if !ids.contains(after), !known.contains(after) {
                    problems.append(.unknownAfter(task: task.id, after: after))
                }
            }
        }
        if let cycle = cycle(tasks) { problems.append(.cycle(cycle)) }
        return problems
    }

    /// A circle of tasks waiting for each other, in plan order from its first task; nil when there is none. Waiting for
    /// itself is not a circle here (`problems` names it on its own).
    public static func cycle(_ tasks: [SwarmTask]) -> [String]? {
        let index = Dictionary(tasks.enumerated().map { ($0.element.id, $0.offset) }) { first, _ in first }
        var state: [String: Int] = [:] // 1 visiting, 2 done
        var path: [String] = []
        func visit(_ id: String) -> [String]? {
            state[id] = 1
            path.append(id)
            for next in tasks[index[id]!].after where next != id && index[next] != nil {
                if state[next] == 1, let start = path.firstIndex(of: next) { return Array(path[start...]) }
                if state[next] == nil, let found = visit(next) { return found }
            }
            path.removeLast()
            state[id] = 2
            return nil
        }
        for task in tasks where state[task.id] == nil {
            if let found = visit(task.id) {
                // Start the circle at its earliest task in the plan, so the same circle always reads the same.
                let first = found.indices.min { index[found[$0]]! < index[found[$1]]! } ?? 0
                return Array(found[first...] + found[..<first])
            }
        }
        return nil
    }

    /// The order tasks can start in: a task after everything it waits for, otherwise in plan order. Nil when they wait
    /// for each other in a circle.
    public static func order(_ tasks: [SwarmTask]) -> [SwarmTask]? {
        let ids = Set(tasks.map(\.id))
        let pairs = tasks.map { task in (task.id, Set(task.after.filter { ids.contains($0) && $0 != task.id })) }
        var waiting = Dictionary(pairs) { first, _ in first }
        var result: [SwarmTask] = []
        var left = tasks
        while !left.isEmpty {
            guard let next = left.firstIndex(where: { waiting[$0.id]?.isEmpty ?? true }) else { return nil }
            let task = left.remove(at: next)
            result.append(task)
            for key in waiting.keys {
                waiting[key]?.remove(task.id)
            }
        }
        return result
    }

    /// The plan's estimate, in minutes: every task's, summed.
    public static func estimate(_ tasks: [SwarmTask]) -> Int { tasks.compactMap(\.estimate).reduce(0, +) }

    // MARK: Changes

    /// What can change about a task.
    public enum Field: String, Hashable, Sendable, CaseIterable {
        case title, phase, owner, host, estimate, after, doneWhen

        public var title: String {
            switch self {
            case .title: "title"
            case .phase: "phase"
            case .owner: "owner"
            case .host: "runs on"
            case .estimate: "estimate"
            case .after: "after"
            case .doneWhen: "done when"
            }
        }
    }

    /// One difference between two versions of a plan.
    public enum Change: Hashable, Sendable {
        case added(SwarmTask)
        case removed(SwarmTask)
        /// The same task with other fields: the task as it was and as it is.
        case changed(old: SwarmTask, new: SwarmTask, fields: [Field])
        /// The task moved past others in the plan's order.
        case moved(SwarmTask)
    }

    /// What `new` changed from `old`: removed tasks first, in `old`'s order, then the rest in `new`'s.
    public static func diff(old: [SwarmTask], new: [SwarmTask]) -> [Change] {
        let before = Dictionary(old.map { ($0.id, $0) }) { first, _ in first }
        let after = Dictionary(new.map { ($0.id, $0) }) { first, _ in first }
        let common = new.map(\.id).filter { before[$0] != nil }
        let kept = Set(longestCommon(old.map(\.id).filter { after[$0] != nil }, common))
        var changes: [Change] = []
        for task in old where after[task.id] == nil {
            changes.append(.removed(task))
        }
        for task in new {
            guard let was = before[task.id] else {
                changes.append(.added(task))
                continue
            }
            let fields = Field.allCases.filter { differs(was, task, $0) }
            if !fields.isEmpty { changes.append(.changed(old: was, new: task, fields: fields)) }
            if !kept.contains(task.id) { changes.append(.moved(task)) }
        }
        return changes
    }

    static func differs(_ one: SwarmTask, _ other: SwarmTask, _ field: Field) -> Bool {
        switch field {
        case .title: one.title != other.title
        case .phase: one.phase != other.phase
        case .owner: one.owner != other.owner
        case .host: one.host != other.host
        case .estimate: one.estimate != other.estimate
        case .after: Set(one.after) != Set(other.after)
        case .doneWhen: one.doneWhen != other.doneWhen
        }
    }

    /// The longest run of ids both lists have in the same order: what did not move.
    static func longestCommon(_ one: [String], _ other: [String]) -> [String] {
        guard !one.isEmpty, !other.isEmpty else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: other.count + 1), count: one.count + 1)
        for i in stride(from: one.count - 1, through: 0, by: -1) {
            for j in stride(from: other.count - 1, through: 0, by: -1) {
                table[i][j] = one[i] == other[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [String] = []
        var i = 0
        var j = 0
        while i < one.count, j < other.count {
            if one[i] == other[j] {
                result.append(one[i])
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }

    /// How big a plan change is. Small: reordering, another owner, host, estimate or phase; it applies by itself.
    /// Structural:
    /// a task added, dropped or renamed, what it waits for, or when it is done; it waits for you. A plan never changes
    /// the goal: that is a GOAL.md scope proposal, made apart from the plan.
    public enum Size: String, Hashable, Sendable {
        case none, small, structural
    }

    public static func classify(old: [SwarmTask], new: [SwarmTask]) -> Size {
        let changes = diff(old: old, new: new)
        guard !changes.isEmpty else { return .none }
        for change in changes {
            switch change {
            case .added, .removed: return .structural
            case let .changed(_, _, fields):
                if fields.contains(where: { [.title, .after, .doneWhen].contains($0) }) { return .structural }
            case .moved: continue
            }
        }
        return .small
    }

    /// The diff as lines for the pane and PLAN.md: `- 3.2 Cold-cache tests`, `+ 3.3 Warm-cache tests`, a changed task
    /// with its fields' old and new values, `↕ 2.1 Cache layer: was 2.2`.
    public static func lines(old: [SwarmTask], new: [SwarmTask]) -> [DiffLine] {
        let oldNumbers = numbers(old)
        let newNumbers = numbers(new)
        return diff(old: old, new: new).flatMap { change -> [DiffLine] in
            switch change {
            case let .added(task):
                return [DiffLine(mark: .added, text: "\(newNumbers[task.id] ?? "") \(task.title)")]
            case let .removed(task):
                return [DiffLine(mark: .removed, text: "\(oldNumbers[task.id] ?? "") \(task.title)")]
            case let .moved(task):
                return [DiffLine(
                    mark: .moved,
                    text: "\(newNumbers[task.id] ?? "") \(task.title): was \(oldNumbers[task.id] ?? "?")"
                )]
            case let .changed(was, task, fields):
                let head = "\(newNumbers[task.id] ?? "") \(task.title)"
                return [DiffLine(mark: .context, text: head)] + fields.flatMap { field -> [DiffLine] in
                    let before = value(was, field, numbers: oldNumbers)
                    let after = value(task, field, numbers: newNumbers)
                    return [
                        DiffLine(mark: .removed, text: "\(field.title): \(before)"),
                        DiffLine(mark: .added, text: "\(field.title): \(after)"),
                    ]
                }
            }
        }
    }

    public struct DiffLine: Hashable, Sendable {
        public enum Mark: String, Hashable, Sendable {
            case added, removed, moved, context

            public var glyph: String {
                switch self {
                case .added: "+"
                case .removed: "-"
                case .moved: "↕"
                case .context: " "
                }
            }
        }

        public var mark: Mark
        public var text: String
    }

    static func value(_ task: SwarmTask, _ field: Field, numbers: [String: String]) -> String {
        switch field {
        case .title: task.title
        case .phase: task.phase
        case .owner: task.owner?.label ?? "anyone"
        case .host: task.host.map { $0 == SwarmPlace.local ? "this Mac" : "@\($0)" } ?? "where the swarm runs"
        case .estimate: task.estimate.map(SwarmEstimate.text) ?? "none"
        case .after: task.after.isEmpty ? "nothing" : task.after.map { numbers[$0] ?? short($0) }
            .joined(separator: ", ")
        case .doneWhen: task.doneWhen.isEmpty ? "nothing said" : task.doneWhen.joined(separator: "; ")
        }
    }

    /// An item id without its goal.
    public static func short(_ id: String) -> String { id.split(separator: "/", maxSplits: 1).last
        .map(String.init) ?? id
    }

    // MARK: Editing

    /// The tasks grouped by phase, phases in the order they first appear: the order the outline reads in.
    public static func grouped(_ tasks: [SwarmTask]) -> [SwarmTask] { phases(tasks).flatMap(\.tasks) }

    /// The plan with the task at `index` (in outline order) one place up (`-1`) or down (`1`); past the edge of its
    /// phase it joins the next phase instead (as last of the one above, first of the one below). Nil when it cannot
    /// move.
    public static func move(_ tasks: [SwarmTask], at index: Int, by delta: Int) -> [SwarmTask]? {
        let tasks = grouped(tasks)
        guard delta == 1 || delta == -1, tasks.indices.contains(index), tasks.indices.contains(index + delta) else {
            return nil
        }
        var result = tasks
        if tasks[index + delta].phase != tasks[index].phase {
            result[index].phase = tasks[index + delta].phase
            return grouped(result)
        }
        result.swapAt(index, index + delta)
        return result
    }

    /// The plan without the task, and with nothing waiting for it any more.
    public static func drop(_ tasks: [SwarmTask], id: String) -> [SwarmTask] {
        tasks.filter { $0.id != id }.map { task in
            var task = task
            task.after.removeAll { $0 == id }
            return task
        }
    }

    // MARK: PLAN.md

    /// The plan as `PLAN.md`, written next to `GOAL.md` on every version, for agents and editors.
    public static func render(_ version: SwarmPlanVersion, swarm: GoalSwarm, goalTitle: String) -> String {
        let numbers = numbers(version.tasks)
        var lines = [
            "# Plan: \(goalTitle)",
            "",
            "Swarm \(swarm.number) · plan v\(version.number) · \(swarm.isApproved && swarm.plan == version.number ? "approved" : "draft")"
                + " · \(version.tasks.count) task\(version.tasks.count == 1 ? "" : "s")"
                + (estimate(version.tasks) > 0 ? " · est \(SwarmEstimate.text(estimate(version.tasks)))" : "")
                + (swarm.settings.host.map { " · on @\($0)" } ?? ""),
            "",
            "Written by heed from goals.sqlite; edits here are not read back. Change the plan in heed or with "
                + "`heed goal plan propose`.",
        ]
        for (index, phase) in phases(version.tasks).enumerated() {
            lines += ["", "## \(index + 1). \(phase.name)", ""]
            for task in phase.tasks {
                var head = "- **\(numbers[task.id] ?? "") \(task.title)** (`\(task.slug)`)"
                var details: [String] = []
                if let owner = task.owner { details.append(owner.label) }
                if let host = task.host { details.append(host == SwarmPlace.local ? "on this Mac" : "on @\(host)") }
                if let estimate = task.estimate { details.append(SwarmEstimate.text(estimate)) }
                if !task.after.isEmpty {
                    details.append("after " + task.after.map { numbers[$0] ?? short($0) }.joined(separator: ", "))
                }
                if !details.isEmpty { head += " · " + details.joined(separator: " · ") }
                lines.append(head)
                for check in task.doneWhen {
                    lines.append("  - done when: \(check)")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Estimates in minutes, read from what a lead writes (`15m`, `1h`, `1h 30m`, `1.5h`, `90`) and written back short.
public enum SwarmEstimate {
    public static func minutes(_ text: String) -> Int? {
        let words = text.lowercased().replacingOccurrences(of: " ", with: "")
        guard !words.isEmpty else { return nil }
        if let plain = Double(words) { return plain > 0 ? Int(plain.rounded()) : nil }
        var total = 0.0
        var number = ""
        var found = false
        var index = words.startIndex
        while index < words.endIndex {
            let character = words[index]
            if character.isNumber || character == "." {
                number.append(character)
                index = words.index(after: index)
                continue
            }
            var unit = ""
            while index < words.endIndex, words[index].isLetter {
                unit.append(words[index])
                index = words.index(after: index)
            }
            guard let value = Double(number) else { return nil }
            switch unit {
            case "h", "hr", "hrs", "hour", "hours": total += value * 60
            case "m", "min", "mins", "minute", "minutes": total += value
            case "d", "day", "days": total += value * 8 * 60
            default: return nil
            }
            found = true
            number = ""
        }
        guard number.isEmpty, found, total > 0 else { return nil }
        return Int(total.rounded())
    }

    /// `12m`, `1h`, `3h 40m`.
    public static func text(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}

/// What steering rows say together: the questions and their answers, and the plan change waiting for you.
public enum SwarmSteering {
    public struct Question: Hashable, Sendable, Identifiable {
        public var row: SwarmSteer
        public var answer: SwarmSteer?

        public var id: Int64 { row.id ?? 0 }
    }

    /// Every question, oldest first, with the answer that stands: the newest answer or overrule of it.
    public static func questions(_ rows: [SwarmSteer]) -> [Question] {
        rows.filter { $0.kind == .question }.map { question in
            Question(
                row: question,
                answer: rows.last {
                    ($0.kind == .answer || $0.kind == .overrule) && $0.about == question.id && question.id != nil
                }
            )
        }
    }

    /// The answers you overruled: each overrule names the answer it overrules (`ref` `steer:<id>`).
    public static func overruled(_ rows: [SwarmSteer]) -> Set<Int64> {
        Set(rows.filter { $0.kind == .overrule }.compactMap { row in
            row.ref.flatMap { $0.hasPrefix("steer:") ? Int64($0.dropFirst(6)) : nil }
        })
    }

    /// A row's state as the log shows it: what it was written as, or overruled once a later row overrules it.
    public static func state(_ row: SwarmSteer, overruled: Set<Int64>) -> SwarmSteer.State {
        guard let id = row.id, overruled.contains(id) else { return row.state }
        return .overruled
    }

    /// The controller's newest suggestion for a question, unless an answer came after it.
    public static func suggestion(_ question: Question, rows: [SwarmSteer]) -> SwarmSteer? {
        guard question.answer == nil, let id = question.row.id else { return nil }
        return rows.last { $0.kind == .suggest && $0.about == id }
    }

    /// A row that proposed a plan: a version it made, or tasks waiting for you (not a GOAL.md change it carried).
    static func plans(_ row: SwarmSteer) -> Bool { row.kind == .propose && (row.version != nil || row.tasks != nil) }

    /// The newest structural change the lead proposed that nothing approved, rejected or replaced since.
    public static func pendingChange(_ rows: [SwarmSteer]) -> SwarmSteer? {
        guard let last = rows.last(where: { plans($0) && $0.state == .pending }), let id = last.id else { return nil }
        let settled = rows.contains { row in
            guard let rowID = row.id, rowID > id else { return false }
            return row.about == id || plans(row)
        }
        return settled ? nil : last
    }

    /// Your re-plan feedback the lead has not answered with a new proposal yet, oldest first.
    public static func feedback(_ rows: [SwarmSteer]) -> [SwarmSteer] {
        let lastProposal = rows.last { plans($0) && $0.actor == .lead }?.id ?? 0
        return rows.filter { $0.kind == .replan && ($0.id ?? 0) > lastProposal }
    }

    /// `Answered: local first, remote later`: a row as the log reads.
    public static func line(_ row: SwarmSteer) -> String {
        let what = switch row.kind {
        case .start: row.text
        case .propose: row.state == .pending ? "Proposed (waits for you): \(row.text)" : "Proposed: \(row.text)"
        case .question: "Asked: \(row.text)"
        case .answer: "Answered: \(row.text)"
        case .replan: "Re-plan: \(row.text)"
        case .approve: "Approved \(row.text)"
        case .reject: "Said no: \(row.text)"
        case .restore: "Restored \(row.text)"
        case .message: "To \(row.to.flatMap(SwarmAddress.init(raw:))?.label() ?? "an agent"): \(row.text)"
        case .note: "Note: \(row.text)"
        case .suggest: "Suggests: \(row.text)"
        case .overrule: "Overruled: \(row.text)"
        case .rule: "Same answer for similar questions: \(row.answer ?? "") (\(row.text))"
        default: row.text
        }
        // A run's start says its settings already; its reason (your say) is in the plan's header.
        return what + (row.kind == .start ? "" : row.reason.map { " (\($0))" } ?? "")
    }
}
