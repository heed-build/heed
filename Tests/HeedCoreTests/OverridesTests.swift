import Foundation
@testable import HeedCore
import Testing

/// Org and repo overrides: removing one from config.toml, and what applies where.
struct OverridesTests {
    @Test func removingAKeyKeepsTheRestAndDropsAnEmptiedTable() throws {
        let source = """
        # heed
        [pilot]
        green = "ask"

        [orgs.elastic]
        # the org's color
        color = "teal"
        reviewers = [
          "copilot",
        ]

        [repos."elastic/docs"]
        green = "auto" # sends on its own
        """
        let document = try TOMLDocument(source)
        let withoutReviewers = document.removing(["orgs", "elastic", "reviewers"])
        #expect(!withoutReviewers.contains("copilot"))
        #expect(withoutReviewers.contains("# the org's color\ncolor = \"teal\""))
        let withoutRepo = try TOMLDocument(document.removing(["repos", "elastic/docs", "green"]))
        #expect(withoutRepo.root.value(at: ["repos", "elastic/docs"]) == nil)
        #expect(!withoutRepo.source.contains("[repos."))
        #expect(withoutRepo.source.contains("[orgs.elastic]"))
        // A key that is not there changes nothing.
        #expect(document.removing(["orgs", "elastic", "merge"]) == source)
    }

    @Test func eachValueSaysWhereItComesFrom() {
        var config = HeedConfig.default
        var org = PilotOverrides(reviewers: ["copilot"])
        org.quietMinutes = 10
        var repo = PilotOverrides()
        repo.quietMinutes = 15
        config.pilot = PilotRules(orgs: ["elastic": org], repos: ["elastic/docs": repo])
        config.issues.repos["elastic/docs"] = .all
        let docs = OverrideScope.repo(Repo(org: "elastic", name: "docs"))
        func key(_ id: String) -> OverrideKey { Overrides.keys.first { $0.id == id }! }

        #expect(Overrides.effective(key("quiet_minutes"), at: docs, in: config) == (.integer(15), .repo))
        #expect(Overrides.effective(key("reviewers"), at: docs, in: config) == (.list(["copilot"]), .org))
        #expect(Overrides.effective(key("green"), at: docs, in: config).source == .default)
        #expect(Overrides.effective(key("quiet_minutes"), at: .org("elastic"), in: config) == (.integer(10), .org))
        #expect(Set(Overrides.setKeys(at: docs, in: config)) == ["issues", "quiet_minutes"])
        #expect(Set(Overrides.setKeys(at: .org("elastic"), in: config)) == ["reviewers", "quiet_minutes"])
        #expect(!Overrides.keys(for: .org("elastic")).contains { $0.id == "admin_merge" })
        #expect(Overrides.configuredScopes(in: config) == [.org("elastic"), docs])
        #expect(OverrideValue.list(["a", "b"]).toml == .array([.string("a"), .string("b")]))
    }
}
