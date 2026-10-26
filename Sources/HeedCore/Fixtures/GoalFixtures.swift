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

    /// What the Goals view draws first, with no store: the goals at their newest version, and their links.
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
        return GoalSnapshot(goals: goals, links: links, docs: docs)
    }

    /// Each goal's versions, newest first, as the store returns them.
    public static func versions(_ fixtures: [GoalFixture]) -> [String: [GoalVersion]] {
        Dictionary(uniqueKeysWithValues: fixtures.map { ($0.goal.id, $0.versions.reversed()) })
    }

    private static func fixture(
        _ id: String, status: HeedGoal.Status = .active, _ docs: [(Date, String, GoalDoc)], links: [GoalLink]
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
        return GoalFixture(goal: goal, versions: versions, links: links)
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
        ])
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
