import Foundation

/// The fake world's goals, on `Fixtures.main`'s sessions: one with three `GOAL.md` versions and two sessions on it, one
/// just started, and a done one whose work is in History. Invented, as every fixture is.
public enum GoalFixtures {
    /// Times are whole seconds before `now`, so they read back from the store as they went in.
    public static func all(now: Date = Clock.now) -> [GoalFixture] {
        let base = now.timeIntervalSince1970.rounded(.down)
        func ago(_ hours: Double) -> Date { Date(timeIntervalSince1970: base - hours * 3600) }
        return [anchors(ago), diagrams(ago), nav(ago)]
    }

    /// What the Goals view draws first, with no store: the goals at their newest version, their links, items,
    /// evidence (numbered as the store numbers it) and edits.
    public static func snapshot(_ fixtures: [GoalFixture]) -> GoalSnapshot {
        var docs: [String: GoalDoc] = [:]
        for fixture in fixtures {
            docs[fixture.goal.id] = fixture.versions.last.map { GoalDoc.parse($0.text) }
        }
        // In the store's order: goals by creation, links by when they were made.
        let goals = fixtures.map(\.goal).sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        let links = fixtures.flatMap(\.links).sorted {
            ($0.at, $0.kind.rawValue, $0.target) < ($1.at, $1.kind.rawValue, $1.target)
        }
        let items = fixtures.flatMap(\.items).sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        var evidence: [GoalEvidence] = []
        var edits: [GoalEdit] = []
        for fixture in fixtures {
            for entry in fixture.evidence {
                var entry = entry
                entry.id = Int64(evidence.count + 1)
                evidence.append(entry)
            }
            for edit in fixture.edits {
                var edit = edit
                edit.id = Int64(edits.count + 1)
                edits.append(edit)
            }
        }
        evidence.sort { ($0.at, $0.id ?? 0) < ($1.at, $1.id ?? 0) }
        edits.sort { ($0.at, $0.id ?? 0) < ($1.at, $1.id ?? 0) }
        return GoalSnapshot(goals: goals, links: links, docs: docs, items: items, evidence: evidence, edits: edits)
    }

    /// Each goal's versions, newest first, as the store returns them.
    public static func versions(_ fixtures: [GoalFixture]) -> [String: [GoalVersion]] {
        Dictionary(uniqueKeysWithValues: fixtures.map { ($0.goal.id, $0.versions.reversed()) })
    }

    private static func fixture(
        _ id: String, status: HeedGoal.Status = .active, _ docs: [(Date, String, GoalDoc)], links: [GoalLink],
        items: [GoalItem] = [], evidence: [GoalEvidence] = [], edits: [GoalEdit] = []
    ) -> GoalFixture {
        let versions = docs.enumerated().map { index, entry in
            GoalVersion(
                goal: id, number: index + 1, at: entry.0, text: entry.2.render(), note: entry.1,
                author: index == 0 ? .you : entry.1.hasPrefix("criterion") ? .heed : .you
            )
        }
        let goal = HeedGoal(
            id: id, title: docs.last?.2.title ?? id, status: status, createdAt: docs.first?.0 ?? Clock.now,
            updatedAt: docs.last?.0, version: versions.count
        )
        return GoalFixture(
            goal: goal, versions: versions, links: links, items: items, evidence: evidence, edits: edits
        )
    }

    private static func anchors(_ ago: (Double) -> Date) -> GoalFixture {
        let id = "anchors-survive-page-moves"
        let first = GoalDoc.new(title: "Anchors survive page moves", statement: "Moving a page should not break links.")
        var second = first
        second.goal = "A page that moves keeps every inbound anchor working: old URLs redirect to the right heading, "
            + "and the build fails before a broken one ships."
        second.notTheGoal = ["Rewriting the link checker", "Changing how URLs are shaped", "Redirects for other sites"]
        second.doneWhen = [
            GoalDoc.Criterion("every redirect target resolves to a real heading"),
            GoalDoc.Criterion("the cross-link validator runs in CI for assemblies"),
            GoalDoc.Criterion("a moved page in the sample site keeps its anchors"),
        ]
        second.openQuestions = ["Do assemblies need a redirects file of their own?"]
        second.decisions = [GoalDoc.Decision("Redirect targets name a heading id, not a title", source: "you, Mon")]
        var third = second
        third.doneWhen[0] = GoalDoc.Criterion(
            "every redirect target resolves to a real heading", met: true, evidence: "acme/docs-toolkit#2841"
        )
        third.decisions.insert(
            GoalDoc.Decision("redirects.yml stays the one source of redirects", source: "session Fix broken anchors"),
            at: 0
        )
        return fixture(id, [
            (ago(8 * 24), "created", first), (ago(5 * 24), "the goal sharpened, done when", second),
            (ago(2), "criterion met: redirects resolve", third),
        ], links: [
            GoalLink(goal: id, kind: .session, target: "s1", at: ago(5 * 24)),
            GoalLink(goal: id, kind: .session, target: "s2", at: ago(3 * 24)),
        ], items: SwarmFixtures.planned(anchorItems(id, ago)), evidence: anchorEvidence(id, ago), edits: anchorEdits(
            id,
            ago
        ))
    }

    /// The anchors goal's work: planned, found in its sessions, raised in a chat and by a reviewer.
    private static func anchorItems(_ goal: String, _ ago: (Double) -> Date) -> [GoalItem] {
        func item(
            _ slug: String, _ title: String, _ source: GoalItem.Source, kind: GoalItem.Kind = .work,
            links: [GoalItem.Link] = [], confidence: Double? = nil, reason: String? = nil, hours: Double
        ) -> GoalItem {
            GoalItem(
                id: "\(goal)/\(slug)", goal: goal, title: title, kind: kind, source: source, links: links,
                confidence: confidence, reason: reason, createdAt: ago(hours)
            )
        }
        let plan = "from GOAL.md v2"
        return [
            item(
                "redirect-checker",
                "Redirect checker, first pass",
                .planner,
                links: [GoalItem.Link(.pr, "acme/docs-toolkit#2836")],
                reason: plan,
                hours: 120
            ),
            item(
                "resolve-targets",
                "Resolve redirect targets to headings",
                .planner,
                links: [GoalItem.Link(.session, "s1"), GoalItem.Link(.pr, "acme/docs-toolkit#2841")],
                reason: plan,
                hours: 119.9
            ),
            item(
                "website-redirects",
                "Redirects for moved website pages",
                .planner,
                links: [GoalItem.Link(.pr, "acme/docs-website#1920")],
                reason: plan,
                hours: 119.8
            ),
            item(
                "validator-ci",
                "Cross-link validator in CI",
                .planner,
                links: [GoalItem.Link(.session, "s2"), GoalItem.Link(.pr, "acme/docs-toolkit#2838")],
                reason: plan,
                hours: 119.7
            ),
            item("assembly-redirects", "Redirects for moved assemblies", .planner, reason: plan, hours: 119.6),
            item("sample-site", "Sample site with moved pages", .swarm, reason: "a swarm's plan", hours: 100),
            item(
                "heading-ids",
                "Anchor ids from heading text",
                .session,
                links: [GoalItem.Link(.session, "s1")],
                confidence: 0.91,
                reason: "follow-up in Fix broken anchors in redirects",
                hours: 70
            ),
            item(
                "validator-speed",
                "Validator speed on a 10k-page site",
                .session,
                links: [GoalItem.Link(.session, "s2")],
                confidence: 0.82,
                reason: "follow-up in Cross-link validator for assemblies",
                hours: 40
            ),
            item(
                "rules-home",
                "Where do redirect rules live?",
                .chat,
                kind: .question,
                reason: "asked in a chat",
                hours: 90
            ),
            item(
                "assembly-file",
                "Do assemblies need a redirects file of their own?",
                .chat,
                kind: .question,
                reason: "asked in a chat",
                hours: 50
            ),
            item(
                "removed-heading",
                "Should a removed heading redirect to the page top?",
                .reviewer,
                kind: .question,
                reason: "the docs reader asked",
                hours: 20
            ),
        ]
    }

    private static func anchorEvidence(_ goal: String, _ ago: (Double) -> Date) -> [GoalEvidence] {
        func entry(
            _ slug: String, _ kind: GoalEvidence.Kind, _ text: String, state: GoalEvidence.State = .done,
            source: String, ref: String? = nil, score: Double? = nil, hours: Double
        ) -> GoalEvidence {
            GoalEvidence(
                goal: goal, item: "\(goal)/\(slug)", kind: kind, state: state, at: ago(hours), source: source,
                text: text, ref: ref, score: score
            )
        }
        let checker = "acme/docs-toolkit#2836"
        let targets = "acme/docs-toolkit#2841"
        return [
            entry("redirect-checker", .planReview, "plan read, no objections", source: "plan critic", hours: 118),
            entry("redirect-checker", .built, "first pass in Fix broken anchors", source: "session s1", hours: 110),
            entry(
                "redirect-checker",
                .codeReview,
                "two nits, fixed",
                source: "implementation",
                score: 7.5,
                hours: 100
            ),
            entry(
                "redirect-checker",
                .dx,
                "error names the broken target",
                source: "DX first run",
                score: 7,
                hours: 99
            ),
            entry("redirect-checker", .pr, "#2836 open · CI ok", source: "#2836", ref: checker, hours: 98),
            entry("redirect-checker", .merged, "#2836 merged", source: "#2836", ref: checker, hours: 96),
            entry("resolve-targets", .planReview, "plan read", source: "plan critic", hours: 100),
            entry("resolve-targets", .built, "targets resolve on the sample", source: "session s1", hours: 30),
            entry(
                "resolve-targets",
                .codeReview,
                "changes requested: 2 threads",
                state: .issue,
                source: "#2841",
                ref: targets,
                hours: 6
            ),
            entry(
                "resolve-targets",
                .pr,
                "#2841 open · CI failing",
                state: .issue,
                source: "#2841",
                ref: targets,
                hours: 2
            ),
            entry("website-redirects", .built, "redirects written", source: "session s1", hours: 26),
            entry(
                "website-redirects",
                .pr,
                "#1920 open · CI ok",
                source: "#1920",
                ref: "acme/docs-website#1920",
                hours: 20
            ),
            entry("validator-ci", .planReview, "plan read", source: "plan critic", hours: 80),
            entry(
                "validator-ci",
                .built,
                "validator runs locally",
                state: .inProgress,
                source: "session s2",
                hours: 30
            ),
            entry(
                "validator-ci",
                .pr,
                "#2838 open · CI running",
                state: .inProgress,
                source: "#2838",
                ref: "acme/docs-toolkit#2838",
                hours: 3
            ),
            entry("heading-ids", .built, "ids from heading text", state: .inProgress, source: "session s1", hours: 10),
            entry("validator-speed", .built, "a first version", source: "session s2", hours: 12),
            entry(
                "validator-speed",
                .perf,
                "adds 40 s to a 10k-page build",
                state: .issue,
                source: "perf probe",
                score: 4.5,
                hours: 5
            ),
            entry("rules-home", .decision, "redirects.yml stays the one source", source: "chat", hours: 60),
        ]
    }

    private static func anchorEdits(_ goal: String, _ ago: (Double) -> Date) -> [GoalEdit] {
        [
            GoalEdit(
                goal: goal, section: .doneWhen, op: .check, text: "every redirect target resolves to a real heading",
                target: "every redirect target resolves to a real heading", evidence: "acme/docs-toolkit#2841",
                from: "Fix broken anchors in redirects", state: .applied, at: ago(2), version: 3
            ),
            GoalEdit(
                goal: goal, section: .notTheGoal, op: .add, text: "Anchors inside generated API reference pages",
                from: "Fix broken anchors in redirects",
                reason: "Generated API pages take their anchors from symbols, not headings: a separate piece of work.",
                at: ago(1.5)
            ),
            GoalEdit(
                goal: goal, section: .doneWhen, op: .add, text: "the validator adds at most 10 s to a 10k-page build",
                from: "perf probe · validator run",
                reason: "Validating every link adds 40 s to a 10k-page build. Nobody wrote a limit down.", at: ago(1)
            ),
            GoalEdit(
                goal: goal, section: .openQuestions, op: .add, text: "Do redirects survive a version switch?",
                from: "chat · Where do redirect rules live?",
                reason: "Versioned docs keep their own redirects, so a switch may drop them.", at: ago(0.5)
            ),
        ]
    }

    private static func diagrams(_ ago: (Double) -> Date) -> GoalFixture {
        let id = "sequence-diagrams-read-cleanly"
        let first = GoalDoc.new(
            title: "Sequence diagrams read cleanly",
            statement: "Arrows, labels and lifelines in sequence diagrams render without overlaps at any zoom."
        )
        var second = first
        second.notTheGoal = ["New diagram types", "A theme editor"]
        second.doneWhen = [
            GoalDoc.Criterion("arrowheads meet the lifeline exactly"),
            GoalDoc.Criterion("long labels wrap instead of overlapping"),
        ]
        return fixture(id, [(ago(30), "created", first), (ago(26), "edited", second)], links: [
            GoalLink(goal: id, kind: .session, target: "s4", at: ago(26)),
        ])
    }

    private static func nav(_ ago: (Double) -> Date) -> GoalFixture {
        let id = "one-docs-nav-model"
        var first = GoalDoc.new(title: "One docs nav model", statement: "Every page's navigation comes from the toc.")
        first.doneWhen = [GoalDoc.Criterion("nav built from the toc"), GoalDoc.Criterion("breadcrumbs match the nav")]
        var second = first
        second.doneWhen = [
            GoalDoc.Criterion("nav built from the toc", met: true, evidence: "acme/docs-toolkit#2852"),
            GoalDoc.Criterion("breadcrumbs match the nav", met: true, evidence: "the spike's sample site"),
        ]
        second.decisions = [GoalDoc.Decision("Toc order wins over file order", source: "chat")]
        return fixture(id, status: .done, [(ago(14 * 24), "created", first), (ago(3 * 24), "done", second)], links: [
            GoalLink(goal: id, kind: .session, target: "h-docs-nav-spike-v1", at: ago(14 * 24)),
            GoalLink(goal: id, kind: .session, target: "s6", at: ago(4 * 24)),
        ])
    }
}
