import Foundation

/// The fake world's stranger walks, on `GoalFixtures`' goals: a DX first run walked twice on the anchors goal (the
/// re-walk after a fix, faster), its docs walked once, its screens drafted but not walked yet; the diagrams goal's
/// evaluators spawned. Invented, as every fixture is.
public extension GoalQualityFixtures {
    static func evaluations(_ ago: (Double) -> Date) -> [QualityRecord] {
        anchorWalks(ago) + diagramEvaluators(ago)
    }

    private static func walked(_ reviewer: String, run: String, _ walk: EvaluationWalk, heads: [String])
        -> QualityEntry
    {
        .review(ReviewResult(
            run: run, reviewer: reviewer, basis: ReviewBasis(goalVersion: walk.draftVersion, heads: heads),
            report: ReviewReport(walk: walk)
        ))
    }

    private static func walking(_ reviewer: String, run: String, heads: [String], trigger: ReviewTrigger)
        -> QualityEntry
    {
        .run(ReviewRunStart(
            id: run, reviewer: reviewer, trigger: trigger, basis: ReviewBasis(goalVersion: 3, heads: heads),
            agent: "claude", model: "haiku"
        ))
    }

    private static func steps(_ steps: [(String, WalkStep.Outcome, Double)]) -> [WalkStep] {
        steps.map { WalkStep(title: $0.0, outcome: $0.1, seconds: $0.2) }
    }

    private static func anchorWalks(_ ago: (Double) -> Date) -> [QualityRecord] {
        let id = "anchors-survive-page-moves"
        let pull = "acme/docs-toolkit#2841"
        let heads = ["acme/docs-toolkit#2841@4be1f20"]
        let titles = [
            "Read the quick start", "Install the toolkit", "Build the sample site", "Move a page and add a redirect",
            "Rebuild and follow the old link", "Find why a redirect did not apply",
        ]
        let silent = "The build prints nothing about redirects, so a skipped one looks like success."
        let trace = "A redirect to a missing heading fails with a bare KeyNotFound stack trace."
        let whereFile = "The README does not say where redirects.yml lives, or that its paths are relative to docs/."
        let indexing = "The first build sits at \"indexing…\" for 90 s with no progress."
        let pinned = "The install line pins a version two releases old."
        let first = EvaluationWalk(
            lens: .dxFirstRun, draftVersion: 3,
            steps: steps(zip(titles, [
                (WalkStep.Outcome.ok, 75.0),
                (.ok, 130),
                (.stalled, 95),
                (.confusing, 200),
                (.stalled, 100),
                (.failed, 240),
            ]).map { ($0.0, $0.1.0, $0.1.1) }),
            friction: [
                Friction(
                    severity: .high,
                    step: 5,
                    area: "rebuild",
                    finding: silent,
                    suggestion: "list the redirects applied at the end of a build"
                ),
                Friction(
                    severity: .high,
                    step: 6,
                    area: "error",
                    finding: trace,
                    suggestion: "name the file, the line and the heading"
                ),
                Friction(
                    severity: .med,
                    step: 4,
                    area: "redirects",
                    finding: whereFile,
                    suggestion: "one example in the quick start"
                ),
                Friction(
                    severity: .med,
                    step: 3,
                    area: "first build",
                    finding: indexing,
                    suggestion: "show pages done out of the total"
                ),
                Friction(
                    severity: .low,
                    step: 2,
                    area: "install",
                    finding: pinned,
                    suggestion: "point it at the latest tag"
                ),
            ],
            summary: "Got the sample site built, but could not tell whether a redirect applied, and the first error "
                + "was a stack trace.",
            source: pull
        )
        let second = EvaluationWalk(
            lens: .dxFirstRun, draftVersion: 3,
            steps: steps(zip(titles, [
                (WalkStep.Outcome.ok, 70.0),
                (.ok, 125),
                (.ok, 48),
                (.confusing, 180),
                (.stalled, 95),
                (.confusing, 142),
            ]).map { ($0.0, $0.1.0, $0.1.1) }),
            friction: [
                Friction(
                    severity: .high,
                    step: 5,
                    area: "rebuild",
                    finding: silent,
                    suggestion: "list the redirects applied at the end of a build"
                ),
                Friction(
                    severity: .med,
                    step: 4,
                    area: "redirects",
                    finding: whereFile,
                    suggestion: "one example in the quick start"
                ),
                Friction(
                    severity: .low,
                    step: 6,
                    area: "error",
                    finding: "The error names the file now, but not "
                        + "the heading it looked for.",
                    suggestion: "say which heading was missing"
                ),
                Friction(
                    severity: .low,
                    step: 2,
                    area: "install",
                    finding: pinned,
                    suggestion: "point it at the latest tag"
                ),
            ],
            summary: "Faster: the first build shows its progress and the error names the file. A skipped redirect "
                + "still looks like success.",
            source: pull
        )
        let docs = EvaluationWalk(
            lens: .docsWalk, draftVersion: 3,
            steps: steps([
                ("Open the docs' first page", .ok, 40), ("Find the page on redirects", .confusing, 150),
                ("Follow it to the end", .ok, 210), ("Look up the redirect error", .ok, 60),
            ]),
            friction: [
                Friction(
                    severity: .med,
                    step: 2,
                    area: "navigation",
                    finding: "Redirects are under Reference, not "
                        + "under Moving pages where a newcomer looks.",
                    suggestion: "link it from Moving pages"
                ),
            ],
            summary: "The redirects page is good once found.",
            source: pull
        )
        let entries: [(Double, QualityEntry)] = [
            (1.97, .reviewer(ReviewerConfig(id: "dx-evaluator", kind: .dxEvaluator))),
            (1.96, .reviewer(ReviewerConfig(id: "docs-walk", kind: .docsReader, evaluation: .docsWalk))),
            (1.95, .pins([.perf: 6, .ux: 6, .dx: 7])),
            (1.9, .walkDraft(WalkDraft(
                reviewer: "dx-evaluator", lens: .dxFirstRun, goalVersion: 3, steps: titles
            ))),
            (1.9, .walkDraft(WalkDraft(
                reviewer: "ux-evaluator", lens: .uxScreens, goalVersion: 3,
                steps: [
                    "Open the sample site",
                    "Move a page in the nav",
                    "Follow an old link",
                    "Read the not-found page",
                ]
            ))),
            (1.85, walking("dx-evaluator", run: "x1", heads: heads, trigger: .goalVersion(3))),
            (1.6, walked("dx-evaluator", run: "x1", first, heads: heads)),
            (1.55, walking("docs-walk", run: "w1", heads: heads, trigger: .goalVersion(3))),
            (1.4, walked("docs-walk", run: "w1", docs, heads: heads)),
            (0.8, walking("dx-evaluator", run: "x2", heads: heads, trigger: .fixMerged("acme/docs-toolkit#2843"))),
            (0.6, walked("dx-evaluator", run: "x2", second, heads: heads)),
            (0.5, .action(ObjectionAction(
                reviewer: "dx-evaluator", objection: ObjectionMatch.id(pinned), state: .acceptedRisk
            ))),
        ]
        return entries.map { QualityRecord(goal: id, at: ago($0.0), entry: $0.1) }
    }

    /// The diagrams goal is a user-facing product: its screens' evaluator came with its profile; its accessibility
    /// and docs walks too.
    private static func diagramEvaluators(_ ago: (Double) -> Date) -> [QualityRecord] {
        let id = "sequence-diagrams-read-cleanly"
        let profile = GoalProfile(stakes: .product, userFacing: true)
        let reviewers = ReviewPlanner.missing(bars: profile.bars(), reviewers: []).map {
            ReviewerConfig(id: $0.rawValue, kind: $0)
        }
        return EvaluationPlanner.missing(profile: profile, bars: profile.bars(), configs: reviewers).map {
            QualityRecord(goal: id, at: ago(24.85), entry: .reviewer($0))
        }
    }
}
