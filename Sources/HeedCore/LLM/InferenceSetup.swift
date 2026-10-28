import Foundation

/// How a test in Settings › Inference & decisions went: one tiny model call, or one decision. Kept between launches,
/// so a failed one still says so (and reminds you) after a restart.
public struct SetupTest: Codable, Equatable, Sendable {
    /// What was tested: the `[llm] agent` value, or the `[decisions] decider`.
    public var subject: String
    public var ok: Bool
    /// The answer, or the error.
    public var detail: String
    public var seconds: Double?
    public var at: Date

    public init(subject: String, ok: Bool, detail: String, seconds: Double? = nil, at: Date) {
        self.subject = subject
        self.ok = ok
        self.detail = detail
        self.seconds = seconds
        self.at = at
    }
}

public struct SetupTests: Codable, Equatable, Sendable {
    public var inference: SetupTest?
    public var decisions: SetupTest?

    public init(inference: SetupTest? = nil, decisions: SetupTest? = nil) {
        self.inference = inference
        self.decisions = decisions
    }
}

/// Where one half of the setup stands.
public enum SetupState: Equatable, Sendable {
    case configured(String)
    case notConfigured(String)
    case failing(String)
    /// Turned off on purpose: nothing to remind you of, but what needs it goes without.
    case off(String)

    public var label: String {
        switch self {
        case .configured: "configured"
        case .notConfigured: "not configured"
        case .failing: "failing"
        case .off: "off"
        }
    }

    public var detail: String {
        switch self {
        case let .configured(text), let .notConfigured(text), let .failing(text), let .off(text): text
        }
    }

    /// Not chosen yet, or chosen and not working.
    public var needsAttention: Bool {
        switch self {
        case .notConfigured, .failing: true
        case .configured, .off: false
        }
    }
}

/// Settings › Inference & decisions, decided: where model calls (`[llm]`) and decisions (`[decisions]`) stand, what
/// detection suggests for each, what goes without while they do not work, and whether the title bar reminds you.
public struct InferenceSetup: Equatable, Sendable {
    public var inference: SetupState
    public var decisions: SetupState
    /// The agent one click sets up: the first one logged in, in the built-in order; nil when there is none.
    public var suggestedAgent: String?
    public var suggestedDecider: DecisionSettings.Choice
    /// What does not happen as things stand, for the status at the top of the pane.
    public var degraded: [String]
    /// Where Hunch stands, for the status and the reminder.
    public var hunch: HunchStatus = .unavailable("not checked")
    /// `[decisions] decider`, nil when not chosen.
    public var chosenDecider: DecisionSettings.Choice?

    /// What needs a model call.
    public static let inferenceFeatures = [
        "History's ledger summaries",
        "Attention's thread summaries and drafted replies",
        "goal plans, edits, personas and walk-throughs",
        "finding new work's goal when the signals are unsure",
    ]

    /// What needs a decision.
    public static let decisionFeatures = [
        "Attention's suggested weights for items no rule matched",
        "telling a new goal item from one the board has",
        "goal quality profiles and matching reviewers' objections",
    ]

    /// `statuses`: what detection found, nil before it ran (then a chosen agent is taken to work).
    /// `hunch`: where Hunch stands on this Mac.
    public static func evaluate(
        llm: LLMSettings, decisions: DecisionSettings, statuses: [LLMAgentStatus]?, local: LocalModel,
        tests: SetupTests, hunch: HunchStatus = .unavailable("not checked")
    ) -> InferenceSetup {
        let agent = suggestedAgent(statuses ?? [])
        // Hunch chosen stays chosen: Set up never trades it for another decider while its model is missing or
        // downloading.
        let decider = decisions.decider == .hunch ? .hunch : suggestedDecider(local: local, agent: agent, hunch: hunch)
        let inference = inferenceState(llm: llm, statuses: statuses, suggested: agent, test: tests.inference)
        let chosen = decisions.decider
        let decisions = decisionState(
            decisions, inference: inference, local: local, suggested: decider, test: tests.decisions, hunch: hunch
        )
        let inferenceWorks = switch inference {
        case .configured: true
        case .notConfigured: statuses.map { $0.contains { $0.usable && llm.isEnabled($0.name) } } ?? true
        case .failing, .off: false
        }
        let decisionsWork = switch decisions {
        case .configured: true
        case .notConfigured: inferenceWorks
        case .failing, .off: false
        }
        return InferenceSetup(
            inference: inference, decisions: decisions, suggestedAgent: agent, suggestedDecider: decider,
            degraded: (inferenceWorks ? [] : inferenceFeatures) + (decisionsWork ? [] : decisionFeatures),
            hunch: hunch, chosenDecider: chosen
        )
    }

    /// The first agent logged in, in the built-in order (claude, codex, cursor, pi, opencode, gemini); else the first
    /// installed one without a login check.
    public static func suggestedAgent(_ statuses: [LLMAgentStatus]) -> String? {
        statuses.first { $0.login == .loggedIn }?.name ?? statuses.first { $0.login == .unknown }?.name
    }

    /// Hunch once its model is downloaded (you downloaded it to use it), else Apple's on-device model when this Mac
    /// has it (free, private), else a model call when there is an agent for it, else off. Set up never downloads a
    /// model: the pane offers that as its own button, with its size.
    public static func suggestedDecider(
        local: LocalModel, agent: String?, hunch: HunchStatus = .unavailable("not checked")
    ) -> DecisionSettings.Choice {
        if hunch.modelReady { return .hunch }
        if local.ready { return .local }
        return agent == nil ? .off : .model
    }

    static func inferenceState(
        llm: LLMSettings, statuses: [LLMAgentStatus]?, suggested: String?, test: SetupTest?
    ) -> SetupState {
        guard llm.enabled else { return .off("Model calls are off ([llm] enabled = false): heed makes none.") }
        guard let chosen = llm.agent else {
            return .notConfigured(suggested.map {
                "Not chosen yet: calls take turns over every agent you are logged in to. Suggested: \($0)."
            } ?? "No agent heed can call is installed and logged in.")
        }
        if let test, test.subject == chosen, !test.ok { return .failing("The last test failed: \(test.detail)") }
        if let name = llm.only {
            guard let statuses else { return .configured("\(name), \(llm.model(for: name) ?? "its cheap model").") }
            guard let status = statuses.first(where: { $0.name == name }) else {
                return .failing("\(name) is not an agent heed can make model calls through.")
            }
            switch status.login {
            case .notInstalled: return .failing("\(name) is not installed.")
            case .loggedOut: return .failing("\(name) is not logged in.")
            case .loggedIn, .unknown: break
            }
            let model = llm.model(for: name) ?? status.detectedModel ?? "its default model"
            return .configured("\(name), \(model).")
        }
        guard let statuses else { return .configured("Every agent you are logged in to, taking turns.") }
        let usable = statuses.filter { $0.usable && llm.isEnabled($0.name) }.map(\.name)
        guard !usable.isEmpty else { return .failing("No agent heed can call is installed and logged in.") }
        return .configured("Every agent you are logged in to, taking turns: \(usable.joined(separator: ", ")).")
    }

    static func decisionState(
        _ decisions: DecisionSettings, inference: SetupState, local: LocalModel, suggested: DecisionSettings.Choice,
        test: SetupTest?, hunch: HunchStatus = .unavailable("not checked")
    ) -> SetupState {
        guard let chosen = decisions.decider else {
            return .notConfigured("Not chosen yet: decisions go to a model call. Suggested: \(name(suggested)).")
        }
        if let test, test.subject == chosen.rawValue, !test.ok {
            return .failing("The last test failed: \(test.detail)")
        }
        switch chosen {
        case .off: return .off("Decisions are off ([decisions] decider = \"off\").")
        case .local:
            return local.ready ? .configured("Apple's on-device model, on this Mac.") : .failing(local.description)
        case .hunch:
            let rest = switch HunchRouting.overflow(localReady: local.ready, modelCalls: inferenceWorks(inference)) {
            case .local: "Apple's on-device model"
            case .model: "a model call"
            case .hunch, .none: "nothing (they go unanswered)"
            }
            switch hunch {
            case let .unavailable(why): return .failing(why)
            case .noModel:
                return .failing("Hunch has no model yet: download one below. Until then decisions go to \(rest).")
            case let .downloading(fraction):
                return .configured(
                    "Hunch's model is downloading\(HunchStatus.percent(fraction)). Until then decisions go to \(rest)."
                )
            case let .stopped(fraction, reason):
                return .failing(
                    "Hunch's download stopped\(HunchStatus.percent(fraction))\(reason.map { " (\($0))" } ?? ""): "
                        + "Download resumes it. Until then decisions go to \(rest)."
                )
            case .ready:
                return .configured("Hunch on this Mac; choices among many options go to \(rest).")
            case .learning:
                return .configured("Hunch on this Mac, learning from your corrections now; many options go to \(rest).")
            }
        case .model:
            switch inference {
            case .off: return .failing("A model call, but model calls are off.")
            case .failing: return .failing("A model call, but model calls are failing.")
            case .configured, .notConfigured: return .configured("A model call, through Inference above.")
            }
        }
    }

    static func inferenceWorks(_ inference: SetupState) -> Bool {
        switch inference {
        case .configured, .notConfigured: true
        case .failing, .off: false
        }
    }

    /// How the pane and the docs name a decider.
    public static func name(_ choice: DecisionSettings.Choice) -> String {
        switch choice {
        case .local: "Apple's on-device model"
        case .hunch: "Hunch"
        case .model: "a model call"
        case .off: "off"
        }
    }

    public var needsAttention: Bool { inference.needsAttention || decisions.needsAttention }

    /// Decisions are Hunch's.
    var hunchChosen: Bool { chosenDecider == .hunch }

    /// The reminder's words for Hunch while it needs you.
    var hunchReminder: String? {
        switch hunch {
        case .noModel: "Hunch has no model"
        case let .downloading(fraction): "Hunch downloading" + HunchStatus.percent(fraction)
        case .stopped: "Hunch's download stopped"
        case .unavailable: "Hunch unavailable"
        case .ready, .learning: nil
        }
    }

    /// The title bar's reminder, or nil: only while something needs attention, `[llm] setup_reminder` is on and it was
    /// not hidden in this launch.
    public func reminder(enabled: Bool, hiddenThisLaunch: Bool) -> String? {
        guard enabled, !hiddenThisLaunch else { return nil }
        // A download in progress is news, not a problem: it shows while it runs.
        if hunchChosen, case .downloading = hunch, !inference.needsAttention { return hunchReminder }
        guard needsAttention else { return nil }
        if case .failing = inference { return "Model calls failing" }
        if hunchChosen, let hunch = hunchReminder { return hunch }
        if case .failing = decisions { return "Decisions failing" }
        return "Set up model calls"
    }
}
