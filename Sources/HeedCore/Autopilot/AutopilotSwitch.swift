import Foundation

/// Turning a capability on, to ask first, or off, as Autopilot's `y` `a` `x` and `Y` do: the config.toml keys it
/// writes, the same ones Settings writes (`[repos."org/name"] green = "auto"`, `[cleanup] enabled = true`).
public enum AutopilotSwitch {
    public enum Choice: String, Sendable {
        case on, ask, off
    }

    /// One key to write; a nil value removes it (the repo goes back to what it inherits).
    public struct Write: Equatable, Sendable {
        public var path: [String]
        public var value: TOMLValue?

        public init(_ path: [String], _ value: TOMLValue?) {
            self.path = path
            self.value = value
        }
    }

    public enum Refusal: Error, Equatable, Sendable {
        /// The capability has no such choice: why, in a line.
        case noChoice(String)
    }

    /// The default continue prompt, written when Continue is turned on with none.
    public static let continuePrompt = "Continue where you left off."

    /// What `choice` writes for `capability`: in `repo` for a per-repo one (nil: the `[pilot]` default), else its own
    /// section.
    public static func writes(
        _ capability: Capability, _ choice: Choice, repo: Repo?, config: HeedConfig,
        facts: AutopilotRepoFacts = AutopilotRepoFacts()
    ) throws(Refusal) -> [Write] {
        let base = repo.map { ["repos", $0.slug] } ?? ["pilot"]
        let settings = repo.map(config.pilot.resolve) ?? config.pilot.defaults
        switch capability {
        case .green:
            let value = switch choice {
            case .on: "auto"
            case .ask: "ask"
            case .off: "off"
            }
            var writes = [Write(base + ["green"], .string(value))]
            if choice != .off, !settings.watch { writes.append(Write(base + ["watch"], .bool(true))) }
            return writes
        case .merge:
            switch choice {
            case .ask: throw .noChoice("merge has no ask-first: zM merges one PR now, and asks first")
            case .off: return [Write(base + ["merge"], .string("off"))]
            case .on:
                // GitHub's auto-merge where the repo allows it, else heed's own rules.
                let mode = facts.allowsAutoMerge == false ? "heed" : "auto"
                return [Write(base + ["merge"], .string(mode))]
            }
        case .copilot:
            switch choice {
            case .ask: throw .noChoice("Copilot has no ask-first: the PR overlay's C asks it for one PR")
            case .on, .off:
                return [
                    Write(base + ["copilot_conflicts"], .bool(choice == .on)),
                    Write(base + ["copilot_comments"], .bool(choice == .on)),
                ]
            }
        case .reviewers:
            switch choice {
            case .ask: throw .noChoice("reviewers has no ask-first: zv asks them for one PR")
            case .off: return [Write(base + ["reviewers"], .array([]))]
            case .on:
                let names = settings.reviewers.isEmpty ? ["copilot"] : settings.reviewers
                return [Write(base + ["reviewers"], .array(names.map(TOMLValue.string)))]
            }
        case .cleanup:
            return switch choice {
            case .on: [Write(["cleanup", "enabled"], .bool(true)), Write(["cleanup", "ask_before_sweep"], .bool(false))]
            case .ask: [Write(["cleanup", "enabled"], .bool(true)), Write(["cleanup", "ask_before_sweep"], .bool(true))]
            case .off: [Write(["cleanup", "enabled"], .bool(false))]
            }
        case .goals:
            guard choice != .ask else { throw .noChoice("goals asks on its own when it is not sure") }
            return [Write(["goals", "attach"], .bool(choice == .on))]
        case .summaries:
            let value = switch choice {
            case .on: "ahead"
            case .ask: "open"
            case .off: "off"
            }
            return [Write(["attention", "summaries"], .string(value))]
        case .resume:
            switch choice {
            case .ask: throw .noChoice("continue has no ask-first")
            case .off: return [Write(["sessions", "continue_prompt"], .string(""))]
            case .on:
                let prompt = config.work.continuePrompt.isEmpty ? continuePrompt : config.work.continuePrompt
                return [Write(["sessions", "continue_prompt"], .string(prompt))]
            }
        case .names:
            guard choice != .ask else { throw .noChoice("names has no ask-first: session.rename titles one yourself") }
            return [Write(["sessions", "name_sessions"], .bool(choice == .on))]
        }
    }

    /// `Y`: on everywhere. A per-repo one is set in `[pilot]`, and every org and repo that says otherwise goes back to
    /// inheriting it.
    public static func everywhere(
        _ capability: Capability, config: HeedConfig, facts: [String: AutopilotRepoFacts] = [:]
    ) throws(Refusal) -> [Write] {
        guard capability.scope == .perRepo else {
            return try writes(capability, .on, repo: nil, config: config)
        }
        // Auto-merge only when no repo is known to refuse it.
        let refuses = facts.values.contains { $0.allowsAutoMerge == false }
        var writes = try writes(
            capability, .on, repo: nil, config: config,
            facts: AutopilotRepoFacts(allowsAutoMerge: refuses ? false : nil)
        )
        let keys = Set(writes.map { $0.path.last ?? "" })
        for (level, overrides) in [("orgs", config.pilot.orgs), ("repos", config.pilot.repos)] {
            for name in overrides.keys.sorted() {
                for key in keys.sorted() where overrides[name].map({ set($0, key) }) == true {
                    writes.append(Write([level, name, key], nil))
                }
            }
        }
        return writes
    }

    /// Whether an override sets `key`.
    static func set(_ overrides: PilotOverrides, _ key: String) -> Bool {
        switch key {
        case "green": overrides.green != nil
        case "watch": overrides.watch != nil
        case "merge": overrides.merge != nil
        case "copilot_conflicts": overrides.copilotConflicts != nil
        case "copilot_comments": overrides.copilotComments != nil
        case "reviewers": overrides.reviewers != nil
        default: false
        }
    }

    /// The writes applied to a config in memory, as reading the written file back would: what the fake world does,
    /// where nothing is written to disk.
    public static func apply(_ writes: [Write], to config: inout HeedConfig) {
        for write in writes {
            let path = write.path
            guard let key = path.last else { continue }
            switch path.first {
            case "pilot" where path.count == 2:
                var defaults = config.pilot.defaults
                assign(key, write.value, defaults: &defaults)
                config.pilot.defaults = defaults
            case "repos" where path.count == 3:
                var overrides = config.pilot.repos[path[1]] ?? PilotOverrides()
                assign(key, write.value, overrides: &overrides)
                config.pilot.repos[path[1]] = overrides.isEmpty ? nil : overrides
            case "orgs" where path.count == 3:
                var overrides = config.pilot.orgs[path[1]] ?? PilotOverrides()
                assign(key, write.value, overrides: &overrides)
                config.pilot.orgs[path[1]] = overrides.isEmpty ? nil : overrides
            case "cleanup":
                if key == "enabled" { config.cleanup.enabled = write.value?.bool ?? false }
                if key == "ask_before_sweep" { config.cleanup.askBeforeSweep = write.value?.bool ?? false }
            case "goals" where key == "attach": config.goals.attach.enabled = write.value?.bool ?? true
            case "attention" where key == "summaries":
                config.attention.summaries = write.value?.string.flatMap(AttentionSummaryMode.init) ?? .ahead
            case "sessions" where key == "continue_prompt":
                config.work.continuePrompt = write.value?.string ?? continuePrompt
            case "sessions" where key == "name_sessions": config.work.nameSessions = write.value?.bool ?? true
            default: break
            }
        }
    }

    private static func assign(_ key: String, _ value: TOMLValue?, overrides: inout PilotOverrides) {
        switch key {
        case "green": overrides.green = value?.string.flatMap(AutoFeed.named)
        case "watch": overrides.watch = value?.bool
        case "merge": overrides.merge = value?.string.flatMap(MergeMode.named)
        case "copilot_conflicts": overrides.copilotConflicts = value?.bool
        case "copilot_comments": overrides.copilotComments = value?.bool
        case "reviewers": overrides.reviewers = value?.array?.compactMap(\.string)
        default: break
        }
    }

    private static func assign(_ key: String, _ value: TOMLValue?, defaults: inout PilotSettings) {
        switch key {
        case "green": defaults.green = value?.string.flatMap(AutoFeed.named) ?? .ask
        case "watch": defaults.watch = value?.bool ?? true
        case "merge": defaults.merge = value?.string.flatMap(MergeMode.named) ?? .off
        case "copilot_conflicts": defaults.copilotConflicts = value?.bool ?? false
        case "copilot_comments": defaults.copilotComments = value?.bool ?? false
        case "reviewers": defaults.reviewers = value?.array?.compactMap(\.string) ?? []
        default: break
        }
    }
}
