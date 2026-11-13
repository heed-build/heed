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

    /// Open issues the search finds mentioning you or assigned to you, opened long ago and with no notification about
    /// them: folded out of Needs me as mentioned (assigned) before. One had a bot's comment today: still folded.
    static let attentionOldIssues: [Issue] = {
        func ago(_ days: Double) -> Date { Clock.now.addingTimeInterval(-days * 86400) }
        func old(
            _ repo: Repo, _ number: Int, _ title: String, opened: Double, updated: Double, assigned: Bool = false
        ) -> Issue {
            Issue(
                repo: repo, number: number, title: title, url: "https://github.com/\(repo.slug)/issues/\(number)",
                body: "", labels: [], author: "maintainer", updatedAt: ago(updated), createdAt: ago(opened),
                assigned: assigned, mentioned: !assigned
            )
        }
        return [
            old(docsToolkit, 1204, "Assembler: support versioned nav", opened: 410, updated: 0.2),
            old(docsToolkit, 1388, "Broken anchors after a heading is renamed", opened: 330, updated: 41),
            old(guides, 51, "Style guide: one word for sign in", opened: 600, updated: 120),
            old(guides, 58, "Screenshots go stale after each release", opened: 520, updated: 200),
            old(markgraph, 7, "Theme tokens for diagrams", opened: 700, updated: 300),
            old(ingest, 40, "Retry budget per stage", opened: 250, updated: 30, assigned: true),
        ]
    }()

    /// What the fake world's last sync fetched of each source: everything GitHub has, a minute ago.
    static func attentionFetches(_ state: GitHubState) -> GitHubFetches {
        let at = Clock.now.addingTimeInterval(-60)
        func all(_ count: Int) -> SourceFetch { SourceFetch(fetched: count, total: count, capped: false, at: at) }
        return GitHubFetches(
            notifications: all(state.inbox.count(where: \.unread)),
            mentions: all(state.issues.count(where: \.mentioned)),
            assigned: all(state.issues.count(where: \.assigned)), pulls: all(state.pulls.count { $0.state == .open })
        )
    }

    /// Thread details, by URL: who opened each, and the last comments (the three-line digest).
    static let attentionDetails: [String: ThreadDetail] = {
        func ago(_ minutes: Double) -> Date { Clock.now.addingTimeInterval(-minutes * 60) }
        let details = [
            ThreadDetail(
                url: "https://github.com/acme/docs-toolkit/pull/2845", author: "reviewer", labels: ["feature"],
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

    /// The catch-up summaries the fake world's model wrote, by item id: the PR under the cursor for the one comment
    /// that is new to you (written two minutes ago), the team mention and the assigned issue for their whole thread.
    static var attentionCatchUps: [String: CatchUpSummary] {
        func ago(_ minutes: Double) -> Date { Clock.now.addingTimeInterval(-minutes * 60) }
        return [
            "acme/docs-toolkit#2845": CatchUpSummary(
                text: """
                - The reviewer asks one thing before approving: is the redirect map generated at build time or \
                checked in?
                - Generated costs about 40 s of CI and needs the assembler to run before lint; checked in risks drift.
                - Your review is the only one requested.
                """,
                since: ago(20), coversUpTo: ago(4), count: 1, state: "open", writtenAt: ago(2), agent: "claude",
                model: "haiku"
            ),
            "acme/guides#77": CatchUpSummary(
                text: """
                - Your team is asked to say by Friday whether the 7.x guides can be archived in Q1.
                - Writers agreed as long as the redirects stay; your team owns most of the pages.
                """,
                since: nil, coversUpTo: ago(130), count: 3, state: "open", writtenAt: ago(60), agent: "codex",
                model: "fast-model"
            ),
            "acme/docs-toolkit#2830": CatchUpSummary(
                text: """
                - Assigned to you: moving a page drops its heading anchors from the redirects.
                - Reproduced on main; you are fixing it in #2841, where a missing anchor now fails the build.
                """,
                since: nil, coversUpTo: ago(26 * 60), count: 1, state: "open", writtenAt: ago(25 * 60),
                agent: "claude", model: "haiku"
            ),
        ]
    }

    /// The Decider's suggestions for items no rule matched, by item id.
    static let attentionSuggestions: [String: String] = ["acme/docs-toolkit#2830": "boost 1"]

    /// When you last looked: Attention an hour and a quarter ago, and the PR under the cursor 25 minutes ago (so its
    /// reader folds the comment you read and marks the new ones), the issue assigned to you after it last changed.
    static var attentionSeen: AttentionSeen {
        AttentionSeen(
            threads: [
                "acme/docs-toolkit#2845": Clock.now.addingTimeInterval(-25 * 60),
                "acme/docs-toolkit#2830": Clock.now.addingTimeInterval(-30 * 60),
            ],
            leftAt: Clock.now.addingTimeInterval(-75 * 60)
        )
    }

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
