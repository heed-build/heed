import Foundation
@testable import HeedCore
import Testing

/// Review comments queue by themselves only from people who can write to the repo, and from you.
struct FeedbackTrustTests {
    let ref = PullRef(repo: Repo(org: "acme", name: "docs"), number: 7)

    private func thread(_ id: String, by author: String, _ trust: ExternalText.Trust) -> ReviewThread {
        ReviewThread(
            id: id, isResolved: false, path: "a.cs", line: 1, author: author, body: "Do \(id)", diff: [], replies: 0,
            url: nil, trust: trust
        )
    }

    private func detail(_ threads: [ReviewThread], failing: [PullDetail.FailingCheck] = []) -> PullDetail {
        PullDetail(
            ref: ref, title: "t", body: "", author: "me", baseBranch: "main", headBranch: "b", additions: 0,
            deletions: 0, commitCount: 1, headSHA: "abc", reviews: [], threads: threads, failingChecks: failing,
            checks: CheckSummary(), closes: [], fetchedAt: Date()
        )
    }

    @Test func onAutoOnlyCollaboratorsAndYouQueueByThemselves() {
        var pipeline = PullFeedback(ref: ref, autoFeed: .auto)
        pipeline.merge(detail([
            thread("owner", by: "boss", .owner), thread("member", by: "mate", .collaborator),
            thread("stranger", by: "drive-by", .stranger), thread("bot", by: "lint[bot]", .bot),
            thread("mine", by: "Me", .stranger),
        ]), viewer: "me")
        let status = Dictionary(uniqueKeysWithValues: pipeline.items.map { ($0.id, $0.status) })
        #expect(status == ["owner": .queued, "member": .queued, "stranger": .new, "bot": .new, "mine": .queued])
        let prompt = pipeline.prompt()?.display ?? ""
        #expect(prompt.contains("Do owner") && prompt.contains("Do member") && prompt.contains("Do mine"))
        #expect(!prompt.contains("Do stranger") && !prompt.contains("Do bot"))
    }

    @Test func anOrganisationMembersCommentQueuesOnlyWithWriteAccess() {
        var unchecked = PullFeedback(ref: ref, autoFeed: .auto)
        unchecked.merge(detail([thread("m", by: "Mate", .member)]))
        #expect(unchecked.items.map(\.status) == [.new])
        #expect(unchecked.items[0].outsideNote
            == "not sent automatically: @Mate is an organisation member gh hasn't said can write to the repo")
        var checked = PullFeedback(ref: ref, autoFeed: .auto)
        var writes = detail([thread("m", by: "Mate", .member)])
        writes.writers = ["mate"]
        checked.merge(writes)
        #expect(checked.items.map(\.status) == [.queued])
        #expect(checked.items[0].outsideNote == nil && !checked.items[0].fromOutside)
    }

    @Test func aStrangersCommentSaysWhyItWaitsAndGoesWhenYouQueueIt() throws {
        var pipeline = PullFeedback(ref: ref, autoFeed: .auto)
        pipeline.merge(detail([thread("s", by: "drive-by", .stranger), thread("b", by: "lint[bot]", .bot)]))
        #expect(pipeline.items[0].outsideNote == "not sent automatically: @drive-by isn't a collaborator")
        #expect(pipeline.items[1].outsideNote == "not sent automatically: @lint[bot] is a bot")
        pipeline.items[0].status = .queued
        #expect(pipeline.items[0].outsideNote == nil)
        let prompt = try #require(pipeline.prompt()).rendered(nonce: "n")
        #expect(prompt.contains("trust=\"stranger\" source=\"thread\" id=\"n\">Do s</external n>"))
    }

    @Test func aFailingCheckStillQueuesFencedAsItsApps() throws {
        var pipeline = PullFeedback(ref: ref, autoFeed: .auto)
        let summary = ExternalText("too long", source: .checkSummary, author: .init(login: "actions", trust: .bot))
        pipeline.merge(detail([], failing: [PullDetail.FailingCheck(name: "lint", summary: summary, url: nil)]))
        #expect(pipeline.items.map(\.status) == [.queued])
        let prompt = try #require(pipeline.prompt()).rendered(nonce: "n")
        #expect(prompt.contains("check lint failed: <external author=\"@actions\" trust=\"bot\""))
    }

    @Test func copilotIsAskedAboutOutsideCommentsOnlyByHand() {
        var pipeline = PullFeedback(ref: ref, autoFeed: .ask)
        pipeline.merge(detail([thread("s", by: "drive-by", .stranger), thread("m", by: "mate", .collaborator)]))
        var settings = PilotSettings()
        settings.copilotComments = true
        #expect(CopilotAsk.items(pipeline, settings: settings).map(\.id) == ["m"])
        #expect(CopilotAsk.items(pipeline, settings: settings, everything: true).map(\.id) == ["s", "m"])
    }
}
