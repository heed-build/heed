import Foundation
@testable import HeedCore
import Testing

struct AttentionListingTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    private func item(
        _ id: String, _ reasons: Set<AttentionReason>, kind: AttentionItem.Kind = .pr, minutes: Double = 5,
        unread: Bool = false, others: Double? = nil
    ) -> AttentionItem {
        AttentionItem(
            id: id, kind: kind, repo: Repo(org: "acme", name: "docs"), number: 1, title: id, url: nil,
            reasons: reasons, updatedAt: ago(minutes), notificationID: unread ? "n-\(id)" : nil, unread: unread,
            activity: others.map { ThreadActivity(others: ago($0)) }
        )
    }

    private func entries(_ items: [AttentionItem], marks: [String: AttentionMark] = [:]) -> [AttentionEntry] {
        AttentionRanking.entries(live: items, rules: AttentionRules(lines: []), marks: marks, viewer: "you", now: now)
    }

    // MARK: Tabs

    @Test func oldNamesStillOpenTheirTab() {
        #expect(AttentionFilter.named("needs") == .forYou)
        #expect(AttentionFilter.named("tagged") == .mentions)
        #expect(AttentionFilter.named("inbox") == .everything)
        #expect(AttentionFilter.named("mine") == .myPRs)
        #expect(AttentionFilter.named("issues") == .issues)
        #expect(AttentionFilter.named("For you") == .forYou)
        #expect(AttentionFilter.named("My PRs") == .myPRs)
        #expect(AttentionFilter.named("nonsense") == nil)
        // t steps through the tabs, then Muted; CI and Issues are reached by name only.
        #expect(AttentionFilter.cycle == [.forYou, .reviews, .mentions, .myPRs, .agents, .everything, .muted])
    }

    @Test func everythingListsWhatTheOtherTabsLeaveOut() {
        let all = entries([
            item("watch", [.watching], kind: .issue), item("mine", [.yourPR]), item("review", [.reviewRequested]),
        ])
        #expect(AttentionListing.of(all, filter: .everything, seen: AttentionSeen(), now: now).rows.count == 3)
        #expect(AttentionListing.of(all, filter: .forYou, seen: AttentionSeen(), now: now).rows.map(\.id)
            == ["review"])
    }

    // MARK: For you's sections

    @Test func newWaitingAndFoldedBefore() {
        let seen = AttentionSeen(threads: ["read": ago(10)], leftAt: ago(60))
        let all = entries([
            // Someone else commented after you left Attention: new.
            item("fresh", [.reviewRequested], minutes: 3, others: 3),
            // You read it after the last comment: waiting, as the review is still asked.
            item("read", [.reviewRequested], minutes: 20, others: 20),
            // Changed before you left, nothing since: waiting.
            item("asked", [.assigned], kind: .issue, minutes: 90),
            // Only news (a comment notification) you have seen: For you lets it go, Everything keeps it.
            item("news", [.comment], minutes: 90, unread: true),
            // An old mention: folded.
            item("old", [.mentionedBefore], kind: .issue, minutes: 1),
        ])
        let listing = AttentionListing.of(all, filter: .forYou, seen: seen, now: now)
        #expect(listing.ids(.new) == ["fresh"])
        #expect(listing.ids(.waiting) == ["read", "asked"])
        #expect(listing.section(.before)?.total == 1 && listing.section(.before)?.folded == true)
        #expect(listing.rows.map(\.id) == ["fresh", "read", "asked"])
        #expect(listing.sections(startingAt: 3).map(\.kind) == [.before])

        let unfolded = AttentionListing.of(all, filter: .forYou, seen: seen, unfoldBefore: true, now: now)
        #expect(unfolded.rows.map(\.id) == ["fresh", "read", "asked", "old"])
        #expect(unfolded.ids(.before) == ["old"])

        let counts = AttentionListing.counts(all, seen: seen, now: now)
        #expect(counts[.forYou] == 3)
        #expect(counts[.everything] == 5)
    }

    @Test func neverLookedMeansNewWhenSomeoneElseIsInIt() {
        let all = entries([
            item("talked", [.reviewRequested], others: 5),
            // Your own PR with changes requested and no notification: nothing says someone else spoke.
            item("yours", [.changesRequested, .yourPR]),
            item("agent", [.agentAsking], kind: .agent),
        ])
        let listing = AttentionListing.of(all, filter: .forYou, seen: AttentionSeen(), now: now)
        #expect(listing.ids(.new) == ["agent", "talked"])
        #expect(listing.ids(.waiting) == ["yours"])
    }

    @Test func doneLeavesTheSectionsAndSnoozedToo() {
        let all = entries(
            [item("done", [.reviewRequested], others: 5), item("kept", [.reviewRequested], others: 5)],
            marks: ["done": AttentionMark(doneAt: now)]
        )
        #expect(AttentionListing.of(all, filter: .forYou, seen: AttentionSeen(), now: now).ids(.new) == ["kept"])
    }

    @Test func otherTabsAreOneSection() {
        let listing = AttentionListing.of(
            entries([item("r", [.reviewRequested])]), filter: .reviews, seen: AttentionSeen(), now: now
        )
        #expect(listing.sections.map(\.kind) == [.all])
        #expect(listing.rows.map(\.id) == ["r"])
    }

    // MARK: Seen

    @Test func sinceIsTheLaterOfTheThreadAndAttention() {
        let seen = AttentionSeen(threads: ["a": ago(5), "b": ago(90)], leftAt: ago(60))
        #expect(seen.since("a") == ago(5))
        #expect(seen.since("b") == ago(60))
        #expect(seen.since("c") == ago(60))
        #expect(AttentionSeen(threads: ["a": ago(5)]).since("a") == ago(5))
        #expect(AttentionSeen().since("a") == nil)
    }

    @Test func passingOverIsNotReading() {
        let shown = AttentionVisit(id: "a", startedAt: now)
        #expect(shown.seen(leavingAt: now.addingTimeInterval(0.5)) == nil)
        #expect(shown.seen(leavingAt: now.addingTimeInterval(AttentionVisit.dwell)) == now)
        var opened = shown
        opened.opened = true
        #expect(opened.seen(leavingAt: now.addingTimeInterval(0.1)) == now)
    }

    // MARK: Preview

    @Test func previewIsTheSummaryElseTheNewCommentElseNothingNew() {
        let pr = item("p", [.reviewRequested])
        let detail = ThreadDetail(
            url: "u", comments: [.init(author: "reviewer", text: "One question\nmore", at: ago(1))], updatedAt: now
        )
        #expect(AttentionPreview.of(pr, detail: detail, summary: "S\nmore", isNew: true, seenAt: ago(9))
            == .summary("S"))
        #expect(AttentionPreview.of(pr, detail: detail, summary: nil, isNew: true, seenAt: ago(9))
            == .comment(author: "reviewer", text: "One question"))
        #expect(AttentionPreview.of(pr, detail: detail, summary: "S", isNew: false, seenAt: ago(9))
            == .nothingNew(since: ago(9)))
        #expect(AttentionPreview.of(pr, detail: nil, summary: nil, isNew: true, seenAt: nil) == nil)
    }

    // MARK: Coverage agrees with Muted

    @Test func theLinesMutedCountIsTheMutedTabs() {
        let live = [item("muted", [.comment], unread: true)]
        let remembered = [item("gone", [.comment], minutes: 3000)]
        let all = AttentionRanking.entries(
            live: live, stored: remembered, rules: AttentionRules(lines: []),
            marks: ["muted": AttentionMark(mutedAt: now), "gone": AttentionMark(mutedAt: ago(4000))], viewer: "you",
            now: now
        )
        let coverage = AttentionCoverage.of(github: GitHubState(), entries: all, now: now)
        let tab = AttentionListing.counts(all, seen: AttentionSeen(), now: now)[.muted]
        #expect(coverage.muted == 2 && tab == 2)
        #expect(coverage.line.hasSuffix("2 muted"))
    }
}

struct AttentionSeenStoreTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func seenKeepsTheLaterTimeAndLeftIsRemembered() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heed-seen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("attention.sqlite").path
        let store = try AttentionStore(path: path)
        try await store.setSeen("a", at: now)
        try await store.setSeen("a", at: now.addingTimeInterval(-60))
        try await store.setLeft(at: now.addingTimeInterval(30))
        #expect(try await store.seen() == AttentionSeen(threads: ["a": now], leftAt: now.addingTimeInterval(30)))
        // A thread no longer kept goes with the items.
        try await store.prune(now: now)
        #expect(try await store.seen().threads.isEmpty)
        // Reopened: the same.
        let again = try AttentionStore(path: path)
        #expect(try await again.seen().leftAt == now.addingTimeInterval(30))
    }
}
