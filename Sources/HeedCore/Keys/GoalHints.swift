import Foundation

/// The status bar's hints in Goals, by the key scope of the pane that is open: each names a command bound in that scope
/// (`DefaultKeys.scoped`), so a pane never shows a key that means something else there (the map does not offer
/// `a archive`). The words follow where the cursor is.
public enum GoalHints {
    public struct Hint: Hashable, Sendable {
        /// The command line as bound (`swarm.map.move l`).
        public var command: String
        public var label: String
        /// Fixed key text for a pair of keys (`h l`), else the command's key as bound.
        public var key: String?

        public init(_ command: String, _ label: String, key: String? = nil) {
            self.command = command
            self.label = label
            self.key = key
        }
    }

    /// What the words depend on.
    public struct Context: Hashable, Sendable {
        /// `GoalsBrowser.Focus`'s raw value: `goals`, `links`, `versions`, …
        public var focus: String
        /// GOAL.md has changes waiting for you.
        public var proposals: Bool
        /// The swarm's plan is approved and it left planning.
        public var running: Bool
        /// The lead's plan change waits for your yes or no.
        public var pendingChange: Bool
        /// The swarm is done: the agents pane shows its summary.
        public var done: Bool
        /// heed proposes an item source for the goal (`y` takes it on the list and the overview).
        public var sourceProposal: Bool

        public init(
            focus: String = "goals", proposals: Bool = false, running: Bool = false, pendingChange: Bool = false,
            done: Bool = false, sourceProposal: Bool = false
        ) {
            self.sourceProposal = sourceProposal
            self.focus = focus
            self.proposals = proposals
            self.running = running
            self.pendingChange = pendingChange
            self.done = done
        }
    }

    /// The hints for `scope`, most useful first, and plain words after them (`/ filter`, `h l column`) for keys
    /// that are not the scope's own.
    public static func hints(scope: String, _ context: Context) -> (hints: [Hint], tail: String) {
        switch scope {
        case "goalplan" where context.running:
            ([
                Hint("goal.focus", context.focus == "versions" ? "goals" : "next"), Hint("swarm.task.pause", "pause"),
                Hint("swarm.task.swap", "swap"), Hint("swarm.task.open", "worker"), Hint("swarm.task.edit", "edit"),
                Hint("swarm.replan", "re-plan"), Hint("swarm.diff", "diff"), Hint("goal.swarm", "overview"),
            ], "")
        case "goalplan":
            ([
                Hint("goal.focus", context.focus == "versions" ? "goals" : "next"), Hint("swarm.task.edit", "edit"),
                Hint("swarm.task.add", "add"), Hint("swarm.task.drop", "drop"), Hint("swarm.replan", "re-plan"),
                context.pendingChange ? Hint("swarm.accept", "yes") : Hint("swarm.approve", "approve"),
                Hint("swarm.answer", "answer"), Hint("swarm.diff", "diff"), Hint("goal.swarm", "overview"),
            ], "")
        case "goalagents" where context.done:
            ([
                Hint("swarm.followup", "follow-up swarm"), Hint("goal.swarm", "plan"), Hint("goal.map", "map"),
                Hint("goal.agents", "overview"),
            ], "")
        case "goalagents":
            ([
                Hint("swarm.task.open", "its tab"), Hint("swarm.task.pause", "pause"), Hint("swarm.task.swap", "swap"),
                Hint("swarm.answer", "answer"), Hint("swarm.controller", "ask the controller"),
                Hint("goal.map", "map"), Hint("goal.agents", "overview"),
            ], "j k agent")
        case "goalmap":
            ([
                Hint("swarm.map.move l", "column", key: "h l"), Hint("swarm.map.move j", "card", key: "j k"),
                Hint("swarm.task.open", "worker"), Hint("swarm.task.pause", "pause"), Hint("swarm.task.swap", "swap"),
                Hint("swarm.task.edit", "edit plan"), Hint("goal.agents", "agents"), Hint("goal.map", "overview"),
            ], "")
        case "goalpersonas":
            ([
                Hint("goal.focus", context.focus == "personas" ? "goals" : "personas"),
                Hint("persona.session", "session"), Hint("persona.chat", "chat"), Hint("persona.reviewer", "reviewer"),
                Hint("persona.edit", "edit"), Hint("persona.derive", "work out again"), Hint(
                    "goal.personas",
                    "overview"
                ),
            ], "")
        case "goalevals":
            ([
                Hint("goal.focus", context.focus == "friction" ? "goals" : "friction"), Hint("eval.fix", "fix"),
                Hint("eval.accept", "accept"), Hint("eval.rewalk", "walk again"), Hint("eval.lens 1", "next lens"),
                Hint("goal.evaluations", "overview"),
            ], "")
        case "goalreviewers":
            ([
                Hint("goal.focus", context.focus == "objections" ? "goals" : "next"),
                Hint("review.recheck", "re-check"), Hint("review.accept", "accept risk"), Hint("review.fix", "fix"),
                Hint("review.why", "why"), Hint("reviewer.spawn", "spawn"), Hint("goal.reviewers", "overview"),
            ], "")
        case "goalboard":
            ([
                Hint("goal.item.move right", "move"), Hint("goal.item.add", "add"), Hint("goal.item.work", "work here"),
                Hint("goal.item.open", "open"), Hint("goal.board", "overview"),
            ], "h l column · j k card")
        case "goaldoc" where context.proposals:
            ([
                Hint("goal.proposal.accept", "accept"), Hint("goal.proposal.reject", "no"),
                Hint("goal.proposal.edit", "reword"), Hint("goal.edit", "edit"), Hint("goal.doc", "overview"),
            ], "")
        case "unassigned":
            ([
                Hint("goal.ask.yes", "yes"), Hint("goal.ask.no", "no"), Hint("goal.ask.move", "move"),
                Hint("goal.ask.ignore", "ignore like this"), Hint("goal.attach.undo", "undo last"),
                Hint("goal.unassigned", "back"),
            ], "")
        default:
            // The list and the overview, and GOAL.md with nothing waiting: the goal is what you are on. In GOAL.md `n`
            // says no to a change, so it offers no new goal.
            // A proposed source comes first where y takes it: not in GOAL.md, where y answers its changes.
            ((context.sourceProposal && scope != "goaldoc" ? [Hint("goal.source.accept", "add the proposed source")]
                    : []) + [
                Hint("goal.open", context.focus == "links" ? "go there" : "open"),
                Hint("goal.focus", context.focus == "links" ? "goals" : "what is on it"),
            ] + (scope == "goaldoc" ? [] : [Hint("goal.new", "new")]) + [
                Hint("goal.doc", scope == "goaldoc" ? "overview" : "GOAL.md"),
                Hint("goal.edit", "edit"),
                Hint("goal.archive", "archive"),
            ], "/ filter")
        }
    }
}
