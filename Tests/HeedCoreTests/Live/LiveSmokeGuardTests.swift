import Foundation
@testable import HeedCore
import Testing

/// The smoke suite's one safety property, checked on every `swift test` (no network, no model): a write names
/// `Mpdreamz/heed-smoke` or it does not run.
@Suite("LiveSmokeGuardTests")
struct LiveSmokeGuardTests {
    @Test func theOnlySlugIsTheSmokeRepository() {
        #expect(LiveSmoke.slug == "Mpdreamz/heed-smoke")
        #expect(LiveSmoke.repo.slug == LiveSmoke.slug)
        #expect(LiveSmoke.model == "claude-haiku-4-5")
    }

    @Test func aWriteToTheSmokeRepositoryPasses() throws {
        try SmokeGH.requireSmoke(["api", "-X", "POST", "repos/Mpdreamz/heed-smoke/issues", "-f", "title=x"])
        try SmokeGH.requireSmoke(["pr", "create", "-R", "Mpdreamz/heed-smoke", "--title", "x"])
        try SmokeGH.requireSmoke(["api", "-X", "DELETE", "repos/mpdreamz/HEED-SMOKE/git/refs/heads/heed-live-1"])
        try SmokeGH.requireSmoke(LiveSmoke.repo)
    }

    @Test func aWriteToAnyOtherRepositoryIsRefused() {
        let others: [[String]] = [
            ["api", "-X", "POST", "repos/cli/cli/issues", "-f", "title=x"],
            ["api", "-X", "DELETE", "repos/Mpdreamz/heed/git/refs/heads/main"],
            ["api", "-X", "DELETE", "repos/Mpdreamz/heed-smoke-evil/git/refs/heads/x"],
            ["pr", "create", "-R", "cli/cli", "--title", "x"],
            ["pr", "create", "--repo", "elastic/elasticsearch"],
            ["pr", "create", "--repo=elastic/elasticsearch"],
            ["issue", "comment", "https://github.com/cli/cli/issues/1", "-b", "x"],
            // The right repository named beside another one: still refused.
            ["api", "repos/Mpdreamz/heed-smoke/issues/1", "-f", "body=see repos/cli/cli/issues/2"],
            // No repository at all: the write cannot be checked, so it does not run.
            ["api", "-X", "POST", "user/repos", "-f", "name=x"],
            ["api", "graphql", "-f", "query=mutation { x }"],
            [],
        ]
        for arguments in others {
            #expect(throws: SmokeRefusal.self, "\(arguments)") { try SmokeGH.requireSmoke(arguments) }
        }
        #expect(throws: SmokeRefusal.self) { try SmokeGH.requireSmoke(Repo(org: "cli", name: "cli")) }
        #expect(throws: SmokeRefusal.self) { try SmokeGH.requireSmoke(Repo(org: "Mpdreamz", name: "heed")) }
    }

    @Test func theWriteHelpersRefuseBeforeGHStarts() async {
        await #expect(throws: SmokeRefusal.self) {
            try await SmokeGH.write(["api", "-X", "POST", "repos/cli/cli/issues"])
        }
        await #expect(throws: SmokeRefusal.self) { try await SmokeGH.deleteBranch("main") }
        await #expect(throws: SmokeRefusal.self) { try await SmokeGH.deleteBranch("") }
    }

    @Test func bulkWritesThroughTheSuiteRefuseOtherRepositories() async {
        let item = BrowseItem(
            repo: Repo(org: "cli", name: "cli"), number: 1,
            title: ExternalText("t", source: .issueTitle, author: .unknown), author: "someone"
        )
        let writer: @Sendable (BrowseBulkAction, BrowseItem) async throws -> Void = { _, item in
            try SmokeGH.requireSmoke(item.repo)
        }
        let report = await BrowseBulk.run(BrowseBulk.plan(.comment("x"), items: [item]), items: [item], write: writer)
        #expect(report.done == 0 && report.failed.count == 1)
    }

    @Test func theLiveSuitesAreOffWithoutBothSwitches() {
        let environment = ProcessInfo.processInfo.environment
        #expect(LiveSmoke.enabled == (environment["HEED_LIVE"] == "1" && environment["HEED_LIVE_BROWSE"] == "1"))
    }
}
