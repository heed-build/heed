import Foundation

/// How much model a call is worth: `cheap` (the model heed detects for short calls, today's default), `standard` (the
/// next step up) and `strong` (the agent's strongest). A feature asks for a tier; each agent's dialect says which
/// model that is.
public enum LLMTier: String, Hashable, Sendable, Codable, CaseIterable {
    case cheap, standard, strong

    public var label: String { rawValue }

    /// The model this tier names for `dialect`, where heed knows one without asking the CLI: claude's aliases. nil is
    /// the agent's own default: for `cheap` the model heed detects (`LLMDialect.cheapModel`), for the others what the
    /// CLI runs when no model is given (codex's default is its standard and its strongest model).
    public func model(for dialect: LLMDialect) -> String? {
        switch (self, dialect) {
        case (.cheap, _): dialect.fixedModel
        case (.standard, .claude): "sonnet"
        case (.strong, .claude): "opus"
        default: nil
        }
    }

    /// The same by the agent's name; nil for an agent heed has no dialect for.
    public func model(agent: String) -> String? {
        LLMDialect(rawValue: agent).flatMap { model(for: $0) }
    }

    /// For the call log: what this tier meant for `agent`, saying so when it fell back to the agent's default.
    public func note(agent: String, model: String?) -> String {
        if let model { return "\(rawValue): \(model)" }
        return switch self {
        case .cheap: "cheap: no model detected for \(agent), its own default"
        case .standard, .strong: "\(rawValue): no \(rawValue) model known for \(agent), its own default"
        }
    }

    /// What the tier means, for Settings: the model it names and what the call can do.
    public var summary: String {
        switch self {
        case .cheap: "What heed's short model calls use (haiku for claude, a small one for the others). They read the diff only."
        case .standard: "The next step up: sonnet for claude, the agent's own default for the others. They read the diff only."
        case .strong: "claude's opus, or the agent's own default, run headless and read-only in the session's worktree: the personas can read the code around the diff. Slower and dearer."
        }
    }
}
