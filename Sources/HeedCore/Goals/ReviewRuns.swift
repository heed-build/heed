import Foundation

/// Why reviewers would look again.
public enum ReviewTrigger: Hashable, Sendable, Codable {
    case prOpened(String)
    case prUpdated(String)
    case prMerged(String)
    /// A new GOAL.md version.
    case goalVersion(Int)
    case nightly
    /// You pressed re-check.
    case manual
    /// An agent asked (`heed goal review request`): like a change, within the day's budget.
    case asked(String)
    /// A persona the goal needs now that nobody with its view has looked: spawned as a reviewer on its own.
    case personaGap(String)

    public var text: String {
        switch self {
        case let .prOpened(ref): "after \(ref) opened"
        case let .prUpdated(ref): "after \(ref) changed"
        case let .prMerged(ref): "after \(ref) merged"
        case let .goalVersion(number): "after GOAL.md v\(number)"
        case .nightly: "nightly"
        case .manual: "you asked"
        case let .asked(who): "\(who) asked"
        case let .personaGap(name): "a gap: nobody has looked as \(name)"
        }
    }

    /// The triggers from a goal's PRs between two looks: `before` and `after` map `org/repo#n` to its head and state
    /// (`open`, `merged`, `closed`). A PR new to the goal opened, a head that moved changed, a state that became merged
    /// merged.
    public static func from(
        before: [String: (head: String?, state: String)], after: [String: (head: String?, state: String)]
    ) -> [ReviewTrigger] {
        after.keys.sorted().compactMap { ref in
            let now = after[ref]!
            guard let was = before[ref] else { return now.state == "open" ? .prOpened(ref) : nil }
            if now.state == "merged", was.state != "merged" { return .prMerged(ref) }
            if now.state == "open", now.head != nil, now.head != was.head { return .prUpdated(ref) }
            return nil
        }
    }
}

/// Which reviewers run for a trigger, which wait for budget, and which stay quiet, and why.
public struct ReviewPlan: Hashable, Sendable {
    public var run: [String]
    /// Due, but the day's budget is spent: an Attention ask.
    public var overBudget: [String]
    /// reviewer → why it does not run.
    public var quiet: [String: String]

    public init(run: [String] = [], overBudget: [String] = [], quiet: [String: String] = [:]) {
        self.run = run
        self.overBudget = overBudget
        self.quiet = quiet
    }
}

public enum ReviewPlanner {
    /// The reviewers heed spawns on its own: one per required lens that has none. Custom reviewers are yours.
    public static func missing(bars: [GoalLens: Double], reviewers: [ReviewerState]) -> [ReviewerKind] {
        bars.keys.sorted().compactMap { lens in
            reviewers.contains { $0.config.kind.lens == lens } ? nil : ReviewerKind.of(lens)
        }
    }

    /// Runs started on `day` (the calendar's day of `now`).
    public static func used(_ runs: [Date], now: Date, calendar: Calendar = .current) -> Int {
        runs.count { calendar.isDate($0, inSameDayAs: now) }
    }

    /// Who runs for `trigger`. A reviewer runs when it is live, not running, its lens is required (custom ones always
    /// are), its policy takes the trigger, and it is under its bar or there is new evidence since its last review
    /// (`basis` moved); a manual re-check runs it anyway. Each run takes one of the day's `limit` runs; a manual one
    /// is never held back by the budget but still counts.
    public static func plan(
        trigger: ReviewTrigger, only: Set<String>? = nil, reviewers: [ReviewerState], bars: [GoalLens: Double],
        basis: ReviewBasis, used: Int, limit: Int
    ) -> ReviewPlan {
        var plan = ReviewPlan()
        var left = max(limit - used, 0)
        for state in reviewers where !state.config.removed {
            let id = state.id
            if let only, !only.contains(id) { continue }
            if state.running {
                plan.quiet[id] = "running now"
                continue
            }
            let bar = state.config.kind.lens.flatMap { bars[$0] }
            if state.config.kind != .custom, bar == nil {
                plan.quiet[id] = "its lens is not required for this goal"
                continue
            }
            let manual = trigger == .manual
            if !manual {
                switch (state.config.policy, trigger) {
                case (.manual, _):
                    plan.quiet[id] = "re-checks only when you ask"
                    continue
                case (.nightly, .nightly), (.onChange, _): break
                case (.nightly, _):
                    plan.quiet[id] = "re-checks nightly"
                    continue
                }
                let newEvidence = state.lastReview?.basis != basis
                if let score = state.score?.value, score >= (bar ?? 0), !newEvidence {
                    plan.quiet[id] = "at its bar, nothing new since"
                    continue
                }
                if state.lastReview != nil, !newEvidence {
                    plan.quiet[id] = "nothing new since its last review"
                    continue
                }
            }
            // A plan is all manual or all automatic: a manual one never waits, and its run is counted next time.
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

    /// Whether the nightly sweep is due: it last ran on an earlier day and it is past `hour` now.
    public static func nightlyDue(last: Date?, now: Date, hour: Int = 3, calendar: Calendar = .current) -> Bool {
        guard calendar.component(.hour, from: now) >= hour else { return false }
        guard let last else { return true }
        return !calendar.isDate(last, inSameDayAs: now)
    }
}

/// What a reviewer run is told, and how it is kept from changing anything.
public enum ReviewRun {
    /// Its branch: `heed/review/<goal>-<reviewer>`; the sweep removes it like other run branches.
    public static func branch(goal: String, reviewer: String) -> String { "\(Runs.prefix)review/\(goal)-\(reviewer)" }

    public static func isReviewBranch(_ name: String) -> Bool { name.hasPrefix(Runs.prefix + "review/") }

    /// `<root>/heed/<repo>/review-<goal>-<reviewer>`.
    public static func worktreePath(root: String, repo: Repo, goal: String, reviewer: String) -> String {
        "\(root)/heed/\(repo.name)/review-\(goal)-\(reviewer)"
    }

    /// A reviewer run still working after this long is stopped.
    public static let timeout: TimeInterval = 30 * 60

    /// Where it writes its review, in its worktree.
    public static func reportPath(worktree: String) -> String { "\(worktree)/.heed/\(ReviewReport.fileName)" }

    /// The arguments that keep an agent from changing the work, where its CLI has them (both checked against the
    /// installed CLIs' `--help`):
    /// - claude: its read tools and Bash allowed, `--disallowedTools` for its edit tools and for git commit and push
    ///   through Bash (a deny wins over the allow), and `--permission-mode dontAsk`: nobody is there to answer, so
    ///   anything else is refused rather than asked. Bash stays, for tests and benchmarks and to write the review;
    ///   the disposable worktree catches what a shell could still change. The mode also ends the variadic tool lists,
    ///   so the prompt after them stays the prompt.
    /// - codex: `--sandbox workspace-write`, which keeps writes inside the worktree and has no network, so it cannot
    ///   push. Not `read-only`: that would keep it from writing its review.
    /// - others: none; the disposable worktree (removed when the run ends, never pushed) is the guard.
    public static func restrictions(agent: String) -> [String] {
        switch agent {
        case "claude":
            [
                "--allowedTools",
                "Bash",
                "Read",
                "Grep",
                "Glob",
                "--disallowedTools",
                "Edit",
                "Write",
                "NotebookEdit",
                "MultiEdit",
                "Bash(git push:*)",
                "Bash(git commit:*)",
                "--permission-mode",
                "dontAsk",
            ]
        case "codex": ["--sandbox", "workspace-write"]
        default: []
        }
    }

    /// The prompt: who it is, the goal, its bar, what changed, and how to write `review.json`.
    public static func prompt(
        config: ReviewerConfig, goalTitle: String, doc: String, bar: Double?, changed: [String], worktree: String,
        known: [Objection]
    ) -> String {
        var lines: [String] = []
        if let persona = config.persona {
            // A persona reviews as itself: who it is comes first, the instructions are its brief.
            lines.append("You review the goal \"\(goalTitle)\" as \(persona), the expert described below. Look at the "
                + "work as that expert would: what it gets wrong, misses or should ask.")
        } else {
            lines.append(
                "You are the \(config.kind.title.lowercased()) for the goal \"\(goalTitle)\". \(config.kind.brief)"
            )
        }
        if let instructions = config.instructions, !instructions.isEmpty {
            lines += ["", config.persona == nil ? "Instructions:" : "Who you are:", instructions]
        }
        lines += [
            "",
            "You are in a worktree of your own at the goal's work. Read, run tests and benchmarks, but never edit "
                + "files, commit or push: this worktree is removed when you are done.",
        ]
        if let bar {
            lines.append("The bar for this goal is \(GoalBarTable.number(bar)) out of 10: object to what keeps the "
                + "work under it, not to everything that could be better.")
        }
        if !changed.isEmpty { lines += ["", "What changed since the last review:"] + changed.map { "- " + $0 } }
        let open = known.filter { $0.state != .fixed }
        if !open.isEmpty {
            lines += ["", "Objections from before (say them again, in the same words, if they still hold):"]
            lines += open
                .map { "- [\($0.severity.rawValue)] \($0.text)" + ($0.state == .acceptedRisk ? " (accepted)" : "") }
        }
        lines += ["", "The goal (GOAL.md):", "", doc, ""]
        lines.append(
            "When you are done, write your review as JSON to \(reportPath(worktree: worktree)) (make the folder; use "
                + "the shell, e.g. a heredoc) and stop. The shape: {\"summary\": \"how happy you are and why, in a "
                + "sentence or two\", \"objections\": [{\"severity\": \"high|med|low\", \"text\": \"one sentence\", "
                + "\"evidence\": \"what shows it\", \"file\": \"path\"}], \"ran\": [\"commands you ran\"], "
                + "\"files\": <how many files you read>}. high: it must change before the goal is done; med: it "
                + "should; low: worth knowing. End your reply with the same JSON."
        )
        return lines.joined(separator: "\n")
    }

    /// Why a run left no review, from what it left: no file, or a file that is not a review.
    public static func read(_ data: Data?) -> (report: ReviewReport?, failure: String?) {
        guard let data else { return (nil, "it wrote no review") }
        guard let report = ReviewReport.parse(data) else { return (nil, "its review.json is not a review") }
        return (report, nil)
    }
}

/// Where a reviewer runs: a clone to start its worktree from, the branch, and the session whose tab shows it (nil:
/// it runs headless, with no session needed).
public struct ReviewTarget: Hashable, Sendable {
    public var record: RepoRecord
    public var branch: String
    public var repo: Repo
    public var host: String?

    public init(record: RepoRecord, branch: String, repo: Repo, host: String? = nil) {
        self.record = record
        self.branch = branch
        self.repo = repo
        self.host = host
    }
}

public enum ReviewPlace: Hashable, Sendable {
    case target(ReviewTarget)
    /// The work is in this repo, but there is no clone of it on this Mac to start from: an Attention note.
    case noClone(Repo)
    /// Nothing to look at yet: no PR and no branch.
    case nothing
}

public extension ReviewRun {
    /// A PR of the goal, as the place picks from.
    struct Pull: Hashable, Sendable {
        public var ref: PullRef
        public var headBranch: String?
        public var open: Bool

        public init(ref: PullRef, headBranch: String?, open: Bool) {
            self.ref = ref
            self.headBranch = headBranch
            self.open = open
        }
    }

    /// Where a goal's reviewer runs, with or without a session open:
    /// 1. the goal's open PR, at its head branch, from the worktree a run would start beside or the repo's clone on
    ///    this Mac (the session's machine when one on the goal is open);
    /// 2. a branch of a worktree an open session on the goal owns;
    /// 3. a branch the goal's work was on (its sessions' ledger entries, closed ones too), from this Mac's clone.
    /// An open session on the goal in the same place hosts it in a tab; otherwise it runs headless. `noClone` when
    /// the work is somewhere this Mac has no clone of.
    static func place(
        pulls: [Pull], sessions: [Session], worktrees: [Worktree], repos: [RepoRecord],
        branches: [(repo: Repo, branch: String)]
    ) -> ReviewPlace {
        func record(of worktree: Worktree) -> RepoRecord {
            repos.first { $0.repo == worktree.repo && $0.location == worktree.location }
                ?? RepoRecord(repo: worktree.repo, path: worktree.path, location: worktree.location)
        }
        func host(for record: RepoRecord, preferring session: Session?) -> String? {
            let candidates = (session.map { [$0] } ?? []) + sessions
            return candidates.first { $0.location == record.location }?.id
        }
        var missing: Repo?
        for pull in pulls where pull.open {
            guard let head = pull.headBranch else { continue }
            let session = sessions.first { $0.trackedPRs.contains(pull.ref) } ?? sessions.first
            let location = session?.location ?? .local
            let owned = session.map { session in worktrees.filter { session.owns($0) } } ?? []
            let base = Runs.baseWorktree(
                for: pull.ref, headBranch: head, owned: owned, all: worktrees.filter { $0.location == location }
            )
            let here = repos.filter { $0.location == location }
            // The session's machine first; else this Mac's clone, headless.
            guard let found = base.map(record(of:)) ?? Runs.clone(for: pull.ref, in: here, at: location)
                ?? Runs.clone(for: pull.ref, in: repos.filter(\.location.isLocal), at: .local)
            else {
                missing = missing ?? pull.ref.repo
                continue
            }
            return .target(ReviewTarget(
                record: found, branch: head, repo: pull.ref.repo, host: host(for: found, preferring: session)
            ))
        }
        for session in sessions {
            guard let worktree = worktrees.first(where: { session.owns($0) && $0.branch != nil }),
                  let branch = worktree.branch
            else { continue }
            return .target(ReviewTarget(
                record: record(of: worktree),
                branch: branch,
                repo: worktree.repo,
                host: session.id
            ))
        }
        for (repo, branch) in branches where !branch.isEmpty {
            guard let found = repos.first(where: { $0.repo == repo && $0.location.isLocal }) else {
                missing = missing ?? repo
                continue
            }
            return .target(ReviewTarget(record: found, branch: branch, repo: repo))
        }
        return missing.map(ReviewPlace.noClone) ?? .nothing
    }

    /// Where a headless run's last message goes.
    static func lastMessagePath(worktree: String) -> String { "\(worktree)/.heed/last-message.txt" }

    /// The command line of a headless reviewer (no tab, no session): claude `-p` with its tools limited and no one
    /// to ask (`dontAsk`), codex `exec` in its sandbox with its last message to a file. Nil for agents with no such
    /// mode: they need a session's tab. The first word is the executable, then the command's own fixed arguments.
    static func headless(agent: String, command: String, prompt: String, model: String?, worktree: String)
        -> [String]?
    {
        let command = command.split(separator: " ").map(String.init)
        switch agent {
        case "claude":
            return command + ["-p", prompt] + restrictions(agent: agent) + (model.map { ["--model", $0] } ?? [])
        case "codex":
            return command + ["exec"] + restrictions(agent: agent) + [
                "-C",
                worktree,
                "-o",
                lastMessagePath(worktree: worktree),
            ]
                + (model.map { ["-m", $0] } ?? []) + [prompt]
        default:
            return nil
        }
    }

    /// The review a run left: its `review.json`, else the JSON in its last message (headless runs end with it).
    static func read(file: Data?, lastMessage: String?) -> (report: ReviewReport?, failure: String?) {
        if let file, let report = ReviewReport.parse(file) { return (report, nil) }
        if let lastMessage, let json = LLMDialect.jsonObject(in: lastMessage), let report = ReviewReport.parse(json) {
            return (report, nil)
        }
        return read(file)
    }
}
