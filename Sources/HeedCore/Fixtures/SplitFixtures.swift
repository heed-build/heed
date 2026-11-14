import Foundation

/// Step 4 and the goal's page in the fake world: your agents (with what heed would know of them), their records, a
/// complex goal split in fifteen parts and a small one in three, a definition under way, and the complex goal building.
/// Invented, as every fixture is; the shots render them through the real layout and assignment.
public enum SplitFixtures {
    public static let complexID = "schema-v2"
    public static let smallID = "sequence-diagrams"

    // MARK: Your agents

    /// Claude and Codex on subscriptions (Codex's rollout reported its window: the only ring), Copilot's coding agent
    /// with GitHub, Gemini and Cursor with nothing reported: spark only.
    public static func fleet(now: Date = Clock.now) -> [FleetAgent] {
        let thousand = { (values: [Int]) in values.map { $0 * 1000 } }
        return [
            FleetAgent(
                id: "claude", model: "sonnet", plan: .subscription, week: thousand([700, 900, 800, 950, 850, 600, 700])
            ),
            FleetAgent(
                id: "codex", model: "gpt-5-codex", plan: .subscription,
                quota: FleetQuota(left: 0.81, source: .window, resetsAt: now.addingTimeInterval(3 * 3600), at: now),
                week: thousand([100, 0, 150, 50, 0, 100, 120])
            ),
            FleetAgent(
                id: AgentFleet.copilot,
                model: "on GitHub",
                plan: .included,
                week: thousand([0, 100, 0, 0, 200, 0, 50])
            ),
            FleetAgent(id: "gemini", model: "2.5 pro", week: thousand([0, 0, 50, 0, 0, 0, 20])),
            FleetAgent(id: "cursor", model: "background"),
        ]
    }

    public static let records: [AgentRecord] = [
        AgentRecord(agent: "codex", repo: "engine", pulls: 12, merged: 11),
        AgentRecord(agent: "claude", repo: "engine", pulls: 9, merged: 7, stalls: 1),
        AgentRecord(agent: "claude", repo: "console", pulls: 10, merged: 9),
        AgentRecord(agent: "claude", repo: "diagrams", pulls: 9, merged: 9),
        AgentRecord(agent: AgentFleet.copilot, repo: "engine", pulls: 3, merged: 2),
        AgentRecord(agent: AgentFleet.copilot, repo: "sdk", pulls: 2, merged: 2),
        AgentRecord(agent: "gemini", repo: "docs", pulls: 3, merged: 3),
        AgentRecord(agent: "cursor", repo: "engine", pulls: 2, merged: 1, stalls: 1),
    ]

    // MARK: The complex goal

    static func part(
        _ goal: String, _ slug: String, _ title: String, _ agent: String, _ repo: String, _ size: PartSize,
        _ minutes: Int, after: [String] = [], done: [String] = [], context: [String] = []
    ) -> SplitPart {
        let model = fleet().first { $0.id == agent }.flatMap { $0.onGitHub ? nil : $0.model }
        return SplitPart(
            task: SwarmTask(
                id: "\(goal)/\(slug)", title: title, phase: "Build", owner: GoalItem.Owner(agent: agent, model: model),
                estimate: minutes, after: after.map { "\(goal)/\($0)" }, doneWhen: done
            ),
            repo: repo, size: size, context: context
        )
    }

    public static func complex() -> SplitDraft {
        let g = complexID
        let parts = [
            part(
                g,
                "schema",
                "Schema v2 and the migration plan",
                "claude",
                "engine",
                .m,
                120,
                done: ["the v2 schema and a migration plan are reviewed"],
                context: ["store/", "docs/schema.md"]
            ),
            part(
                g,
                "endpoints",
                "v2 endpoints",
                "codex",
                "engine",
                .m,
                155,
                after: ["schema"],
                done: ["every v1 endpoint has a v2 twin with tests"],
                context: ["api/"]
            ),
            part(
                g,
                "console-read",
                "Read v2 in the console",
                "claude",
                "console",
                .m,
                130,
                after: ["schema"],
                done: ["the console reads v2 behind the flag"]
            ),
            part(
                g,
                "migrate",
                "Migrate the store",
                "codex",
                "engine",
                .l,
                190,
                after: ["schema", "endpoints"],
                done: ["every v1 row reads back as v2, and the old reader still works behind the flag"],
                context: ["store/", "migrations/0042_*.sql", "#2790 v1 reader", "decision: online, not downtime"]
            ),
            part(
                g,
                "guide-draft",
                "Migration guide draft",
                "gemini",
                "docs",
                .s,
                90,
                after: ["schema"],
                done: ["a draft guide covers every breaking change"]
            ),
            part(
                g,
                "sdks",
                "Regenerate the SDKs",
                AgentFleet.copilot,
                "sdk",
                .s,
                70,
                after: ["endpoints"],
                done: ["the SDKs build against v2"]
            ),
            part(
                g,
                "edit-flows",
                "Edit flows",
                "claude",
                "console",
                .m,
                180,
                after: ["console-read"],
                done: ["editing works in v2"]
            ),
            part(
                g,
                "load-test",
                "Load-test harness",
                "cursor",
                "engine",
                .m,
                145,
                done: ["the harness replays a day of traffic"]
            ),
            part(
                g,
                "online",
                "Online migration path",
                "codex",
                "engine",
                .l,
                200,
                after: ["migrate"],
                done: ["v1 and v2 serve together"],
                context: ["store/", "#2790 v1 reader"]
            ),
            part(
                g,
                "deprecations",
                "Deprecations",
                AgentFleet.copilot,
                "sdk",
                .xs,
                40,
                after: ["online"],
                done: ["v1 calls warn once"]
            ),
            part(
                g,
                "empty-states",
                "Empty and error states",
                "claude",
                "console",
                .s,
                95,
                after: ["edit-flows"],
                done: ["every v2 view has an empty and an error state"]
            ),
            part(
                g,
                "review",
                "Review: code, tests, performance",
                "claude",
                "engine",
                .m,
                120,
                after: ["online"],
                done: ["the reviewers' bars pass"]
            ),
            part(
                g,
                "guide",
                "Migration guide, final",
                "gemini",
                "docs",
                .s,
                80,
                after: ["online", "guide-draft"],
                done: ["the guide's steps run as written"]
            ),
            part(
                g,
                "walks",
                "Stranger walks",
                "cursor",
                "engine",
                .l,
                205,
                after: ["review", "guide", "empty-states"],
                done: ["two strangers migrate a sample app with the guide alone"]
            ),
            part(
                g,
                "drill",
                "Rollback drill",
                "codex",
                "engine",
                .m,
                120,
                after: ["walks"],
                done: ["a rollback from v2 to v1 loses no row"]
            ),
        ]
        return SplitDraft(parts: parts, balance: .credits, lead: GoalItem.Owner(agent: "claude", model: "opus"))
    }

    public static func small() -> SplitDraft {
        let g = smallID
        let parts = [
            part(
                g,
                "wrap",
                "Wrap labels at the lifeline gap",
                "claude",
                "diagrams",
                .s,
                60,
                done: ["no label crosses a lifeline at any zoom"],
                context: ["layout/labels.rs"]
            ),
            part(
                g,
                "golden",
                "Golden images at three zooms",
                "claude",
                "diagrams",
                .s,
                70,
                after: ["wrap"],
                done: ["golden images pass at 50%, 100% and 200%"]
            ),
            part(
                g,
                "docs",
                "Docs: how labels wrap",
                "gemini",
                "docs",
                .xs,
                35,
                after: ["wrap"],
                done: ["the docs page shows a wrapped label"]
            ),
        ]
        return SplitDraft(parts: parts, balance: .credits, lead: GoalItem.Owner(agent: "claude", model: "opus"))
    }

    /// The goals the split shots show: the complex one at Split, the small one at Split.
    public static func goal(_ id: String, now: Date = Clock.now) -> GoalFixture {
        let small = id == smallID
        let title = small ? "Sequence diagrams read cleanly" : "Schema v2 without downtime"
        let statement = small ? "labels overlap lifelines in sequence diagrams" : "move the store to schema v2 online"
        let at = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down) - 3600)
        // Done looks like wrote its criteria into GOAL.md, as the wizard does.
        let doc = wizard(id, now: now).criteria.apply(to: GoalDoc.new(title: title, statement: statement))
        let goal = HeedGoal(id: id, title: title, createdAt: at, version: 1)
        return GoalFixture(
            goal: goal, versions: [GoalVersion(goal: id, number: 1, at: at, text: doc.render(), note: "plan")],
            links: []
        )
    }

    /// The goal's wizard at Split, its first three steps done, the split made.
    public static func wizard(_ id: String, now: Date = Clock.now) -> GoalWizard {
        let isSmall = id == smallID
        var wizard = GoalWizard(goal: id, at: now.addingTimeInterval(-3600))
        let plan = WizardPlan(
            title: isSmall ? "Sequence diagrams read cleanly" : "Schema v2 without downtime",
            summary: isSmall ? "Labels wrap at the lifeline gap, at every zoom." :
                "The store moves to v2 while it serves.",
            steps: isSmall ? ["wrap labels", "golden images", "docs"] : ["v2 schema", "endpoints", "migration", "drill"]
        )
        wizard.plan.turns = [PlanTurn(role: .you, text: plan.summary)]
        wizard.plan.add(plan, goalVersion: 1)
        wizard.advance(at: now)
        wizard.panel.decision = .worthIt
        wizard.advance(at: now)
        wizard.criteria = DoneDraft(
            statement: plan.summary,
            criteria: (isSmall ? small().parts : complex().parts).prefix(4).flatMap(\.task.doneWhen)
                .map { DoneCriterion($0) }
        )
        wizard.advance(at: now)
        wizard.split = isSmall ? small() : complex()
        wizard.split?.fromPlan = 1
        wizard.spent(WizardCost(step: .split, agent: "claude", model: "haiku", dollars: 0.01))
        return wizard
    }

    /// The split call's answer in the fake world: the small or the complex split, as the model writes it.
    static func splitJSON(small isSmall: Bool) -> String {
        let draft = isSmall ? small() : complex()
        let parts = draft.parts.map { part -> [String: Any] in
            [
                "id": part.task.slug, "title": part.title, "repo": part.repo ?? NSNull(), "size": part.size.rawValue,
                "estimate": SwarmEstimate.text(part.minutes), "after": part.task.after.map(SwarmPlan.short),
                "doneWhen": part.task.doneWhen, "context": part.context,
            ]
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["parts": parts], options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static let halvesJSON = """
    {"parts": [{"id": "first-half", "title": "The first half", "size": "S", "estimate": "1h 30m"}, \
    {"id": "second-half", "title": "The second half", "size": "S", "estimate": "1h 40m", "after": ["first-half"]}]}
    """

    // MARK: Defining a part

    /// Part 4 being defined with Codex: what it read, its two questions, your answer, and the part as it would be.
    public static func definition(now: Date = Clock.now) -> PartDefinition {
        var definition = PartDefinition(
            part: "\(complexID)/migrate", agent: "codex", via: "codex via ACP", at: now.addingTimeInterval(-100)
        )
        definition.reads = ["store/ · 14 files", "migrations/ · 41 files"]
        definition.turns = [
            .init(
                role: .agent,
                text: "The store has 3 tables with v1 rows: docs (2.1 M), links (9.8 M), anchors (31 M). anchors is "
                    + "too big to migrate in one transaction.\n\nTwo ways to keep it online:",
                options: ["batch in the background, readers accept both versions", "dual-write, then backfill"],
                picked: 0
            ),
            .init(role: .you, text: "batch it. readers already handle both behind the flag"),
            .init(
                role: .agent,
                text: "Then \"done\" should include a resumable backfill: if it stops at row 12 M it continues there. "
                    + "Add that to done when?",
                options: ["yes", "no, restart is fine"], picked: 0
            ),
        ]
        definition.draft = PartDraft(
            doneWhen: [
                "every v1 row reads back as v2, and the old reader still works behind the flag",
                "the backfill is resumable; a stop at row N continues at N",
                "anchors migrate in batches of 50 k, never one transaction",
            ],
            estimate: 270, context: [
                "store/",
                "migrations/0042_*.sql",
                "anchors: 31 M rows",
                "decision: batch, not dual-write",
            ]
        )
        definition.seconds = 100
        definition.cost = 0
        return definition
    }

    // MARK: The goal building

    /// The complex goal seven hours into building, Thorough: parts that ended over an hour and a half ago done, those
    /// that ended
    /// since under review, those under way running, part 7 asking you, the rest waiting.
    /// The level the complex goal goes with: other code depends on the engine and the SDKs.
    public static let care = CareLevel.thorough
    public static let profile = GoalProfile(stakes: .publicAPI, userFacing: true)

    /// The goal's wizard past Go: Thorough, the defaults, started as its first swarm.
    public static func started(_ id: String, now: Date = Clock.now) -> GoalWizard {
        var wizard = wizard(id, now: now)
        wizard.careful = id == complexID ? care : .standard
        wizard.go = GoChoices()
        wizard.advance(at: now)
        wizard.advance(at: now)
        wizard.advance(at: now)
        wizard.swarm = "\(id)/swarm-1"
        return wizard
    }

    public static func page(now: Date = Clock.now) -> GoalPage {
        let draft = complex()
        let numbers = Dictionary(draft.parts.enumerated().map { ($0.element.id, $0.offset + 1) }) { first, _ in first }
        let schedule = SplitSchedule.make(draft.parts, numbers: numbers)
        let hours = 7.2
        var states: [String: PartState] = [:]
        for (id, slot) in schedule.slots {
            if slot.end <= hours - 1.5 {
                states[id] = .done
            } else if slot.end <= hours {
                // Thorough: a part that ended in the last hour and a half has its PR open, under review.
                states[id] = PartState.running(progress: 1).reviewing(prOpen: true, care: care)
            } else if slot.start < hours {
                states[id] = .running(progress: (hours - slot.start) / slot.hours)
            } else {
                states[id] = .planned
            }
        }
        states["\(complexID)/edit-flows"] = .asking
        let wizard = started(complexID, now: now)
        let done = states.values.count { $0 == .done }
        return GoalPage(
            draft: draft, states: states, startedAt: now.addingTimeInterval(-hours * 3600), now: now,
            journey: GoalJourney.of(wizard: wizard, done: done, total: draft.parts.count, swarm: nil, goalDone: false),
            next: GoalNextStep(
                title: "Your next step: pick how editing works in the console",
                detail: "Claude on part 7 asked the lead; the lead asks you. Inline edits or a side panel? Part 11 "
                    + "waits on it.",
                options: ["inline", "side panel"]
            ),
            spent: 2.10
        )
    }
}
