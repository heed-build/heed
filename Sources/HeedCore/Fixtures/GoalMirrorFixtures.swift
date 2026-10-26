import Foundation

/// The fake world's GitHub mirror: the anchors goal follows along in an invented planning repo, its meta issue and a
/// sub-issue per item, synced a few minutes ago, with one colleague's change waiting for an answer. Nothing here was
/// ever on GitHub.
public enum GoalMirrorFixtures {
    public static let repo = "acme/planning"
    static let goal = "anchors-survive-page-moves"
    static let meta = 212

    /// The fixture goals with the anchors goal's tracker and its items' sub-issue numbers filled in.
    public static func apply(to fixtures: [GoalFixture]) -> [GoalFixture] {
        fixtures.map { fixture in
            guard fixture.goal.id == goal else { return fixture }
            var fixture = fixture
            fixture.goal.tracker = GoalTracker(repo: repo, metaIssue: meta)
            fixture.items = fixture.items.enumerated().map { index, item in
                var item = item
                item.issueNumber = meta + 1 + index
                return item
            }
            return fixture
        }
    }

    /// Each fixture goal's mirror state: the anchors goal's, on.
    public static func states(_ fixtures: [GoalFixture], now: Date = Clock.now) -> [String: GoalMirrorState] {
        guard let fixture = apply(to: fixtures).first(where: { $0.goal.id == goal }) else { return [:] }
        let base = now.timeIntervalSince1970.rounded(.down)
        var state = GoalMirrorState(
            on: true, repo: repo,
            meta: MirroredIssue(number: meta, id: 4_000_000_000 + Int64(meta), title: fixture.goal.title, body: ""),
            syncedAt: Date(timeIntervalSince1970: base - 4 * 60), seen: Date(timeIntervalSince1970: base - 4 * 60)
        )
        for item in fixture.items {
            guard let number = item.issueNumber else { continue }
            state.items[item.id] = MirroredIssue(
                number: number, id: 4_000_000_000 + Int64(number), title: item.title, body: "", attached: true
            )
        }
        if let sample = fixture.items.first(where: { $0.id.hasSuffix("/sample-site") }),
           let number = sample.issueNumber
        {
            state.items[sample.id]?.open = false
            state.asks = [MirrorAsk(
                item: sample.id, issue: number, kind: .done, at: Date(timeIntervalSince1970: base - 40 * 60)
            )]
        }
        return [goal: state]
    }
}
