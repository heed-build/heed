import Foundation

/// The fake world's Attention: team mentions and a bot's PR on top of the inbox, rules that boost, lower and ignore
/// some of them, details and summaries for the threads, and what was muted earlier. All invented.
public extension Fixtures {
    static let guides = Repo(org: "acme", name: "guides")

    static let attentionRules = [
        "mention user:me                 boost 3",
        "review requested:me             boost 2",
        "mention team:acme/docs-eng      boost 2",
        "mention team:acme/everyone      ignore",
        "author bot:dependabot           ignore",
        "agent blocked|asking            boost 3",
        "ci branch:main                  lower",
    ]

    /// Notifications only Attention's shots add: two team mentions (one ignored by a rule) and a bot's PR.
    static let attentionInbox: [InboxItem] = {
        func ago(_ minutes: Double) -> Date { Clock.now.addingTimeInterval(-minutes * 60) }
        return [
            InboxItem(
                id: "n20", kind: .issue, repo: guides, number: 77, title: "Archive the 7.x guides in Q1?",
                reason: "team_mention", unread: true, updatedAt: ago(130),
                url: "https://github.com/acme/guides/issues/77", teams: ["acme/docs-eng"]
            ),
            InboxItem(
                id: "n21", kind: .issue, repo: guides, number: 80, title: "New release train starts Monday",
                reason: "team_mention", unread: true, updatedAt: ago(200),
                url: "https://github.com/acme/guides/issues/80", teams: ["acme/everyone"]
            ),
            InboxItem(
                id: "n22", kind: .pr, repo: guides, number: 81, title: "Bump markdown-it from 13.0.1 to 13.0.2",
                reason: "review_requested", unread: true, updatedAt: ago(240),
                url: "https://github.com/acme/guides/pull/81", teams: ["acme/docs-eng"]
            ),
        ]
    }()

    /// Thread details, by URL: who opened each, and the last comments (the three-line digest).
    static let attentionDetails: [String: ThreadDetail] = {
        func ago(_ minutes: Double) -> Date { Clock.now.addingTimeInterval(-minutes * 60) }
        let details = [
            ThreadDetail(
                url: "https://github.com/elastic/docs-builder/pull/2845", author: "reviewer", labels: ["feature"],
                isDraft: false, size: 212, headBranch: "link-validation",
                body: "Validates every link the assembler writes, and fails the build on a broken one.",
                comments: [
                    .init(author: "reviewer", text: "Validator looks good, one question first.", at: ago(30)),
                    .init(author: "you", text: "The map is generated at build time.", at: ago(20)),
                    .init(author: "reviewer", text: "Then put that in the description and I'll approve.", at: ago(4)),
                ],
                updatedAt: ago(4)
            ),
            ThreadDetail(
                url: "https://github.com/acme/guides/issues/77", author: "maintainer", labels: ["proposal"],
                body: "Proposal: archive the 7.x guides in Q1 and redirect them to the current ones.",
                comments: [
                    .init(author: "maintainer", text: "Every team please reply by Friday.", at: ago(400)),
                    .init(author: "writer", text: "Fine by us, as long as redirects stay.", at: ago(300)),
                    .init(author: "maintainer", text: "@acme/docs-eng you own most of these: ok?", at: ago(130)),
                ],
                updatedAt: ago(130)
            ),
            ThreadDetail(
                url: "https://github.com/acme/guides/pull/81", author: "dependabot", authorIsBot: true,
                labels: ["dependencies"], isDraft: false, size: 6, headBranch: "dependabot/npm/markdown-it-13.0.2",
                updatedAt: ago(240)
            ),
        ]
        return Dictionary(uniqueKeysWithValues: details.map { ($0.url.lowercased(), $0) })
    }()

    /// What the cheap model wrote, by item id.
    static let attentionSummaries: [String: String] = [
        "elastic/docs-builder#2845": "Asks you one thing before approving: whether the redirect map is generated at "
            + "build time or checked in, and to say so in the PR description. Checks are green.",
        "acme/guides#77": "A proposal to archive the 7.x guides in Q1, with redirects. Each team is asked to reply by "
            + "Friday; your team owns most of the pages.",
    ]

    /// The Decider's suggestions for items no rule matched, by item id.
    static let attentionSuggestions: [String: String] = ["elastic/docs-builder#2830": "boost 1"]

    /// Marks: one thread muted earlier.
    static let attentionMarks: [String: AttentionMark] = [
        "acme/guides#64": AttentionMark(mutedAt: Clock.now.addingTimeInterval(-3 * 86400)),
    ]

    /// Items the store remembers that are no longer live: the muted thread.
    static let attentionStored: [StoredAttentionItem] = [
        StoredAttentionItem(
            item: AttentionItem(
                id: "acme/guides#64", kind: .issue, repo: guides, number: 64, title: "Weekly link report",
                url: "https://github.com/acme/guides/issues/64", reasons: [.subscribed],
                updatedAt: Clock.now.addingTimeInterval(-2 * 86400), notificationID: "n9"
            ),
            firstSeen: Clock.now.addingTimeInterval(-9 * 86400), lastSeen: Clock.now.addingTimeInterval(-2 * 86400)
        ),
    ]

    /// The reply the fake world's model drafts.
    static let attentionDraft = """
    Thanks! The redirect map is generated at build time from the nav files, never checked in. \
    I've added a line saying so to the description.
    """
}
