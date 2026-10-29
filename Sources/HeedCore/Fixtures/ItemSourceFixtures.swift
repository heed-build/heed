import Foundation

/// The fake world's item sources: a goal to review every open PR in an invented repo, its PRs as items (one
/// reviewed, one asked for again after your review, one merged, one being reviewed in a session, two waiting, one that
/// left the source), and a goal heed read as a set of issues, with the source it proposes waiting for a yes. Nothing
/// here was ever on GitHub.
public enum ItemSourceFixtures {
    public static let repo = "acme/widgets"
    public static let reviewGoal = "review-open-prs-in-acme-widgets"
    public static let issuesGoal = "close-every-flaky-test-issue"

    /// The two goals, their items and evidence.
    public static func all(now: Date = Clock.now) -> [GoalFixture] {
        let base = now.timeIntervalSince1970.rounded(.down)
        func ago(_ hours: Double) -> Date { Date(timeIntervalSince1970: base - hours * 3600) }
        return [review(ago), issues(ago)]
    }

    /// Each goal's sources and proposal.
    public static func states(now: Date = Clock.now) -> [String: GoalSourceState] {
        let base = now.timeIntervalSince1970.rounded(.down)
        func ago(_ hours: Double) -> Date { Date(timeIntervalSince1970: base - hours * 3600) }
        let issues = issuesDoc
        return [
            reviewGoal: GoalSourceState(
                sources: [source(ago(5))], checked: 2, syncedAt: ago(0.05), next: 2
            ),
            issuesGoal: GoalSourceState(
                proposal: ItemSourceDetect.byWords(
                    title: issues.title, statement: issues.goal, repos: [repo], now: ago(0.5)
                ),
                checked: 1
            ),
        ]
    }

    static func source(_ at: Date) -> ItemSource {
        ItemSource(
            id: "s1", query: "is:pr is:open repo:\(repo)", label: "open PRs in \(repo)", rule: .reviewed,
            origin: .proposal, addedAt: at
        )
    }

    /// A PR as the source found it.
    struct Pull {
        var number: Int
        var title: String
        var author: String
        var state: SourceMatch.State = .open
        var review: SourceMatch.Review?
        var draft = false
        var failing = false
        var session: String?
        var left = false
        /// Reviewed, and your review asked for again since.
        var again = false
        var hours: Double
    }

    static let pulls: [Pull] = [
        Pull(
            number: 418,
            title: "Cache parsed templates between builds",
            author: "tess",
            review: .approved,
            hours: 4.8
        ),
        Pull(
            number: 421,
            title: "Drop the legacy YAML loader",
            author: "omar",
            review: .changesRequested,
            again: true,
            hours: 4.8
        ),
        Pull(number: 423, title: "Bump the markdown parser to 4.2", author: "lin", state: .merged, hours: 4.8),
        Pull(
            number: 425, title: "Retry uploads with backoff", author: "devi", session: "s-review-425", hours: 4.8
        ),
        Pull(number: 427, title: "Fix tab order in the settings form", author: "ravi", hours: 4.8),
        Pull(number: 429, title: "Stream large exports instead of buffering", author: "tess", failing: true, hours: 2),
        Pull(number: 412, title: "Experiment: a second sidebar", author: "omar", draft: true, left: true, hours: 4.8),
    ]

    private static var reviewDoc: GoalDoc {
        var doc = GoalDoc.new(
            title: "Review open PRs in acme/widgets",
            statement: "Review all open PRs in acme/widgets before the 2.0 branch is cut."
        )
        doc.doneWhen = [GoalDoc.Criterion(source(Date()).criterion)]
        return doc
    }

    private static var issuesDoc: GoalDoc {
        GoalDoc.new(
            title: "Close every flaky test issue",
            statement: "Fix or close every issue labelled flaky in acme/widgets, so the nightly run is green again."
        )
    }

    private static func review(_ ago: (Double) -> Date) -> GoalFixture {
        let id = reviewGoal
        let first = GoalDoc.new(title: reviewDoc.title, statement: reviewDoc.goal)
        let source = source(ago(5))
        var items: [GoalItem] = []
        var evidence: [GoalEvidence] = []
        for pull in pulls {
            let ref = "\(repo)#\(pull.number)"
            let item = GoalItem(
                id: "\(id)/pr-\(pull.number)", goal: id, title: pull.title, source: .github,
                links: [GoalItem.Link(.pr, ref)] + (pull.session.map { [GoalItem.Link(.session, $0)] } ?? []),
                reason: "from \(source.label)", createdAt: ago(pull.hours),
                sourced: GoalItem.Sourced(
                    source: source.id, ref: ref, kind: .pr,
                    url: "https://github.com/\(ref.replacingOccurrences(of: "#", with: "/pull/"))",
                    author: pull.author, rule: source.rule, left: pull.left ? ago(1) : nil
                )
            )
            items.append(item)
            let match = SourceMatch(
                ref: ref, kind: .pr, title: pull.title, url: item.sourced?.url ?? "", author: pull.author,
                state: pull.state, isDraft: pull.draft,
                checks: CheckSummary(
                    passed: pull.failing ? 6 : 7,
                    failed: pull.failing ? 1 : 0,
                    failedNames: pull.failing ? ["e2e"] : []
                ),
                review: pull.review, reviewRequested: pull.again
            )
            evidence += ItemSourceSync.evidence(
                match, rule: source.rule, goal: id, item: item.id, source: source, now: ago(pull.hours - 0.5)
            )
        }
        return GoalFixture(
            goal: HeedGoal(id: id, title: reviewDoc.title, createdAt: ago(5), updatedAt: ago(5), version: 2),
            versions: [
                GoalVersion(goal: id, number: 1, at: ago(5), text: first.render(), note: "created"),
                GoalVersion(goal: id, number: 2, at: ago(5), text: reviewDoc.render(), note: "done when: + source s1"),
            ],
            links: [], items: items, evidence: evidence
        )
    }

    private static func issues(_ ago: (Double) -> Date) -> GoalFixture {
        let id = issuesGoal
        let doc = issuesDoc
        return GoalFixture(
            goal: HeedGoal(id: id, title: doc.title, createdAt: ago(0.6), updatedAt: ago(0.6)),
            versions: [GoalVersion(goal: id, number: 1, at: ago(0.6), text: doc.render(), note: "created")],
            links: []
        )
    }
}
