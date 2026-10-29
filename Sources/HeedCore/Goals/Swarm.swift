import Foundation

/// A swarm run on a goal: a burst of parallel work, planned by a lead agent, approved by you, run by workers, landed in
/// order. The goal outlives it: a goal has at most one active run, and when it ends the goal carries on as a normal
/// goal; the next swarm on the same goal is the next run. Old runs stay readable with their plans and steering.
public struct GoalSwarm: Hashable, Sendable, Codable, Identifiable {
    public enum Status: String, Hashable, Sendable, Codable, CaseIterable {
        /// The lead drafts the plan; you read it, change it, approve it. Nothing runs.
        case planning
        case running, paused, landing
        case done, stopped

        /// Still the goal's swarm: not done and not stopped.
        public var active: Bool { self != .done && self != .stopped }
    }

    /// `<goal>/swarm-<n>`.
    public var id: String
    public var goal: String
    /// 1 for the goal's first swarm, 2 for the follow-up.
    public var number: Int
    public var status: Status
    public var settings: SwarmSettings
    /// The plan version that is current; 0 until the lead proposes one.
    public var plan: Int
    /// The version you approved last, if any: what workers run from (later).
    public var approved: Int?
    /// The lead's session, once it started.
    public var lead: String?
    public var startedAt: Date
    public var endedAt: Date?
    /// When its first worker started: its hours count from here.
    public var runningAt: Date?
    /// Every worker that ran on it, oldest first: who, on which task, from which base, how it ended, what it cost.
    public var workers: [SwarmWorker]
    /// The limit it stopped at, while it waits for you to raise it (paused by heed, not by you).
    public var held: SwarmLimit?
    /// Its end-of-build summary, once it is done (and again when the lead rewrites it).
    public var summary: SwarmSummary?

    public init(
        id: String, goal: String, number: Int, status: Status = .planning, settings: SwarmSettings, plan: Int = 0,
        approved: Int? = nil, lead: String? = nil, startedAt: Date, endedAt: Date? = nil, runningAt: Date? = nil,
        workers: [SwarmWorker] = [], held: SwarmLimit? = nil, summary: SwarmSummary? = nil
    ) {
        self.id = id
        self.goal = goal
        self.number = number
        self.status = status
        self.settings = settings
        self.plan = plan
        self.approved = approved
        self.lead = lead
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.runningAt = runningAt
        self.workers = workers
        self.held = held
        self.summary = summary
    }

    private enum CodingKeys: String, CodingKey {
        case id, goal, number, status, settings, plan, approved, lead, startedAt, endedAt, runningAt, workers, held,
             summary
    }

    /// Runs stored before workers decode unchanged: no workers, never running.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        goal = try values.decode(String.self, forKey: .goal)
        number = try values.decode(Int.self, forKey: .number)
        status = try values.decode(Status.self, forKey: .status)
        settings = try values.decode(SwarmSettings.self, forKey: .settings)
        plan = try values.decode(Int.self, forKey: .plan)
        approved = try values.decodeIfPresent(Int.self, forKey: .approved)
        lead = try values.decodeIfPresent(String.self, forKey: .lead)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        endedAt = try values.decodeIfPresent(Date.self, forKey: .endedAt)
        runningAt = try values.decodeIfPresent(Date.self, forKey: .runningAt)
        workers = try values.decodeIfPresent([SwarmWorker].self, forKey: .workers) ?? []
        held = try values.decodeIfPresent(SwarmLimit.self, forKey: .held)
        summary = try values.decodeIfPresent(SwarmSummary.self, forKey: .summary)
    }

    /// Its workers at work now (recorded as started, not ended).
    public var liveWorkers: [SwarmWorker] { workers.filter(\.isLive) }

    /// The newest worker on a task.
    public func lastWorker(on task: String) -> SwarmWorker? { workers.last { $0.task == task } }

    /// Whether workers may start: approved and planning, running or landing.
    public var startsWorkers: Bool {
        switch status {
        case .planning: approved != nil
        case .running, .landing: true
        case .paused, .done, .stopped: false
        }
    }

    /// The plan you approved is the current one.
    public var isApproved: Bool { approved != nil && approved == plan }

    /// `planning · plan v2`, `approved · plan v2`, `stopped`.
    public var stateLine: String {
        let state = status == .planning && isApproved ? "approved" : status.rawValue
        return plan == 0 ? "\(state) · no plan yet" : "\(state) · plan v\(plan)"
    }
}

/// How a swarm runs: where, who leads and who works, its limits and how much you are asked.
public struct SwarmSettings: Hashable, Sendable, Codable {
    /// How much say you want once the plan is approved.
    public enum Autonomy: String, Hashable, Sendable, Codable, CaseIterable {
        /// Approve the plan, then check in at the end of each phase.
        case eachPhase
        /// Approve the plan; after that heed asks only when the plan or the scope changes (the default).
        case planChanges
        /// Approve the plan, then it runs to the end; you read the result.
        case toTheEnd

        public var title: String {
            switch self {
            case .eachPhase: "Approve the plan, then check in per phase"
            case .planChanges: "Approve the plan, ask only when it changes"
            case .toTheEnd: "Approve the plan, run to the end, I read the result"
            }
        }
    }

    /// Agents of one kind on the worker team.
    public struct Worker: Hashable, Sendable, Codable {
        public var agent: String
        public var model: String?
        public var count: Int

        public init(agent: String, model: String? = nil, count: Int = 1) {
            self.agent = agent
            self.model = model?.isEmpty == true ? nil : model
            self.count = max(count, 1)
        }

        /// `claude ×3`, `codex · o4 ×2`.
        public var label: String { GoalItem.Owner(agent: agent, model: model).label + " ×\(count)" }
    }

    /// What a swarm may spend: agents at once, hours of wall time, dollars (estimated for subscriptions). Reaching one
    /// pauses spawning and asks you.
    public struct Limits: Hashable, Sendable, Codable {
        public var agents: Int
        public var hours: Double
        public var dollars: Double

        public init(agents: Int = 4, hours: Double = 4, dollars: Double = 40) {
            self.agents = agents
            self.hours = hours
            self.dollars = dollars
        }

        /// `4 agents · 4 h · $40`.
        public var line: String {
            "\(agents) agent\(agents == 1 ? "" : "s") · \(String(format: "%g", hours)) h · $\(String(format: "%g", dollars))"
        }

        /// The limits with `limit` raised by half again (at least an hour, at least $5), rounded up: what saying yes
        /// to a swarm stopped at a limit gives it.
        public func raised(_ limit: SwarmLimit) -> Limits {
            var next = self
            switch limit {
            case .hours: next.hours = hours + max(1, (hours / 2).rounded(.up))
            case .dollars: next.dollars = dollars + max(5, (dollars / 2 / 5).rounded(.up) * 5)
            }
            return next
        }
    }

    /// Get it merged for the swarm's PRs: what the repo says (the default), or a mode of the swarm's own. Either way
    /// its PRs merge in merge order, a held child waits for its parent, and a PR's own choice (`zm`) wins over it.
    public enum Merge: String, Hashable, Sendable, Codable, CaseIterable {
        case repo, off, auto, heed

        /// The mode a swarm PR gets, from what its repo's `[pilot]` settings say.
        public func mode(repo: MergeMode) -> MergeMode {
            switch self {
            case .repo: repo
            case .off: .off
            case .auto: .auto
            case .heed: .heed
            }
        }

        /// The word `:swarm.merge` takes: `off`, `auto`, `heed`, or `repo` (also `follow`, `default`) for the repo's.
        public static func named(_ word: String) -> Merge? {
            switch word.lowercased() {
            case "repo", "follow", "default": .repo
            default: Merge(rawValue: word.lowercased())
            }
        }

        /// `merge as the repo says (off)`, `merge auto`.
        public func line(repo: MergeMode) -> String {
            self == .repo ? "merge as the repo says (\(repo.configName))" : "merge \(rawValue)"
        }
    }

    /// `org/name` of the repos the swarm works in; the lead starts in the first.
    public var repos: [String]
    public var lead: GoalItem.Owner
    public var workers: [Worker]
    public var limits: Limits
    public var autonomy: Autonomy
    /// When a worker counts as stuck, and how long a question may wait on a peer or on you.
    public var stuck: SwarmStuck.Settings
    /// Get it merged for its PRs.
    public var merge: Merge

    public init(
        repos: [String] = [], lead: GoalItem.Owner = GoalItem.Owner(agent: "claude"), workers: [Worker] = [],
        limits: Limits = Limits(), autonomy: Autonomy = .planChanges, stuck: SwarmStuck.Settings = .defaults,
        merge: Merge = .repo
    ) {
        self.merge = merge
        self.repos = repos
        self.lead = lead
        self.workers = workers
        self.limits = limits
        self.autonomy = autonomy
        self.stuck = stuck
    }

    private enum CodingKeys: String, CodingKey {
        case repos, lead, workers, limits, autonomy, stuck, merge
    }

    /// Settings stored before stuck detection (or the merge setting) read with their defaults.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        repos = try values.decode([String].self, forKey: .repos)
        lead = try values.decode(GoalItem.Owner.self, forKey: .lead)
        workers = try values.decode([Worker].self, forKey: .workers)
        limits = try values.decode(Limits.self, forKey: .limits)
        autonomy = try values.decode(Autonomy.self, forKey: .autonomy)
        stuck = try values.decodeIfPresent(SwarmStuck.Settings.self, forKey: .stuck) ?? .defaults
        merge = try values.decodeIfPresent(Merge.self, forKey: .merge) ?? .repo
    }

    /// The agents the lead may assign tasks to: the workers' agents, or the lead's when there are none.
    public var team: [String] {
        let agents = workers.map(\.agent)
        return agents.isEmpty ? [lead.agent] : agents.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
}

/// One task of a plan version, as the plan had it: the item it is (or becomes, once approved), and the plan's fields.
public struct SwarmTask: Hashable, Sendable, Codable, Identifiable {
    /// The item's id, `<goal>/<slug>`: an item already on the goal, or the one approval makes.
    public var id: String
    public var title: String
    public var phase: String
    public var owner: GoalItem.Owner?
    /// Minutes.
    public var estimate: Int?
    /// Ids of the tasks (or items) it waits for.
    public var after: [String]
    public var doneWhen: [String]

    public init(
        id: String, title: String, phase: String, owner: GoalItem.Owner? = nil, estimate: Int? = nil,
        after: [String] = [], doneWhen: [String] = []
    ) {
        self.id = id
        self.title = title
        self.phase = phase
        self.owner = owner
        self.estimate = estimate
        self.after = after
        self.doneWhen = doneWhen
    }

    public var slug: String { id.split(separator: "/", maxSplits: 1).last.map(String.init) ?? id }
}

/// A plan version: every change to the plan, by the lead, by you or by a restore, is a new one; none is ever lost.
public struct SwarmPlanVersion: Hashable, Sendable, Codable, Identifiable {
    public enum Author: String, Hashable, Sendable, Codable {
        case lead, you, heed, restore
    }

    public var swarm: String
    public var goal: String
    public var number: Int
    public var at: Date
    public var author: Author
    /// What changed, in a few words (`draft from the lead`, `dropped Cold-cache tests`, `restored v1`).
    public var note: String
    public var tasks: [SwarmTask]

    public init(
        swarm: String, goal: String, number: Int, at: Date, author: Author, note: String, tasks: [SwarmTask]
    ) {
        self.swarm = swarm
        self.goal = goal
        self.number = number
        self.at = at
        self.author = author
        self.note = note
        self.tasks = tasks
    }

    public var id: String { "\(swarm)@\(number)" }
}

/// One steering decision: who decided what, when and why. Rows are only ever added: an answer, an approval or an
/// overrule is a new row that points at the one it is about, so the whole history stays and can be restored.
public struct SwarmSteer: Hashable, Sendable, Codable, Identifiable {
    public enum Actor: String, Hashable, Sendable, Codable, CaseIterable {
        case you, controller, lead, agent, heed
    }

    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        /// The run started (you), its lead started (heed).
        case start
        /// The lead proposed a plan version.
        case propose
        /// The lead (or a worker) asks you something.
        case question
        /// An answer to a question.
        case answer
        /// A task changed by hand (title, owner, estimate, after, done when).
        case edit
        /// A task moved up or down the plan.
        case move
        case add, drop
        /// Re-plan, with feedback for the lead.
        case replan
        case approve
        /// No to a plan change that waited for you.
        case reject
        case restore
        /// A task (ref `task:<id>`) or the whole run paused, and resumed.
        case pause, resume
        /// A task's agent swapped for another.
        case swap
        /// A limit reached (heed), raised or kept (you).
        case limit
        /// The run stopped.
        case stop
        /// A worker started on a task (heed: which agent, from which base) or ended.
        case work
        /// Every task has its PR: the run lands; every task merged: it is done.
        case land
        /// A stacked PR moved to a new base after the PR it stacked on merged (or could not be moved: why).
        case retarget
        /// A message from you or an agent to an agent (`heed swarm send`): to a task's worker, the lead, or @all.
        case message
        /// An agent's progress note (`heed swarm note`): what it is doing, in a line.
        case note
        /// The ladder moved a question on (heed): to a peer, the lead, the controller or you, and why.
        case escalate
        /// The controller's suggested answer to a question that is yours to answer: you take it or answer otherwise.
        case suggest
        /// You answered a question someone else had answered (the controller, the lead, a peer): the new answer, which
        /// is retyped to the agent. It points at the question (`about`) and at the answer it overrules (`ref`).
        case overrule
        /// "Same answer for similar questions" (`A` in Needs you): the controller answers questions like this one with
        /// `answer` from now on, in this goal's swarms.
        case rule
        /// heed handed something to an agent (`about`: the message, question or answer; `ref`: to whom): typed into
        /// its pane, or read by its waiting `heed goal ask` or its `plan show`.
        case deliver
        /// A worker looks stuck (heed, `ref` its task): why, and the ladder's step (`step`: nudge, ask, clear).
        case stuck
        /// heed reminded you of a question that waits on you (`about`).
        case remind
        /// The lead's end-of-build summary (`heed swarm summary`): its outcome, decisions and follow-ups.
        case summary
        /// You deleted a repeat rule (`about`): the controller no longer answers with it.
        case unrule
        /// A PR's merge conflict or rebase went back to the task's own worker (heed, `ref` its task), or to a get it
        /// merged run because that worker could not take it (`reason` says why).
        case handback
    }

    public enum State: String, Hashable, Sendable, Codable, CaseIterable {
        /// Done: it changed what it says.
        case applied
        /// Waiting: a question not answered, a structural change not approved.
        case pending
        /// An overrule: this row overrules the answer its `ref` names (rows are never changed, so the answer it
        /// overrules reads as overruled from this row on: `SwarmSteering.overruled`).
        case overruled
    }

    /// Its row in `goals.sqlite`; nil until stored.
    public var id: Int64?
    public var swarm: String
    public var goal: String
    public var at: Date
    public var actor: Actor
    public var kind: Kind
    /// What was decided, in a line (the question, the answer, the feedback, `dropped 3.2 Cold-cache tests`).
    public var text: String
    public var reason: String?
    public var state: State
    /// The row it answers, approves, rejects or overrules.
    public var about: Int64?
    /// The plan version it made, if it made one.
    public var version: Int?
    /// What it points at outside the swarm: a session, a GOAL.md edit (`edit:12`).
    public var ref: String?
    /// A question's choices.
    public var options: [String]
    /// A plan change waiting for you: the tasks it would make the plan.
    public var tasks: [SwarmTask]?
    /// Who wrote it, when that is not plain from `actor`: an agent's address (`lead`, `task:<id>`, `session:<id>`).
    public var from: String?
    /// Whom it is for: `you`, `lead`, `task:<id>`, `all` (a message, a question asked of someone).
    public var to: String?
    /// A question's choices: what each would change, in the order of `options` (empty where the asker said nothing).
    public var effects: [String]?
    /// A question's category (`SwarmAuthority.Category`), and the ladder it climbs (`SwarmAuthority.Answerer`s).
    public var category: String?
    public var ladder: [String]?
    /// A question's step on the ladder when asked, or the step an escalation moved it to.
    public var step: String?
    /// A message to @all: the addresses it went to (the lead and the tasks at work then).
    public var targets: [String]?
    /// A repeat rule's answer.
    public var answer: String?
    /// The lead's summary: its decisions and follow-ups.
    public var decisions: [String]?
    public var followUps: [String]?

    public init(
        id: Int64? = nil, swarm: String, goal: String, at: Date, actor: Actor, kind: Kind, text: String,
        reason: String? = nil, state: State = .applied, about: Int64? = nil, version: Int? = nil, ref: String? = nil,
        options: [String] = [], tasks: [SwarmTask]? = nil, from: String? = nil, to: String? = nil,
        effects: [String]? = nil, category: String? = nil, ladder: [String]? = nil, step: String? = nil,
        targets: [String]? = nil, answer: String? = nil, decisions: [String]? = nil, followUps: [String]? = nil
    ) {
        self.decisions = decisions
        self.followUps = followUps
        self.from = from
        self.to = to
        self.effects = effects
        self.category = category
        self.ladder = ladder
        self.step = step
        self.targets = targets
        self.answer = answer
        self.id = id
        self.swarm = swarm
        self.goal = goal
        self.at = at
        self.actor = actor
        self.kind = kind
        self.text = text
        self.reason = reason
        self.state = state
        self.about = about
        self.version = version
        self.ref = ref
        self.options = options
        self.tasks = tasks
    }
}

/// A swarm with its plan versions and steering rows: what the plan pane draws.
public struct SwarmBoard: Hashable, Sendable {
    public var swarm: GoalSwarm
    /// Newest first.
    public var versions: [SwarmPlanVersion]
    /// Oldest first.
    public var steering: [SwarmSteer]

    public init(swarm: GoalSwarm, versions: [SwarmPlanVersion] = [], steering: [SwarmSteer] = []) {
        self.swarm = swarm
        self.versions = versions
        self.steering = steering
    }

    /// The current plan's tasks.
    public var tasks: [SwarmTask] { versions.first { $0.number == swarm.plan }?.tasks ?? [] }

    public func version(_ number: Int) -> SwarmPlanVersion? { versions.first { $0.number == number } }

    public var questions: [SwarmSteering.Question] { SwarmSteering.questions(steering) }
    public var openQuestions: [SwarmSteering.Question] { questions.filter { $0.answer == nil } }
    public var pending: SwarmSteer? { SwarmSteering.pendingChange(steering) }
}
