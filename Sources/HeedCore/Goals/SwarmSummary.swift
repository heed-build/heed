import Foundation

/// The end-of-build summary (deck p15): what got built, the PRs and their merge order, who did what when, what the
/// agents ran into, every question with who answered it and how long it took, the decisions and the follow-ups.
/// Assembled by heed from the run's record (its workers, steering rows and plan) and written by the lead: its outcome,
/// decisions and follow-ups (`heed swarm summary`) go over heed's. Pure: the app stores it on the run, in the ledger,
/// in History and on the goal's page.
public struct SwarmSummary: Hashable, Sendable, Codable {
    public struct PR: Hashable, Sendable, Codable {
        public var task: String
        public var number: String
        public var title: String
        public var pr: Int?
        /// `merged`, `CI passing`, `CI running`, `no PR`.
        public var state: String
        /// Its place in the merge order, from 1.
        public var order: Int
        /// The task number it stacked on.
        public var stackedOn: String?
    }

    /// A stretch of a lane in "who did what, when".
    public struct Span: Hashable, Sendable, Codable {
        public enum Kind: String, Hashable, Sendable, Codable {
            case working, waiting, stuck
        }

        public var kind: Kind
        /// Seconds from the run's start.
        public var start: TimeInterval
        public var end: TimeInterval
    }

    public struct Lane: Hashable, Sendable, Codable {
        /// `lead`, `1.2`.
        public var name: String
        public var spans: [Span]
    }

    public struct Episode: Hashable, Sendable, Codable {
        public enum Kind: String, Hashable, Sendable, Codable {
            case stuck, waited, conflict
        }

        public var kind: Kind
        public var title: String
        public var detail: String
        public var minutes: Int
    }

    public struct Question: Hashable, Sendable, Codable {
        public var text: String
        /// `2.1`, `the lead`.
        public var from: String
        /// `you`, `controller`, `peer`, `lead`; nil when nobody answered.
        public var answeredBy: String?
        public var answer: String?
        public var seconds: TimeInterval?
    }

    public var swarm: String
    public var title: String
    public var outcome: String
    /// The lead wrote the outcome (else it is heed's).
    public var byLead: Bool
    public var startedAt: Date
    public var endedAt: Date
    public var agentTime: TimeInterval
    public var agents: Int
    public var versions: Int
    public var dollars: Double
    public var tokens: Int
    public var prs: [PR]
    public var lanes: [Lane]
    public var episodes: [Episode]
    public var questions: [Question]
    public var decisions: [String]
    public var followUps: [String]

    public var elapsed: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }

    /// The lead's part (`heed swarm summary`), the newest `summary` row's.
    public struct Written: Hashable, Sendable {
        public var outcome: String?
        public var decisions: [String]
        public var followUps: [String]

        public init(outcome: String? = nil, decisions: [String] = [], followUps: [String] = []) {
            self.outcome = outcome
            self.decisions = decisions
            self.followUps = followUps
        }

        public static func of(_ rows: [SwarmSteer]) -> Written? {
            guard let row = rows.last(where: { $0.kind == .summary }) else { return nil }
            return Written(
                outcome: row.text.isEmpty ? nil : row.text, decisions: row.decisions ?? [],
                followUps: row.followUps ?? []
            )
        }
    }

    /// The summary of `board`'s run. `facts`: what heed knows of each task now (its PR); `use`: what the run used.
    public static func assemble(
        _ board: SwarmBoard, goal: String, tasks: [SwarmTask], facts: [String: SwarmTaskFacts],
        use: SwarmUsageRollup, now: Date
    ) -> SwarmSummary {
        let swarm = board.swarm
        let rows = board.steering
        let numbers = SwarmPlan.numbers(tasks)
        // From when it ran: planning took what it took, the run is what the summary is about.
        let start = swarm.runningAt ?? swarm.startedAt
        let end = swarm.endedAt ?? now
        func offset(_ date: Date) -> TimeInterval { max(0, date.timeIntervalSince(start)) }
        func name(_ task: String) -> String { numbers[task] ?? SwarmPlan.short(task) }
        func label(_ raw: String?) -> String {
            guard let address = raw.flatMap(SwarmAddress.init(raw:)) else { return "an agent" }
            if case let .task(id) = address { return name(id) }
            return address.label(numbers)
        }

        // The PRs, in merge order.
        let order = SwarmLanding.order(tasks)
        var prs: [PR] = []
        for (index, id) in order.enumerated() {
            guard let task = tasks.first(where: { $0.id == id }) else { continue }
            let fact = facts[id] ?? SwarmTaskFacts()
            let (number, state): (Int?, String) = switch fact.pr {
            case .none: (nil, "no PR")
            case let .merged(number): (number > 0 ? number : nil, "merged")
            case let .closed(number): (number, "closed")
            case let .open(number, _, checks):
                (
                    number,
                    checks == .passing ? "CI passing" : checks == .failing ? "CI failing"
                        : checks == .draft ? "draft" : "CI running"
                )
            }
            let stacked = swarm.lastWorker(on: id)?.stackedOn.map(name)
            prs.append(PR(
                task: id, number: name(id), title: task.title, pr: number, state: state, order: index + 1,
                stackedOn: stacked
            ))
        }

        // Who did what, when: the lead planning, then each task's workers, its waits and stuck stretches over them.
        var lanes: [Lane] = []
        // The lead, as it acted during the run: each answer, message or summary of its a short stretch.
        let leading = rows.filter { $0.actor == .lead && $0.at >= start && $0.at <= end }
            .map { Span(kind: .working, start: offset($0.at), end: offset($0.at) + 120) }
        if !leading.isEmpty { lanes.append(Lane(name: "lead", spans: leading)) }
        let questions = SwarmSteering.questions(rows)
        for task in tasks {
            var spans = swarm.workers.filter { $0.task == task.id }.map { worker in
                Span(kind: .working, start: offset(worker.startedAt), end: offset(worker.endedAt ?? end))
            }
            let mine = SwarmAddress.task(task.id).raw
            for question in questions where question.row.from == mine {
                spans.append(Span(
                    kind: .waiting, start: offset(question.row.at), end: offset(question.answer?.at ?? end)
                ))
            }
            for episode in stuckEpisodes(rows, task: task.id, end: end) {
                spans.append(Span(kind: .stuck, start: offset(episode.start), end: offset(episode.end)))
            }
            if !spans.isEmpty { lanes.append(Lane(name: name(task.id), spans: spans.sorted { $0.start < $1.start })) }
        }

        // What they ran into: stuck stretches, long waits on you, PRs that could not be moved.
        var episodes: [Episode] = []
        for task in tasks {
            for episode in stuckEpisodes(rows, task: task.id, end: end) {
                episodes.append(Episode(
                    kind: .stuck, title: "\(name(task.id)): \(episode.why)", detail: episode.how,
                    minutes: Int(episode.end.timeIntervalSince(episode.start) / 60)
                ))
            }
        }
        for question in questions {
            guard let answer = question.answer, answer.actor == .you,
                  answer.at.timeIntervalSince(question.row.at) >= 5 * 60
            else { continue }
            let asker = question.row.from == nil && question.row.actor == .lead ? "the lead" : label(question.row.from)
            episodes.append(Episode(
                kind: .waited, title: "\(asker) waited for your answer",
                detail: "\(question.row.text) You answered \(answer.text).",
                minutes: Int(answer.at.timeIntervalSince(question.row.at) / 60)
            ))
        }
        for row in rows where row.kind == .retarget && row.state == .pending {
            episodes.append(Episode(kind: .conflict, title: row.text, detail: row.reason ?? "", minutes: 0))
        }

        let asked = questions.map { question -> Question in
            let answer = question.answer
            let by: String? = answer.map { row in
                switch row.actor {
                case .you: "you"
                case .controller: "controller"
                case .lead: "lead"
                case .agent: row.from == SwarmAddress.lead.raw ? "lead" : "peer"
                case .heed: "heed"
                }
            }
            return Question(
                text: question.row.text, from: label(question.row.from ?? (question.row.actor == .lead ? "lead" : nil)),
                answeredBy: by, answer: answer?.text, seconds: answer.map { $0.at.timeIntervalSince(question.row.at) }
            )
        }

        let written = Written.of(rows)
        var decisions = written?.decisions ?? []
        // Answers you and the controller gave are decisions; heed's own questions for a stuck worker are not.
        for question in questions where question.row.actor != .heed {
            guard let answer = question.answer, answer.actor == .you || answer.actor == .controller else { continue }
            let line = "\(question.row.text) \(answer.text) (\(answer.actor == .you ? "you" : "controller"))"
            if !decisions.contains(where: { GoalEdits.same($0, line) }) { decisions.append(line) }
        }
        var followUps = written?.followUps ?? []
        for question in questions where question.answer == nil {
            followUps.append("Unanswered: \(question.row.text)")
        }
        let done = tasks.count { facts[$0.id]?.merged == true || facts[$0.id]?.done == true }
        let stacked = prs.count { $0.stackedOn != nil }
        let heedsOutcome = "\(done) of \(tasks.count) tasks merged, in merge order. The swarm opened \(prs.count { $0.pr != nil }) "
            + "PR\(prs.count { $0.pr != nil } == 1 ? "" : "s")" + (stacked > 0 ? ", \(stacked) stacked." : ".")
        return SwarmSummary(
            swarm: swarm.id, title: goal, outcome: written?.outcome ?? heedsOutcome, byLead: written?.outcome != nil,
            startedAt: start, endedAt: end, agentTime: use.agentTime, agents: Set(swarm.workers.map(\.owner)).count,
            versions: board.versions.count, dollars: use.dollars, tokens: use.tokens, prs: prs, lanes: lanes,
            episodes: episodes, questions: asked, decisions: decisions, followUps: followUps
        )
    }

    /// A task's stuck stretches: from each episode's first row to the row that cleared it (or `end`).
    static func stuckEpisodes(_ rows: [SwarmSteer], task: String, end: Date)
        -> [(start: Date, end: Date, why: String, how: String)]
    {
        var episodes: [(start: Date, end: Date, why: String, how: String)] = []
        var open: (start: Date, why: String, steps: [String])?
        for row in rows where row.kind == .stuck && row.ref == "task:\(task)" {
            switch row.step {
            case SwarmStuck.Step.clear.rawValue:
                if let current = open {
                    episodes.append((current.start, row.at, current.why, how(current.steps)))
                    open = nil
                }
            case SwarmStuck.Step.nudge.rawValue where open == nil:
                open = (row.at, row.reason ?? row.text, ["nudged to try another way"])
            default:
                open?.steps.append("asked for help")
            }
        }
        if let current = open { episodes.append((current.start, end, current.why, how(current.steps))) }
        return episodes
    }

    private static func how(_ steps: [String]) -> String {
        steps.joined(separator: ", then ").prefix(1).uppercased() + steps.joined(separator: ", then ").dropFirst()
            + "."
    }

    // MARK: Text

    /// Hours and minutes: `3 h 22 m`, `14 m`.
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) m" : "\(minutes) m"
    }

    /// The summary as markdown: for the ledger, History and the goal's page.
    public var markdown: String {
        var lines = ["## Swarm summary: \(title)", "", outcome, ""]
        lines.append(
            "\(Self.duration(elapsed)) elapsed · \(Self.duration(agentTime)) agent time · \(agents) agent"
                + "\(agents == 1 ? "" : "s") · \(versions) plan version\(versions == 1 ? "" : "s")"
                + (dollars > 0 ? " · \(AgentUsage.dollars(dollars))" : "")
        )
        if !prs.isEmpty {
            lines += ["", "### PRs, in merge order"]
            lines += prs.map { pr in
                "\(pr.order). \(pr.number) \(pr.title): " + (pr.pr.map { "#\($0) " } ?? "") + pr.state
                    + (pr.stackedOn.map { " · stacked on \($0)" } ?? "")
            }
        }
        if !episodes.isEmpty {
            lines += ["", "### What they ran into"]
            lines += episodes.map { "- \($0.kind.rawValue): \($0.title) (\($0.minutes) m). \($0.detail)" }
        }
        if !questions.isEmpty {
            lines += ["", "### Questions"]
            lines += questions.map { question in
                "- \(question.text) (\(question.from)) → " + (question.answer.map {
                    "\($0), by \(question.answeredBy ?? "?") in \(Self.duration(question.seconds ?? 0))"
                } ?? "unanswered")
            }
        }
        if !decisions.isEmpty { lines += ["", "### Decisions"] + decisions.map { "- \($0)" } }
        if !followUps.isEmpty { lines += ["", "### Follow-ups"] + followUps.map { "- \($0)" } }
        return lines.joined(separator: "\n")
    }

    /// Questions answered by each: `2 you · 2 controller · 2 peers`.
    public var answeredLine: String {
        let counts = Dictionary(grouping: questions.compactMap(\.answeredBy), by: { $0 }).mapValues(\.count)
        return ["you", "controller", "peer", "lead"].compactMap { who in
            counts[who].map { "\($0) \(who == "peer" && $0 != 1 ? "peers" : who)" }
        }.joined(separator: " · ")
    }

    /// The ledger's entry for the run: one per swarm, replaced when the lead rewrites it.
    public func ledger(repos: [String], pulls: [PullRef], lead: String, usage: AgentUsage?) -> LedgerEntry {
        LedgerEntry(
            id: "swarm:\(swarm)", title: "Swarm: \(title)", repos: repos, branch: "", agent: lead,
            startedAt: startedAt, endedAt: endedAt, outcome: "swarm done", pulls: pulls, agentTime: agentTime,
            usage: usage, summary: outcome, decisions: decisions, followUps: followUps,
            source: byLead ? .signOff : nil, trigger: "swarm done", summarizedAt: endedAt
        )
    }
}
