import Foundation

/// The fake world's swarm runs, on `GoalFixtures`' goals: the diagrams goal's lead has drafted a plan (v2) and asks two
/// things; the anchors goal's swarm has a plan you approved (v3), whose tasks are items the goal had, with their owners
/// and order. Invented, as every fixture is.
public enum SwarmFixtures {
    public static let diagrams = "sequence-diagrams-read-cleanly"
    public static let anchors = "anchors-survive-page-moves"

    public static func all(now: Date = Clock.now) -> [SwarmFixture] {
        let base = now.timeIntervalSince1970.rounded(.down)
        func ago(_ hours: Double) -> Date { Date(timeIntervalSince1970: base - hours * 3600) }
        var fixtures = [drafting(ago), approved(ago)]
        // Row ids as the store gives them: one sequence across runs, in the order they are laid down.
        var next: Int64 = 1
        for index in fixtures.indices {
            for row in fixtures[index].steering.indices {
                fixtures[index].steering[row].id = next
                next += 1
            }
            // An answer points at its question by id, which is only known now.
            fixtures[index].steering = fixtures[index].steering.map { row in
                var row = row
                if let about = row.about, about < 0 {
                    row.about = fixtures[index].steering[Int(-about) - 1].id
                }
                return row
            }
        }
        return fixtures
    }

    /// The boards the plan pane draws before the store answers, by swarm id.
    public static func boards(_ fixtures: [SwarmFixture]) -> [String: SwarmBoard] {
        Dictionary(uniqueKeysWithValues: fixtures.map { fixture in
            (fixture.swarm.id, SwarmBoard(
                swarm: fixture.swarm, versions: fixture.versions.sorted { $0.number > $1.number },
                steering: fixture.steering
            ))
        })
    }

    /// The anchors goal's items with the fields its approved plan gave them.
    public static func planned(_ items: [GoalItem]) -> [GoalItem] {
        guard let plan = approved({ _ in Date() }).versions.last?.tasks else { return items }
        let byID = Dictionary(uniqueKeysWithValues: plan.map { ($0.id, $0) })
        return items.map { item in
            guard let task = byID[item.id] else { return item }
            var item = item
            item.phase = task.phase
            item.owner = task.owner
            item.estimate = task.estimate
            item.after = task.after
            item.doneWhen = task.doneWhen
            return item
        }
    }

    /// The anchors goal's run once its workers are going: as shots and previews load it over the approved one.
    public enum Running: Sendable {
        /// Two workers at work, both stacked on 1.1's open PR; 1.2 merged and done.
        case running
        /// The same, paused at its 4 h limit, asking you for more.
        case pausedAtLimit
        /// Landing: every task has its PR; 1.1's is green and first to merge, the two stacked on it held after it.
        case landing
        /// Done: 1.1 merged, its two children moved to main and merged after it.
        case done
        /// Running, with its steering: questions, answers, an overrule, messages and notes (`steering(now:)`).
        case steering
        /// The steering world, watched: 2.2 is stuck on the same error, heed nudged it and asked on its behalf
        /// (`watch(now:)`), and every worker has its activity (`activity(now:)`).
        case watch
        /// Done, with what its end-of-build summary is made of: a stuck episode, questions and who answered them,
        /// and the lead's own summary (`summaryRows(now:)`).
        case summary
        /// The watched world with 2.1's worker on @devbox: its worktree there, its agent in zmx.
        case remote
    }

    /// The host the remote world's worker runs on, and its task.
    public static let remoteHost = "devbox"
    public static let remoteTask = "\(anchors)/sample-site"

    /// What a running fixture lays over the approved run: the run as it is now, the steering rows that came after
    /// approval (no ids yet; `about` and `steer:` refs below zero count back into `steering`, 1-based, until
    /// `SwarmFixtures.number` gives them ids), the evidence its workers left, and the PRs they opened.
    public struct RunningWorld: Sendable {
        public var swarm: GoalSwarm
        public var steering: [SwarmSteer]
        public var evidence: [GoalEvidence]
        public var pulls: [PullRequest]
        /// The pilot's details for its PRs, as if fetched.
        public var details: [PullDetail] = []
        /// Feedback on its PRs (a rebase after a retarget), by `PullRef.description`.
        public var feedback: [String: [FeedbackItem]] = [:]
    }

    /// The live workers' agents, by task, as their hooks would say.
    public static let workerStates: [String: AgentState] = ["\(anchors)/validator-speed": .asking]

    public static func running(_ variant: Running, now: Date = Clock.now) -> RunningWorld {
        if variant == .landing || variant == .done || variant == .summary { return landed(variant, now: now) }
        if variant == .remote {
            var world = running(.watch, now: now)
            if let index = world.swarm.workers.lastIndex(where: { $0.task == remoteTask }) {
                world.swarm.workers[index].machine = remoteHost
                world.swarm.workers[index].worktree = "/home/you/code/wt/heed/docs-toolkit/swarm-\(anchors)-sample-site"
            }
            return world
        }
        let base = now.timeIntervalSince1970.rounded(.down)
        func ago(_ hours: Double) -> Date { Date(timeIntervalSince1970: base - hours * 3600) }
        let goal = anchors
        var swarm = approved(ago).swarm
        let toolkit = "acme/docs-toolkit"
        func branch(_ slug: String) -> String { SwarmWork.branch(goal: goal, slug: slug) }
        func worker(
            _ slug: String, _ owner: GoalItem.Owner, from base: String, stackedOn: String? = nil, started: Double,
            ended: Double? = nil, cost: Double? = nil
        ) -> SwarmWorker {
            SwarmWorker(
                id: "fixture-\(slug)", task: "\(goal)/\(slug)", owner: owner, host: "s2", repo: toolkit,
                branch: branch(slug), base: base, stackedOn: stackedOn.map { "\(goal)/\($0)" },
                worktree: "/Users/you/code/wt/heed/docs-toolkit/swarm-\(goal)-\(slug)", startedAt: ago(started),
                endedAt: ended.map(ago), outcome: ended == nil ? nil : .turnOver, costUSD: cost
            )
        }
        let claude = GoalItem.Owner(agent: "claude")
        let paused = variant == .pausedAtLimit
        swarm.status = paused ? .paused : .running
        swarm.held = paused ? .hours : nil
        swarm.runningAt = ago(paused ? 4.05 : 3.2)
        swarm.workers = [
            worker("heading-ids", claude, from: "main", started: 3.2, ended: 2.6, cost: 2.4),
            worker(
                "assembly-redirects",
                GoalItem.Owner(agent: "codex"),
                from: "main",
                started: 3.2,
                ended: 2.2,
                cost: 1.9
            ),
            worker(
                "validator-speed", GoalItem.Owner(agent: "claude", model: "opus"), from: branch("heading-ids"),
                stackedOn: "heading-ids", started: 0.87
            ),
            worker("sample-site", claude, from: branch("heading-ids"), stackedOn: "heading-ids", started: 0.3),
        ]
        let id = swarm.id
        func work(_ hours: Double, _ slug: String, _ text: String) -> SwarmSteer {
            SwarmSteer(
                swarm: id, goal: goal, at: ago(hours), actor: .heed, kind: .work, text: text,
                ref: "task:\(goal)/\(slug)"
            )
        }
        let stacked = "stacked on 1.1's PR"
        var steering = [
            steer(id, goal, ago(3.2), .heed, .start, "Running: workers start on plan v3"),
            work(3.2, "heading-ids", "1.1 Anchor ids from heading text: claude from main"),
            work(3.2, "assembly-redirects", "1.2 Redirects for moved assemblies: codex from main"),
            work(2.6, "heading-ids", "claude on heading-ids ended: its turn is over"),
            work(2.2, "assembly-redirects", "codex on assembly-redirects ended: its turn is over"),
            work(0.87, "validator-speed", "2.2 Validator speed on a 10k-page site: claude · opus \(stacked)"),
            work(0.3, "sample-site", "2.1 Sample site with moved pages: claude \(stacked)"),
        ]
        if variant == .steering || variant == .watch {
            // Its back references count from the start of the world's rows, not of its own.
            let before = Int64(steering.count)
            steering += Self.steering(now: now).map { row in
                var row = row
                if let about = row.about, about < 0 { row.about = about - before }
                if let ref = row.ref, ref.hasPrefix("steer:"), let value = Int64(ref.dropFirst(6)), value < 0 {
                    row.ref = "steer:\(value - before)"
                }
                return row
            }
        }
        if variant == .watch {
            let before = Int64(steering.count)
            steering += Self.watch(now: now).map { row in
                var row = row
                if let about = row.about, about < 0 { row.about = about - before }
                return row
            }
            steering = Self.byTime(steering)
        }
        if variant == .pausedAtLimit {
            steering.append(steer(
                id, goal, ago(0.05), .heed, .limit, "Paused at its 4 h limit",
                reason: "nothing more starts until you raise it"
            ))
        }
        func entry(
            _ slug: String, _ kind: GoalEvidence.Kind, _ text: String, state: GoalEvidence.State = .done,
            source: String, ref: String? = nil, hours: Double
        ) -> GoalEvidence {
            GoalEvidence(
                goal: goal, item: "\(goal)/\(slug)", kind: kind, state: state, at: ago(hours), source: source,
                text: text, ref: ref
            )
        }
        let evidence = [
            entry("heading-ids", .pr, "#412 open · CI ok", source: "#412", ref: "\(toolkit)#412", hours: 2.6),
            entry(
                "heading-ids", .criterion, "two headings with the same text get distinct ids",
                source: "swarm worker on heading-ids", ref: "swift test --filter HeadingIds", hours: 2.6
            ),
            entry(
                "assembly-redirects", .criterion, "a moved assembly keeps its inbound anchors",
                source: "swarm worker on assembly-redirects", ref: "the sample's assembly links resolve", hours: 2.2
            ),
            entry("assembly-redirects", .pr, "#409 merged", source: "#409", ref: "\(toolkit)#409", hours: 1),
            entry("assembly-redirects", .merged, "#409 merged", source: "#409", ref: "\(toolkit)#409", hours: 1),
            entry(
                "validator-speed", .built, "claude · opus works on it in \(branch("validator-speed"))",
                state: .inProgress, source: "swarm 1", hours: 0.87
            ),
            entry(
                "sample-site", .built, "claude works on it in \(branch("sample-site"))", state: .inProgress,
                source: "swarm 1", hours: 0.3
            ),
        ]
        func pull(_ number: Int, _ slug: String, _ title: String, _ state: PullRequest.State) -> PullRequest {
            PullRequest(
                ref: PullRef(repo: Repo(org: "acme", name: "docs-toolkit"), number: number), title: title,
                url: "https://github.com/\(toolkit)/pull/\(number)", state: state, isDraft: false,
                headBranch: branch(slug), review: nil, checks: CheckSummary(passed: 6), unresolvedThreads: 0,
                updatedAt: ago(1)
            )
        }
        return RunningWorld(swarm: swarm, steering: steering, evidence: evidence, pulls: [
            pull(412, "heading-ids", "Anchor ids from heading text", .open),
            pull(409, "assembly-redirects", "Redirects for moved assemblies", .merged),
        ])
    }

    static func steer(
        _ swarm: String, _ goal: String, _ at: Date, _ actor: SwarmSteer.Actor, _ kind: SwarmSteer.Kind,
        _ text: String, reason: String? = nil, state: SwarmSteer.State = .applied, about: Int64? = nil,
        version: Int? = nil, options: [String] = []
    ) -> SwarmSteer {
        SwarmSteer(
            swarm: swarm, goal: goal, at: at, actor: actor, kind: kind, text: text, reason: reason, state: state,
            about: about, version: version, options: options
        )
    }

    /// Planning: the lead's second draft, two questions open.
    private static func drafting(_ ago: (Double) -> Date) -> SwarmFixture {
        let goal = diagrams
        let id = "\(goal)/swarm-1"
        func task(
            _ slug: String, _ title: String, _ phase: String, _ owner: String, model: String? = nil, _ minutes: Int,
            after: [String] = [], done: [String]
        ) -> SwarmTask {
            SwarmTask(
                id: "\(goal)/\(slug)", title: title, phase: phase, owner: GoalItem.Owner(agent: owner, model: model),
                estimate: minutes, after: after.map { "\(goal)/\($0)" }, doneWhen: done
            )
        }
        let measure = task(
            "arrowhead-offsets", "Arrowhead offsets per zoom level", "Measure", "claude", 20,
            done: ["a table of offsets from 50% to 400% zoom"]
        )
        let snap = task(
            "snap-arrowheads", "Snap arrowheads to the lifeline", "Fix", "codex", 45, after: ["arrowhead-offsets"],
            done: ["arrowheads meet the lifeline at every zoom in the sample"]
        )
        let wrap = task(
            "wrap-labels", "Wrap long labels", "Fix", "claude", 35, done: [
                "labels over 40 characters wrap",
                "no label overlaps an arrow",
            ]
        )
        let golden = task(
            "golden-images", "Golden images at three zooms", "Prove", "claude", model: "haiku", 30,
            after: ["snap-arrowheads", "wrap-labels"], done: ["golden images pass in CI"]
        )
        let docs = task(
            "wrapping-docs", "Docs: how labels wrap", "Prove", "codex", 15, after: ["wrap-labels"],
            done: ["the docs page shows a wrapped label"]
        )
        var firstWrap = wrap
        firstWrap.owner = GoalItem.Owner(agent: "codex")
        let v1 = [measure, snap, firstWrap, golden]
        let v2 = [measure, snap, wrap, golden, docs]
        let settings = SwarmSettings(
            repos: ["globex/markgraph"], lead: GoalItem.Owner(agent: "claude", model: "opus"),
            workers: [SwarmSettings.Worker(agent: "claude", count: 2), SwarmSettings.Worker(agent: "codex")],
            limits: SwarmSettings.Limits(agents: 3, hours: 3, dollars: 30)
        )
        let swarm = GoalSwarm(id: id, goal: goal, number: 1, settings: settings, plan: 2, startedAt: ago(3))
        return SwarmFixture(swarm: swarm, versions: [
            SwarmPlanVersion(
                swarm: id, goal: goal, number: 1, at: ago(2.6), author: .lead, note: "draft from the lead", tasks: v1
            ),
            SwarmPlanVersion(
                swarm: id, goal: goal, number: 2, at: ago(1.2), author: .lead, note: "docs for wrapping; claude wraps",
                tasks: v2
            ),
        ], steering: [
            steer(
                id,
                goal,
                ago(3),
                .you,
                .start,
                "Started swarm 1: lead claude · opus, limits \(settings.limits.line)",
                reason: settings.autonomy.title
            ),
            steer(id, goal, ago(3), .heed, .start, "Lead claude · opus started, drafting the plan"),
            steer(id, goal, ago(2.6), .lead, .propose, "v1: draft from the lead", version: 1),
            steer(id, goal, ago(2), .you, .replan, "Wrapping changes what users see: plan the docs for it"),
            steer(id, goal, ago(1.2), .lead, .propose, "v2: docs for wrapping; claude wraps", version: 2),
            steer(
                id, goal, ago(1.1), .lead, .question,
                "Should labels wrap at a fixed width or at the gap between lifelines?", state: .pending,
                options: ["a fixed 40 characters", "the gap between lifelines"]
            ),
            steer(
                id, goal, ago(1), .lead, .question, "Are dark-theme golden images in scope for this swarm?",
                state: .pending, options: ["yes", "a follow-up"]
            ),
        ])
    }

    /// Approved: three versions, a question answered, your move, the plan approved; its tasks the goal's own items.
    static func approved(_ ago: (Double) -> Date) -> SwarmFixture {
        let goal = anchors
        let id = "\(goal)/swarm-1"
        func task(
            _ slug: String, _ title: String, _ phase: String, _ owner: String, model: String? = nil, _ minutes: Int,
            after: [String] = [], done: [String]
        ) -> SwarmTask {
            SwarmTask(
                id: "\(goal)/\(slug)", title: title, phase: phase, owner: GoalItem.Owner(agent: owner, model: model),
                estimate: minutes, after: after.map { "\(goal)/\($0)" }, doneWhen: done
            )
        }
        let assemblies = task(
            "assembly-redirects", "Redirects for moved assemblies", "Moves", "codex", 40,
            done: ["a moved assembly keeps its inbound anchors"]
        )
        let headings = task(
            "heading-ids", "Anchor ids from heading text", "Moves", "claude", 30,
            done: ["two headings with the same text get distinct ids"]
        )
        let sample = task(
            "sample-site", "Sample site with moved pages", "Proof", "claude", 25,
            after: ["assembly-redirects", "heading-ids"], done: ["the sample site builds with no broken anchor"]
        )
        let speed = task(
            "validator-speed", "Validator speed on a 10k-page site", "Proof", "claude", model: "opus", 45,
            after: ["heading-ids"], done: ["the validator checks 10k pages in under a minute"]
        )
        var firstSample = sample
        firstSample.after = ["\(goal)/assembly-redirects"]
        let v1 = [assemblies, headings, firstSample]
        let v2 = [assemblies, headings, sample, speed]
        let v3 = [headings, assemblies, sample, speed]
        let settings = SwarmSettings(
            repos: ["acme/docs-toolkit", "acme/docs-website"], lead: GoalItem.Owner(agent: "claude"),
            workers: [SwarmSettings.Worker(agent: "claude", count: 2), SwarmSettings.Worker(agent: "codex")],
            limits: SwarmSettings.Limits(agents: 3, hours: 4, dollars: 40)
        )
        let swarm = GoalSwarm(
            id: id, goal: goal, number: 1, settings: settings, plan: 3, approved: 3, startedAt: ago(30)
        )
        return SwarmFixture(swarm: swarm, versions: [
            SwarmPlanVersion(
                swarm: id, goal: goal, number: 1, at: ago(29), author: .lead, note: "draft from the lead", tasks: v1
            ),
            SwarmPlanVersion(
                swarm: id, goal: goal, number: 2, at: ago(27), author: .lead,
                note: "a speed task; the sample waits for heading ids", tasks: v2
            ),
            SwarmPlanVersion(
                swarm: id, goal: goal, number: 3, at: ago(26.5), author: .you,
                note: "moved Anchor ids from heading text up",
                tasks: v3
            ),
        ], steering: [
            steer(
                id,
                goal,
                ago(30),
                .you,
                .start,
                "Started swarm 1: lead claude, limits \(settings.limits.line)",
                reason: settings.autonomy.title
            ),
            steer(id, goal, ago(30), .heed, .start, "Lead claude started, drafting the plan"),
            steer(id, goal, ago(29), .lead, .propose, "v1: draft from the lead", version: 1),
            steer(
                id, goal, ago(28.9), .lead, .question, "Should the sample site live in the repo or be generated?",
                state: .pending, options: ["in the repo", "generated in CI"]
            ),
            steer(id, goal, ago(28), .you, .answer, "generated in CI", about: -4),
            steer(id, goal, ago(28), .you, .replan, "The validator is slow on big sites: plan for it"),
            steer(id, goal, ago(27), .lead, .propose, "v2: a speed task; the sample waits for heading ids", version: 2),
            steer(id, goal, ago(26.5), .you, .move, "moved Anchor ids from heading text up", version: 3),
            steer(id, goal, ago(26), .you, .approve, "plan v3 (4 tasks)", version: 3),
        ])
    }
}
