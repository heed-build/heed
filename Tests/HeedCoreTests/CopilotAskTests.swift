import Foundation
@testable import HeedCore
import Testing

struct CopilotAskTests {
    private let ref = PullRef(repo: Repo(org: "nullean", name: "heed"), number: 7)

    private func pipeline(behind: Bool = false, threads: Int = 2) -> PullFeedback {
        PullFeedback(ref: ref, items: [FeedbackItem(
            id: "conflict", kind: .conflict(base: "main", behind: behind), text: "Merge conflict with main."
        )] + (0 ..< threads).map {
            FeedbackItem(
                id: "T\($0)", kind: .review(location: "File.cs:\($0 + 10)", author: "reviewer"),
                text: "Fix number \($0).\nMore detail."
            )
        } + [FeedbackItem(id: "check:lint", kind: .check(name: "lint"), text: "line too long")])
    }

    private func ids(_ pipeline: PullFeedback, conflicts: Bool = false, comments: Bool = false) -> [String] {
        CopilotAsk.items(
            pipeline, settings: PilotSettings(copilotConflicts: conflicts, copilotComments: comments)
        ).map(\.id)
    }

    @Test func offByDefault() {
        let settings = PilotSettings()
        #expect(!settings.copilotConflicts && !settings.copilotComments && settings.reviewers.isEmpty)
        #expect(ids(pipeline()).isEmpty)
    }

    @Test func separateOptions() {
        #expect(ids(pipeline(), conflicts: true) == ["conflict"])
        #expect(ids(pipeline(), comments: true) == ["T0", "T1"])
        #expect(ids(pipeline(), conflicts: true, comments: true) == ["conflict", "T0", "T1"])
        // Behind is the merge queue's, and checks are never Copilot's here.
        #expect(ids(pipeline(behind: true), conflicts: true).isEmpty)
        // C: both, whatever the settings.
        #expect(CopilotAsk.items(pipeline(), settings: PilotSettings(), everything: true).count == 3)
    }

    @Test func oneCommentForBoth() {
        let both = CopilotAsk.comment(base: "main", items: pipeline().items)
        #expect(both.hasPrefix(
            "@copilot Please merge in main and resolve the conflicts, then address these review comments:"
        ))
        #expect(both.contains("1. `File.cs:10` (@reviewer): Fix number 0."))
        #expect(both.contains("2. `File.cs:11` (@reviewer): Fix number 1."))
        #expect(!both.contains("More detail"))
        #expect(both.hasSuffix("Make sure the build and tests still pass."))
        let conflictOnly = CopilotAsk.comment(base: "main", items: [pipeline().items[0]])
        #expect(conflictOnly
            == "@copilot Please merge in main and resolve the conflicts. Make sure the build and tests still pass.")
        let one = CopilotAsk.comment(base: "main", items: [pipeline().items[1]])
        #expect(one.hasPrefix("@copilot Please address this review comment:"))
    }

    @Test func askedOnceAndNotSentToTheAgentToo() {
        var pipeline = pipeline()
        CopilotAsk.asked(&pipeline, items: ["conflict", "T0"], at: Date())
        #expect(ids(pipeline, conflicts: true, comments: true) == ["T1"])
        #expect(pipeline.items.first { $0.id == "T0" }?.status == .sent)
        #expect(pipeline.prompt() == nil)
    }

    @Test func reviewersOnceNotTheAuthorNotDrafts() {
        var detail = PullDetail(
            ref: ref, title: "t", body: "", author: "me", baseBranch: "main", headBranch: "b", additions: 0,
            deletions: 0, commitCount: 1, headSHA: "a", reviews: [], threads: [], failingChecks: [],
            checks: CheckSummary(), closes: [], fetchedAt: Date()
        )
        detail.state = "OPEN"
        detail.isDraft = false
        let settings = PilotSettings(reviewers: ["copilot", "alice", "me", "elastic/docs"])
        #expect(ReviewRequests.wanted(settings, detail: detail, asked: []) == ["@copilot", "alice", "elastic/docs"])
        #expect(ReviewRequests.wanted(settings, detail: detail, asked: ["@copilot", "ALICE"]) == ["elastic/docs"])
        detail.isDraft = true
        #expect(ReviewRequests.wanted(settings, detail: detail, asked: []).isEmpty)
    }

    @Test func detection() {
        let with = #"{"data":{"repository":{"suggestedActors":{"nodes":[{"login":"copilot-swe-agent"},{"login":"me"}]}}}}"#
        let without = #"{"data":{"repository":{"suggestedActors":{"nodes":[{"login":"me"}]}}}}"#
        #expect(GitHub.parseCopilotAvailable(Data(with.utf8)))
        #expect(!GitHub.parseCopilotAvailable(Data(without.utf8)))
    }

    @Test func configReadsTheOptionsAtEveryLevel() throws {
        let (decoded, _) = ConfigLoader.decode("""
        [pilot]
        copilot_conflicts = true
        reviewers = ["copilot"]
        [orgs.employer]
        copilot_comments = true
        reviewers = ["copilot", "employer/platform"]
        [repos."employer/quiet"]
        copilot_conflicts = false
        """)
        let config = try #require(decoded)
        #expect(config.pilot.defaults.copilotConflicts)
        #expect(!config.pilot.defaults.copilotComments)
        let quiet = config.pilot.resolve(Repo(org: "employer", name: "quiet"))
        #expect(!quiet.copilotConflicts && quiet.copilotComments)
        #expect(quiet.reviewers == ["copilot", "employer/platform"])
        // A pipeline cached before review requests still loads.
        let old = #"{"ref":{"repo":{"org":"nullean","name":"heed"},"number":7},"items":[],"autoFeed":"Ask","#
            + #""watching":true,"rounds":0,"approvalsSeen":0}"#
        #expect(try JSONDecoder().decode(PullFeedback.self, from: Data(old.utf8)).reviewersRequested.isEmpty)
    }
}
