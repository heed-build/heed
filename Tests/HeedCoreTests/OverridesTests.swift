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

        [orgs.acme]
        # the org's color
        color = "teal"
        reviewers = [
          "copilot",
        ]

        [repos."acme/docs"]
        green = "auto" # sends on its own
        """
        let document = try TOMLDocument(source)
        let withoutReviewers = document.removing(["orgs", "acme", "reviewers"])
        #expect(!withoutReviewers.contains("copilot"))
        #expect(withoutReviewers.contains("# the org's color\ncolor = \"teal\""))
        let withoutRepo = try TOMLDocument(document.removing(["repos", "acme/docs", "green"]))
        #expect(withoutRepo.root.value(at: ["repos", "acme/docs"]) == nil)
        #expect(!withoutRepo.source.contains("[repos."))
        #expect(withoutRepo.source.contains("[orgs.acme]"))
        // A key that is not there changes nothing.
        #expect(document.removing(["orgs", "acme", "merge"]) == source)
    }

    @Test func eachValueSaysWhereItComesFrom() {
        var config = HeedConfig.default
        var org = PilotOverrides(reviewers: ["copilot"])
        org.quietMinutes = 10
        var repo = PilotOverrides()
        repo.quietMinutes = 15
        config.pilot = PilotRules(orgs: ["acme": org], repos: ["acme/docs": repo])
        config.issues.repos["acme/docs"] = .all
        let docs = OverrideScope.repo(Repo(org: "acme", name: "docs"))
        func key(_ id: String) -> OverrideKey { Overrides.keys.first { $0.id == id }! }

        #expect(Overrides.effective(key("quiet_minutes"), at: docs, in: config) == (.integer(15), .repo))
        #expect(Overrides.effective(key("reviewers"), at: docs, in: config) == (.list(["copilot"]), .org))
        #expect(Overrides.effective(key("green"), at: docs, in: config).source == .default)
        #expect(Overrides.effective(key("quiet_minutes"), at: .org("acme"), in: config) == (.integer(10), .org))
        #expect(Set(Overrides.setKeys(at: docs, in: config)) == ["issues", "quiet_minutes"])
        #expect(Set(Overrides.setKeys(at: .org("acme"), in: config)) == ["reviewers", "quiet_minutes"])
        #expect(!Overrides.keys(for: .org("acme")).contains { $0.id == "admin_merge" })
        #expect(Overrides.configuredScopes(in: config) == [.org("acme"), docs])
        #expect(OverrideValue.list(["a", "b"]).toml == .array([.string("a"), .string("b")]))
    }

    /// The goal tracker and mirror moved from General › Goals to Orgs & repos: the same `goals_tracker` and
    /// `goals_mirror` keys config.toml already had, now overrides like the rest.
    @Test func goalTrackersAreOverridesReadFromTheKeysConfigAlreadyHad() throws {
        let source = """
        [goals]
        tracker = "acme/planning"

        [orgs.beta]
        goals_tracker = "beta/roadmap"
        goals_mirror = true

        [repos."beta/site"]
        goals_tracker = "beta/site-plans"

        [repos."gamma/tools"]
        goals_mirror = false
        """
        let config = try #require(ConfigLoader.decode(source).config)
        func key(_ id: String) -> OverrideKey { Overrides.keys.first { $0.id == id }! }
        let site = OverrideScope.repo(Repo(org: "beta", name: "site"))
        let api = OverrideScope.repo(Repo(org: "beta", name: "api"))
        let tools = OverrideScope.repo(Repo(org: "gamma", name: "tools"))
        let tracker = key("goals_tracker")

        #expect(Overrides.effective(tracker, at: site, in: config) == (.text("beta/site-plans"), .repo))
        #expect(Overrides.effective(tracker, at: api, in: config) == (.text("beta/roadmap"), .org))
        #expect(Overrides.effective(tracker, at: .org("beta"), in: config) == (.text("beta/roadmap"), .org))
        #expect(Overrides.effective(tracker, at: tools, in: config) == (.text("acme/planning"), .default))
        #expect(Overrides.effective(key("goals_mirror"), at: api, in: config) == (.bool(true), .org))
        #expect(Overrides.effective(key("goals_mirror"), at: tools, in: config) == (.bool(false), .repo))
        #expect(Overrides.effective(key("goals_mirror"), at: .org("delta"), in: config) == (.bool(false), .default))
        #expect(Overrides.keys(for: .org("beta")).contains { $0.id == "goals_tracker" })
        #expect(tracker.group == "Goals")
        #expect(Overrides.setKeys(at: .org("beta"), in: config) == ["goals_tracker", "goals_mirror"])
        #expect(Overrides.setKeys(at: site, in: config) == ["goals_tracker"])
        // Orgs and repos only the goal keys name are listed too.
        #expect(Overrides.configuredScopes(in: config) == [.org("beta"), site, tools])

        // What the page writes (the override's path) is what the mirror reads back, and ↺ hands it to the org.
        let document = try TOMLDocument(source)
        let written = try #require(ConfigLoader.decode(
            document.setting(site.path + [tracker.id], to: OverrideValue.text("beta/other").toml)
        ).config)
        #expect(written.goals.mirror.tracker(for: "beta/site") == "beta/other")
        let removed = try #require(ConfigLoader.decode(document.removing(site.path + [tracker.id])).config)
        #expect(removed.goals.mirror.tracker(for: "beta/site") == "beta/roadmap")
        #expect(Overrides.effective(tracker, at: site, in: removed) == (.text("beta/roadmap"), .org))
    }

    /// The page's tabs: every key on exactly one, in the page's order, and none so long it is a scroll again.
    @Test func everyKeyIsOnOneShortTab() {
        let grouped = Overrides.groups.flatMap(\.keys)
        #expect(grouped.count == Set(grouped).count)
        #expect(Set(grouped) == Set(Overrides.keys.map(\.id)))
        let repo = OverrideScope.repo(Repo(org: "acme", name: "docs"))
        let config = HeedConfig.default
        let perTab = OverrideTab.allCases.map { Overrides.keys(for: repo, on: $0, in: config).map(\.id) }
        // Tab by tab, the keys are the page's order cut in pieces.
        #expect(perTab.flatMap(\.self) == Overrides.keys(for: repo).map(\.id))
        #expect(perTab.allSatisfy { !$0.isEmpty && $0.count <= 9 })
        #expect(Overrides.keys(for: repo, on: .general, in: config).map(\.id)
            == ["color", "issues", "setup", "goals_tracker", "goals_mirror", "watch"])
        #expect(Overrides.keys(for: repo, on: .reviews, in: config).map(\.id)
            == ["reviewers", "trusted_reviewers", "self_review", "copilot_comments", "copilot_conflicts"])
        // An org has no admin merge, so its merged tab is one shorter.
        #expect(Overrides.keys(for: .org("acme"), on: .merged, in: config).count
            == Overrides.keys(for: repo, on: .merged, in: config).count - 1)
        #expect(Overrides.tab(of: "admin_merge") == .merged)
        #expect(Overrides.tab(of: "merge_agent") == .green)
        #expect(Overrides.tab(of: "tasks") == .general)
        #expect(OverrideTab.named("Merge") == .merged)
        #expect(OverrideTab.named("prompts") == .instructions)
        #expect(OverrideTab.named("pilot") == nil)
        #expect(Set(OverrideTab.allCases.map(\.shortTitle)).count == OverrideTab.allCases.count)
    }

    /// Each tab says how many overrides it holds, and Only overridden shows just those rows.
    @Test func tabsCountTheirOverridesAndFilterToThem() throws {
        let source = """
        [orgs.acme]
        color = "teal"
        reviewers = ["copilot"]

        [repos."acme/docs"]
        green = "auto"
        merge_agent = "codex"
        quiet_minutes = 15
        issues = "all"

        [repos."acme/docs".tasks]
        test = "make test"
        """
        let config = try #require(ConfigLoader.decode(source).config)
        let docs = OverrideScope.repo(Repo(org: "acme", name: "docs"))

        let counts = Overrides.overrideCounts(at: docs, in: config)
        #expect(counts == [.general: 2, .green: 2, .merged: 1, .reviews: 0, .instructions: 0])
        #expect(counts.values.reduce(0, +) == Overrides.setKeys(at: docs, in: config).count)
        // The org's own, not what its repos set.
        #expect(Overrides.overrideCounts(at: .org("acme"), in: config)
            == [.general: 1, .green: 0, .merged: 0, .reviews: 1, .instructions: 0])

        #expect(Overrides.keys(for: docs, on: .green, in: config, onlyOverridden: true).map(\.id)
            == ["green", "merge_agent"])
        #expect(Overrides.keys(for: docs, on: .general, in: config, onlyOverridden: true).map(\.id) == ["issues"])
        // Inherited from the org is not overridden here.
        #expect(Overrides.keys(for: docs, on: .reviews, in: config, onlyOverridden: true).isEmpty)
        #expect(Overrides.keys(for: docs, on: .reviews, in: config).count == 5)
    }
}
