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
                createdAt: ago(days: 25), updatedAt: ago(days: 21), hasLinkedPull: true, checks: .passing,
                requestedReviewers: ["you"]
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

        /// An older item the first one may duplicate: closed, so the list (open items) does not show it, but the
        /// cache holds it for the "possibly the same as" line.
        static let closedAnchors = BrowseItem(
            repo: acmeDocs, number: 2701,
            title: ExternalText(
                "Anchors dropped on rename",
                source: .issueTitle,
                author: .init(login: "jdoe", trust: .member)
            ),
            state: .closed, author: "jdoe", labels: ["bug"], comments: 3, createdAt: ago(days: 80),
            updatedAt: ago(days: 60)
        )

        /// The cache: the ten the list shows, and the closed one a read points at.
        public static let cached: [BrowseItem] = items + [closedAnchors]

        /// heed's read of each of them but two (those say unread), with the numbers the design draws.
        public static let reads: BrowseReads = {
            func read(
                _ item: BrowseItem, _ kind: BrowseClass, _ size: BrowseSize, _ ready: Int, _ tldr: String,
                duplicates: [String] = []
            ) -> BrowseRead {
                BrowseRead(
                    itemID: item.id, kind: kind, size: size, agentReady: ready, tldr: tldr, duplicates: duplicates,
                    readAt: ago(days: 0.01), itemUpdatedAt: item.updatedAt, agent: "claude", model: "haiku"
                )
            }
            let list = items
            return Dictionary(uniqueKeysWithValues: [
                read(
                    list[0], .bug, .s, 82,
                    "Moving a page drops the heading anchors from its redirects, so deep links 404 after a "
                        + "restructure. Reproducible with a two-file move; the fix is in how the anchor table keys "
                        + "on the old path.",
                    duplicates: [closedAnchors.id]
                ),
                read(
                    list[1], .bug, .m, 64,
                    "Requests to /reference redirect to themselves when the trailing-slash rule runs before the "
                        + "alias table. Reproducible, but the right order of the rules needs a look."
                ),
                read(
                    list[2], .feature, .l, 31,
                    "Snippets cannot include other snippets. Needs a decision on cycles and relative paths before "
                        + "anyone builds it."
                ),
                read(
                    list[3], .bug, .s, 48,
                    "Bursts above ~5k events/s overflow the stage queue and events are dropped silently. Needs a "
                        + "decision on blocking versus shedding first, so only half-ready for an agent."
                ),
                read(
                    list[4], .bug, .s, 91,
                    "Arrow heads detach from their lines below 50% zoom because the marker offset is in screen "
                        + "pixels. A one-line scale fix with a clear repro."
                ),
                read(
                    list[5], .feature, .s, 88,
                    "Adds a dark theme to the code switcher from the existing theme tokens. Small and bounded, with "
                        + "clear acceptance."
                ),
                read(
                    list[6], .chore, .s, 90,
                    "Updates the spec-test fixtures to 0.17. No source changes. One snapshot changed meaningfully: "
                        + "the renamed anchor-fold case."
                ),
                read(
                    list[9], .docs, .s, 90,
                    "Document how the retry budget is counted and what happens when it runs out. A small writing "
                        + "task with the source in one file."
                ),
            ].map { ($0.itemID, $0) })
        }()

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

        /// Pinned in the rail, in order.
        public static let scopes: [BrowseScope] = [
            .org("acme"), .repo(acmeDocs), .repo(acmeIngest), .repo(acmeMarkgraph), .org("globex"),
        ]

        /// The orgs open in the rail's Scopes.
        public static let expanded: Set<String> = ["acme"]

        /// What the rail counts, as GitHub's searches would answer.
        public static let scopeTotals: [String: Int] = [
            BrowseScope.org("acme").id: 212, BrowseScope.repo(acmeDocs).id: 83, BrowseScope.repo(acmeIngest).id: 40,
            BrowseScope.repo(acmeMarkgraph).id: 21, BrowseScope.org("globex").id: 64, BrowseScope.ownRepos("acme").id: 131,
        ]

        public static let queries: [SavedQuery] = [
            SavedQuery.agentReady,
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
            "agent-ready": 23, "bugs-untouched": 14, "good-first": 8, "stale": 41, "blockers": 5, "ideas": 17,
        ]

        /// Queries with something new since you looked: the blue dot.
        public static let newQueries: Set<String> = ["agent-ready", "good-first"]

        /// What Browse opens on.
        public static let last = BrowseLast(
            scope: .org("acme"), query: BrowseQuery(scope: .org("acme"), tokens: [.state(.open)])
        )

        public static let orgs: [BrowsePalette.Org] = [
            .init(name: "acme", repoCount: 38, openCount: 212, ownRepos: 4),
            .init(name: "globex", repoCount: 1240, ownRepos: 1),
            .init(name: "Mpdreamz", repoCount: 61, personal: true),
        ]

        public static let listings: [RepoListing] = [
            RepoListing(repo: Repo(org: "globex", name: "glossary")),
            RepoListing(repo: Repo(org: "globex", name: "glass-api")),
        ]

        public static let openCounts: [String: Int] = ["globex/glossary": 12, "globex/glass-api": 31]

        /// What the model's answer to "bugs nobody touched, agent ready" reads as: three tokens, the last of them
        /// heed's own read of items, applied on this Mac.
        public static let understood = BrowseUnderstanding(
            tokens: [.label(.any, ["bug"]), .activity(.olderThan(30)), .heedReady(BrowseRead.readyLine)]
        )

        /// The repos of the big org the palette warns about, for the org view builder.
        public static let globexRepos: [BrowseRepoInfo] = [
            ("glossary", "C#"), ("glass-api", "Go"), ("docs-site", "TypeScript"), ("style-guide", "Markdown"),
            ("billing", "C#"), ("ledger", "Go"), ("web-shop", "TypeScript"), ("infra", "HCL"), ("sdk-dotnet", "C#"),
            ("sdk-go", "Go"), ("old-wiki", "Ruby"),
        ].map { entry in
            BrowseRepoInfo(slug: "globex/\(entry.0)", language: entry.1, isArchived: entry.0 == "old-wiki")
        }
    }
}
