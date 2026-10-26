import Foundation

/// The fake world's quality records, on `GoalFixtures`' goals: profiles, reviewers, their reviews and your accepted
/// risks. Invented, as every fixture is.
public enum GoalQualityFixtures {
    public static func all(now: Date = Clock.now) -> [QualityRecord] {
        let base = now.timeIntervalSince1970.rounded(.down)
        func ago(_ hours: Double) -> Date { Date(timeIntervalSince1970: base - hours * 3600) }
        return anchors(ago) + diagrams(ago) + nav(ago) + evaluations(ago)
    }

    /// Each goal's quality, folded with its newest GOAL.md.
    public static func qualities(_ records: [QualityRecord], goals: [GoalFixture]) -> [String: GoalQuality] {
        Dictionary(uniqueKeysWithValues: goals.map { fixture in
            let doc = fixture.versions.last.map { GoalDoc.parse($0.text) }
            return (fixture.goal.id, GoalQuality.fold(records.filter { $0.goal == fixture.goal.id }, doc: doc))
        })
    }

    /// The reviews in the fixture goals' shared model, as `GoalOps` would have put them: each reviewer's evidence on
    /// the items it looked at, and an item for each open HIGH objection.
    public static func share(_ qualities: [String: GoalQuality], into snapshot: inout GoalSnapshot) {
        for goal in snapshot.goals {
            guard let quality = qualities[goal.id] else { continue }
            var items = snapshot.items(of: goal.id)
            for (reviewer, objection) in ReviewEvidence.newItems(quality, items: items) {
                let taken = Set(items.map(\.slug))
                let item = GoalItem(
                    id: "\(goal.id)/\(GoalSlug.make(objection.text, taken: taken))", goal: goal.id,
                    title: GoalDoc.oneLine(objection.text), source: .reviewer, links: [GoalItem.Link(
                        .review,
                        reviewer.id
                    )],
                    reason: "\(reviewer.config.title): HIGH " + ReviewEvidence.marker(
                        reviewer: reviewer.id,
                        objection: objection.id
                    ),
                    createdAt: objection.firstSeen
                )
                items.append(item)
                snapshot.items.append(item)
                if let kind = EvaluationEvidence.kind(reviewer) {
                    snapshot.evidence.append(GoalEvidence(
                        goal: goal.id, item: item.id, kind: kind, state: .issue, at: objection.lastSeen,
                        source: EvaluationEvidence.source(reviewer), text: objection.evidence ?? "HIGH objection",
                        ref: "review:\(reviewer.id)"
                    ))
                }
            }
            for reviewer in quality.live {
                guard let at = reviewer.lastReviewAt else { continue }
                let bar = reviewer.config.kind.lens.flatMap { lens in quality.lenses.first { $0.lens == lens }?.bar }
                snapshot.evidence += reviewer.config.walk == nil
                    ? ReviewEvidence.of(reviewer: reviewer, bar: bar, goal: goal.id, items: items, at: at)
                    : EvaluationEvidence.of(evaluator: reviewer, bar: bar, goal: goal.id, items: items, at: at)
            }
        }
    }

    private static func profile(
        _: String, _ profile: GoalProfile, version: Int, pins: [GoalLens: Double] = [:], changes: [BarChange] = []
    ) -> QualityEntry {
        .profile(ProfileDecision(
            profile: profile, bars: profile.bars(pins: pins), changes: changes,
            note: BarChange.note(profile: profile, changes: changes), goalVersion: version
        ))
    }

    private static func review(
        _ reviewer: String, run: String, version: Int, heads: [String] = [], summary: String,
        _ objections: [(Severity, String, String?)], ran: [String] = [], files: Int = 0
    ) -> QualityEntry {
        .review(ReviewResult(
            run: run, reviewer: reviewer, basis: ReviewBasis(goalVersion: version, heads: heads),
            report: ReviewReport(
                summary: summary,
                objections: objections.map { .init(severity: $0.0, text: $0.1, evidence: $0.2) },
                ran: ran, files: files
            )
        ))
    }

    private static func start(
        _ reviewer: String,
        run: String,
        version: Int,
        heads: [String] = [],
        trigger: ReviewTrigger
    ) -> QualityEntry {
        .run(ReviewRunStart(
            id: run, reviewer: reviewer, trigger: trigger, basis: ReviewBasis(goalVersion: version, heads: heads),
            agent: "claude"
        ))
    }

    private static func anchors(_ ago: (Double) -> Date) -> [QualityRecord] {
        let id = "anchors-survive-page-moves"
        let head = ["acme/docs-toolkit#2841@4be1f20"]
        let older = ["acme/docs-toolkit#2841@1c09a7e"]
        let profile = GoalProfile(stakes: .product)
        let pins: [GoalLens: Double] = [.perf: 6, .ux: 6]
        var entries: [(Double, QualityEntry)] = [
            (5 * 24, Self.profile(id, profile, version: 2)),
            (5 * 24 - 0.1, .pins(pins)),
        ]
        for kind in [ReviewerKind.planCritic, .implementation, .testArchitect, .docsReader, .perfProber, .uxEvaluator] {
            entries.append((5 * 24 - 0.2, .reviewer(ReviewerConfig(
                id: kind.rawValue, kind: kind, policy: kind == .perfProber ? .nightly : .onChange
            ))))
        }
        let redirectsByTitle = "Redirect targets are matched by heading title, so renaming a heading breaks them."
        let anchorIndex = "The anchor index is rebuilt for every page instead of once per build."
        let noSchema = "redirects.yml has no schema version."
        let sharedLogger = "A shared logger is written by two builds at once."
        entries += [
            (30, start("plan-critic", run: "p1", version: 2, heads: older, trigger: .goalVersion(2))),
            (29.8, review(
                "plan-critic",
                run: "p1",
                version: 2,
                heads: older,
                summary: "A clear goal. The criteria are checkable, but nothing says what happens to anchors "
                    + "on pages that are deleted rather than moved.",
                [
                    (.med, "Done-when says nothing about deleted pages.", nil),
                    (.low, "The open question on assemblies blocks the third criterion.", nil),
                ],
                files: 3
            )),
            (1.2, start("plan-critic", run: "p2", version: 3, heads: head, trigger: .goalVersion(3))),
            (1, review(
                "plan-critic",
                run: "p2",
                version: 3,
                heads: head,
                summary: "Better: the redirect decision settles most of it. Deleted pages are still open.",
                [(.med, "Done-when says nothing about deleted pages.", nil)],
                files: 3
            )),
            (
                26,
                start(
                    "implementation",
                    run: "i1",
                    version: 2,
                    heads: older,
                    trigger: .prOpened("acme/docs-toolkit#2841")
                )
            ),
            (25.5, review(
                "implementation",
                run: "i1",
                version: 2,
                heads: older,
                summary: "Direction is right and redirects.yml reads cleanly.",
                [
                    (.high, redirectsByTitle, "RedirectResolver.cs:88"),
                    (.high, sharedLogger, "BuildContext.cs:41"),
                    (.low, noSchema, nil),
                ],
                ran: ["dotnet test"],
                files: 11
            )),
            (24, .action(ObjectionAction(
                reviewer: "implementation", objection: ObjectionMatch.id(noSchema), state: .acceptedRisk
            ))),
            (2.2, start(
                "implementation",
                run: "i2",
                version: 3,
                heads: head,
                trigger: .prUpdated("acme/docs-toolkit#2841")
            )),
            (2, review(
                "implementation",
                run: "i2",
                version: 3,
                heads: head,
                summary: "Direction is right and redirects resolve. Unhappy about matching redirects by title, "
                    + "which renames break, and about rebuilding the anchor index for every page.",
                [
                    (.high, redirectsByTitle, "RedirectResolver.cs:88"),
                    (.med, anchorIndex, "AnchorIndex.cs:23"),
                    (.low, noSchema, nil),
                ],
                ran: ["dotnet test", "toolkit build --sample"],
                files: 14
            )),
            (20, start("perf-prober", run: "f1", version: 2, heads: older, trigger: .nightly)),
            (19.6, review(
                "perf-prober",
                run: "f1",
                version: 2,
                heads: older,
                summary: "No baseline to compare against, and the anchor index shows up in every page's "
                    + "build time.",
                [
                    (.med, anchorIndex, "AnchorIndex.cs:23"),
                    (.med, "There is no build-time baseline for the sample site.", nil),
                    (.low, "Link validation runs twice on assemblies.", nil),
                ],
                ran: ["toolkit build --sample --timings"],
                files: 6
            )),
            (8, start("test-architect", run: "t1", version: 3, heads: head, trigger: .goalVersion(3))),
            (7.5, review(
                "test-architect",
                run: "t1",
                version: 3,
                heads: head,
                summary: "The redirect tests are good; moved pages are only tested in one assembly.",
                [(.med, "Moved pages are tested in one assembly only.", "RedirectTests.cs")],
                ran: ["dotnet test"],
                files: 9
            )),
            (0.1, start("test-architect", run: "t2", version: 3, heads: head, trigger: .manual)),
            (6, start("docs-reader", run: "d1", version: 3, heads: head, trigger: .goalVersion(3))),
            (5.8, review(
                "docs-reader",
                run: "d1",
                version: 3,
                heads: head,
                summary: "The redirects page explains the new file well.",
                [],
                files: 4
            )),
        ]
        return entries.map { QualityRecord(goal: id, at: ago($0.0), entry: $0.1) }
    }

    private static func diagrams(_ ago: (Double) -> Date) -> [QualityRecord] {
        let id = "sequence-diagrams-read-cleanly"
        let profile = GoalProfile(stakes: .product, userFacing: true)
        var entries: [(Double, QualityEntry)] = [(25, Self.profile(id, profile, version: 2))]
        for kind in ReviewPlanner.missing(bars: profile.bars(), reviewers: []) {
            entries.append((24.9, .reviewer(ReviewerConfig(id: kind.rawValue, kind: kind))))
        }
        entries += [
            (4, start("implementation", run: "s1", version: 2, trigger: .goalVersion(2))),
            (3.7, review(
                "implementation",
                run: "s1",
                version: 2,
                summary: "Arrowheads now meet the lifeline; label wrapping is not started.",
                [(.med, "Long labels still overlap the next message.", "SequenceLayout.ts:140")],
                ran: ["npm test"],
                files: 7
            )),
        ]
        return entries.map { QualityRecord(goal: id, at: ago($0.0), entry: $0.1) }
    }

    private static func nav(_ ago: (Double) -> Date) -> [QualityRecord] {
        let id = "one-docs-nav-model"
        let profile = GoalProfile(stakes: .spike)
        var entries: [(Double, QualityEntry)] = [(14 * 24, Self.profile(id, profile, version: 1))]
        for kind in ReviewPlanner.missing(bars: profile.bars(), reviewers: []) {
            entries.append((14 * 24 - 0.1, .reviewer(ReviewerConfig(id: kind.rawValue, kind: kind))))
        }
        entries += [
            (4 * 24, review("plan-critic", run: "n1", version: 2, summary: "Small and clear.", [])),
            (3.9 * 24, review(
                "implementation",
                run: "n2",
                version: 2,
                summary: "Good enough for a spike.",
                [(.low, "The toc reader has no tests for empty sections.", nil)],
                files: 5
            )),
            (3 * 24, .done(DoneMark(done: true, basis: "plan=10,code=9.5"))),
        ]
        return entries.map { QualityRecord(goal: id, at: ago($0.0), entry: $0.1) }
    }
}
