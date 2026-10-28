import Foundation

/// Landing a swarm: the order its PRs merge in, what holds a PR back, where a stacked PR goes once the PR it stacks on
/// merged, and when the run is done. Pure: the app carries the retargets out with `gh`, and the pilot (get it green,
/// get it merged) does the rest for each PR, by that PR's own settings. Nothing here merges anything.
public enum SwarmLanding {
    // MARK: Order

    /// The merge order: every task after the tasks of the plan it waits for, otherwise in plan order (always the
    /// earliest task of the plan whose blockers are placed). What it waits for outside the plan does not order it. A
    /// cycle (the plan refuses them) leaves the rest in plan order.
    public static func order(_ tasks: [SwarmTask]) -> [String] {
        let known = Set(tasks.map(\.id))
        var remaining = tasks
        var placed: [String] = []
        var done: Set<String> = []
        while !remaining.isEmpty {
            guard let next = remaining.firstIndex(where: { task in
                task.after.allSatisfy { !known.contains($0) || done.contains($0) }
            }) else {
                placed += remaining.map(\.id)
                break
            }
            let task = remaining.remove(at: next)
            placed.append(task.id)
            done.insert(task.id)
        }
        return placed
    }

    /// A task's place in the merge order, and the constraints on it that are real: the tasks of the plan it waits for
    /// and the ones that wait for it. A task with neither may merge in any order.
    public struct Slot: Hashable, Sendable, Identifiable {
        public var task: String
        /// 1 is the first to merge.
        public var position: Int
        public var total: Int
        /// The tasks of the plan it waits for, in merge order.
        public var after: [String]
        /// The tasks of the plan that wait for it, in merge order.
        public var before: [String]

        public var id: String { task }

        /// Nothing orders it: it merges whenever it is ready, before or after the others.
        public var isolated: Bool { after.isEmpty && before.isEmpty }
    }

    /// Every task's slot, in merge order.
    public static func slots(_ tasks: [SwarmTask]) -> [Slot] {
        let order = order(tasks)
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.enumerated().map { index, id in
            let after = (byID[id]?.after ?? []).filter { rank[$0] != nil }.sorted { rank[$0]! < rank[$1]! }
            let before = order.filter { other in byID[other]?.after.contains(id) == true }
            return Slot(task: id, position: index + 1, total: order.count, after: after, before: before)
        }
    }

    /// `2/4 · after #412`: its place, then what it waits for (a task's PR when it has one, else its plan number);
    /// `3/4 · any order` when nothing orders it. `prs`: task → its PR number.
    public static func label(_ slot: Slot, prs: [String: Int], numbers: [String: String]) -> String {
        let place = "\(slot.position)/\(slot.total)"
        if slot.isolated { return place + " · any order" }
        if slot.after.isEmpty { return place }
        return place + " · after " + slot.after.map { name($0, prs: prs, numbers: numbers) }.joined(separator: " ")
    }

    /// `#412`, else `1.1`.
    public static func name(_ task: String, prs: [String: Int], numbers: [String: String]) -> String {
        if let number = prs[task], number > 0 { return "#\(number)" }
        return numbers[task] ?? SwarmPlan.short(task)
    }

    /// Each task's PR number, from its facts (open, merged or closed), when it has one heed knows.
    public static func prs(_ facts: [String: SwarmTaskFacts]) -> [String: Int] {
        facts.compactMapValues { fact in
            switch fact.pr {
            case .none: nil
            case let .open(number, _, _), let .merged(number), let .closed(number): number > 0 ? number : nil
            }
        }
    }

    // MARK: Holding

    /// Why a task's PR may not merge yet: a task it waits for has not merged. Dependencies merge first, so a stacked
    /// PR never merges before the PR it stacks on (into its branch, or past it into the default branch). Nil: as far
    /// as the swarm goes it may merge; the PR's own merge rules and its get it merged setting still decide.
    public static func hold(
        _ task: SwarmTask, facts: [String: SwarmTaskFacts], prs: [String: Int], numbers: [String: String]
    ) -> String? {
        let waiting = task.after.filter { blocker in
            let fact = facts[blocker] ?? SwarmTaskFacts()
            return !(fact.merged || fact.done)
        }
        guard !waiting.isEmpty else { return nil }
        let names = waiting.map { name($0, prs: prs, numbers: numbers) }
        let one = names.count == 1
        return "after \(names.joined(separator: " and ")), which \(one ? "is" : "are") not merged yet: "
            + "dependencies merge first"
    }

    // MARK: Retargeting

    /// A stacked PR whose parent merged: it goes against where the parent merged, and its branch is rebased there.
    public struct Retarget: Hashable, Sendable {
        public var task: String
        /// Its PR.
        public var pr: Int
        /// The task whose PR merged, and that PR.
        public var parent: String
        public var parentPR: Int
        /// Its base now (the parent's branch), and the base it goes to.
        public var from: String
        public var to: String
        /// The task it stacks on after: the parent's own parent, when the parent was stacked on a PR still open;
        /// nil when it goes to the default branch.
        public var stackedOn: String?
        /// Whether `gh pr edit --base` is needed: GitHub moves a PR itself when its base branch is deleted, and then
        /// only heed's record changes.
        public var edit: Bool

        public init(
            task: String, pr: Int, parent: String, parentPR: Int, from: String, to: String, stackedOn: String?,
            edit: Bool
        ) {
            self.task = task
            self.pr = pr
            self.parent = parent
            self.parentPR = parentPR
            self.from = from
            self.to = to
            self.stackedOn = stackedOn
            self.edit = edit
        }

        /// `#415 now goes against main: #412 merged`.
        public var text: String {
            "#\(pr) now goes against \(to): #\(parentPR > 0 ? String(parentPR) : SwarmPlan.short(parent)) merged"
        }
    }

    /// The stacked PRs to retarget now: open, stacked (by its newest worker's record) on a task whose PR merged. It
    /// goes where the parent went: the parent's own base, past any ancestor that merged too, else the default branch.
    /// `bases`: task → its PR's base as GitHub last said, when known. Never a PR of the default branch: those have
    /// nowhere further to go.
    public static func retargets(
        _ tasks: [SwarmTask], swarm: GoalSwarm, facts: [String: SwarmTaskFacts], bases: [String: String] = [:],
        defaultBranch: String
    ) -> [Retarget] {
        var out: [Retarget] = []
        for task in tasks {
            guard case let .open(number, _, _) = facts[task.id]?.pr, let worker = swarm.lastWorker(on: task.id),
                  let parent = worker.stackedOn, worker.base != defaultBranch
            else { continue }
            let parentFact = facts[parent] ?? SwarmTaskFacts()
            guard parentFact.merged || parentFact.done else { continue }
            let (to, stackedOn) = landing(parent, swarm: swarm, facts: facts, defaultBranch: defaultBranch)
            guard to != worker.base else { continue }
            let parentPR: Int = if case let .merged(merged) = parentFact.pr { merged } else { 0 }
            out.append(Retarget(
                task: task.id, pr: number, parent: parent, parentPR: parentPR, from: worker.base, to: to,
                stackedOn: stackedOn, edit: bases[task.id] != to
            ))
        }
        return out
    }

    /// Where a merged task's work went, and the task that branch belongs to: up its own stack past every ancestor
    /// that merged too, to the first one still open, else the default branch.
    static func landing(
        _ merged: String, swarm: GoalSwarm, facts: [String: SwarmTaskFacts], defaultBranch: String
    ) -> (base: String, stackedOn: String?) {
        var current = merged
        var seen: Set<String> = [merged]
        while true {
            guard let worker = swarm.lastWorker(on: current), let up = worker.stackedOn,
                  worker.base != defaultBranch, !seen.contains(up)
            else { return (defaultBranch, nil) }
            let fact = facts[up] ?? SwarmTaskFacts()
            if !(fact.merged || fact.done) { return (worker.base, up) }
            seen.insert(up)
            current = up
        }
    }

    /// The get it green item that has a retargeted PR's branch rebased: the PR's agent run is told what moved and
    /// how (`FeedbackItem.Kind.rebase`). `past`: the parent's last commit, else its branch. Queued when its get it
    /// green is auto, as any feedback; one per parent.
    public static func rebaseItem(_ retarget: Retarget, past: String, queued: Bool) -> FeedbackItem {
        FeedbackItem(
            id: "rebase:\(retarget.parentPR)", kind: .rebase(onto: retarget.to, parent: retarget.parentPR, past: past),
            text: "Rebase onto \(retarget.to): #\(retarget.parentPR) merged.", status: queued ? .queued : .new
        )
    }

    // MARK: Done

    /// Every task of the plan merged (or done by its evidence): the run is done. Holds keep the merges in order.
    public static func landed(_ tasks: [SwarmTask], facts: [String: SwarmTaskFacts]) -> Bool {
        !tasks.isEmpty && tasks.allSatisfy { task in
            let fact = facts[task.id] ?? SwarmTaskFacts()
            return fact.merged || fact.done
        }
    }

    /// Merged of all: `3 of 4 merged`.
    public static func mergedLine(_ tasks: [SwarmTask], facts: [String: SwarmTaskFacts]) -> String {
        let merged = tasks.count { task in
            let fact = facts[task.id] ?? SwarmTaskFacts()
            return fact.merged || fact.done
        }
        return "\(merged) of \(tasks.count) merged"
    }

    // MARK: Rows

    /// One task in the merge order, as the plan pane's merge order, the PR rows and the merge queue show it.
    public struct Row: Hashable, Sendable, Identifiable {
        public enum State: String, Hashable, Sendable {
            /// No PR yet.
            case noPR = "no PR"
            /// Its PR is open and may merge (its own rules permitting).
            case open
            /// Its PR is open and waits for what it comes after.
            case held
            case merged
            /// Its PR closed without merging.
            case closed
        }

        public var slot: Slot
        public var title: String
        public var number: String
        public var pr: Int?
        public var state: State
        /// `2/4 · after #412`.
        public var label: String
        /// Why it is held.
        public var hold: String?
        /// The base its PR goes against, and the task it stacks on, from its newest worker.
        public var base: String?
        public var stackedOn: String?

        public var id: String { slot.task }
    }

    /// The merge order's rows.
    public static func rows(
        _ tasks: [SwarmTask], swarm: GoalSwarm, facts: [String: SwarmTaskFacts]
    ) -> [Row] {
        let numbers = SwarmPlan.numbers(tasks)
        let prs = prs(facts)
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return slots(tasks).compactMap { slot in
            guard let task = byID[slot.task] else { return nil }
            let fact = facts[task.id] ?? SwarmTaskFacts()
            let hold = hold(task, facts: facts, prs: prs, numbers: numbers)
            let state: Row.State = switch fact.pr {
            case .none: fact.done ? .merged : .noPR
            case .open: hold == nil ? .open : .held
            case .merged: .merged
            case .closed: .closed
            }
            let worker = swarm.lastWorker(on: task.id)
            return Row(
                slot: slot, title: task.title, number: numbers[task.id] ?? "", pr: prs[task.id], state: state,
                label: label(slot, prs: prs, numbers: numbers), hold: state == .merged ? nil : hold,
                base: worker?.base, stackedOn: worker?.stackedOn
            )
        }
    }

    // MARK: The GitHub mirror

    /// The meta issue's section for a swarm: its state, then its tasks in merge order with each one's PR and state.
    /// `issues`: item → its sub-issue number. From what the goal's evidence says, so it needs no PR lookup.
    public static func mirrorSection(
        _ swarm: GoalSwarm, tasks: [SwarmTask], items: [GoalItem], evidence: [GoalEvidence], issues: [String: Int]
    ) -> [String] {
        guard !tasks.isEmpty else { return [] }
        let byItem = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let numbers = SwarmPlan.numbers(tasks)
        var lines = ["## Swarm \(swarm.number)", ""]
        let merged = tasks.count { mirrorState($0.id, item: byItem[$0.id], evidence: evidence).merged }
        lines.append("State: **\(swarm.status.rawValue)** · \(merged) of \(tasks.count) merged · merge order:")
        lines.append("")
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for slot in slots(tasks) {
            guard let task = byID[slot.task] else { continue }
            let state = mirrorState(task.id, item: byItem[task.id], evidence: evidence)
            let issue = issues[task.id].map { " (#\($0))" } ?? ""
            let after = slot.after.isEmpty ? (slot.isolated ? " · any order" : "")
                : " · after " + slot.after.map { blocker in
                    issues[blocker].map { "#\($0)" } ?? numbers[blocker] ?? SwarmPlan.short(blocker)
                }.joined(separator: ", ")
            lines.append("\(slot.position). \(task.title)\(issue) · \(state.text)\(after)")
        }
        lines.append("")
        return lines
    }

    /// An item's sub-issue line saying what it comes after: `After #12, #14.` (another sub-issue's number, else the
    /// item's title). Nil when it waits for nothing.
    public static func mirrorAfter(_ item: GoalItem, items: [GoalItem], issues: [String: Int]) -> String? {
        guard !item.after.isEmpty else { return nil }
        let titles = Dictionary(items.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        return "After " + item.after.map { id in
            issues[id].map { "#\($0)" } ?? titles[id] ?? SwarmPlan.short(id)
        }.joined(separator: ", ") + "."
    }

    struct MirrorState {
        var merged: Bool
        var text: String
    }

    /// From the item's evidence and links: merged, a PR open, or none yet.
    static func mirrorState(_ id: String, item: GoalItem?, evidence: [GoalEvidence]) -> MirrorState {
        let mine = evidence.filter { $0.item == id && $0.state == .done }
        if let merged = mine.last(where: { $0.kind == .merged }) {
            return MirrorState(merged: true, text: "merged" + (merged.ref.map { " \($0)" } ?? ""))
        }
        if let pull = item?.linked(.pr).last {
            return MirrorState(merged: false, text: "PR \(pull)")
        }
        return MirrorState(merged: false, text: "no PR yet")
    }
}
