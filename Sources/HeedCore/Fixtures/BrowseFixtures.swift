import Foundation

/// The fake world's Browse: an org with ten open items (the first is the issue the reader's conversation fixture is
/// about), the queries and scopes in the rail with the counts GitHub would give, and the palette's orgs and repos.
/// All invented; relative to `Clock.now`.
public extension Fixtures {
    enum Browse {
        static let acmeDocs = Repo(org: "acme", name: "docs-toolkit")
        static let acmeIngest = Repo(org: "acme", name: "ingest")
        static let acmeMarkgraph = Repo(org: "acme", name: "markgraph")
        static let acmeRules = Repo(org: "acme", name: "editor-rules")
        static let acmeGuides = Repo(org: "acme", name: "guides")

        static func ago(days: Double) -> Date { Clock.now.addingTimeInterval(-days * 86400) }

        static func issue(
            _ repo: Repo, _ number: Int, _ title: String, labels: [String], days: Double, comments: Int,
            assignees: [String] = [], author: String = "mara-k", linked: Bool = false
        ) -> BrowseItem {
            BrowseItem(
                repo: repo, number: number, title: ExternalText(
                    title,
                    source: .issueTitle,
                    author: .init(login: author, trust: .member)
                ),
                author: author, labels: labels, assignees: assignees, comments: comments,
                createdAt: ago(days: days + 6), updatedAt: ago(days: days), hasLinkedPull: linked
            )
        }

        /// The ten the design lists, newest update first.
        public static let items: [BrowseItem] = [
            issue(
                acmeDocs,
                2830,
                "Anchors lost when a page is moved",
                labels: ["bug"],
                days: 2,
                comments: 4,
                assignees: ["you"]
            ),
            issue(
                acmeDocs,
                2833,
                "Redirect loop on /reference",
                labels: ["bug", "redirects"],
                days: 3,
                comments: 6,
                author: "jdoe"
            ),
            issue(
                acmeDocs,
                2851,
                "Support nested includes in snippets",
                labels: ["enhancement"],
                days: 5,
                comments: 12
            ),
            issue(
                acmeIngest,
                94,
                "Backpressure drops events under burst",
                labels: ["bug", "perf"],
                days: 7,
                comments: 9
            ),
            issue(
                acmeMarkgraph,
                12,
                "Arrow heads render detached at small zoom",
                labels: ["bug"],
                days: 14,
                comments: 2
            ),
            issue(
                acmeDocs,
                2790,
                "Add dark mode to the code switcher",
                labels: ["good first issue", "enhancement"],
                days: 21,
                comments: 3
            ),
            BrowseItem(
                repo: acmeRules, number: 412, kind: .pull,
                title: ExternalText(
                    "Bump spec tests to 0.17",
                    source: .pullTitle,
                    author: .init(login: "dependabot[bot]", trust: .bot)
                ),
                author: "dependabot[bot]", authorIsBot: true, labels: ["chore"], comments: 1,
                createdAt: ago(days: 25), updatedAt: ago(days: 21), hasLinkedPull: true, checks: .passing
            ),
            issue(acmeGuides, 77, "Archive the 7.x guides in Q1?", labels: ["question"], days: 28, comments: 21),
            issue(acmeDocs, 2802, "Changelog generator skips squashed merges", labels: ["bug"], days: 35, comments: 5),
            issue(
                acmeIngest,
                101,
                "Document the retry budget",
                labels: ["docs", "good first issue"],
                days: 42,
                comments: 0
            ),
        ]

        /// What GitHub says the open search holds, of which `items` are the first ten.
        public static let total = 47

        /// The checkouts the fake Mac has: every repo above but ingest, and glossary for the palette's shot.
        public static let records: [RepoRecord] = [
            acmeDocs,
            acmeMarkgraph,
            acmeRules,
            acmeGuides,
            Repo(org: "globex", name: "glossary"),
        ]
        .map { RepoRecord(repo: $0, path: "/Users/you/code/\($0.name)", defaultBranch: "main") }

        public static let project = BrowseScope.project(owner: "acme", number: 7, title: "Docs 2.0 board")

        /// Pinned in the rail, in order.
        public static let scopes: [BrowseScope] = [
            .org("acme"), .repo(acmeDocs), .repo(acmeIngest), .repo(acmeMarkgraph), .org("globex"), project,
        ]

        /// What the rail counts, as GitHub's searches would answer.
        public static let scopeTotals: [String: Int] = [
            BrowseScope.org("acme").id: 212, BrowseScope.repo(acmeDocs).id: 83, BrowseScope.repo(acmeIngest).id: 40,
            BrowseScope.repo(acmeMarkgraph).id: 21, BrowseScope.org("globex").id: 64, project.id: 29,
        ]

        public static let queries: [SavedQuery] = [
            SavedQuery(
                id: "assigned",
                name: "Assigned to me",
                glyph: .bolt,
                query: BrowseQuery(tokens: [.state(.open), .assignee("@me")])
            ),
            SavedQuery(
                id: "bugs-untouched",
                name: "Bugs nobody touched",
                query: BrowseQuery(tokens: [.state(.open), .label(.any, ["bug"]), .raw("no:assignee")])
            ),
            SavedQuery(
                id: "good-first",
                name: "Good first issues",
                query: BrowseQuery(tokens: [.state(.open), .label(.any, ["good first issue"])])
            ),
            SavedQuery(
                id: "stale",
                name: "Stale 30d+",
                query: BrowseQuery(tokens: [.state(.open), .activity(.olderThan(30))])
            ),
            SavedQuery(
                id: "blockers",
                name: "3.2 blockers",
                query: BrowseQuery(tokens: [.state(.open), .milestone("3.2"), .label(.any, ["blocker"])])
            ),
            SavedQuery(
                id: "ideas",
                name: "Docs 2.0 ideas",
                glyph: .star,
                query: BrowseQuery(tokens: [.state(.open), .project("acme/7"), .label(.any, ["idea"])])
            ),
        ]

        public static let queryTotals: [String: Int] = [
            "assigned": 23, "bugs-untouched": 14, "good-first": 8, "stale": 41, "blockers": 5, "ideas": 17,
        ]

        /// Queries with something new since you looked: the blue dot.
        public static let newQueries: Set<String> = ["assigned", "good-first"]

        /// What Browse opens on.
        public static let last = BrowseLast(
            scope: .org("acme"), query: BrowseQuery(scope: .org("acme"), tokens: [.state(.open)])
        )

        public static let orgs: [BrowsePalette.Org] = [
            .init(name: "acme", repoCount: 38, openCount: 212),
            .init(name: "globex", repoCount: 1240),
            .init(name: "Mpdreamz", repoCount: 61, personal: true),
        ]

        public static let listings: [RepoListing] = [
            RepoListing(repo: Repo(org: "globex", name: "glossary")),
            RepoListing(repo: Repo(org: "globex", name: "glass-api")),
        ]

        public static let openCounts: [String: Int] = ["globex/glossary": 12, "globex/glass-api": 31]
    }
}
