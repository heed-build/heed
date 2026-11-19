import Foundation
@testable import HeedCore
import Testing

/// The brief's table, row by row.
struct BrowseVerbsTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let docs = Repo(org: "acme", name: "docs")

    private func issue(
        _ number: Int = 1, state: BrowseItem.State = .open, linked: Bool = false, author: String = "mara"
    ) -> BrowseItem {
        BrowseItem(
            repo: docs, number: number, title: ExternalText("An issue", source: .issueTitle, author: .unknown),
            state: state, author: author, updatedAt: now, hasLinkedPull: linked
        )
    }

    private func pull(
        state: BrowseItem.State = .open, author: String = "bot", checks: BrowseItem.Checks? = .passing,
        review: ReviewDecision? = nil, requested: [String]? = nil, draft: Bool = false
    ) -> BrowseItem {
        BrowseItem(
            repo: docs, number: 9, kind: .pull,
            title: ExternalText("A pull", source: .pullTitle, author: .unknown), state: state, author: author,
            updatedAt: now, isDraft: draft, checks: checks, review: review, requestedReviewers: requested
        )
    }

    private func read(
        _ item: BrowseItem, _ kind: BrowseClass, ready: Int, size: BrowseSize = .s, readAt: Date? = nil
    ) -> BrowseRead {
        BrowseRead(
            itemID: item.id, kind: kind, size: size, agentReady: ready, tldr: "t", readAt: readAt ?? now,
            itemUpdatedAt: item.updatedAt
        )
    }

    private func verbs(_ item: BrowseItem, _ read: BrowseRead?, viewer: String? = "you") -> BrowseVerbs {
        BrowseVerbs.recommend(item: item, read: read, viewer: viewer)
    }

    @Test func everyVerbIsAlwaysAnswered() {
        let item = issue()
        for read in [nil, read(item, .bug, ready: 90), read(item, .question, ready: 10)] {
            let answer = verbs(item, read)
            #expect(answer.advice.map(\.verb) == [.fix, .implement, .chat, .review])
            #expect(answer.advice.allSatisfy { !$0.reason.isEmpty })
            #expect(answer.advice.count(where: { $0.availability == .recommended }) <= 1)
        }
    }

    @Test func aClearSmallBugWithNoPullRequestIsFix() {
        let item = issue()
        let answer = verbs(item, read(item, .bug, ready: 82))
        #expect(answer.recommended?.verb == .fix)
        #expect(answer[.fix].reason == "Clear bug, small, no PR yet")
        #expect(answer[.implement].availability == .unavailable)
        #expect(answer[.implement].reason == "Not a feature, so Fix fits better here.")
        #expect(answer[.chat].availability == .available)
        #expect(answer[.review].availability == .unavailable)
        #expect(answer[.review].reason == "No pull request linked to this issue yet.")
        #expect(answer.headline == "Clear bug, small, no PR yet")
    }

    @Test func aBugBetween50And70IsStillFixButSaysItIsLikely() {
        let item = issue()
        let answer = verbs(item, read(item, .bug, ready: 64))
        #expect(answer.recommended?.verb == .fix)
        #expect(answer[.fix].reason == "Likely a bug, 64% agent-ready, no PR yet")
        #expect(verbs(item, read(item, .bug, ready: 50)).recommended?.verb == .fix)
    }

    @Test func aBugUnder50NeedsADecisionFirstSoChatLeads() {
        let item = issue()
        let answer = verbs(item, read(item, .bug, ready: 48))
        #expect(answer.recommended?.verb == .chat)
        #expect(answer.headline == "Needs a decision first, only 48% agent-ready")
        #expect(answer[.fix].availability == .available)
        #expect(answer[.fix].reason == "Possible, but heed would be guessing the design.")
        #expect(verbs(item, read(item, .bug, ready: 49)).recommended?.verb == .chat)
    }

    @Test func aFeatureDocsOrChoreIsImplementWhenClear() {
        let item = issue()
        for kind in [BrowseClass.feature, .docs, .chore] {
            let answer = verbs(item, read(item, kind, ready: 88))
            #expect(answer.recommended?.verb == .implement)
            #expect(answer[.fix].availability == .unavailable)
            #expect(answer[.fix].reason == "Not a bug, so Implement fits better here.")
        }
        #expect(verbs(item, read(item, .feature, ready: 31)).recommended?.verb == .chat)
        #expect(verbs(item, read(item, .feature, ready: 31))[.implement].availability == .available)
    }

    @Test func aQuestionIsChatAndNothingElseFits() {
        let item = issue()
        let answer = verbs(item, read(item, .question, ready: 95))
        #expect(answer.recommended?.verb == .chat)
        #expect(answer[.fix].availability == .unavailable && answer[.implement].availability == .unavailable)
    }

    @Test func anIssueWithALinkedPullRequestIsNotFixedAgain() {
        let item = issue(linked: true)
        let answer = verbs(item, read(item, .bug, ready: 90))
        #expect(answer.recommended?.verb == .chat)
        #expect(answer[.fix].availability == .available)
        #expect(answer[.review].availability == .available)
    }

    @Test func anIssueNobodyHasReadGetsNoRecommendation() {
        let answer = verbs(issue(), nil)
        #expect(answer.recommended == nil)
        #expect(answer.headline == "No suggestion yet")
        #expect(answer[.fix].availability == .available && answer[.implement].availability == .available)
        #expect(answer[.chat].availability == .available)
    }

    @Test func aStaleReadStillCountsItIsShownDimmedNotIgnored() {
        let item = issue()
        let old = read(item, .bug, ready: 90, readAt: now.addingTimeInterval(-9000))
        var moved = item
        moved.updatedAt = now.addingTimeInterval(500)
        #expect(old.isStale(for: moved))
        #expect(verbs(moved, old).recommended?.verb == .fix)
    }

    @Test func aClosedOrMergedItemIsChatOnly() {
        for state in [BrowseItem.State.closed, .merged] {
            for item in [issue(state: state), pull(state: state)] {
                let answer = verbs(item, read(item, .bug, ready: 99))
                #expect(answer.recommended?.verb == .chat)
                #expect(answer.advice.filter { $0.availability != .unavailable }.map(\.verb) == [.chat])
            }
        }
    }

    @Test func yourPullRequestWithFailingChecksIsFixAddressTheFeedback() {
        let mine = pull(author: "you", checks: .failing)
        let answer = verbs(mine, nil)
        #expect(answer.recommended?.verb == .fix)
        #expect(answer[.fix].reason == "Your PR has failing checks: address the feedback")
        #expect(answer[.implement].availability == .unavailable)
        #expect(answer[.implement].reason == "Pull requests are reviewed or fixed, not implemented.")
        #expect(answer[.review].availability == .unavailable)
    }

    @Test func yourPullRequestWithChangesRequestedIsFixToo() {
        let answer = verbs(pull(author: "You", checks: .passing, review: .changesRequested), nil)
        #expect(answer.recommended?.verb == .fix)
        #expect(answer[.fix].reason == "Changes were requested on your PR: address the feedback")
        let both = verbs(pull(author: "you", checks: .failing, review: .changesRequested), nil)
        #expect(both[.fix].reason == "Your PR has failing checks and requested changes: address the feedback")
    }

    @Test func aPullRequestAwaitingYourReviewIsReview() {
        let item = pull(requested: ["YOU", "other"])
        let answer = verbs(item, nil)
        #expect(answer.recommended?.verb == .review)
        #expect(answer[.review].reason == "Review requested, CI green")
        #expect(answer[.fix].availability == .unavailable)
        #expect(answer[.fix].reason == "Push a change to this PR. Not needed: CI is green.")
        #expect(answer[.chat].availability == .available)
        #expect(verbs(pull(checks: .failing, requested: ["you"]), nil)[.review]
            .reason == "Review requested, CI failing")
    }

    @Test func aPullRequestNobodyAskedYouToReviewHasNoRecommendationButAReviewOnOffer() {
        let answer = verbs(pull(requested: []), nil)
        #expect(answer.recommended == nil)
        #expect(answer[.review].availability == .available)
        #expect(verbs(pull(requested: nil), nil).recommended == nil)
    }

    @Test func aDraftRequestedOfYouIsOnOfferNotSuggested() {
        #expect(verbs(pull(requested: ["you"], draft: true), nil).recommended == nil)
    }

    @Test func ordersPutTheSuggestionFirstAndKeepTheRestInPlace() {
        let item = issue()
        let answer = verbs(item, read(item, .bug, ready: 48))
        #expect(answer.ordered.map(\.verb) == [.chat, .fix, .implement, .review])
        let none = verbs(item, nil)
        #expect(none.ordered.map(\.verb) == [.fix, .implement, .chat, .review])
    }

    @Test func withoutAViewerNobodyOwnsAPullRequest() {
        let item = pull(author: "you", checks: .failing)
        #expect(verbs(item, nil, viewer: nil).recommended == nil)
    }
}
