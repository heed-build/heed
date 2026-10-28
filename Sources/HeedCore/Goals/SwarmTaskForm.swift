import Foundation

/// A plan task as you type it in the plan pane: its fields as text, read back into a task (`after` as plan numbers
/// like `1.2` or ids, done-when one check per line, the owner as `agent` or `agent:model`).
public struct SwarmTaskForm: Hashable, Sendable {
    public var title = ""
    public var phase = ""
    public var owner = ""
    public var estimate = ""
    public var after = ""
    public var doneWhen = ""

    public init() {}

    /// A task's fields as text; `after` as its plan numbers in `tasks`.
    public init(_ task: SwarmTask, in tasks: [SwarmTask]) {
        let numbers = SwarmPlan.numbers(tasks)
        title = task.title
        phase = task.phase
        owner = task.owner.map { owner in owner.model.map { "\(owner.agent):\($0)" } ?? owner.agent } ?? ""
        estimate = task.estimate.map(SwarmEstimate.text) ?? ""
        after = task.after.map { numbers[$0] ?? SwarmPlan.short($0) }.joined(separator: ", ")
        doneWhen = task.doneWhen.joined(separator: "\n")
    }

    /// The task the fields describe, with `id`, in a plan of `tasks`; or what is wrong, in words.
    public func task(id: String, in tasks: [SwarmTask]) -> Result<SwarmTask, Problem> {
        let title = GoalDoc.oneLine(title)
        guard !title.isEmpty else { return .failure(Problem("a task needs a title")) }
        var minutes: Int?
        if !estimate.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let read = SwarmEstimate.minutes(estimate) else {
                return .failure(Problem("no estimate in \(estimate): 15m, 1h 30m"))
            }
            minutes = read
        }
        let byNumber = Dictionary(SwarmPlan.numbers(tasks).map { ($0.value, $0.key) }) { first, _ in first }
        var waits: [String] = []
        for word in after.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init) where !word.isEmpty {
            guard let found = byNumber[word] ?? tasks.first(where: { $0.id == word || $0.slug == word })?.id else {
                return .failure(Problem("no task \(word) to wait for (a number like 1.2, or an id)"))
            }
            guard found != id else { return .failure(Problem("a task cannot wait for itself")) }
            if !waits.contains(found) { waits.append(found) }
        }
        let parts = owner.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
        let who = parts.first.flatMap { $0.isEmpty ? nil : GoalItem.Owner(
            agent: $0,
            model: parts.count > 1 ? parts[1] : nil
        ) }
        let phase = GoalDoc.oneLine(phase)
        return .success(SwarmTask(
            id: id, title: title, phase: phase.isEmpty ? "Plan" : phase, owner: who, estimate: minutes, after: waits,
            doneWhen: doneWhen.components(separatedBy: "\n").map(GoalDoc.oneLine).filter { !$0.isEmpty }
        ))
    }

    public struct Problem: Error, Equatable, Sendable {
        public var text: String
        public init(_ text: String) { self.text = text }
    }
}
