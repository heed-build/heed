import AppKit
import Foundation
import HeedCore
#if canImport(FoundationModels)
    import FoundationModels
#endif

/// How Settings › Inference & decisions' decision test went.
struct DecisionTest: Equatable {
    var running = false
    var answer: String?
    var error: String?
    var seconds: Double?
}

/// Settings › Inference & decisions: where model calls and decisions stand (`InferenceSetup`), one click to set both
/// up from what is detected, a test of each, and the title bar's reminder while they are not set up.
extension AppModel {
    /// Where the setup stands. Before detection has run, a chosen agent is taken to work.
    var inferenceSetup: InferenceSetup {
        InferenceSetup.evaluate(
            llm: config.llm, decisions: config.decisions, statuses: llmStatuses.isEmpty ? nil : llmStatuses,
            local: localModel, tests: setupTests, hunch: hunch.status
        )
    }

    /// The title bar's reminder: not in the tutor, not in fixtures and screenshots unless a shot asks, not before
    /// detection has said what there is.
    var inferenceReminder: String? {
        guard tutor == nil, tutorPicker == nil else { return nil }
        if isFixture || ShotMode.active {
            guard inferenceReminderInShots else { return nil }
        } else if llmStatuses.isEmpty {
            return nil
        }
        return inferenceSetup.reminder(enabled: config.llm.setupReminder, hiddenThisLaunch: inferenceReminderHidden)
    }

    /// `inference.setup`: Settings, on the pane.
    func openInferenceSetup() {
        settingsSection = .inference
        openSettings?()
        guard !isFixture else { return }
        localModel = LocalModels.availability
        Task { await refreshLLMStatuses() }
        Task { await hunch.refresh() }
    }

    /// `inference.hide [always]`, or the reminder's ×: hidden until the next launch; `always` turns it off in
    /// config.toml (`[llm] setup_reminder = false`).
    func hideInferenceReminder(always: Bool) {
        if always {
            if !isFixture { setConfig(["llm", "setup_reminder"], .bool(false)) }
            flash = "setup reminder off; :inference.setup still opens the pane"
        } else {
            guard inferenceReminder != nil else { return flash = "no setup reminder here" }
            flash = "reminder hidden until the next launch; :inference.setup opens the pane"
        }
        inferenceReminderHidden = true
    }

    /// One click: the suggested agent and decider written to config.toml, then both tested.
    func applySuggestedSetup() {
        let setup = inferenceSetup
        if let agent = setup.suggestedAgent {
            setConfig(["llm", "agent"], .string(agent))
            testInference(chosen: agent)
        }
        setConfig(["decisions", "decider"], .string(setup.suggestedDecider.rawValue))
        if setup.suggestedDecider != .off { testDecision(choice: setup.suggestedDecider) }
    }

    /// One tiny call to the chosen agent (for `auto`, the first one logged in), never cached. `chosen`: the
    /// `[llm] agent` value to test, when config.toml was just written and is not read back yet.
    func testInference(chosen: String? = nil) {
        let subject = chosen ?? config.llm.agent ?? LLMSettings.auto
        let only = subject == LLMSettings.auto ? nil : subject
        guard let agent = only ?? inferenceSetup.suggestedAgent else {
            setupTests.inference = SetupTest(
                subject: subject, ok: false, detail: "no agent is installed and logged in", at: Clock.now
            )
            return
        }
        guard !isFixture, llmTests[agent]?.running != true else { return }
        llmTests[agent] = LLMTest(running: true)
        let request = LLMRequest(
            call: LLMCall(
                system: "You check that a connection works. Reply in at most five words.", prompt: "Say hello."
            ),
            priority: .interactive, caller: "settings.test", operation: "test", agent: agent, cached: false
        )
        Task {
            do {
                let response = try await runLLM(request)
                let answer = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                llmTests[agent] = LLMTest(
                    answer: answer, model: response.model, seconds: response.duration, cost: response.cost
                )
                setupTests.inference = SetupTest(
                    subject: subject, ok: true, detail: answer, seconds: response.duration, at: Clock.now
                )
            } catch {
                llmTests[agent] = LLMTest(error: "\(error)")
                setupTests.inference = SetupTest(subject: subject, ok: false, detail: "\(error)", at: Clock.now)
            }
            await refreshLLMStatuses()
        }
    }

    /// The question the decision test asks: its answer is plain from the state.
    static let testQuestion = Question.choice(
        instructions: "Where does this work stand?", options: ["working", "waiting for you", "done"]
    )
    static let testState = "The agent said: All tests pass and the pull request is merged. Nothing is left to do."

    /// One decision through `choice` (default: the one chosen), shown with its pick, confidence and time.
    func testDecision(choice: DecisionSettings.Choice? = nil) {
        let choice = choice ?? config.decisions.effective
        guard !isFixture, decisionTest?.running != true else { return }
        decisionTest = DecisionTest(running: true)
        let decider = decider(caller: "settings.test", priority: .interactive, choice: choice)
        let started = Date()
        Task {
            do {
                let answers = try await decider.decide(
                    subject: "settings.test", state: Self.testState, questions: ["stands": Self.testQuestion]
                )
                let seconds = Date().timeIntervalSince(started)
                let answer = answers["stands"].map { "\($0.choice ?? "?") (confidence \(Int($0.confidence * 100))%)" }
                    ?? "?"
                decisionTest = DecisionTest(answer: answer, seconds: seconds)
                setupTests.decisions = SetupTest(
                    subject: choice.rawValue, ok: true, detail: answer, seconds: seconds, at: Clock.now
                )
            } catch {
                decisionTest = DecisionTest(error: "\(error)")
                setupTests.decisions = SetupTest(
                    subject: choice.rawValue, ok: false, detail: "\(error)", at: Clock.now
                )
            }
        }
    }

    /// Whether anything can answer a decision now: what features check before asking.
    var decisionsOn: Bool {
        switch config.decisions.effective {
        case .local: localModel.ready
        case .hunch: hunch.status.modelReady || localModel.ready || config.llm.enabled
        case .model: config.llm.enabled
        case .off: false
        }
    }

    /// Apple's on-device model as a Decider, or one that says why it cannot run.
    func localDecider(caller: String) -> any Decider {
        LocalDecider(caller: caller) { prompt in try await LocalModels.ask(prompt) }
    }

    // MARK: Kept between launches

    private static let setupTestsKey = "inferenceSetupTests"

    func loadInferenceSetup() {
        localModel = LocalModels.availability
        if let data = UserDefaults.standard.data(forKey: Self.setupTestsKey),
           let tests = try? JSONDecoder().decode(SetupTests.self, from: data)
        {
            setupTests = tests
        }
    }

    func saveSetupTests() {
        guard !isFixture, !ShotMode.active, let data = try? JSONEncoder().encode(setupTests) else { return }
        UserDefaults.standard.set(data, forKey: Self.setupTestsKey)
    }
}

/// Apple's on-device model (FoundationModels): whether it can run here, and asking it a `LocalDecider` prompt.
enum LocalModels {
    static var availability: LocalModel {
        #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                switch SystemLanguageModel.default.availability {
                case .available: return .available
                case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
                case .unavailable(.modelNotReady): return .notReady
                case .unavailable(.deviceNotEligible): return .notEligible
                case .unavailable: return .unsupported
                }
            }
        #endif
        return .unsupported
    }

    /// Each field one of its options, in one structured answer at temperature 0.
    static func ask(_ prompt: LocalDecider.Prompt) async throws -> [String: String] {
        let availability = availability
        guard availability.ready else { throw DeciderError.unavailable(availability.description) }
        #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                let properties = prompt.fields.map { field in
                    DynamicGenerationSchema.Property(
                        name: field.name,
                        schema: DynamicGenerationSchema(
                            name: field.name, description: field.description, anyOf: field.options
                        )
                    )
                }
                let schema = try GenerationSchema(
                    root: DynamicGenerationSchema(name: "Decision", properties: properties), dependencies: []
                )
                let session = LanguageModelSession(instructions: prompt.instructions)
                let response = try await session.respond(
                    to: prompt.prompt, schema: schema, options: GenerationOptions(temperature: 0)
                )
                var picks: [String: String] = [:]
                for field in prompt.fields {
                    picks[field.name] = try? response.content.value(String.self, forProperty: field.name)
                }
                return picks
            }
        #endif
        throw DeciderError.unavailable(LocalModel.unsupported.description)
    }
}
