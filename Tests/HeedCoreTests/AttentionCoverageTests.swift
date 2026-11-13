import Foundation
@testable import HeedCore
import Testing

/// Reading every notification and every page of the issue searches, and merging what came into what heed had.
struct NotificationFetchTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let docs = Repo(org: "acme", name: "docs")

    private func note(_ id: String, unread: Bool = true, daysAgo: Double = 0, reason: String = "comment") -> InboxItem {
        InboxItem(
            id: id, kind: .issue, repo: docs, number: Int(id) ?? 1, title: "Thread \(id)", reason: reason,
            unread: unread, updatedAt: now.addingTimeInterval(-daysAgo * 86400), url: nil
        )
    }

    @Test func pagesAreReadUntilOneIsShortOrTheCapIsReached() async throws {
        var asked: [Int] = []
        let three = try await GitHub.pages(perPage: 2, cap: 10) { page in
            asked.append(page)
            return page < 2 ? [page, page] : [page]
        }
        #expect(three.items == [1, 1, 2] && !three.capped && asked == [1, 2])
        // A full last page at the cap: GitHub may have more, and that is said.
        let capped = try await GitHub.pages(perPage: 2, cap: 4) { page in [page, page] }
        #expect(capped.items == [1, 1, 2, 2] && capped.capped)
        let empty = try await GitHub.pages(perPage: 2, cap: 4) { _ in [Int]() }
        #expect(empty.items.isEmpty && !empty.capped)
    }

    @Test func aThreadReadElsewhereStaysReadInsteadOfVanishing() {
        let previous = [note("1"), note("2"), note("3", unread: false, daysAgo: 2)]
        // GitHub's unread set no longer has 2: it was read on the phone. 4 is new, 5 arrived and was read meanwhile.
        let merged = GitHub.mergeNotifications(
            previous: previous, unread: [note("1"), note("4")], unreadComplete: true,
            recent: [note("5", unread: false)], now: now
        )
        let byID = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
        #expect(Set(byID.keys) == ["1", "2", "3", "4", "5"])
        #expect(byID["1"]?.unread == true && byID["4"]?.unread == true)
        #expect(byID["2"]?.unread == false && byID["3"]?.unread == false && byID["5"]?.unread == false)
    }

    @Test func aCappedUnreadFetchSaysNothingAboutWhatItDidNotReach() {
        let merged = GitHub.mergeNotifications(
            previous: [note("1"), note("2")], unread: [note("1")], unreadComplete: false, recent: [], now: now
        )
        #expect(merged.allSatisfy(\.unread) && merged.count == 2)
    }

    @Test func readThreadsLeaveAfterThirtyDaysUnreadOnesStayAndTeamsAreKept() {
        var known = note("7", reason: "team_mention")
        known.teams = ["acme/docs-eng"]
        let merged = GitHub.mergeNotifications(
            previous: [note("1", unread: false, daysAgo: 31), note("2", unread: true, daysAgo: 60), known],
            unread: [note("2", daysAgo: 60), note("7", reason: "team_mention")], unreadComplete: true, recent: [],
            now: now
        )
        #expect(merged.map(\.id) == ["7", "2"])
        #expect(merged[0].teams == ["acme/docs-eng"])
    }

    private func searchPage(_ numbers: [Int], next: String?, total: Int) -> Data {
        let nodes = numbers.map {
            #"{"number":\#($0),"title":"T","url":"u","bodyText":"","updatedAt":"2033-05-18T03:20:00Z","#
                + #""createdAt":"2032-01-02T00:00:00Z","repository":{"nameWithOwner":"o/r"}}"#
        }.joined(separator: ",")
        let info = next.map { #"{"hasNextPage":true,"endCursor":"\#($0)"}"# } ?? #"{"hasNextPage":false}"#
        return Data(#"{"data":{"search":{"issueCount":\#(total),"pageInfo":\#(info),"nodes":[\#(nodes)]}}}"#.utf8)
    }

    @Test func issueSearchesFollowTheCursorUpToTheCap() async throws {
        var cursors: [String?] = []
        let all = try await GitHub.searchPages(cap: 10) { cursor in
            cursors.append(cursor)
            return cursor == nil ? searchPage([1, 2], next: "c1", total: 3) : searchPage([3], next: nil, total: 3)
        }
        #expect(cursors == [nil, "c1"])
        #expect(all.issues.map(\.number) == [1, 2, 3] && all.total == 3 && !all.capped)
        #expect(all.issues[0].createdAt == Date(timeIntervalSince1970: 1_956_614_400))
        let capped = try await GitHub.searchPages(cap: 2) { cursor in
            searchPage(cursor == nil ? [1, 2] : [3, 4], next: "more", total: 9)
        }
        #expect(capped.issues.count == 2 && capped.capped)
        #expect(capped.fetch(at: now).dropped == 7)
    }
}

/// Old mentions fold, `user:me` boosts only fresh ones, and done holds against your own activity and bots'.
struct AttentionNeedsYouTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let docs = Repo(org: "acme", name: "docs")

    private func days(_ count: Double) -> Date { now.addingTimeInterval(-count * 86400) }

    private func issue(_ number: Int, opened: Double?, updated: Double = 0.1, mentioned: Bool = true) -> HeedCore
        .Issue
    {
        HeedCore.Issue(
            repo: docs, number: number, title: "Issue \(number)", url: "https://github.com/acme/docs/issues/\(number)",
            body: "", labels: [], author: "maria", updatedAt: days(updated), createdAt: opened.map { days($0) },
            assigned: !mentioned, mentioned: mentioned
        )
    }

    private func items(_ github: GitHubState) -> [String: AttentionItem] {
        Dictionary(uniqueKeysWithValues: AttentionFeed.items(github: github, sessions: [], now: now)
            .map { ($0.id, $0) })
    }

    @Test func aSearchOnlyMentionFromBeforeFoldsAFreshOneDoesNot() {
        let found = items(GitHubState(viewer: "you", issues: [
            issue(1, opened: 400), issue(2, opened: 3), issue(3, opened: 400, mentioned: false),
            issue(4, opened: 2, mentioned: false), issue(5, opened: nil, updated: 20), issue(6, opened: nil),
        ]))
        #expect(found["acme/docs#1"]?.reasons == [.mentionedBefore])
        #expect(found["acme/docs#2"]?.reasons == [.mentioned])
        #expect(found["acme/docs#3"]?.reasons == [.assignedBefore])
        #expect(found["acme/docs#4"]?.reasons == [.assigned])
        // A cache from before heed asked when it was opened goes by its last update.
        #expect(found["acme/docs#5"]?.reasons == [.mentionedBefore])
        #expect(found["acme/docs#6"]?.reasons == [.mentioned])
        // Folded: out of For you, still under Mentions.
        #expect(found["acme/docs#1"]?.wantsYou == false && found["acme/docs#3"]?.wantsYou == false)
        #expect(AttentionFilter.mentions.matches(found["acme/docs#1"]!))
        #expect(!found["acme/docs#1"]!.wantsYou)
    }

    @Test func theFourteenDayWindowEndsAtFourteenDays() {
        let found = items(GitHubState(issues: [issue(1, opened: 13.9), issue(2, opened: 14.1)]))
        #expect(found["acme/docs#1"]?.reasons == [.mentioned] && found["acme/docs#2"]?.reasons == [.mentionedBefore])
    }

    @Test func aNotificationThatSaysMentionKeepsItFresh() {
        let mention = InboxItem(
            id: "9", kind: .issue, repo: docs, number: 1, title: "Issue 1", reason: "mention", unread: false,
            updatedAt: days(1), url: nil
        )
        let comment = InboxItem(
            id: "10", kind: .issue, repo: docs, number: 2, title: "Issue 2", reason: "comment", unread: true,
            updatedAt: days(1), url: nil
        )
        let found = items(GitHubState(
            inbox: [mention, comment],
            issues: [issue(1, opened: 400), issue(2, opened: 400)]
        ))
        #expect(found["acme/docs#1"]?.reasons == [.mentioned])
        // Something new in an old mention's thread wants you for that, not for the old mention.
        #expect(found["acme/docs#2"]?.reasons == [.comment, .mentionedBefore])
    }

    @Test func aReadNotificationStaysOnlyWhileItAsksSomethingOfYou() {
        func read(_ id: String, _ reason: String) -> InboxItem {
            InboxItem(
                id: id, kind: .pr, repo: docs, number: Int(id)!, title: "", reason: reason, unread: false,
                updatedAt: days(1), url: nil
            )
        }
        let found = items(GitHubState(inbox: [
            read("1", "review_requested"), read("2", "mention"), read("3", "comment"), read("4", "subscribed"),
        ]))
        #expect(Set(found.keys) == ["acme/docs#1", "acme/docs#2"])
    }

    @Test func mentionUserMeBoostsOnlyAFreshMention() {
        let rules = AttentionRules(lines: ["mention user:me boost 3", "mention boost 1"])
        let found = items(GitHubState(issues: [issue(1, opened: 400), issue(2, opened: 1)]))
        let old = rules.outcome(for: found["acme/docs#1"]!, viewer: "you", now: now)
        let fresh = rules.outcome(for: found["acme/docs#2"]!, viewer: "you", now: now)
        #expect(fresh.action.boost == 3 && fresh.rule?.line == 1)
        // `mention` still matches the old one; `user:me` does not.
        #expect(old.action.boost == 1 && old.rule?.line == 2)
        #expect(AttentionRules(lines: ["assigned ignore"]).outcome(
            for: items(GitHubState(issues: [issue(3, opened: 400, mentioned: false)]))["acme/docs#3"]!,
            viewer: "you", now: now
        ).action.ignore)
    }

    // MARK: Done

    private func thread(
        _ reasons: Set<AttentionReason>, updated: Date, unread: Bool = false, activity: ThreadActivity? = nil,
        kind: AttentionItem.Kind = .pr
    ) -> AttentionItem {
        AttentionItem(
            id: "acme/docs#1", kind: kind, repo: docs, number: 1, title: "", url: nil, reasons: reasons,
            updatedAt: updated, notificationID: "n1", unread: unread, activity: activity
        )
    }

    @Test func yourOwnCommentOrPushDoesNotUndoDone() {
        let done = days(1)
        // You commented: the details say nobody else spoke since, and GitHub sent nothing.
        #expect(!AttentionActivity.isNew(thread([.mentioned], updated: days(0.5), activity: .init()), since: done))
        // A push: no comment at all, and no details for the update yet.
        #expect(!AttentionActivity.isNew(thread([.yourPR, .changesRequested], updated: days(0.5)), since: done))
        // Nothing since.
        #expect(!AttentionActivity.isNew(thread([.mentioned], updated: done, unread: true), since: done))
    }

    @Test func someoneElsesCommentOrANotificationDoes() {
        let done = days(1)
        let other = ThreadActivity(others: days(0.5))
        #expect(AttentionActivity.isNew(thread([.mentioned], updated: days(0.5), activity: other), since: done))
        // A comment from before you were done is no news.
        let before = ThreadActivity(others: days(2))
        #expect(!AttentionActivity.isNew(thread([.mentioned], updated: days(0.5), activity: before), since: done))
        // GitHub never notifies you of what you did: an unread notification is someone else.
        #expect(AttentionActivity.isNew(thread([.mentioned], updated: days(0.5), unread: true), since: done))
    }

    @Test func aBotIsNewsOnlyForChecksAndReviews() {
        let done = days(1)
        let bot = ThreadActivity(bots: days(0.5))
        #expect(!AttentionActivity.isNew(
            thread([.mentioned], updated: days(0.5), unread: true, activity: bot),
            since: done
        ))
        #expect(AttentionActivity.isNew(thread([.reviewRequested], updated: days(0.5), activity: bot), since: done))
        #expect(AttentionActivity.isNew(thread([.yourPR, .ciFailed], updated: days(0.5), activity: bot), since: done))
    }

    @Test func threadsWithoutDetailsAndHeedsOwnItemsComeBackOnAnyUpdate() {
        let done = days(1)
        #expect(AttentionActivity.isNew(thread([.ciFailed], updated: days(0.5), kind: .ci), since: done))
        #expect(AttentionActivity.isNew(thread([.agentAsking], updated: days(0.5), kind: .agent), since: done))
        #expect(AttentionMark(doneAt: done).hides(thread([.mentioned], updated: days(0.5)), now: now))
        #expect(!AttentionMark(doneAt: done).hides(thread([.mentioned], updated: days(0.5), unread: true), now: now))
    }

    @Test func activityComesFromCurrentDetailsBotsByTypeOrLogin() {
        let detail = ThreadDetail(
            url: "u", comments: [
                .init(author: "You", text: "pushed a fix", at: days(0.3)),
                .init(author: "github-actions", text: "Deployed", at: days(0.2), isBot: true),
                .init(author: "renovate[bot]", text: "Rebased", at: days(0.25)),
                .init(author: "maria", text: "Thanks", at: days(0.4)),
            ],
            updatedAt: days(0.2)
        )
        let activity = ThreadActivity.of(detail, viewer: "you", updatedAt: days(0.2))
        #expect(activity == ThreadActivity(others: days(0.4), bots: days(0.2)))
        // Details older than the update cannot say who made it.
        #expect(ThreadActivity.of(detail, viewer: "you", updatedAt: days(0.1)) == nil)
        // Through the feed: the item carries it.
        let item = AttentionFeed.items(
            github: GitHubState(viewer: "you", issues: [issue(1, opened: 1, updated: 0.2)]), sessions: [],
            details: ["https://github.com/acme/docs/issues/1": detail], now: now
        )[0]
        #expect(item.activity == activity)
    }

    @Test func detailsFromBeforeBotsWereAskedStillLoad() throws {
        let json = #"{"author":"maria","text":"hi","at":0}"#
        let comment = try JSONDecoder().decode(ThreadDetail.Comment.self, from: Data(json.utf8))
        #expect(comment.author == "maria" && !comment.isBot)
    }
}

struct AttentionCoverageTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let docs = Repo(org: "acme", name: "docs")

    private func note(_ number: Int, reason: String = "comment") -> InboxItem {
        InboxItem(
            id: "n\(number)", kind: .issue, repo: docs, number: number, title: "", reason: reason, unread: true,
            updatedAt: now.addingTimeInterval(-600), url: nil
        )
    }

    private func issue(_ number: Int, old: Bool = true, assigned: Bool = false) -> HeedCore.Issue {
        HeedCore.Issue(
            repo: docs, number: number, title: "", url: "", body: "", labels: [], author: nil,
            updatedAt: now.addingTimeInterval(-3600), createdAt: now.addingTimeInterval(old ? -400 * 86400 : -3600),
            assigned: assigned, mentioned: !assigned
        )
    }

    private func coverage(
        _ github: GitHubState, rules: [String] = [], marks: [String: AttentionMark] = [:]
    ) -> AttentionCoverage {
        let items = AttentionFeed.items(github: github, sessions: [], now: now)
        let entries = AttentionRanking.entries(
            live: items, rules: AttentionRules(lines: rules), marks: marks, viewer: "you", now: now
        )
        return AttentionCoverage.of(github: github, entries: entries, now: now)
    }

    private func all(_ count: Int) -> SourceFetch {
        SourceFetch(fetched: count, total: count, capped: false, at: now.addingTimeInterval(-120))
    }

    @Test func everythingFetchedSaysSoInOneLine() {
        var github = GitHubState(
            inbox: [note(1), note(2), note(3), note(4, reason: "mention")],
            issues: [issue(10), issue(11), issue(4, old: false), issue(12, assigned: true)]
        )
        github.fetches = GitHubFetches(notifications: all(4), mentions: all(3), assigned: all(1), pulls: all(0))
        let result = coverage(
            github, marks: ["acme/docs#2": AttentionMark(mutedAt: now), "acme/docs#3": AttentionMark(doneAt: now)]
        )
        #expect(!result.mismatch)
        #expect(result.line == "4 of 4 unread from GitHub · 3 old mentions and assignments folded · 1 muted")
        let notes = result.row(.notifications)
        #expect(notes?.count(.listed) == 2 && notes?.count(.muted) == 1 && notes?.count(.done) == 1)
        let mentions = result.row(.mentions)
        #expect(mentions?.count(.folded) == 2 && mentions?.count(.listed) == 1)
        #expect(result.row(.assigned)?.count(.folded) == 1)
        #expect(result
            .table(now: now)[0] == "Notifications: 4 of 4 unread · 2 in For you · 1 done · 1 muted · fetched 2m ago")
        #expect(result.table(now: now)[1] == "Mentions: 3 of 3 open · 1 in For you · 2 folded · fetched 2m ago")
    }

    @Test func aCapOrSAMLIsAMismatch() {
        var github = GitHubState(inbox: [note(1)], issues: [issue(10)])
        github.fetches = GitHubFetches(
            notifications: SourceFetch(fetched: 500, total: nil, capped: true, at: now),
            mentions: SourceFetch(fetched: 200, total: 254, capped: true, at: now), assigned: all(0)
        )
        let capped = coverage(github)
        #expect(capped.mismatch)
        #expect(capped.line.hasPrefix("500 of 500+ unread from GitHub, stopped at the cap · mentions 200 of 254"))
        #expect(capped.table(now: now)[1].contains("54 past the cap of 200"))

        var hidden = GitHubState(inbox: [note(1)], status: .partial(hidden: 2, note: ""))
        hidden.fetches = GitHubFetches(notifications: all(1))
        #expect(coverage(hidden).mismatch && coverage(hidden).line == "1 of 1 unread from GitHub · 2 hidden by SAML")
        hidden.status = .ok
        #expect(!coverage(hidden).mismatch)
    }

    @Test func ruleIgnoredAndMutedCountApart() {
        var github = GitHubState(inbox: [note(1), note(2)])
        github.fetches = GitHubFetches(notifications: all(2))
        let result = coverage(
            github,
            rules: ["repo acme/docs ignore"],
            marks: ["acme/docs#2": AttentionMark(mutedAt: now)]
        )
        #expect(result.row(.notifications)?.count(.hiddenByRule) == 1 && result.row(.notifications)?.count(.muted) == 1)
        #expect(result.line == "2 of 2 unread from GitHub · 2 muted")
    }
}
