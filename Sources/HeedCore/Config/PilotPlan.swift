import Foundation

/// What heed would do next for a PR, from its effective settings and where it stands: the PR card's `next` line and
/// the `pilot.why` explainer. Pure: the app passes in the settings, the pipeline, the status and the session's agent.
public enum PilotPlan {
    /// The next round, or why there is none.
    public enum Step: Hashable, Sendable {
        /// A run of its own (a tab, worktree and branch): `run_in = "background"`.
        case background(Round)
        /// Typed into the session's agent once it is idle: `run_in = "session"`.
        case session(Round)
        /// GitHub's Copilot coding agent is asked on the PR (`copilot_conflicts`).
        case copilot(RunGoal)
        case paused(until: Date?)
        /// Out of rounds without a new approval.
        case stopped(rounds: Int)
        /// Get it green is off and get it merged is on: no rounds, and how merging goes.
        case merging(MergeMode)
        /// Nothing will be sent, and why.
        case nothing(String)
    }

    /// The shape of one round: what runs, with what, for how long, with how many extra instructions.
    public struct Round: Hashable, Sendable {
        public let goal: RunGoal
        /// The agent: the configured one, else the session's; nil when neither is known.
        public let agent: String?
        /// Nil: the agent's own default (always nil for a round typed into the session).
        public let model: String?
        public let timeout: TimeInterval
        /// Non-empty lines of `green_instructions`.
        public let instructions: Int
    }

    public static func next(
        settings: PilotSettings, pipeline: PullFeedback?, status: PilotStatus, sessionAgent: String?,
        now: Date = Date()
    ) -> Step {
        let effective = PullFeedback.effective(pipeline, settings)
        switch status {
        case let .closed(merged): return .nothing(merged ? "merged" : "closed")
        case .unwatched: return .nothing("not watched")
        case let .paused(until): return .paused(until: until)
        case let .stalled(rounds): return .stopped(rounds: rounds)
        case .stuck: return .nothing("no session to send to")
        default: break
        }
        guard effective.green != .off else {
            return effective.merge == .off ? .nothing("get it green is off") : .merging(effective.merge)
        }
        if let pipeline, pipeline.isPaused(now) {
            return .paused(until: pipeline.pausedForever ? nil : pipeline.pausedUntil)
        }
        if let pipeline, pipeline.rounds >= effective.maxRounds { return .stopped(rounds: effective.maxRounds) }
        let goal = Runs.goal(for: status) ?? .green
        if goal == .merged, settings.copilotConflicts { return .copilot(goal) }
        let instructions = instructionCount(settings.greenInstructions)
        if settings.runIn == .session {
            return .session(Round(
                goal: goal, agent: sessionAgent, model: nil, timeout: settings.runTimeout, instructions: instructions
            ))
        }
        let chosen = settings.runAgent(for: goal)
        return .background(Round(
            goal: goal, agent: chosen.agent ?? sessionAgent, model: chosen.model, timeout: settings.runTimeout,
            instructions: instructions
        ))
    }

    static func instructionCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isNewline).count { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// `1 instruction`, `2 instructions`; nil for none.
    static func instructionsText(_ count: Int) -> String? {
        count == 0 ? nil : "\(count) instruction\(count == 1 ? "" : "s")"
    }

    /// `codex gpt-5`, `claude`, `the session's agent`.
    static func agentText(_ round: Round) -> String {
        [round.agent ?? "the session's agent", round.model].compactMap(\.self).joined(separator: " ")
    }

    /// The PR card's line: `background run · codex gpt-5 · 30m · 1 instruction`, `typed into the session's claude`,
    /// `nothing: get it green is off`, `paused until 14:00`, `stopped after 3 rounds`.
    public static func text(_ step: Step, now: Date = Date(), calendar: Calendar = .current) -> String {
        switch step {
        case let .background(round):
            [
                round.goal == .merged ? "conflict run" : "background run", agentText(round),
                PilotDuration.text(round.timeout), instructionsText(round.instructions),
            ].compactMap(\.self).joined(separator: " · ")
        case let .session(round):
            [
                "typed into the session's \(round.agent ?? "agent")", instructionsText(round.instructions),
            ].compactMap(\.self).joined(separator: " · ")
        case let .copilot(goal):
            goal == .merged ? "Copilot is asked to resolve the conflicts" : "Copilot is asked on the PR"
        case let .paused(until):
            "paused " + pauseText(until, now: now, calendar: calendar)
        case let .stopped(rounds):
            "stopped after \(rounds) round\(rounds == 1 ? "" : "s")"
        case let .merging(mode):
            mode == .heed ? "no rounds (green off) · heed merges once its rules hold"
                : "no rounds (green off) · GitHub's auto-merge, once its requirements are met"
        case let .nothing(reason):
            "nothing: \(reason)"
        }
    }

    /// Get it green's progress on a PR, for its card: the round it is on and what it sent last. `log` is the PR's
    /// pilot events, newest first. Nil when get it green does nothing for it.
    /// `round 1 of 3 · last: sent 2 items to claude (round 1), 31m ago`, `round 0 of 3 · nothing sent yet`.
    public static func greenProgress(
        pipeline: PullFeedback?, settings: PilotSettings, log: [PilotEvent], now: Date = Date()
    ) -> String? {
        let effective = PullFeedback.effective(pipeline, settings)
        guard effective.watching, effective.green != .off else { return nil }
        let round = "round \(min(pipeline?.rounds ?? 0, effective.maxRounds)) of \(effective.maxRounds)"
        guard let sent = log.first(where: { $0.kind == .sent }) else { return "\(round) · nothing sent yet" }
        return "\(round) · last: \(sent.text), \(PilotDuration.text(now.timeIntervalSince(sent.at))) ago"
    }

    /// `until 14:00` the same day, `for 2d` beyond it, `until resumed`.
    static func pauseText(_ until: Date?, now: Date, calendar: Calendar) -> String {
        guard let until else { return "until resumed" }
        guard calendar.isDate(until, inSameDayAs: now) else {
            return "for \(PilotDuration.text(until.timeIntervalSince(now)))"
        }
        let parts = calendar.dateComponents([.hour, .minute], from: until)
        return String(format: "until %02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    // MARK: Sources

    /// One setting behind the plan, and where its value comes from.
    public struct Source: Hashable, Sendable, Identifiable {
        public var id: String { key }
        /// The key in config.toml.
        public let key: String
        public let value: String
        /// `default`, `org <name>`, `repo`, or `this PR` for a choice made on it by hand.
        public let origin: String

        public var isDefault: Bool { origin == "default" }
        /// `agent: codex (org acme)`.
        public var line: String { "\(key): \(value) (\(origin))" }
    }

    /// Every setting the explainer and the hover help name, with its value and source: the org and repo overrides
    /// from config.toml (`Overrides.effective`), and the PR's own `w`, `zg` and `zm` choices over them.
    public static func sources(for repo: Repo, pipeline: PullFeedback?, in config: HeedConfig) -> [String: Source] {
        let scope = OverrideScope.repo(repo)
        var result: [String: Source] = [:]
        for key in Overrides.keys(for: scope) {
            let (value, source) = Overrides.effective(key, at: scope, in: config)
            let origin = switch source {
            case .default: "default"
            case .org: "org \(repo.org)"
            case .repo: "repo"
            }
            result[key.id] = Source(key: key.id, value: value.display, origin: origin)
        }
        // `run_timeout` is set only under `[pilot]`.
        result["run_timeout"] = Source(
            key: "run_timeout", value: PilotDuration.text(config.pilot.defaults.runTimeout), origin: "default"
        )
        if let pipeline {
            if pipeline.watchSet {
                result["watch"] = Source(key: "watch", value: pipeline.watching ? "on" : "off", origin: "this PR")
            }
            if pipeline.greenSet {
                result["green"] = Source(key: "green", value: pipeline.autoFeed.configName, origin: "this PR")
            }
            if pipeline.mergeSet {
                result["merge"] = Source(key: "merge", value: pipeline.merge.configName, origin: "this PR")
            }
        }
        return result
    }

    /// The keys a step depends on, in the order the hover help lists them.
    public static func keys(for step: Step) -> [String] {
        switch step {
        case let .background(round):
            (round.goal == .merged ? ["run_in", "merge_agent", "merge_model", "agent", "model"]
                : ["run_in", "agent", "model"]) + ["run_timeout", "green_instructions"]
        case .session: ["run_in", "green_instructions"]
        case .copilot: ["copilot_conflicts"]
        case .paused: ["watch"]
        case .stopped: ["max_rounds"]
        case .merging: ["green", "merge"]
        case .nothing: ["watch", "green"]
        }
    }

    /// The PR card's hover help: each setting behind the step, with its source, one per line.
    public static func help(_ step: Step, sources: [String: Source]) -> String {
        keys(for: step).compactMap { sources[$0]?.line }.joined(separator: "\n")
    }

    // MARK: The explainer

    /// One row of the `pilot.why` explainer: a part of the pilot, its value, what that means here, and where it comes
    /// from.
    public struct Row: Hashable, Sendable, Identifiable {
        public enum Tone: Hashable, Sendable {
            /// On and doing something (green).
            case on
            /// Waiting on you (amber).
            case ask
            /// Something runs (blue).
            case busy
            case plain
            /// Off.
            case off
        }

        public var id: String { title }
        public let title: String
        public let value: String
        public let detail: String
        public let tone: Tone
        /// `default`, or the non-default sources joined (`org acme · repo`).
        public let origin: String

        public var isDefault: Bool { origin == "default" }
    }

    /// Watching, Get it green, A round, Conflicts and Get it merged, for a PR.
    public static func rows(
        settings: PilotSettings, pipeline: PullFeedback?, status: PilotStatus, sessionAgent: String?,
        sources: [String: Source], now: Date = Date()
    ) -> [Row] {
        let effective = PullFeedback.effective(pipeline, settings)
        func origin(_ keys: [String]) -> String {
            var seen: [String] = []
            for origin in keys.compactMap({ sources[$0]?.origin }) where origin != "default" && !seen.contains(origin) {
                seen.append(origin)
            }
            return seen.isEmpty ? "default" : seen.joined(separator: " · ")
        }
        var rows: [Row] = []
        rows.append(Row(
            title: "Watching", value: effective.watching ? "on" : "off",
            detail: effective.watching ? "it follows reviews and checks" : "nothing is fetched, sent or merged",
            tone: effective.watching ? .on : .off, origin: origin(["watch"])
        ))

        let queued = pipeline?.count(.queued) ?? 0, new = pipeline?.count(.new) ?? 0
        let rounds = "\(min(pipeline?.rounds ?? 0, effective.maxRounds)) of \(effective.maxRounds) rounds used"
        var green: String = switch effective.green {
        case .off: "what it finds is shown, nothing is sent"
        case .ask:
            queued > 0 ? "\(queued) item\(queued == 1 ? "" : "s") queued: they go when you send them"
                : new > 0 ? "\(new) new item\(new == 1 ? "" : "s"): queue what should go"
                : "items wait for you to queue and send them"
        case .auto:
            queued > 0 ? "\(queued) item\(queued == 1 ? "" : "s") queued: they go once the agent is idle"
                : "what it finds goes to the agent once it is idle"
        }
        let step = next(settings: settings, pipeline: pipeline, status: status, sessionAgent: sessionAgent, now: now)
        switch step {
        case let .paused(until): green = "paused " + pauseText(until, now: now, calendar: .current)
        case let .stopped(count): green = "stopped after \(count) rounds without a new approval"
        default: if effective.green != .off { green += " · \(rounds)" }
        }
        rows.append(Row(
            title: "Get it green", value: effective.green.configName, detail: green,
            tone: effective.green == .off ? .off : effective.green == .ask ? .ask : .on,
            origin: origin(["green", "max_rounds"])
        ))

        let instructions = instructionsText(instructionCount(settings.greenInstructions))
        let greenRound = Round(
            goal: .green, agent: settings.runAgent(for: .green).agent ?? sessionAgent,
            model: settings.runAgent(for: .green).model, timeout: settings.runTimeout,
            instructions: instructionCount(settings.greenInstructions)
        )
        if settings.runIn == .session {
            rows.append(Row(
                title: "A round", value: "the session's agent",
                detail: [
                    "typed into \(sessionAgent ?? "its agent") once it is idle and you have left it alone",
                    instructions.map { "\($0) added" },
                ].compactMap(\.self).joined(separator: ", "),
                tone: .busy, origin: origin(["run_in", "green_instructions"])
            ))
        } else {
            rows.append(Row(
                title: "A round", value: "background run",
                detail: [
                    "\(agentText(greenRound)) in its own worktree",
                    "\(PilotDuration.text(settings.runTimeout)) at most",
                    instructions.map { "\($0) added" },
                ].compactMap(\.self).joined(separator: ", "),
                tone: .busy, origin: origin(["run_in", "agent", "model", "run_timeout", "green_instructions"])
            ))
        }

        let conflicts: (value: String, keys: [String]) = if settings.copilotConflicts {
            ("Copilot", ["copilot_conflicts"])
        } else if settings.runIn == .session {
            ("the session's \(sessionAgent ?? "agent")", ["run_in"])
        } else {
            (agentText(Round(
                goal: .merged, agent: settings.runAgent(for: .merged).agent ?? sessionAgent,
                model: settings.runAgent(for: .merged).model, timeout: settings.runTimeout, instructions: 0
            )), ["merge_agent", "merge_model"])
        }
        let conflicted = if case .conflicted = status { true } else { false }
        rows.append(Row(
            title: "Conflicts", value: conflicts.value,
            detail: settings.copilotConflicts ? "Copilot's coding agent is asked on the PR to resolve them"
                : conflicted ? "the branch conflicts with its base now: this is the next round"
                : "if the base moves and the branch conflicts",
            tone: conflicted ? .busy : .plain, origin: origin(conflicts.keys)
        ))

        let merge = switch effective.merge {
        case .off: "heed leaves merging to you"
        case .auto: "GitHub's auto-merge: GitHub merges once its own requirements are met"
        case .heed: "heed merges once every rule below holds"
        }
        rows.append(Row(
            title: "Get it merged", value: effective.merge.configName, detail: merge,
            tone: effective.merge == .off ? .off : .on, origin: origin(["merge"])
        ))
        return rows
    }

    /// What holds a PR back, failures first, then what is still pending, then what passes: the green verdict, and
    /// with `merge = "heed"` heed's own merge rules after it (its "Green" summary left out, the rules above say it).
    public static func holds(_ green: GreenVerdict, merge: GreenVerdict? = nil) -> [GreenVerdict.Rule] {
        let rules = green.rules + (merge?.rules.filter { $0.name != "Green" } ?? [])
        func rank(_ rule: GreenVerdict.Rule) -> Int {
            switch rule.state {
            case .fail: 0
            case .wait: 1
            case .pass: 2
            }
        }
        return rules.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }
}
