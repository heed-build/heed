import Foundation
@testable import HeedCore
import Testing

struct AttentionFeedTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let docs = Repo(org: "acme", name: "docs")
    private let api = Repo(org: "acme", name: "api")

    private func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    /// Notifications as GitHub sends them: a PR that is a review request, a mention on the same PR, a team mention
    /// on an issue, a CI run, a release.
    private let notifications = """
    [{"id":"101","reason":"review_requested","unread":true,"updated_at":"2033-05-18T03:20:00Z",
      "subject":{"title":"Validate anchors","type":"PullRequest","url":"https://api.github.com/repos/acme/docs/pulls/41"},
      "repository":{"full_name":"acme/docs"}},
     {"id":"102","reason":"mention","unread":false,"updated_at":"2033-05-18T03:25:00Z",
      "subject":{"title":"Validate anchors (v2)","type":"PullRequest","url":"https://api.github.com/repos/Acme/Docs/pulls/41"},
      "repository":{"full_name":"Acme/Docs"}},
     {"id":"103","reason":"team_mention","unread":true,"updated_at":"2033-05-18T02:00:00Z",
      "subject":{"title":"Archive old guides","type":"Issue","url":"https://api.github.com/repos/acme/docs/issues/7"},
      "repository":{"full_name":"acme/docs"}},
     {"id":"104","reason":"ci_activity","unread":true,"updated_at":"2033-05-18T01:00:00Z",
      "subject":{"title":"Build workflow run failed for main branch","type":"CheckSuite","url":null},
      "repository":{"full_name":"acme/api"}},
     {"id":"105","reason":"subscribed","unread":true,"updated_at":"2033-05-17T01:00:00Z",
      "subject":{"title":"v2.0","type":"Release","url":"https://api.github.com/repos/acme/api/releases/9"},
      "repository":{"full_name":"acme/api"}}]
    """

    private func pull(_ number: Int, failed: Int = 0, review: ReviewDecision? = nil, threads: Int = 0)
        -> PullRequest
    {
        PullRequest(
            ref: PullRef(repo: docs, number: number), title: "PR \(number)",
            url: "https://github.com/acme/docs/pull/\(number)", state: .open, isDraft: false,
            headBranch: "fix-\(number)", review: review, checks: CheckSummary(passed: 3, failed: failed),
            unresolvedThreads: threads, updatedAt: ago(Double(number))
        )
    }

    @Test func aThreadIsOneItemWithEveryReason() {
        var inbox = GitHub.parseNotifications(Data(notifications.utf8))
        inbox[2].teams = ["acme/docs-eng"]
        inbox[1].teams = ["acme/docs-all"]
        let issue = Issue(
            repo: docs, number: 7, title: "Archive old guides", url: "https://github.com/acme/docs/issues/7", body: "",
            labels: ["blocker"], author: "maria", updatedAt: ago(500), assigned: true
        )
        let items = AttentionFeed.items(
            github: GitHubState(viewer: "you", inbox: inbox, issues: [issue]), sessions: []
        )
        #expect(items.map(\.id) == ["acme/docs#41", "acme/docs#7", "ci:104", "release:105"])
        let pr = items[0]
        #expect(pr.reasons == [.reviewRequested, .mentioned])
        // The newer notification's title, and unread if either is.
        #expect(pr.title == "Validate anchors (v2)" && pr.unread)
        #expect(pr.notificationID == "101" && pr.teams == ["acme/docs-all"])
        let issueItem = items[1]
        #expect(issueItem.reasons == [.teamMention, .assigned])
        #expect(issueItem.teams == ["acme/docs-eng"] && issueItem.labels == ["blocker"] && issueItem.author == "maria")
        #expect(issueItem.notificationID == "103")
        #expect(items[2].kind == .ci && items[2].branch == "main" && items[2].reasons == [.ciFailed])
        #expect(items[3].kind == .release && items[3].reasons == [.subscribed])
    }

    @Test func yourPRsCarryWhatWantsYou() {
        let driven = pull(3, failed: 1)
        let github = GitHubState(pulls: [pull(1), pull(2, failed: 2, review: .changesRequested, threads: 1), driven])
        let items = AttentionFeed.items(github: github, sessions: [], pilotDriving: [driven.ref])
        let byNumber = Dictionary(uniqueKeysWithValues: items.map { ($0.number ?? 0, $0) })
        #expect(byNumber[1]?.reasons == [.yourPR] && byNumber[1]?.wantsYou == false)
        #expect(byNumber[2]?.reasons == [.yourPR, .ciFailed, .changesRequested, .unresolvedThreads])
        #expect(byNumber[2]?.branch == "fix-2" && byNumber[2]?.wantsYou == true)
        // The pilot is getting it green: its CI is not a reason here.
        #expect(byNumber[3]?.reasons == [.yourPR])
    }

    @Test func aPRReadyToMergeWithMergingOffWantsYou() {
        let ready = pull(5)
        let items = AttentionFeed.items(
            github: GitHubState(pulls: [ready, pull(6)]), sessions: [], readyToMerge: [ready.ref]
        )
        let byNumber = Dictionary(uniqueKeysWithValues: items.map { ($0.number ?? 0, $0) })
        #expect(byNumber[5]?.reasons == [.yourPR, .readyToMerge] && byNumber[5]?.wantsYou == true)
        #expect(byNumber[6]?.reasons == [.yourPR])
        #expect(AttentionReason.readyToMerge.text == "ready to merge")
        #expect(AttentionRules.reasonWords["mergeable"] == [.readyToMerge])
    }

    @Test func closedPRsAndWatchedIssuesStayOutOfNeedsMe() {
        var closed = pull(4)
        closed.state = .merged
        let watched = Issue(
            repo: docs, number: 9, title: "Typo", url: "https://github.com/acme/docs/issues/9", body: "", labels: [],
            author: nil, updatedAt: ago(1)
        )
        let items = AttentionFeed.items(github: GitHubState(issues: [watched], pulls: [closed]), sessions: [])
        #expect(items.map(\.id) == ["acme/docs#9"])
        #expect(items[0].reasons == [.watching] && !AttentionFilter.needsMe.matches(items[0]))
        #expect(AttentionFilter.issues.matches(items[0]))
    }

    @Test func agentsThatNeedYouAreItemsAndSessionsLinkTheirThreads() {
        let asking = Session(
            id: "s1", title: "Retry limits", repos: [api], branch: "retry", agent: "codex",
            state: ObservedState(.asking), trackedPRs: [PullRef(repo: docs, number: 1)], lastActivity: ago(3)
        )
        let working = Session(
            id: "s2", title: "Busy", repos: [api], branch: "b", agent: "claude", state: ObservedState(.working)
        )
        let limited = Session(
            id: "s3", title: "Slow", repos: [api], branch: "c", agent: "claude", state: ObservedState(.limited),
            lastActivity: ago(30)
        )
        let items = AttentionFeed.items(github: GitHubState(pulls: [pull(1)]), sessions: [asking, working, limited])
        #expect(items.map(\.id) == ["acme/docs#1", "agent:s1", "agent:s3"])
        #expect(items[1].reasons == [.agentAsking] && items[1].session == "s1" && items[1].agentState == .asking)
        #expect(items[2].reasons == [.agentLimited])
        #expect(items[0].session == "s1")
    }

    @Test func detailsFillWhatTheNotificationDoesNotSay() {
        let inbox = GitHub.parseNotifications(Data(notifications.utf8))
        let detail = ThreadDetail(
            url: "https://github.com/acme/docs/pull/41", author: "dependabot", authorIsBot: true, labels: ["deps"],
            isDraft: true, size: 120, comments: [ThreadDetail.Comment(author: "you", text: "ok", at: ago(9))],
            updatedAt: ago(0)
        )
        let items = AttentionFeed.items(
            github: GitHubState(inbox: inbox), sessions: [], details: [detail.url: detail]
        )
        let pr = items[0]
        #expect(pr.author == "dependabot" && pr.authorIsBot && pr.labels == ["deps"])
        #expect(pr.isDraft == true && pr.size == 120 && pr.lastCommenter == "you")
    }

    @Test func detailsAreAskedForWhenMissingOrOlderThanTheThread() {
        let items = AttentionFeed.items(
            github: GitHubState(inbox: GitHub.parseNotifications(Data(notifications.utf8)), pulls: [pull(1)]),
            sessions: []
        )
        let wanted = AttentionFeed.detailsNeeded(items, details: [:])
        // Issues and PRs that want you: not the CI run, the release, or a PR with only "your PR".
        #expect(wanted.map(\.url) == ["https://github.com/acme/docs/pull/41", "https://github.com/acme/docs/issues/7"])
        let fresh = ThreadDetail(url: "https://github.com/acme/docs/pull/41", updatedAt: items[0].updatedAt)
        let stale = ThreadDetail(url: "https://github.com/acme/docs/issues/7", updatedAt: .distantPast)
        let known = [fresh.url: fresh, stale.url: stale]
        #expect(AttentionFeed.detailsNeeded(items, details: known).map(\.url) == [
            "https://github.com/acme/docs/issues/7",
        ])
        #expect(AttentionFeed.detailsNeeded(items, details: [:], limit: 1).count == 1)
    }

    @Test func filters() {
        func item(_ kind: AttentionItem.Kind, _ reasons: Set<AttentionReason>) -> AttentionItem {
            AttentionItem(
                id: "x",
                kind: kind,
                repo: docs,
                number: 1,
                title: "",
                url: nil,
                reasons: reasons,
                updatedAt: now
            )
        }
        #expect(AttentionFilter.tagged.matches(item(.pr, [.teamMention])))
        #expect(AttentionFilter.tagged.matches(item(.issue, [.mentioned])))
        #expect(!AttentionFilter.tagged.matches(item(.pr, [.reviewRequested])))
        #expect(AttentionFilter.reviews.matches(item(.pr, [.reviewRequested])))
        #expect(AttentionFilter.myPRs.matches(item(.pr, [.yourPR])))
        #expect(!AttentionFilter.myPRs.matches(item(.pr, [.reviewRequested])))
        #expect(AttentionFilter.agents.matches(item(.agent, [.agentBlocked])))
        #expect(AttentionFilter.ci.matches(item(.ci, [.ciFailed])))
        #expect(AttentionFilter.issues.matches(item(.issue, [.watching])))
        #expect(AttentionFilter.needsMe.matches(item(.issue, [.subscribed])))
        #expect(!AttentionFilter.needsMe.matches(item(.pr, [.yourPR])))
    }

    @Test func marksHideUntilTheyNoLongerApply() {
        let item = AttentionItem(
            id: "x", kind: .pr, repo: docs, number: 1, title: "", url: nil, reasons: [.mentioned], updatedAt: ago(10)
        )
        #expect(!AttentionMark().hides(item, now: now))
        #expect(AttentionMark(mutedAt: ago(100)).hides(item, now: now))
        #expect(AttentionMark(snoozedUntil: now.addingTimeInterval(60)).hides(item, now: now))
        #expect(!AttentionMark(snoozedUntil: ago(1)).hides(item, now: now))
        #expect(AttentionMark(doneAt: ago(5)).hides(item, now: now))
        // Something happened after you were done: back.
        #expect(!AttentionMark(doneAt: ago(20)).hides(item, now: now))
        #expect(AttentionMark(doneAt: ago(10)).hides(item, now: now))
    }

    @Test func theDigestIsTheLastThreeCommentsOneLineEach() {
        let long = String(repeating: "a", count: 200)
        let detail = ThreadDetail(url: "u", comments: [
            .init(author: "a", text: "one", at: ago(4)), .init(author: "b", text: "two\nmore", at: ago(3)),
            .init(author: "c", text: long, at: ago(2)), .init(author: "d", text: "four", at: ago(1)),
        ], updatedAt: now)
        #expect(detail.digest.count == 3)
        #expect(detail.digest[0] == "b: two")
        #expect(detail.digest[1].count == 3 + 120 && detail.digest[1].hasSuffix("…"))
        #expect(detail.digest[2] == "d: four" && detail.lastCommenter == "d")
        #expect(ThreadDetail(url: "u", author: "o", updatedAt: now).lastCommenter == "o")
    }
}

struct ThreadDetailParsingTests {
    @Test func detailsFromAResourceLookup() {
        let asked = [
            (url: "https://github.com/acme/docs/pull/41", updatedAt: Date(timeIntervalSince1970: 0)),
            (url: "https://github.com/acme/docs/issues/7", updatedAt: Date(timeIntervalSince1970: 5)),
            (url: "https://github.com/secret/x/issues/1", updatedAt: Date(timeIntervalSince1970: 5)),
        ]
        let json = """
        {"data":{"r0":{"url":"https://github.com/acme/docs/pull/41","updatedAt":"2033-05-18T03:20:00Z",
          "author":{"__typename":"Bot","login":"dependabot"},"labels":{"nodes":[{"name":"deps"}]},"bodyText":"Bumps x",
          "comments":{"nodes":[{"author":{"login":"maria"},"bodyText":"looks fine","createdAt":"2033-05-18T03:00:00Z"}]},
          "isDraft":false,"additions":10,"deletions":4,"headRefName":"bump-x",
          "reviews":{"nodes":[{"author":{"login":"you"},"bodyText":"","state":"CHANGES_REQUESTED","submittedAt":"2033-05-18T03:10:00Z"},
                              {"author":null,"bodyText":"","state":"COMMENTED","submittedAt":"2033-05-18T02:00:00Z"}]}},
         "r1":{"url":"https://github.com/acme/docs/issues/7","updatedAt":"1970-01-01T00:00:01Z",
          "author":{"__typename":"User","login":"maria"},"labels":{"nodes":[]},"bodyText":"Old guides","comments":{"nodes":[]}},
         "r2":null},
         "errors":[{"type":"FORBIDDEN","extensions":{"saml_failure":true}}]}
        """
        let details = GitHub.parseThreadDetails(Data(json.utf8), asked: asked)
        #expect(details.count == 3)
        let pr = details[0]
        #expect(pr.author == "dependabot" && pr.authorIsBot && pr.labels == ["deps"] && pr.isDraft == false)
        #expect(pr.size == 14 && pr.headBranch == "bump-x" && pr.body == "Bumps x")
        // Comments and reviews together, oldest first; a review without text says what it was.
        #expect(pr.comments.map(\.author) == ["ghost", "maria", "you"])
        #expect(pr.comments.last?.text == "changes requested")
        #expect(pr.updatedAt == GitHub.date("2033-05-18T03:20:00Z"))
        let issue = details[1]
        #expect(issue.author == "maria" && !issue.authorIsBot && issue.size == nil && issue.isDraft == nil)
        // Asked for at 5s, GitHub says 1s: kept at what was asked, so it is not asked again.
        #expect(issue.updatedAt == Date(timeIntervalSince1970: 5))
        #expect(details[2] == ThreadDetail(url: "https://github.com/secret/x/issues/1", updatedAt: asked[2].updatedAt))
    }

    @Test func oneLookupPerURL() {
        let query = GitHub.threadDetailsQuery(count: 2)
        #expect(query.hasPrefix("query($u0: URI!, $u1: URI!) {"))
        #expect(query.contains("r1: resource(url: $u1) { ... on Issue {"))
        #expect(query.contains("... on PullRequest {"))
    }
}

struct AttentionStoreTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func store() throws -> AttentionStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heed-attention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try AttentionStore(path: dir.appendingPathComponent("attention.sqlite").path)
    }

    private func item(_ id: String, updated: Date, reasons: Set<AttentionReason> = [.mentioned]) -> AttentionItem {
        AttentionItem(
            id: id, kind: .issue, repo: Repo(org: "acme", name: "docs"), number: 1, title: id, url: nil,
            reasons: reasons, updatedAt: updated
        )
    }

    @Test func itemsAreKeptWithTheirFirstSighting() async throws {
        let store = try store()
        try await store.record([item("a", updated: now)], now: now)
        try await store.record(
            [item("a", updated: now.addingTimeInterval(60), reasons: [.assigned]), item("b", updated: now)],
            now: now.addingTimeInterval(120)
        )
        let kept = try await store.items(now: now.addingTimeInterval(120))
        #expect(kept.map(\.item.id) == ["a", "b"])
        #expect(kept[0].firstSeen == now && kept[0].lastSeen == now.addingTimeInterval(120))
        #expect(kept[0].item.reasons == [.assigned])
    }

    @Test func thirtyDaysThenGoneWithTheirMarks() async throws {
        let store = try store()
        try await store.record([item("old", updated: now)], now: now)
        let later = now.addingTimeInterval(AttentionStore.retention + 60)
        try await store.record([item("new", updated: later)], now: later)
        try await store.setMark(AttentionMark(mutedAt: now), for: "old")
        try await store.setMark(AttentionMark(doneAt: later), for: "new")
        try await store.saveSummary("s", for: "old", updatedAt: now)
        try await store.saveDetails([ThreadDetail(url: "https://x/1", updatedAt: now)], now: now)
        #expect(try await store.items(now: later).map(\.item.id) == ["new"])
        try await store.prune(now: later)
        #expect(try await store.items(since: .distantPast).map(\.item.id) == ["new"])
        #expect(try await store.marks() == ["new": AttentionMark(doneAt: later)])
        #expect(try await store.summary(for: "old", updatedAt: now) == nil)
        #expect(try await store.details().isEmpty)
    }

    @Test func marksSetAndClear() async throws {
        let store = try store()
        let mark = AttentionMark(doneAt: now, snoozedUntil: now.addingTimeInterval(3600))
        try await store.setMark(mark, for: "a")
        #expect(try await store.marks() == ["a": mark])
        try await store.setMark(AttentionMark(), for: "a")
        #expect(try await store.marks().isEmpty)
    }

    @Test func detailsAndSummariesByUpdate() async throws {
        let store = try store()
        let detail = ThreadDetail(url: "https://github.com/Acme/Docs/pull/41", author: "maria", updatedAt: now)
        try await store.saveDetails([detail], now: now)
        #expect(try await store.details() == ["https://github.com/acme/docs/pull/41": detail])
        try await store.saveSummary("Asks one thing.", for: "acme/docs#41", updatedAt: now)
        #expect(try await store.summary(for: "acme/docs#41", updatedAt: now) == "Asks one thing.")
        // A newer update has no summary yet.
        #expect(try await store.summary(for: "acme/docs#41", updatedAt: now.addingTimeInterval(1)) == nil)
    }
}
