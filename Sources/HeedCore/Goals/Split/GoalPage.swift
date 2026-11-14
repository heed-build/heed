import Foundation

/// The goal's page for a goal with a plan of parts (one that went through the wizard, or a swarm's): the same board as
/// Split, live. Each part's state, the now line, the journey bar, the one next step for you, and the numbers under it.
public struct GoalPage: Hashable, Sendable {
    public var draft: SplitDraft
    public var states: [String: PartState]
    public var schedule: SplitSchedule
    /// Hours since the work started; nil before it did.
    public var now: Double?
    public var journey: GoalJourney
    public var next: GoalNextStep?
    /// Dollars the work used so far, as the agents reported.
    public var spent: Double?

    public init(
        draft: SplitDraft, states: [String: PartState], startedAt: Date?, now: Date, journey: GoalJourney,
        next: GoalNextStep?, spent: Double?
    ) {
        self.draft = draft
        self.states = states
        let numbers = Dictionary(draft.parts.enumerated().map { ($0.element.id, $0.offset + 1) }) { first, _ in first }
        schedule = SplitSchedule.make(draft.parts, numbers: numbers)
        self.now = startedAt.map { max(0, now.timeIntervalSince($0) / 3600) }
        self.journey = journey
        self.next = next
        self.spent = spent
        if let next, next.question != nil, let hours = self.now {
            // The lead's ask, on its spine where it was asked: now.
            schedule.moves.append(SplitSchedule.LeadMove(at: hours, kind: .ask, label: next.title))
            schedule.moves.sort { $0.at < $1.at }
        }
    }

    public var done: Int { draft.active.count { states[$0.id]?.isDone == true } }
    public var total: Int { draft.active.count }

    /// Hours of work left on the plan: from now to its end, at least what the parts not done still need on the
    /// longest agent.
    public var hoursLeft: Double {
        let end = schedule.makespan
        return max(0, end - (now ?? 0))
    }

    /// A swarm's plan as parts: each task one, on its owner's agent (else the worker that took it), with no repo or
    /// context (the swarm never had them).
    public static func parts(_ tasks: [SwarmTask], workers: [SwarmWorker]) -> [SplitPart] {
        tasks.map { task in
            var task = task
            if task.owner == nil, let worker = workers.last(where: { $0.task == task.id }) { task.owner = worker.owner }
            return SplitPart(task: task)
        }
    }
}
