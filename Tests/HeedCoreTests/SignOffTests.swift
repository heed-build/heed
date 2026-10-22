import Foundation
@testable import HeedCore
import Synchronization
import Testing

struct SignOffTests {
    @Test func readsTheLastSignOffLine() {
        #expect(SignOff.extract("Done.\nheed-summary: Added anchor checks; PR #12 waits on review.")
            == "Added anchor checks; PR #12 waits on review.")
        #expect(SignOff.extract("**heed-summary:** Bumped the spec tests.\n") == "Bumped the spec tests.")
        #expect(SignOff.extract("- Heed-Summary: one\nmore text\nheed-summary: two") == "two")
        #expect(SignOff.extract("heed-summary:   ") == nil)
        #expect(SignOff.extract("No sign-off here.") == nil)
        #expect(SignOff.extract(nil) == nil)
    }

    @Test func onlyClaudeAndCodexAreAsked() {
        #expect(SignOff.arguments(agent: "claude") == ["--append-system-prompt", SignOff.instruction])
        #expect(SignOff.arguments(agent: "codex").first == "-c")
        #expect(SignOff.arguments(agent: "codex").last?.hasPrefix("developer_instructions=\"When you finish") == true)
        #expect(SignOff.arguments(agent: "gemini").isEmpty && SignOff.arguments(agent: "pi").isEmpty)
        // Plain words only: nothing a shell or TOML would read differently.
        #expect(!SignOff.instruction.contains { "\"'`$\\".contains($0) })
    }

    @Test func offByDefaultAndOverridablePerOrgAndRepo() throws {
        #expect(HeedConfig.default.work.signOff.applies(to: Repo(org: "a", name: "b")) == false)
        let (config, problems) = ConfigLoader.decode("""
        [pilot]
        summary_sign_off = true
        [orgs.acme]
        summary_sign_off = false
        [repos."acme/api"]
        summary_sign_off = true
        """)
        #expect(problems.isEmpty)
        let rule = try #require(config?.work.signOff)
        #expect(rule.applies(to: Repo(org: "other", name: "x")))
        #expect(!rule.applies(to: Repo(org: "acme", name: "web")))
        #expect(rule.applies(to: Repo(org: "acme", name: "api")))
        #expect(rule.applies(to: nil))
        #expect(config?.pilot.resolve(Repo(org: "acme", name: "web")).summarySignOff == false)
        let key = try #require(Overrides.keys.first { $0.id == "summary_sign_off" })
        #expect(key.read(config!, .org("acme")) == .bool(false))
    }

    @Test func launchesCarryItWhereItApplies() {
        var settings = WorkSettings.default
        settings.signOff = SignOffRule(defaults: false, repos: ["acme/api": true])
        let claude = AgentProfile.builtIn.first { $0.name == "claude" }!
        #expect(settings.signOffArguments(agent: claude, repo: Repo(org: "acme", name: "api")).count == 2)
        #expect(settings.signOffArguments(agent: claude, repo: Repo(org: "acme", name: "web")).isEmpty)
        let files = IntegrationFiles(directory: URL(fileURLWithPath: "/s"), heedBinary: "/app/heed")
        let args = AgentIntegration.launchArguments(
            agent: claude, sessionID: "id", files: files, signOff: SignOff.arguments(agent: "claude")
        )
        #expect(args.suffix(2) == ["--append-system-prompt", SignOff.instruction])
    }
}

private final class Model: Sendable {
    let calls = Mutex(0)
    var summarizer: Summarizer {
        Summarizer { _ in
            self.calls.withLock { $0 += 1 }
            return LLMResponse(text: "Summary: model words\nDecisions:\n- d1\nFollow-ups:\n- f1", agent: "claude")
        }
    }
}

struct SignOffLedgerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theSignOffIsTheSummaryAndTheModelOnlyFillsTheRest() async {
        let model = Model()
        let entry = LedgerEntry(id: "s", title: "t", startedAt: now)
        let signed = await Ledger.write(
            entry, inputs: SummaryInputs(title: "t"), include: Set(LedgerPart.allCases), trigger: .prMerged,
            summarizer: model.summarizer, instructions: "", signedOff: "Agent's own words.", now: now
        )
        #expect(signed.summary == "Agent's own words." && signed.source == .signOff)
        #expect(signed.decisions == ["d1"] && signed.followUps == ["f1"])
        #expect(model.calls.withLock { $0 } == 1)
        // Nothing else to write: no model call at all.
        let only = await Ledger.write(
            entry, inputs: SummaryInputs(title: "t"), include: [.summary, .files], trigger: .prMerged,
            summarizer: model.summarizer, instructions: "", signedOff: "Agent's own words.", now: now
        )
        #expect(only.summary == "Agent's own words." && model.calls.withLock { $0 } == 1)
    }
}
