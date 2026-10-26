import Foundation

/// Which evaluators walk, when, and which stay quiet. Evaluators are reviewers whose run is a walk; they share the
/// reviewers' budget and record, but walk on their own triggers: a new GOAL.md version, a merge, a change in their
/// area, a fix for one of their findings merging, and when you ask. Once at their bar they stay quiet unless you ask.
public enum EvaluationPlanner {
    /// The evaluators a goal needs that it has none for (`EvaluationLens.required`), as heed spawns them; `configs` are
    /// the goal's reviewers, including ones being spawned with these.
    public static func missing(profile: GoalProfile?, bars: [GoalLens: Double], configs: [ReviewerConfig])
        -> [ReviewerConfig]
    {
        let live = configs.filter { !$0.removed }
        let taken = Set(configs.map(\.id))
        return EvaluationLens.required(profile: profile, bars: bars).compactMap { lens in
            guard !live.contains(where: { $0.walk == lens }) else { return nil }
            var id = lens.reviewerID
            var number = 2
            while taken.contains(id) {
                id = "\(lens.reviewerID)-\(number)"
                number += 1
            }
            return ReviewerConfig(
                id: id, kind: lens.kind, evaluation: EvaluationLens.defaultWalk(of: lens.kind) == lens ? nil : lens
            )
        }
    }

    /// Who walks for `trigger`. An evaluator walks when it is live, not walking already, its walk is required, and it
    /// is under its bar (or has not walked); PRs opening or moving and the nightly sweep do not make it walk (a walk
    /// is long, and waits for a merge). You asking walks it anyway. Each walk takes one of the day's `limit` runs; one
    /// you asked for is never held back by the budget.
    public static func plan(
        trigger: ReviewTrigger, only: Set<String>? = nil, evaluators: [ReviewerState], bars: [GoalLens: Double],
        required: Set<EvaluationLens>, used: Int, limit: Int
    ) -> ReviewPlan {
        var plan = ReviewPlan()
        var left = max(limit - used, 0)
        for state in evaluators where !state.config.removed {
            let id = state.id
            guard let walk = state.config.walk else { continue }
            if let only, !only.contains(id) { continue }
            if state.running {
                plan.quiet[id] = "walking now"
                continue
            }
            guard required.contains(walk) else {
                plan.quiet[id] = "the goal's profile does not need \(walk.title)"
                continue
            }
            let manual = trigger == .manual
            if !manual {
                switch trigger {
                case .prOpened, .prUpdated, .nightly:
                    plan.quiet[id] = "walks wait for a merge, a change in their area or a new GOAL.md"
                    continue
                default: break
                }
                if state.config.policy == .manual {
                    plan.quiet[id] = "walks only when you ask"
                    continue
                }
                if !state.walks.isEmpty, let score = state.score?.value, score >= bars[walk.lens] ?? 0 {
                    plan.quiet[id] = "at its bar"
                    continue
                }
            }
            if manual {
                plan.run.append(id)
            } else if left > 0 {
                plan.run.append(id)
                left -= 1
            } else {
                plan.overBudget.append(id)
            }
        }
        return plan
    }
}

/// What makes an evaluator walk again on its own, besides a new GOAL.md version and a merge.
public enum EvaluationTriggers {
    /// Evaluators whose area a changed path touches (`EvaluationLens.touches`), each with the first such path.
    public static func areaChanged(evaluators: [ReviewerState], paths: [String]) -> [(id: String, path: String)] {
        evaluators.compactMap { state in
            guard !state.config.removed, let walk = state.config.walk,
                  let path = paths.sorted().first(where: walk.touches)
            else { return nil }
            return (state.id, path)
        }
    }

    /// The paths in `after` that were not in `before`: what changed since the last look.
    public static func newPaths(before: Set<String>?, after: Set<String>) -> [String] {
        guard let before else { return [] }
        return after.subtracting(before).sorted()
    }

    /// Evaluators with a finding whose item (made from a HIGH entry, or one you linked) has a PR that just merged, each
    /// with that PR: a re-walk to see whether the fix helped.
    public static func fixesMerged(_ quality: GoalQuality, items: [GoalItem], merged: Set<String>)
        -> [(id: String, ref: String)]
    {
        guard !merged.isEmpty else { return [] }
        return quality.live.compactMap { state in
            guard state.config.walk != nil else { return nil }
            for objection in state.objections where objection.state != .fixed {
                let marker = ReviewEvidence.marker(reviewer: state.id, objection: objection.id)
                guard let item = items.first(where: { $0.reason?.hasSuffix(marker) == true }),
                      let ref = item.linked(.pr).sorted().first(where: merged.contains)
                else { continue }
                return (state.id, ref)
            }
            return nil
        }
    }
}

/// What a walk clones: the goal's open PR at its head, else a repo of the goal at its default branch.
public enum WalkSource: Hashable, Sendable {
    case pull(PullRef)
    case defaultBranch(Repo)

    public var repo: Repo {
        switch self {
        case let .pull(ref): ref.repo
        case let .defaultBranch(repo): repo
        }
    }

    /// `acme/docs-toolkit#2841`, `acme/docs-toolkit`.
    public var text: String {
        switch self {
        case let .pull(ref): ref.description
        case let .defaultBranch(repo): repo.slug
        }
    }
}

/// A walk's run: a stranger in a fresh shallow clone (never your worktree; a temp folder removed after), told only the
/// steps, writing `evaluation.json`.
public enum EvaluationRun {
    /// A walk still going after this long is stopped.
    public static let timeout: TimeInterval = 45 * 60

    /// What a goal's walk clones: its first open PR, else the first repo its work is in, at its default branch.
    public static func source(pulls: [ReviewRun.Pull], repos: [Repo]) -> WalkSource? {
        if let pull = pulls.first(where: \.open) { return .pull(pull.ref) }
        return repos.first.map(WalkSource.defaultBranch)
    }

    /// The walk's folder: `<temp>/heed-walk-<goal>-<reviewer>-<run>`, new for every run.
    public static func folder(temp: String, goal: String, reviewer: String, run: String) -> String {
        let base = temp.hasSuffix("/") ? String(temp.dropLast()) : temp
        return "\(base)/heed-walk-\(goal)-\(reviewer)-\(run.prefix(8))"
    }

    /// The clone, inside the walk's folder, named as the repo is.
    public static func clonePath(folder: String, repo: Repo) -> String { "\(folder)/\(repo.name)" }

    /// Whether `path` is safe to walk in and remove: inside the temp folder, a walk's folder, and not inside (nor
    /// holding) any of `keep` (your clones and worktrees).
    public static func isDisposable(_ path: String, temp: String, keep: [String]) -> Bool {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        let base = URL(fileURLWithPath: temp).standardizedFileURL.path
        guard standard.hasPrefix(base + "/"), standard.contains("/heed-walk-") else { return false }
        return !keep.contains { kept in
            let other = URL(fileURLWithPath: kept).standardizedFileURL.path
            return standard == other || standard.hasPrefix(other + "/") || other.hasPrefix(standard + "/")
        }
    }

    /// The commands that make the clone: a shallow `gh repo clone`, then for a PR its head fetched shallow and checked
    /// out, and its push URL pointed nowhere so nothing in the walk can push.
    public static func cloneCommands(_ source: WalkSource, path: String) -> [[String]] {
        var commands = [["gh", "repo", "clone", source.repo.slug, path, "--", "--depth", "1", "--quiet"]]
        if case let .pull(ref) = source {
            commands.append([
                "git",
                "-C",
                path,
                "fetch",
                "--quiet",
                "--depth",
                "1",
                "origin",
                "pull/\(ref.number)/head",
            ])
            commands.append(["git", "-C", path, "checkout", "--quiet", "--detach", "FETCH_HEAD"])
        }
        commands.append(["git", "-C", path, "remote", "set-url", "--push", "origin", "no-push"])
        return commands
    }

    /// Where it writes its walk, in the clone.
    public static func reportPath(clone: String) -> String { "\(clone)/.heed/\(EvaluationWalk.fileName)" }

    public static func lastMessagePath(clone: String) -> String { "\(clone)/.heed/last-message.txt" }

    /// What keeps a walk from pushing: claude may edit (a stranger changes config, makes a change and rebuilds; the
    /// clone is thrown away) but not push or commit, and asks nobody (`dontAsk`); codex writes only inside the clone,
    /// with no network for its commands. Others: the disposable clone and its push URL are the guard.
    public static func restrictions(agent: String) -> [String] {
        switch agent {
        case "claude":
            [
                "--allowedTools", "Bash", "Read", "Grep", "Glob", "Edit", "Write",
                "--disallowedTools", "Bash(git push:*)", "Bash(git commit:*)", "Bash(gh:*)",
                "--permission-mode", "dontAsk",
            ]
        case "codex": ["--sandbox", "workspace-write"]
        default: []
        }
    }

    /// The headless command line of a walk, in the clone; nil for agents with no headless mode.
    public static func headless(agent: String, command: String, prompt: String, model: String?, clone: String)
        -> [String]?
    {
        let command = command.split(separator: " ").map(String.init)
        switch agent {
        case "claude":
            return command + ["-p", prompt] + restrictions(agent: agent) + (model.map { ["--model", $0] } ?? [])
        case "codex":
            return command + ["exec"] + restrictions(agent: agent)
                + ["-C", clone, "-o", lastMessagePath(clone: clone)] + (model.map { ["-m", $0] } ?? []) + [prompt]
        default:
            return nil
        }
    }

    /// The prompt: the stranger it plays, what it may use, the steps (from the draft), how to time them and how to
    /// write `evaluation.json`. Not the goal's GOAL.md: a stranger knows only the task. Findings from before are listed
    /// so that one met again is worded the same.
    public static func prompt(lens: EvaluationLens, steps: [String], clone: String, known: [Objection]) -> String {
        var lines = [
            "You are a stranger evaluating a project you have never seen. \(lens.persona)",
            "",
            "You are in a fresh clone of it at \(clone). You have no prior context: use only what a newcomer has, "
                + (lens == .docsWalk ? "the docs in the repository (start at the README), "
                    : "the README (and the pages it links), the CLI's own help and output, ")
                + "never the source code to work out how something works. Never push or commit; this clone is "
                + "removed when you are done.",
            "",
            "Walk these steps, in order, as a newcomer would (the walk is about \(lens.focus)):",
        ]
        lines += steps.enumerated().map { "\($0.offset + 1). \($0.element)" }
        lines += [
            "",
            "Time each step: run `date +%s` before and after it. For each, note how it went: ok, confusing (you "
                + "hesitated or guessed), stalled (you waited or went round in circles) or failed (you could not "
                + "finish it). If a step fails, say so and carry on with the next one where you can.",
            "",
            "Keep a friction log: every place you hesitated, waited or failed, with its severity (high: a newcomer "
                + "would give up or get it wrong; med: they would lose minutes; low: worth smoothing), the step, a "
                + "word or two on what it was about, what you found, and what would have helped.",
        ]
        let open = known.filter { $0.state != .fixed }
        if !open.isEmpty {
            lines += ["", "Friction from the walk before (word it the same if you meet it again):"]
            lines += open.map { "- [\($0.severity.rawValue)] \($0.text)" }
        }
        lines += [
            "",
            "When you are done, write the walk as JSON to \(reportPath(clone: clone)) (make the folder; use the shell, "
                + "e.g. a heredoc) and stop. The shape: {\"summary\": \"how it went, in a sentence or two\", "
                + "\"steps\": [{\"title\": \"the step\", \"outcome\": \"ok|confusing|stalled|failed\", \"seconds\": "
                + "<how long it took>, \"note\": \"what happened\"}], \"friction\": [{\"severity\": \"high|med|low\", "
                + "\"step\": <its number>, \"area\": \"a word or two\", \"finding\": \"one sentence\", "
                + "\"suggestion\": \"what would have helped\"}]}. End your reply with the same JSON.",
        ]
        return lines.joined(separator: "\n")
    }

    /// The walk a run left: its `evaluation.json`, else the JSON in its last message; else why there is none.
    public static func read(
        file: Data?, lastMessage: String?, lens: EvaluationLens, draftVersion: Int, measured: Double?, source: String
    ) -> (walk: EvaluationWalk?, failure: String?) {
        func parse(_ data: Data) -> EvaluationWalk? {
            EvaluationWalk.parse(data, lens: lens, draftVersion: draftVersion, measured: measured, source: source)
        }
        if let file, let walk = parse(file) { return (walk, nil) }
        if let lastMessage, let json = LLMDialect.jsonObject(in: lastMessage), let walk = parse(json) {
            return (walk, nil)
        }
        return (nil, file == nil ? "it wrote no walk" : "its evaluation.json is not a walk")
    }
}

/// Walks in the goal's shared model: each walk is evidence (DX walks fill the matrix's DX column, UX walks are `ux`
/// evidence) with the evaluator's score, on the items linked to the PR it walked, else on the goal.
public enum EvaluationEvidence {
    public static func of(
        evaluator: ReviewerState, bar: Double?, goal: String, items: [GoalItem], at: Date
    ) -> [GoalEvidence] {
        guard let walk = evaluator.walks.last, evaluator.config.walk != nil, let score = evaluator.score,
              evaluator.lastReview?.report?.walk != nil
        else { return [] }
        let state: GoalEvidence.State = evaluator.open.contains { $0.severity == .high } ? .issue
            : score.value >= (bar ?? 0) ? .done : .inProgress
        let walked = items.filter { $0.linked(.pr).contains(walk.source) }
        let text = "\(evaluator.config.title) \(GoalBarTable.number(score.value))"
            + (bar.map { " (bar \(GoalBarTable.number($0)))" } ?? "")
            + ": \(GoalScore.count(walk.steps.count, "step", plural: "steps")), \(EvaluationWalk.span(walk.seconds))"
        let targets: [String?] = walked.isEmpty ? [nil] : walked.map(\.id)
        return targets.map { item in
            GoalEvidence(
                goal: goal, item: item, kind: walk.lens.evidence, state: state, at: at,
                source: source(evaluator), text: text, ref: "review:\(evaluator.id)",
                score: score.value
            )
        }
    }

    /// Who evidence says it is from: an evaluator's walk title, else the reviewer kind's.
    public static func source(_ reviewer: ReviewerState) -> String {
        (reviewer.config.walk?.evaluatorTitle ?? reviewer.config.kind.title).lowercased()
    }

    /// The evidence kind a reviewer's findings leave on their items: a walk's, else its lens's matrix column.
    public static func kind(_ reviewer: ReviewerState) -> GoalEvidence.Kind? {
        reviewer.config.walk?.evidence ?? reviewer.config.kind.lens.flatMap(ReviewEvidence.stage)?.evidence
    }
}
