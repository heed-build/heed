import Foundation

/// `[llm]` and the `llm` / `llm_model` keys of `[agents.<name>]`: heed's own short model calls (summaries, typed
/// decisions), made headless through the agent CLIs you are logged in to, round-robin. No API keys.
public struct LLMSettings: Equatable, Sendable {
    /// Off: heed makes no model calls of its own at all.
    public var enabled = true
    /// A call still running after this long is stopped.
    public var timeoutSeconds = 120
    /// Calls running at once; more wait, interactive ones first.
    public var concurrency = 2
    /// An agent whose call failed is skipped for this long.
    public var backoffMinutes = 10
    /// Per agent per day: background calls stop for the day at this many calls, or once this many dollars were spent
    /// (counted only where a cost is known: reported by the agent, or estimated from `[usage.prices]`). 0: no cap.
    public var dailyCalls = 100
    public var dailyDollars = 1.0
    /// Per agent (`[agents.<name>] llm = false`, `llm_model = "..."`): absent means on, with the detected cheap model.
    public var agents: [String: Agent] = [:]

    public struct Agent: Equatable, Sendable {
        /// nil: on (the default).
        public var enabled: Bool?
        /// nil or empty: the cheap model heed detects.
        public var model: String?

        public init(enabled: Bool? = nil, model: String? = nil) {
            self.enabled = enabled
            self.model = model
        }
    }

    public init() {}

    public func isEnabled(_ agent: String) -> Bool { agents[agent]?.enabled ?? true }

    /// The model set for `agent`, nil to use the detected one.
    public func model(for agent: String) -> String? {
        guard let model = agents[agent]?.model?.trimmingCharacters(in: .whitespaces), !model.isEmpty else {
            return nil
        }
        return model
    }
}
