import Foundation

/// heed's next step for an Attention item: the one thing it would do now, proposed with one key (`D`). What it is
/// depends on what the item is and whose: someone else's PR gets a review, an issue that tags you a reply, your PR
/// gets green and merged, a repo with no Autopilot its setup, an issue assigned to you Start work. Your own issue
/// where you spoke last has nothing to do.
public enum NextStep: Hashable, Sendable {
    /// A helper reads the PR, runs its tests and drafts review comments; nothing is posted until you send it.
    case review
    /// A reply drafted from the thread; you read it before anything is posted.
    case draftReply
    /// A helper fixes the failing checks and review comments, in its own worktree. `steps` are what it will do, in
    /// order; `merge` when get it merged follows.
    case getGreen(steps: [String], merge: Bool)
    /// A helper resolves the conflict with the base.
    case resolveConflict(base: String)
    /// Merge it now, by the repo's merge rules.
    case merge
    /// The repo has no Autopilot set up: the setup wizard, then the step after it.
    case setUpAutopilot(Repo)
    /// Start work on it: a session in a fresh worktree, its goal attached.
    case startWork
    /// A helper is on it already.
    case helping(HelperKind)
    /// Nothing for you: why.
    case nothing(String)

    /// The proposal's title: `Heed's next step: get it green and merge it`.
    public var title: String {
        switch self {
        case .review: "start a review"
        case .draftReply: "draft a reply"
        case let .getGreen(_, merge): merge ? "get it green and merge it" : "get it green"
        case .resolveConflict: "resolve the conflict"
        case .merge: "merge it"
        case .setUpAutopilot: "set up Autopilot"
        case .startWork: "start work"
        case .helping: rowLine
        case let .nothing(why): why
        }
    }

    /// The row's line under the title: `next: start a review`, `heed is getting it green`.
    public var rowLine: String {
        switch self {
        case let .helping(kind):
            switch kind {
            case .green: "heed is getting it green"
            case .conflict: "heed is resolving the conflict"
            case .review: "heed is reviewing it"
            }
        case let .nothing(why): "\(why) · nothing to do"
        default: "next: \(title)"
        }
    }

    /// The row's short mark, right-aligned on its reasons line (`▶ merge it`): only when heed would act. Nil when
    /// there is nothing to do or heed waits on others.
    public var chip: String? {
        switch self {
        case .review: "▶ review"
        case .draftReply: "▶ reply"
        case let .getGreen(_, merge): merge ? "▶ green + merge" : "▶ get it green"
        case .resolveConflict: "▶ resolve"
        case .merge: "▶ merge it"
        case .setUpAutopilot: "▶ set up"
        case .startWork: "▶ start"
        case .helping: "▶ heed is on it"
        case .nothing: nil
        }
    }

    /// The one button's word: `Review it`, `Draft it`, `Do it`.
    public var button: String? {
        switch self {
        case .review: "Review it"
        case .draftReply: "Draft it"
        case .getGreen, .resolveConflict: "Do it"
        case .merge: "Merge"
        case .setUpAutopilot: "Set it up"
        case .startWork: "Start"
        case .helping: "Watch it"
        case .nothing: nil
        }
    }

    /// What it promises, beside the button.
    public var note: String {
        switch self {
        case .review: "reads the change, runs the tests, drafts comments: posts nothing until you send"
        case .draftReply: "drafts from the thread: posts nothing until you send"
        case .getGreen: "a helper does it beside your session, in its own worktree: pushes once you approve"
        case let .resolveConflict(base): "a helper merges \(base) in, in its own worktree: pushes once you approve"
        case .merge: "merges by the repo's merge rules"
        case .setUpAutopilot: "samples merged PRs and CI, proposes settings: you approve each"
        case .startWork: "a session in a fresh worktree on it"
        case .helping: "it works in its own worktree; you approve before anything is pushed or posted"
        case .nothing: "heed waits for someone else to answer, then it comes back"
        }
    }

    /// The steps it shows as chips: what a get it green helper will do.
    public var steps: [String] {
        if case let .getGreen(steps, _) = self { return steps }
        return []
    }

    /// The Autopilot capability `Y` (Always in <repo>) turns on, when there is one.
    public var capability: Capability? {
        switch self {
        case .getGreen, .resolveConflict: .green
        case .merge: .merge
        default: nil
        }
    }

    /// Something `D` can do.
    public var actionable: Bool { button != nil }

    /// What heed knows about an item that decides its next step.
    public struct Facts: Hashable, Sendable {
        /// You, on GitHub.
        public var viewer: String?
        /// For a PR: the pilot's status, and whether get it merged is on.
        public var status: PilotStatus?
        public var mergeOn: Bool
        /// Failing checks and open review comments, counted.
        public var failingChecks: [String]
        public var reviewComments: Int
        /// Approvals the PR still needs (from its review decision); 0 when none or not known.
        public var approvalsNeeded: Int
        public var conflictBase: String?
        /// Whether the repo has Autopilot set up (get it green or merging configured for it, or its org).
        public var autopilotSetUp: Bool
        /// A helper working on it now.
        public var helper: HelperKind?

        public init(
            viewer: String? = nil, status: PilotStatus? = nil, mergeOn: Bool = false, failingChecks: [String] = [],
            reviewComments: Int = 0, approvalsNeeded: Int = 0, conflictBase: String? = nil,
            autopilotSetUp: Bool = true, helper: HelperKind? = nil
        ) {
            self.viewer = viewer
            self.status = status
            self.mergeOn = mergeOn
            self.failingChecks = failingChecks
            self.reviewComments = reviewComments
            self.approvalsNeeded = approvalsNeeded
            self.conflictBase = conflictBase
            self.autopilotSetUp = autopilotSetUp
            self.helper = helper
        }
    }

    /// The next step for `item`; nil for what heed has no step for (CI runs, releases, agents, goals).
    public static func of(_ item: AttentionItem, facts: Facts) -> NextStep? {
        if let helper = facts.helper { return .helping(helper) }
        let mine = item.reasons.contains(.yourPR) || item.reasons.contains(.author)
            || (facts.viewer != nil && item.author?.lowercased() == facts.viewer?.lowercased())
        let spokeLast = facts.viewer != nil && item.lastCommenter?.lowercased() == facts.viewer?.lowercased()
        switch item.kind {
        case .pr:
            if mine {
                guard facts.autopilotSetUp else { return item.repo.map(NextStep.setUpAutopilot) }
                if let base = facts.conflictBase { return .resolveConflict(base: base) }
                if !facts.failingChecks.isEmpty || facts.reviewComments > 0 {
                    var steps = facts.failingChecks.map { "fix \($0)" }
                    if facts.reviewComments > 0 {
                        steps.append("address \(facts.reviewComments) comment\(facts.reviewComments == 1 ? "" : "s")")
                    }
                    if facts.approvalsNeeded > 0 { steps.append("wait for approval") }
                    if facts.mergeOn { steps.append("merge with heed's rules") }
                    return .getGreen(steps: steps, merge: facts.mergeOn)
                }
                if item.reasons.contains(.readyToMerge) || facts.status == .green { return .merge }
                return .nothing(facts.status == .pending ? "checks running" : "waiting on reviewers")
            }
            if item.reasons.contains(.reviewRequested) { return .review }
            if item.reasons.contains(.mentioned) || item.reasons.contains(.teamMention) {
                return spokeLast ? .nothing("you replied last") : .draftReply
            }
            return nil
        case .issue:
            if item.reasons.contains(.assigned) || item.reasons.contains(.assignedBefore) { return .startWork }
            if spokeLast { return .nothing(mine ? "waiting on others" : "you replied last") }
            if item.reasons.contains(.mentioned) || item.reasons.contains(.teamMention)
                || item.reasons.contains(.mentionedBefore)
            {
                return .draftReply
            }
            if mine { return .nothing("waiting on others") }
            return nil
        case .ci, .release, .discussion, .agent, .goal, .other:
            return nil
        }
    }

    /// The other steps `.` offers for an item, after the proposed one: what you might do instead.
    public static func others(_ item: AttentionItem, proposed: NextStep?) -> [NextStep] {
        var steps: [NextStep] = []
        if item.kind == .pr || item.kind == .issue { steps.append(.draftReply) }
        if item.kind == .issue { steps.append(.startWork) }
        if item.kind == .pr, !item.reasons.contains(.yourPR) { steps.append(.review) }
        return steps.filter { $0 != proposed }
    }
}
