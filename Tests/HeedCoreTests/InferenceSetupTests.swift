import Foundation
@testable import HeedCore
import Testing

struct InferenceSetupTests {
    private let at = Date(timeIntervalSince1970: 2_000_000_000)

    private func status(_ name: String, _ login: LLMAgentStatus.Login, model: String? = nil) -> LLMAgentStatus {
        LLMAgentStatus(
            name: name, command: name, path: login == .notInstalled ? nil : "/opt/bin/\(name)", login: login,
            detectedModel: model, checkedAt: at
        )
    }

    private var detected: [LLMAgentStatus] {
        [
            status("claude", .loggedIn, model: "haiku"), status("codex", .loggedIn), status("cursor", .notInstalled),
            status("pi", .loggedOut), status("gemini", .unknown),
        ]
    }

    private func evaluate(
        agent: String? = nil, enabled: Bool = true, decider: DecisionSettings.Choice? = nil,
        statuses: [LLMAgentStatus]? = nil, local: LocalModel = .available, tests: SetupTests = SetupTests()
    ) -> InferenceSetup {
        var llm = LLMSettings()
        llm.agent = agent
        llm.enabled = enabled
        return InferenceSetup.evaluate(
            llm: llm, decisions: DecisionSettings(decider: decider), statuses: statuses ?? detected, local: local,
            tests: tests
        )
    }

    // MARK: Detection → the default

    @Test func theFirstAgentLoggedInIsSuggested() {
        #expect(InferenceSetup.suggestedAgent(detected) == "claude")
        #expect(InferenceSetup.suggestedAgent([status("claude", .loggedOut), status("codex", .loggedIn)]) == "codex")
        // One without a login check, when none is logged in.
        #expect(InferenceSetup.suggestedAgent([status("pi", .loggedOut), status("gemini", .unknown)]) == "gemini")
        #expect(InferenceSetup.suggestedAgent([status("claude", .notInstalled), status("pi", .loggedOut)]) == nil)
        #expect(InferenceSetup.suggestedAgent([]) == nil)
    }

    @Test func onDeviceDecisionsAreSuggestedWhereTheMacHasThem() {
        #expect(InferenceSetup.suggestedDecider(local: .available, agent: nil) == .local)
        #expect(InferenceSetup.suggestedDecider(local: .notEnabled, agent: "claude") == .model)
        #expect(InferenceSetup.suggestedDecider(local: .unsupported, agent: nil) == .off)
        let setup = evaluate(local: .notReady)
        #expect(setup.suggestedAgent == "claude" && setup.suggestedDecider == .model)
    }

    // MARK: Where it stands

    @Test func nothingChosenIsNotConfiguredAndReminds() {
        let setup = evaluate()
        #expect(setup.inference.label == "not configured" && setup.decisions.label == "not configured")
        #expect(setup.inference.detail.hasSuffix("Suggested: claude."))
        #expect(setup.decisions.detail.hasSuffix("Suggested: Apple's on-device model."))
        // Not chosen still works as before (calls take turns, decisions by model call): nothing goes without.
        #expect(setup.degraded.isEmpty)
        #expect(setup.reminder(enabled: true, hiddenThisLaunch: false) == "Set up model calls")
    }

    @Test func notChosenWithNoAgentAtAllGoesWithout() {
        let setup = evaluate(statuses: [status("claude", .notInstalled)], local: .unsupported)
        #expect(setup.inference.detail == "No agent heed can call is installed and logged in.")
        #expect(setup.degraded == InferenceSetup.inferenceFeatures + InferenceSetup.decisionFeatures)
    }

    @Test func bothChosenAndWorkingIsConfiguredAndQuiet() {
        let setup = evaluate(agent: "claude", decider: .local)
        #expect(setup.inference == .configured("claude, haiku."))
        #expect(setup.decisions == .configured("Apple's on-device model, on this Mac."))
        #expect(setup.degraded.isEmpty && !setup.needsAttention)
        #expect(setup.reminder(enabled: true, hiddenThisLaunch: false) == nil)
        #expect(evaluate(agent: "auto", decider: .model).inference
            == .configured("Every agent you are logged in to, taking turns: claude, codex, gemini."))
    }

    @Test func aChosenAgentThatCannotRunIsFailing() {
        #expect(evaluate(agent: "pi", decider: .local).inference == .failing("pi is not logged in."))
        #expect(evaluate(agent: "cursor", decider: .local).inference == .failing("cursor is not installed."))
        #expect(evaluate(agent: "mytool", decider: .local).inference
            == .failing("mytool is not an agent heed can make model calls through."))
        let none = evaluate(agent: "auto", decider: .model, statuses: [status("pi", .loggedOut)])
        #expect(none.inference == .failing("No agent heed can call is installed and logged in."))
        // Decisions by model call go down with it.
        #expect(none.decisions == .failing("A model call, but model calls are failing."))
        #expect(none.degraded == InferenceSetup.inferenceFeatures + InferenceSetup.decisionFeatures)
        #expect(none.reminder(enabled: true, hiddenThisLaunch: false) == "Model calls failing")
    }

    @Test func beforeDetectionAChosenAgentIsTakenToWork() {
        let setup = InferenceSetup.evaluate(
            llm: { var llm = LLMSettings()
                llm.agent = "codex"
                return llm
            }(),
            decisions: DecisionSettings(decider: .model), statuses: nil, local: .unsupported, tests: SetupTests()
        )
        #expect(setup.inference == .configured("codex, its cheap model."))
        #expect(!setup.needsAttention)
    }

    @Test func theLastFailedTestOfTheChoiceIsFailing() {
        let failed = SetupTests(
            inference: SetupTest(subject: "claude", ok: false, detail: "exit 1: boom", at: at),
            decisions: SetupTest(subject: "local", ok: false, detail: "no answer", at: at)
        )
        let setup = evaluate(agent: "claude", decider: .local, tests: failed)
        #expect(setup.inference == .failing("The last test failed: exit 1: boom"))
        #expect(setup.decisions == .failing("The last test failed: no answer"))
        #expect(setup.reminder(enabled: true, hiddenThisLaunch: false) == "Model calls failing")
        // A test of something no longer chosen does not count, nor one that passed.
        #expect(evaluate(agent: "codex", decider: .model, tests: failed).inference.label == "configured")
        #expect(evaluate(agent: "codex", decider: .model, tests: failed).decisions.label == "configured")
        let passed = SetupTests(inference: SetupTest(subject: "claude", ok: true, detail: "Hello", at: at))
        #expect(evaluate(agent: "claude", decider: .local, tests: passed).inference.label == "configured")
    }

    @Test func onDeviceDecisionsWhereTheMacCannotAreFailing() {
        let setup = evaluate(agent: "claude", decider: .local, local: .notEnabled)
        #expect(setup.decisions == .failing("Turn on Apple Intelligence to use it."))
        #expect(setup.degraded == InferenceSetup.decisionFeatures)
        #expect(setup.reminder(enabled: true, hiddenThisLaunch: false) == "Decisions failing")
    }

    @Test func offOnPurposeGoesWithoutButDoesNotRemind() {
        let setup = evaluate(enabled: false, decider: .off)
        #expect(setup.inference.label == "off" && setup.decisions.label == "off")
        #expect(setup.degraded == InferenceSetup.inferenceFeatures + InferenceSetup.decisionFeatures)
        #expect(setup.reminder(enabled: true, hiddenThisLaunch: false) == nil)
        // Model calls off with decisions by model call is a setup that cannot work.
        let model = evaluate(enabled: false, decider: .model)
        #expect(model.decisions == .failing("A model call, but model calls are off."))
        #expect(model.reminder(enabled: true, hiddenThisLaunch: false) == "Decisions failing")
        // On-device decisions need no model calls.
        let local = evaluate(enabled: false, decider: .local)
        #expect(local.decisions.label == "configured" && local.degraded == InferenceSetup.inferenceFeatures)
    }

    @Test func theReminderIsHiddenForTheLaunchOrForGood() {
        let setup = evaluate()
        #expect(setup.reminder(enabled: false, hiddenThisLaunch: false) == nil)
        #expect(setup.reminder(enabled: true, hiddenThisLaunch: true) == nil)
    }

    @Test func sSurviveARestart() throws {
        let tests = SetupTests(inference: SetupTest(subject: "auto", ok: true, detail: "Hi", seconds: 1.5, at: at))
        let data = try JSONEncoder().encode(tests)
        #expect(try JSONDecoder().decode(SetupTests.self, from: data) == tests)
    }

    // MARK: Config

    @Test func configChoosesTheAgentTheDeciderAndTheReminder() throws {
        let (decoded, problems) = ConfigLoader.decode("""
        [llm]
        agent = " claude "
        setup_reminder = false
        [decisions]
        decider = "Local"
        """)
        #expect(problems.isEmpty)
        let config = try #require(decoded)
        #expect(config.llm.agent == "claude" && config.llm.only == "claude" && !config.llm.setupReminder)
        #expect(config.decisions.decider == .local)

        let (auto, _) = ConfigLoader.decode("[llm]\nagent = \"auto\"\n[decisions]\ndecider = \"\"\n")
        #expect(auto?.llm.agent == "auto" && auto?.llm.only == nil)
        #expect(auto?.decisions.decider == nil && auto?.decisions.effective == .model)

        let (empty, _) = ConfigLoader.decode("[llm]\nagent = \"\"\n")
        #expect(empty?.llm.agent == nil)

        let (_, bad) = ConfigLoader.decode("[decisions]\ndecider = \"oracle\"\n")
        #expect(bad.map(\.description) == ["decisions.decider: expected local, model or off"])
        #expect(HeedConfig.default.llm.agent == nil && HeedConfig.default.decisions.decider == nil)
        #expect(HeedConfig.default.llm.setupReminder)
    }

    // MARK: The command

    @Test func theCommandsAndTheSettingsSection() {
        #expect(Commands.spec("inference.setup") != nil && Commands.spec("inference.hide")?.arguments == "[always]")
        #expect(CommandCompletions.settingsSections.contains("inference"))
        #expect(MenuBar.unlisted["inference.setup"] == nil)
    }
}

struct LocalDeciderTests {
    @Test func aPickBecomesProbabilities() throws {
        let choice = try LocalDecider.answer(
            .choice(instructions: "Where?", options: ["working", "waiting", "done"]), pick: "done", confidence: "high"
        )
        #expect(choice.choice == "done" && choice.confidence == 0.9)
        #expect(abs(choice.probabilities["done"]! - 0.9) < 1e-9 && abs(choice.probabilities["working"]! - 0.05) < 1e-9)
        #expect(abs(choice.probabilities.values.reduce(0, +) - 1) < 1e-9)

        // Never less than an even share, however unsure.
        let unsure = try LocalDecider.answer(
            .choice(instructions: "?", options: ["a", "b", "c"]), pick: "b", confidence: "low"
        )
        #expect(unsure.probabilities["b"]! >= unsure.probabilities["a"]!)
        #expect(abs(unsure.probabilities["b"]! - 0.5) < 1e-9)
        let many = try LocalDecider.answer(
            .choice(instructions: "?", options: ["a", "b", "c", "d"]), pick: "a", confidence: "nonsense"
        )
        #expect(many.confidence == 0.5 && abs(many.probabilities["a"]! - 0.5) < 1e-9)
        let single = try LocalDecider.answer(
            .choice(instructions: "?", options: ["only"]),
            pick: "only",
            confidence: "low"
        )
        #expect(single.probabilities == ["only": 1])
    }

    @Test func aScoreIsTheExpectedLevel() throws {
        let score = try LocalDecider.answer(
            .score(instructions: "How urgent?", levels: ["low", "mid", "high"]), pick: "high", confidence: "medium"
        )
        // 0 × 0.15 + 1 × 0.15 + 2 × 0.7
        #expect(abs(score.score! - 1.55) < 1e-9 && score.choice == "high")
        let choice = try LocalDecider.answer(
            .choice(instructions: "?", options: ["low", "mid", "high"]), pick: "high", confidence: "medium"
        )
        #expect(choice.score == nil)
    }

    @Test func trueOrFalseIsAProbability() throws {
        let yes = try LocalDecider.answer(.noul(instructions: "Stuck?"), pick: "true", confidence: "high")
        #expect(yes.probability == 0.9 && yes.probabilities["false"].map { abs($0 - 0.1) < 1e-9 } == true)
        let no = try LocalDecider.answer(.noul(instructions: "Stuck?"), pick: "false", confidence: "high")
        #expect(no.probability.map { abs($0 - 0.1) < 1e-9 } == true)
        #expect(throws: DeciderError.self) {
            try LocalDecider.answer(.noul(instructions: "Stuck?"), pick: "maybe", confidence: "high")
        }
        #expect(throws: DeciderError.self) {
            try LocalDecider.answer(.choice(instructions: "?", options: ["a"]), pick: nil, confidence: "high")
        }
    }

    @Test func thePromptHasAFieldAndAConfidencePerQuestion() {
        let prompt = LocalDecider.prompt(state: "All green.", questions: [
            "stuck": .noul(instructions: "The agent is stuck."),
            "level": .score(instructions: "How urgent?", levels: ["low", "high"]),
        ])
        #expect(prompt.prompt == "State:\nAll green.")
        #expect(prompt.fields.map(\.name) == ["level", "level_confidence", "stuck", "stuck_confidence"])
        #expect(prompt.fields[2].options == ["true", "false"])
        #expect(prompt.fields[1].options == ["low", "medium", "high"])
    }

    @Test func decidingAsksTheModelOnceAndLogs() async throws {
        let decider = LocalDecider(caller: "test") { prompt in
            #expect(prompt.fields.count == 2)
            return ["stands": "done", "stands_confidence": "high"]
        }
        let answers = try await decider.decide(
            subject: "s1", state: "Merged.",
            questions: ["stands": .choice(instructions: "?", options: ["working", "done"])]
        )
        #expect(answers["stands"]?.choice == "done")
        await #expect(throws: DeciderError.noQuestions) {
            try await decider.decide(subject: "s1", state: "", questions: [:])
        }
        let wrong = LocalDecider(caller: "test") { _ in ["stands": "elsewhere"] }
        await #expect(throws: DeciderError.self) {
            try await wrong.decide(subject: "s1", state: "", questions: ["stands": .noul(instructions: "?")])
        }
    }

    @Test func offDecidesNothing() async {
        await #expect(throws: DeciderError.off) {
            try await OffDecider().decide(subject: "s", state: "", questions: ["q": .noul(instructions: "?")])
        }
        #expect(DecisionSettings().effective == .model && DecisionSettings(decider: .off).effective == .off)
    }
}
