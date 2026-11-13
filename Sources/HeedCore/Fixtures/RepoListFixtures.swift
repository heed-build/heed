import Foundation

/// What `gh repo list` answers in the fake world: your own repos and each org's, for the Add or clone dialog's shots,
/// the tutor and tests. Invented names; pushed relative to `Clock.now`.
public enum RepoListFixtures {
    static func hours(_ value: Double) -> Date { Clock.now.addingTimeInterval(-value * 3600) }

    static func listing(
        _ slug: String, _ description: String = "", pushed hoursAgo: Double, isPrivate: Bool = false,
        archived: Bool = false
    ) -> RepoListing {
        RepoListing(
            repo: RepoEntry.repo(slug), description: description, pushedAt: hours(hoursAgo), isPrivate: isPrivate,
            isArchived: archived
        )
    }

    /// By owner, "" for yours, as `AddRepoForm.lists` takes them.
    public static let lists: [String: [RepoListing]] = [
        "": [
            listing("you/dotfiles", "shell, editor and git settings", pushed: 30),
            listing("you/scratch-notes", pushed: 500, isPrivate: true),
        ],
        "acme": [
            listing("acme/anchor-lint", "lints heading ids in docs", pushed: 2),
            listing("acme/analytics-site", pushed: 26, isPrivate: true),
            listing("acme/docs-toolkit", "builds the docs and checks their links", pushed: 5),
            listing("acme/docs-website", "the docs site's theme and search", pushed: 20),
            listing("acme/release-notes", "release notes, one file per version", pushed: 96),
            listing(
                "acme/legacy-annotator",
                "an annotator from before the docs toolkit",
                pushed: 17000,
                archived: true
            ),
        ],
        "globex": [
            listing("globex/markgraph", "diagrams from markdown", pushed: 8),
            listing("globex/gantt-kit", "gantt charts for markgraph", pushed: 140),
        ],
        "initech": [
            listing("initech/editor-rules", "lint rules for the editor", pushed: 30),
        ],
        "umbrella": [
            listing("umbrella/ingest", "the ingest pipeline", pushed: 70),
            listing("umbrella/ingest-bench", "load tests for ingest", pushed: 300),
        ],
    ]

    /// The orgs gh says you belong to.
    public static let orgs = ["acme", "globex", "initech", "umbrella"]
}
