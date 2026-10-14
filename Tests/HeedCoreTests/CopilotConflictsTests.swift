import Foundation
@testable import HeedCore
import Testing

struct CopilotConflictsTests {
    private let ref = PullRef(repo: Repo(org: "nullean", name: "heed"), number: 7)

    private func pipeline(behind: Bool = false) -> PullFeedback {
        PullFeedback(ref: ref, items: [FeedbackItem(
            id: "conflict", kind: .conflict(base: "main", behind: behind), text: "Merge conflict with main."
        )])
    }

    private func ask(
        _ pipeline: PullFeedback, conflicts: ConflictFixer = .copilot, watching: Bool = true, paused: Bool = false,
        available: Bool = true
    ) -> FeedbackItem? {
        CopilotConflicts.itemToAsk(
            pipeline, settings: PilotSettings(conflicts: conflicts), watching: watching, paused: paused,
            copilotAvailable: available
        )
    }

    @Test func offByDefault() {
        #expect(PilotSettings().conflicts == .agent)
        #expect(ask(pipeline(), conflicts: .agent) == nil)
    }

    @Test func asksOnceForAConflict() {
        var pipeline = pipeline()
        #expect(ask(pipeline)?.id == "conflict")
        CopilotConflicts.asked(&pipeline, item: "conflict", at: Date())
        #expect(ask(pipeline) == nil)
        // Sent, so it does not go to the agent as well.
        #expect(pipeline.items.first?.status == .sent)
        #expect(pipeline.prompt() == nil)
    }

    @Test func notWhenBehindPausedUnwatchedOrUnavailable() {
        #expect(ask(pipeline(behind: true)) == nil)
        #expect(ask(pipeline(), paused: true) == nil)
        #expect(ask(pipeline(), watching: false) == nil)
        #expect(ask(pipeline(), available: false) == nil)
    }

    @Test func theCommentAndDetection() {
        #expect(CopilotConflicts.comment(base: "main").hasPrefix("@copilot Merge in main and resolve the conflicts"))
        let with = #"{"data":{"repository":{"suggestedActors":{"nodes":[{"login":"copilot-swe-agent"},{"login":"me"}]}}}}"#
        let without = #"{"data":{"repository":{"suggestedActors":{"nodes":[{"login":"me"}]}}}}"#
        #expect(GitHub.parseCopilotAvailable(Data(with.utf8)))
        #expect(!GitHub.parseCopilotAvailable(Data(without.utf8)))
    }

    @Test func configReadsConflicts() throws {
        let (decoded, problems) = ConfigLoader.decode("""
        [pilot]
        conflicts = "copilot"
        [orgs.employer]
        conflicts = "agent"
        [repos."x/y"]
        conflicts = "someone"
        """)
        let config = try #require(decoded)
        #expect(config.pilot.defaults.conflicts == .copilot)
        #expect(config.pilot.resolve(Repo(org: "employer", name: "a")).conflicts == .agent)
        #expect(problems.map(\.path) == ["repos.x/y.conflicts"])
    }
}
