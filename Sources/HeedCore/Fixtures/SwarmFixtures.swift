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

    private static func steer(
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
    private static func approved(_ ago: (Double) -> Date) -> SwarmFixture {
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
