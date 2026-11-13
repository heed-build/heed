import Foundation

/// One cell of Autopilot's Where: a capability in a repo (or everywhere), as config says it is now.
public struct AutopilotCell: Hashable, Sendable {
    public enum State: String, Hashable, Sendable {
        case on, ask, off
    }

    public var state: State
    /// What config says, in its own word: `auto`, `heed`, `on`, `copilot`, `2 asked`, `ahead`, `off`.
    public var value: String
    /// What it did there this week, or a reason it cannot work (`auto-merge off on GitHub`).
    public var note: String?
    /// The note is a reason it cannot work, not a count.
    public var warning = false

    public init(_ state: State, _ value: String, note: String? = nil, warning: Bool = false) {
        self.state = state
        self.value = value
        self.note = note
        self.warning = warning
    }
}

/// What heed knows about a repo beyond config: whether GitHub lets it auto-merge, and whether Copilot can work there.
/// Nil when it has not seen it yet.
public struct AutopilotRepoFacts: Hashable, Sendable {
    public var allowsAutoMerge: Bool?
    public var copilotAvailable: Bool?

    public init(allowsAutoMerge: Bool? = nil, copilotAvailable: Bool? = nil) {
        self.allowsAutoMerge = allowsAutoMerge
        self.copilotAvailable = copilotAvailable
    }
}

/// Where each capability is on: per repo from the `[pilot]` levels, once for everything from its own section.
public enum AutopilotCoverage {
    /// A per-repo capability in `repo`, as `rules` resolve it; a global one reads `config`.
    public static func cell(
        _ capability: Capability, repo: Repo, config: HeedConfig, facts: AutopilotRepoFacts = AutopilotRepoFacts()
    ) -> AutopilotCell {
        let settings = config.pilot.resolve(repo)
        switch capability {
        case .green:
            guard settings.watch else { return AutopilotCell(.off, "off", note: "not watched") }
            return switch settings.green {
            case .auto: AutopilotCell(.on, "auto")
            case .ask: AutopilotCell(.ask, "ask")
            case .off: AutopilotCell(.off, "off")
            }
        case .merge:
            switch settings.merge {
            case .off: return AutopilotCell(.off, "off")
            case .heed: return AutopilotCell(.on, "heed")
            case .auto:
                if facts.allowsAutoMerge == false {
                    return AutopilotCell(.ask, "held", note: "auto-merge off on GitHub", warning: true)
                }
                return AutopilotCell(.on, "auto")
            }
        case .copilot:
            if facts.copilotAvailable == false { return AutopilotCell(.off, "no agent") }
            return switch (settings.copilotConflicts, settings.copilotComments) {
            case (true, true): AutopilotCell(.on, "on")
            case (true, false): AutopilotCell(.on, "conflicts")
            case (false, true): AutopilotCell(.on, "comments")
            case (false, false): AutopilotCell(.off, "off")
            }
        case .reviewers:
            let names = settings.reviewers
            if names.isEmpty { return AutopilotCell(.off, "none") }
            return AutopilotCell(.on, names.count == 1 ? names[0] : "\(names.count) asked")
        case .cleanup, .goals, .summaries, .resume, .names:
            return global(capability, config: config)
        }
    }

    /// A capability set once for every repo.
    public static func global(_ capability: Capability, config: HeedConfig) -> AutopilotCell {
        switch capability {
        case .cleanup:
            guard config.cleanup.enabled else { return AutopilotCell(.off, "off") }
            return config.cleanup.askBeforeSweep ? AutopilotCell(.ask, "ask") : AutopilotCell(.on, "on")
        case .goals:
            return config.goals.attach.enabled ? AutopilotCell(.on, "on") : AutopilotCell(.off, "off")
        case .summaries:
            return switch config.attention.summaries {
            case .ahead: AutopilotCell(.on, "ahead")
            case .open: AutopilotCell(.ask, "on open")
            case .off: AutopilotCell(.off, "off")
            }
        case .resume:
            return config.work.continuePrompt.isEmpty ? AutopilotCell(.off, "off") : AutopilotCell(.on, "on")
        case .names:
            return config.work.nameSessions ? AutopilotCell(.on, "on") : AutopilotCell(.off, "off")
        case .green, .merge, .copilot, .reviewers:
            // Per repo: its default, as a repo with no overrides of its own gets it.
            return cell(capability, repo: Repo(org: "", name: ""), config: config)
        }
    }

    /// How much of it is on: across `repos` for a per-repo one.
    public struct Summary: Hashable, Sendable {
        public var on = 0
        public var ask = 0
        public var total = 0
        /// A global one's cell.
        public var global: AutopilotCell?

        /// The coverage bar's fill, 0…1: an ask counts half.
        public var fraction: Double {
            if let global { return global.state == .on ? 1 : global.state == .ask ? 0.5 : 0 }
            guard total > 0 else { return 0 }
            return (Double(on) + Double(ask) / 2) / Double(total)
        }

        /// `on in 3 of 5 repos`, `asks in 2 of 5 repos`, `off in every repo`, `ahead`, `off`.
        public var text: String {
            if let global { return global.value }
            if total == 0 { return "no repos yet" }
            if on == 0, ask == 0 { return "off in every repo" }
            if on == total { return "on in every repo" }
            let repos = "of \(total) repo\(total == 1 ? "" : "s")"
            if on == 0 { return "asks in \(ask) \(repos)" }
            return "on in \(on) \(repos)" + (ask > 0 ? " · \(ask) ask" : "")
        }

        /// Off somewhere: a repo where it is off, or a global one that is off.
        public var offCount: Int {
            if let global { return global.state == .off ? 1 : 0 }
            return total - on - ask
        }
    }

    public static func summary(
        _ capability: Capability, repos: [Repo], config: HeedConfig, facts: [String: AutopilotRepoFacts] = [:]
    ) -> Summary {
        guard capability.scope == .perRepo else { return Summary(global: global(capability, config: config)) }
        var summary = Summary(total: repos.count)
        for repo in repos {
            switch cell(capability, repo: repo, config: config, facts: facts[repo.slug] ?? AutopilotRepoFacts()).state {
            case .on: summary.on += 1
            case .ask: summary.ask += 1
            case .off: break
            }
        }
        return summary
    }

    /// Where's tab count: how many capabilities are off somewhere (in at least one repo, or off everywhere).
    public static func offCount(repos: [Repo], config: HeedConfig, facts: [String: AutopilotRepoFacts] = [:]) -> Int {
        Capability.allCases.count { summary($0, repos: repos, config: config, facts: facts).offCount > 0 }
    }
}
