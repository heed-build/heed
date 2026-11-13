import Foundation

/// What heed saw that a capability would have helped with, from what it records and holds now. Never a guess: each
/// counts something heed has (items you sent yourself, green PRs nobody merges, worktrees the sweep would remove).
public struct AutopilotSignals: Hashable, Sendable {
    /// Items you sent to an agent yourself this week, by repo (`AutopilotDone.sentByYou`).
    public var sentByYou: [String: Int] = [:]
    /// Open green PRs with merging off, by repo.
    public var greenWaiting: [String: Int] = [:]
    /// Open PRs your sessions track that are not watched, by repo.
    public var unwatched: [String: Int] = [:]
    /// Open PRs that conflict with their base, by repo.
    public var conflicting: [String: Int] = [:]
    /// Open, ready PRs nobody was asked to review by heed, by repo.
    public var unreviewed: [String: Int] = [:]
    /// Worktrees the sweep would remove on its next run if it were on, by repo.
    public var removable: [String: Int] = [:]
    /// heed's goal asks waiting for you.
    public var openAsks = 0

    public init(
        sentByYou: [String: Int] = [:], greenWaiting: [String: Int] = [:], unwatched: [String: Int] = [:],
        conflicting: [String: Int] = [:], unreviewed: [String: Int] = [:], removable: [String: Int] = [:],
        openAsks: Int = 0
    ) {
        self.sentByYou = sentByYou
        self.greenWaiting = greenWaiting
        self.unwatched = unwatched
        self.conflicting = conflicting
        self.unreviewed = unreviewed
        self.removable = removable
        self.openAsks = openAsks
    }
}

public struct AutopilotNudge: Hashable, Sendable {
    public var capability: Capability
    /// `org/name`, for a per-repo one.
    public var repo: String?
    /// The Where column's short form: `green: 7 sent by hand`.
    public var short: String
    /// The sentence: `docs-website: you sent 7 items to its agents by hand this week.`
    public var text: String
    /// How much it would help; the strongest wins a repo's could-help column.
    public var weight: Int
}

public enum AutopilotNudges {
    static func plural(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }

    /// Every nudge heed can back with a number, strongest first.
    public static func all(
        repos: [Repo], config: HeedConfig, facts: [String: AutopilotRepoFacts] = [:], signals: AutopilotSignals
    ) -> [AutopilotNudge] {
        var nudges: [AutopilotNudge] = []
        for repo in repos {
            let fact = facts[repo.slug] ?? AutopilotRepoFacts()
            func cell(_ capability: Capability) -> AutopilotCell {
                AutopilotCoverage.cell(capability, repo: repo, config: config, facts: fact)
            }
            let slug = repo.slug
            if cell(.green).state != .on, let sent = signals.sentByYou[slug], sent > 0 {
                nudges.append(AutopilotNudge(
                    capability: .green, repo: slug, short: "green: \(sent) sent by hand",
                    text: "\(repo.name): you sent \(plural(sent, "item")) to its agents by hand this week; on auto "
                        + "heed sends them and checks after each push.",
                    weight: sent * 3
                ))
            }
            if cell(.merge).state == .off, let waiting = signals.greenWaiting[slug], waiting > 0 {
                nudges.append(AutopilotNudge(
                    capability: .merge, repo: slug, short: "merge: \(plural(waiting, "green PR")) waiting",
                    text: "\(repo.name): \(plural(waiting, "green PR")) \(waiting == 1 ? "waits" : "wait") for "
                        + "someone to merge \(waiting == 1 ? "it" : "them").",
                    weight: waiting * 4
                ))
            }
            let merge = cell(.merge)
            if merge.warning {
                nudges.append(AutopilotNudge(
                    capability: .merge, repo: slug, short: "merge held: \(merge.note ?? "")",
                    text: "\(repo.name) asks for GitHub's auto-merge, which the repo does not allow: allow it on "
                        + "GitHub, or merge with heed's rules.",
                    weight: 5
                ))
            }
            if cell(.copilot).state == .off, fact.copilotAvailable != false,
               let conflicts = signals.conflicting[slug], conflicts > 0
            {
                nudges.append(AutopilotNudge(
                    capability: .copilot, repo: slug, short: "copilot: \(plural(conflicts, "conflict"))",
                    text: "\(repo.name): \(plural(conflicts, "PR")) \(conflicts == 1 ? "conflicts" : "conflict") "
                        + "with \(conflicts == 1 ? "its" : "their") base; Copilot could resolve "
                        + "\(conflicts == 1 ? "it" : "them") instead of your agent.",
                    weight: conflicts * 2
                ))
            }
            if cell(.reviewers).state == .off, let open = signals.unreviewed[slug], open > 0 {
                nudges.append(AutopilotNudge(
                    capability: .reviewers, repo: slug, short: "reviewers: \(plural(open, "PR")) unasked",
                    text: "\(repo.name): \(plural(open, "ready PR")) with no reviewer asked by heed.",
                    weight: open * 2
                ))
            }
            if let unwatched = signals.unwatched[slug], unwatched > 0 {
                nudges.append(AutopilotNudge(
                    capability: .green, repo: slug, short: "\(plural(unwatched, "PR")) not watched",
                    text: "\(repo.name): \(plural(unwatched, "PR")) your sessions track \(unwatched == 1 ? "is" : "are") "
                        + "not watched, so heed does nothing for \(unwatched == 1 ? "it" : "them").",
                    weight: unwatched * 2
                ))
            }
            if AutopilotCoverage.global(.cleanup, config: config).state == .off,
               let removable = signals.removable[slug], removable > 0
            {
                nudges.append(AutopilotNudge(
                    capability: .cleanup, repo: slug, short: "cleanup: \(plural(removable, "idle worktree"))",
                    text: "\(repo.name): \(plural(removable, "worktree")) idle past idle_days, work pushed.",
                    weight: removable
                ))
            }
        }
        let removable = signals.removable.values.reduce(0, +)
        if AutopilotCoverage.global(.cleanup, config: config).state == .off, removable > 0 {
            nudges.append(AutopilotNudge(
                capability: .cleanup, repo: nil, short: "cleanup: \(plural(removable, "worktree"))",
                text: "\(plural(removable, "worktree")) would go on the next run: idle \(config.cleanup.idleDays)+ "
                    + "days, work pushed.",
                weight: removable
            ))
        }
        if signals.openAsks > 0 {
            nudges.append(AutopilotNudge(
                capability: .goals, repo: nil, short: "goals: \(plural(signals.openAsks, "ask"))",
                text: "\(plural(signals.openAsks, "ask")) \(signals.openAsks == 1 ? "waits" : "wait") for you in "
                    + "Goals › Unassigned.",
                weight: signals.openAsks
            ))
        }
        return nudges.sorted { $0.weight != $1.weight ? $0.weight > $1.weight : ($0.repo ?? "") < ($1.repo ?? "") }
    }

    /// A capability's strongest nudge.
    public static func best(_ capability: Capability, in nudges: [AutopilotNudge]) -> AutopilotNudge? {
        nudges.first { $0.capability == capability && ($0.repo != nil || capability.scope == .everywhere) }
            ?? nudges.first { $0.capability == capability }
    }

    /// A repo's strongest nudge, for Where's last column.
    public static func couldHelp(_ repo: String, in nudges: [AutopilotNudge]) -> AutopilotNudge? {
        nudges.first { $0.repo == repo }
    }
}
