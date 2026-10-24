import Foundation

/// One setting the wizard proposes for a repo: its value with the choices around it (or, for a list, its items, each
/// on or off), why heed proposes it, what applies now, and whether it is written.
public struct SetupField: Hashable, Sendable, Identifiable {
    public enum Section: String, CaseIterable, Hashable, Sendable {
        case merged = "Get it merged"
        case green = "Get it green"
    }

    public enum Kind: Hashable, Sendable {
        case text, integer, list
    }

    public struct Item: Hashable, Sendable {
        public var name: String
        public var why: String
        public var on: Bool

        public init(_ name: String, why: String, on: Bool = true) {
            self.name = name
            self.why = why
            self.on = on
        }
    }

    /// The key in config.toml.
    public let id: String
    public let section: Section
    public let label: String
    public let kind: Kind
    public var choices: [String]
    public var choice: Int
    public var items: [Item]
    public var why: String
    /// What applies now (from the repo, its org, or the defaults), as config.toml would write it.
    public var current: String
    /// Written to config.toml.
    public var include: Bool

    public init(
        _ id: String, _ section: Section, label: String, kind: Kind = .text, choices: [String] = [], value: String = "",
        items: [Item] = [], why: String, current: String
    ) {
        self.id = id
        self.section = section
        self.label = label
        self.kind = kind
        var choices = choices
        if kind != .list, !choices.contains(value) { choices.append(value) }
        if kind == .integer { choices.sort { (Int($0) ?? 0) < (Int($1) ?? 0) } }
        self.choices = choices
        choice = choices.firstIndex(of: value) ?? 0
        self.items = items
        self.why = why
        self.current = current
        include = false
        include = display != current
    }

    public var value: String { choices.indices.contains(choice) ? choices[choice] : "" }

    /// The value as the wizard shows it, and as `current` is compared to.
    public var display: String {
        switch kind {
        case .list: items.filter(\.on).map(\.name).joined(separator: ", ")
        case .text, .integer: value
        }
    }

    public var toml: TOMLValue {
        switch kind {
        case .list: .array(items.filter(\.on).map { .string($0.name) })
        case .integer: .integer(Int(value) ?? 0)
        case .text: .string(value)
        }
    }

    /// Steps the choice (wrapping); a list has none.
    public mutating func cycle(by step: Int) {
        guard kind != .list, !choices.isEmpty else { return }
        choice = (choice + step + choices.count) % choices.count
        include = true
    }
}

/// What the wizard proposes, from a sample, and why: pure functions over the sampled data, each giving a value and a
/// sentence that says where it came from.
public enum RepoSetupProposal {
    public struct Proposed<Value: Hashable & Sendable>: Hashable, Sendable {
        public var value: Value
        public var why: String

        public init(_ value: Value, _ why: String) {
            self.value = value
            self.why = why
        }
    }

    public static func fields(
        _ sample: RepoSetupSample, current: PilotSettings, agents: [String] = []
    ) -> [SetupField] {
        let mode = mergeMode(sample)
        let method = mergeMethod(sample)
        let quiet = quietMinutes(sample)
        let now = mergeNow(mode.value)
        var fields = [
            SetupField(
                "merge", .merged, label: "Mode", choices: MergeMode.allCases.map(\.configName),
                value: mode.value.configName, why: mode.why, current: current.merge.configName
            ),
            SetupField(
                "merge_method", .merged, label: "Method", choices: sample.settings.methods.isEmpty
                    ? MergeQueue.methods : sample.settings.methods,
                value: method.value, why: method.why, current: current.mergeMethod ?? ""
            ),
            SetupField(
                "trusted_reviewers", .merged, label: "Trusted reviewers", kind: .list,
                items: trustedReviewers(sample, current: current.trustedReviewers),
                why: "Their review of the last push counts as an approval for heed.",
                current: current.trustedReviewers.joined(separator: ", ")
            ),
            SetupField(
                "gate_checks", .merged, label: "Gate checks", kind: .list,
                items: gateChecks(sample, current: current.gateChecks), why: gateWhy(sample),
                current: current.gateChecks.joined(separator: ", ")
            ),
            SetupField(
                "hold_labels", .merged, label: "Hold labels", kind: .list,
                items: holdLabels(sample, current: current.holdLabels),
                why: "A PR with one of these waits.", current: current.holdLabels.joined(separator: ", ")
            ),
            SetupField(
                "quiet_minutes", .merged, label: "Quiet for (minutes)", kind: .integer,
                choices: ["0", "5", "10", "15", "30", "60", String(current.quietMinutes)], value: String(quiet.value),
                why: quiet.why, current: String(current.quietMinutes)
            ),
            SetupField(
                "merge_now", .merged, label: "Merge now", choices: MergeNowConfirm.allCases.map(\.rawValue),
                value: now.value.rawValue, why: now.why, current: current.mergeNow.rawValue
            ),
        ]
        if let force = forceMerge(sample) {
            fields.append(SetupField(
                "force_merge", .merged, label: "Force merge", choices: ForceMerge.allCases.map(\.rawValue),
                value: force.value.rawValue, why: force.why, current: current.forceMerge.rawValue
            ))
        }
        let feed = green(sample.runs)
        let rounds = maxRounds(sample.runs)
        let pick = agent(sample.runs)
        fields += [
            SetupField(
                "green", .green, label: "Get it green", choices: AutoFeed.allCases.map(\.configName),
                value: feed.value.configName, why: feed.why, current: current.green.configName
            ),
            SetupField(
                "max_rounds", .green, label: "Stop after (rounds)", kind: .integer,
                choices: ["1", "2", "3", "5", "8", String(current.maxRounds)], value: String(rounds.value),
                why: rounds.why, current: String(current.maxRounds)
            ),
            SetupField(
                "agent", .green, label: "Run agent", choices: [""] + agents + [current.agent ?? ""],
                value: pick?.agent ?? current.agent ?? "",
                why: pick?.why ?? "No runs on this repo yet: the session's agent (empty) until some have.",
                current: current.agent ?? ""
            ),
            SetupField(
                "model", .green, label: "Run model",
                choices: [""] + Set(sample.runs.compactMap(\.model)).sorted() + [current.model ?? ""],
                value: pick?.model ?? current.model ?? "",
                why: pick.map { _ in "The model those runs used." } ?? "The agent's default (empty).",
                current: current.model ?? ""
            ),
        ]
        if let hint = instructions(sample) {
            var field = SetupField(
                "green_instructions", .green, label: "Green instructions", choices: [current.greenInstructions],
                value: hint.value, why: hint.why, current: current.greenInstructions
            )
            // Replacing instructions you wrote is your call: offered, not ticked.
            if !current.greenInstructions.isEmpty { field.include = false }
            fields.append(field)
        }
        // Collapse duplicate choices the current value may have added.
        return fields.map { field in
            var field = field
            let value = field.value
            var seen = Set<String>()
            field.choices = field.choices.filter { seen.insert($0).inserted }
            field.choice = field.choices.firstIndex(of: value) ?? 0
            return field
        }
    }

    /// Lines about CI that are not settings: flaky workflows, and what failed runs failed on.
    public static func notes(_ sample: RepoSetupSample) -> [String] {
        var notes: [String] = []
        let ci = sample.ci
        if !ci.failures.isEmpty {
            let kinds = CIHistory.Kind.allCases.compactMap { kind -> String? in
                let count = ci.count(kind)
                return count == 0 ? nil : "\(count) \(kind.rawValue)"
            }
            notes.append(
                "CI failures: \(kinds.joined(separator: ", ")) (of \(ci.failures.count) failed jobs on PRs)."
            )
        }
        for flaky in ci.flaky.prefix(4) {
            notes.append(
                "Flaky: \(flaky.workflow) passed on a re-run \(flaky.retried) time\(flaky.retried == 1 ? "" : "s") "
                    + "in \(flaky.runs) PR runs."
            )
        }
        if !ci.flaky.isEmpty {
            notes.append("Re-running a flaky check instead of sending it to the agent comes later; for now it is sent.")
        }
        return notes
    }

    // MARK: Get it merged

    public static func mergeMode(_ sample: RepoSetupSample) -> Proposed<MergeMode> {
        let pulls = sample.pulls
        let base = sample.settings.defaultBranch
        guard !pulls.isEmpty else { return Proposed(.off, "No merged PRs into \(base) to learn from yet.") }
        let count = pulls.count
        let approved = pulls.count(where: \.humanApproved)
        if sample.settings.mergeQueue {
            return Proposed(.auto, "\(base) merges through a merge queue; auto-merge adds each PR to it.")
        }
        let automatic = pulls.count { $0.autoMerge || $0.mergeQueue }
        if sample.settings.autoMergeAllowed == true, automatic * 3 >= count {
            return Proposed(.auto, "Auto-merge was turned on for \(automatic) of \(count) merged PRs.")
        }
        let approvals = "a person approved \(approved) of \(count)"
        if sample.settings.autoMergeAllowed == false {
            return Proposed(.heed, "The repo does not allow auto-merge, so heed merges by its rules; \(approvals).")
        }
        return Proposed(
            .heed,
            "Auto-merge was used on \(automatic) of \(count); heed merges by its rules; \(approvals)."
        )
    }

    public static func mergeMethod(_ sample: RepoSetupSample) -> Proposed<String> {
        let allowed = sample.settings.methods
        guard let first = allowed.first else {
            return Proposed("squash", "The repo allows none of squash, merge or rebase.")
        }
        if allowed.count == 1 { return Proposed(first, "The repo only allows \(first).") }
        let merges = sample.pulls.count { $0.parents == 2 }
        let singles = sample.pulls.count { $0.parents == 1 }
        if merges > singles, allowed.contains("merge") {
            return Proposed("merge", "\(merges) of \(sample.pulls.count) merged PRs were merge commits.")
        }
        let single = allowed.contains("squash") ? "squash" : allowed.contains("rebase") ? "rebase" : first
        if singles > 0, single != "merge" {
            return Proposed(single, "\(singles) of \(sample.pulls.count) merged PRs landed without a merge commit.")
        }
        return Proposed(first, "The first method the repo allows.")
    }

    /// Bots that reviewed at least a fifth of the sample (three PRs at least), Copilot when a ruleset asks it to
    /// review, and whoever is trusted now.
    public static func trustedReviewers(_ sample: RepoSetupSample, current: [String]) -> [SetupField.Item] {
        let count = sample.pulls.count
        var reviewed: [String: Int] = [:]
        var approved: [String: Int] = [:]
        for pull in sample.pulls {
            for bot in pull.botReviewers {
                reviewed[bot, default: 0] += 1
                if pull.reviews.contains(where: { $0.author == bot && $0.state == "APPROVED" }) {
                    approved[bot, default: 0] += 1
                }
            }
        }
        var items: [SetupField.Item] = current.map { SetupField.Item($0, why: "Trusted now.") }
        let threshold = max(3, count / 5)
        for (bot, times) in reviewed.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) where times >= threshold {
            let why = "Reviewed \(times) of \(count), approved \(approved[bot] ?? 0)."
            if let index = items.firstIndex(where: { $0.name.lowercased() == bot.lowercased() }) {
                items[index].why = why
            } else {
                items.append(SetupField.Item(bot, why: why))
            }
        }
        let copilot = "copilot-pull-request-reviewer"
        if sample.settings.copilotReview, !items.contains(where: { $0.name == copilot }) {
            items.append(SetupField.Item(copilot, why: "A ruleset asks Copilot to review every PR."))
        }
        return items
    }

    static func gateWhy(_ sample: RepoSetupSample) -> String {
        sample.settings.requiredChecks.isEmpty
            ? "Nothing is required by GitHub, so green already waits for every check."
            : "Checks GitHub does not require that heed waits for too."
    }

    /// With required checks, the others that passed on most of the sample and never failed at merge time: on when
    /// they ran on nine in ten PRs (a check that runs only for some paths would hold the rest).
    public static func gateChecks(_ sample: RepoSetupSample, current: [String]) -> [SetupField.Item] {
        let count = sample.pulls.count
        // A gate that passed on none of the sample would hold every PR: offered, off.
        var items: [SetupField.Item] = current.map { name in
            let passes = sample.pulls.count { $0.passedChecks.contains(name) }
            return count > 0 && passes == 0
                ? SetupField.Item(
                    name,
                    why: "A gate check now; passed on none of \(count): it would hold every PR.",
                    on: false
                )
                : SetupField.Item(name, why: "A gate check now.")
        }
        let required = Set(sample.settings.requiredChecks)
        guard !required.isEmpty, !sample.pulls.isEmpty else { return items }
        var passed: [String: Int] = [:]
        var failed: Set<String> = []
        for pull in sample.pulls {
            for name in Set(pull.passedChecks) {
                passed[name, default: 0] += 1
            }
            failed.formUnion(pull.failedChecks)
        }
        let candidates = passed
            .filter { !required.contains($0.key) && !failed.contains($0.key) && $0.value * 5 >= count * 4 }
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(5)
        for (name, times) in candidates where !items.contains(where: { $0.name == name }) {
            items.append(SetupField.Item(
                name, why: "Passed on \(times) of \(count), never failed at merge; not required.",
                on: times * 10 >= count * 9
            ))
        }
        return items
    }

    /// Words that name a hold in a label.
    static let holdWords = [
        "hold", "wip", "do-not-merge", "do not merge", "dont-merge", "don't merge", "blocked", "not-ready", "not ready",
        "work in progress",
    ]

    /// The hold labels now (off when merged PRs still carried them: they hold nothing here), labels whose name says
    /// hold, and labels taken off before the merge on two PRs or more.
    public static func holdLabels(_ sample: RepoSetupSample, current: [String]) -> [SetupField.Item] {
        func onMerged(_ label: String) -> Int {
            sample.pulls.count { pull in
                pull.labels.contains { $0.lowercased() == label.lowercased() }
                    && !pull.removedBeforeMerge.contains { $0.lowercased() == label.lowercased() }
            }
        }
        func removed(_ label: String) -> Int {
            sample.pulls.count { $0.removedBeforeMerge.contains { $0.lowercased() == label.lowercased() } }
        }
        var items: [SetupField.Item] = current.map { label in
            let carried = onMerged(label)
            if carried > 0 {
                return SetupField.Item(label, why: "On \(carried) merged PRs: it holds nothing here.", on: false)
            }
            let off = removed(label)
            return SetupField.Item(
                label,
                why: off > 0 ? "Taken off before merging on \(off) PRs." : "A hold label now."
            )
        }
        var seen: [String] = []
        for pull in sample.pulls {
            for label in pull.labelsSeen where !seen.contains(label) {
                seen.append(label)
            }
        }
        for label in seen where !items.contains(where: { $0.name.lowercased() == label.lowercased() }) {
            let off = removed(label)
            let carried = onMerged(label)
            let named = holdWords.contains { label.lowercased().contains($0) }
            if named, carried == 0 {
                items.append(SetupField.Item(
                    label,
                    why: off > 0
                        ? "Taken off before merging on \(off) PRs." : "Its name says hold; no merged PR carried it."
                ))
            } else if off >= 2, carried == 0 {
                items.append(SetupField.Item(label, why: "Taken off before merging on \(off) PRs.", on: false))
            }
        }
        return items
    }

    /// A quarter of the sample merged within this many minutes of its last push or review: heed waits about as long
    /// (5 to 30 minutes, in fives).
    public static func quietMinutes(_ sample: RepoSetupSample) -> Proposed<Int> {
        let gaps = sample.pulls
            .compactMap { pull in pull.lastActivity.map { pull.mergedAt.timeIntervalSince($0) / 60 } }
            .sorted()
        guard !gaps.isEmpty else { return Proposed(5, "The default: no merge in the sample to time.") }
        let quarter = gaps[gaps.count / 4]
        let minutes = min(max(Int((quarter / 5).rounded()) * 5, 5), 30)
        let shown = quarter < 1 ? "under a minute" : PilotDuration.text(quarter * 60)
        return Proposed(minutes, "A quarter of the merges came \(shown) after the last push or review.")
    }

    public static func mergeNow(_ mode: MergeMode) -> Proposed<MergeNowConfirm> {
        mode == .auto
            ? Proposed(.auto, "With auto-merge GitHub waits for its own rules; nothing to confirm.")
            : Proposed(.ask, "You confirm each merge until heed's rules have earned your trust.")
    }

    /// Only for admins: ask when the sample shows merges past the required approvals (a bypass), else off.
    public static func forceMerge(_ sample: RepoSetupSample) -> Proposed<ForceMerge>? {
        guard sample.settings.isAdmin == true else { return nil }
        let required = sample.settings.requiredApprovals
        guard required > 0 else {
            return Proposed(.off, "No approval is required on \(sample.settings.defaultBranch): nothing to bypass.")
        }
        let bypassed = sample.pulls.count { !$0.humanApproved }
        if bypassed > 0 {
            return Proposed(
                .ask,
                "\(bypassed) of \(sample.pulls.count) merged without the \(required) required approval\(required == 1 ? "" : "s"): an admin bypass."
            )
        }
        return Proposed(.off, "Every merged PR had its required approval; nothing needed a bypass.")
    }

    // MARK: Get it green

    static func ended(_ runs: [PilotRun]) -> [PilotRun] {
        runs.filter { run in
            guard run.goal == .green, let outcome = run.outcome else { return false }
            switch outcome {
            case .stopped, .interrupted: return false
            default: return true
            }
        }
    }

    static func pushed(_ run: PilotRun) -> Bool { if case .pushed = run.outcome { true } else { false } }

    public static func green(_ runs: [PilotRun]) -> Proposed<AutoFeed> {
        let done = ended(runs)
        let pushes = done.count(where: pushed)
        guard !done.isEmpty else {
            return Proposed(.ask, "No get it green runs on this repo yet: you queue until runs have earned trust.")
        }
        if done.count >= 3, pushes * 2 >= done.count {
            return Proposed(.auto, "Runs pushed a fix on \(pushes) of \(done.count).")
        }
        return Proposed(.ask, "Runs pushed a fix on only \(pushes) of \(done.count): you queue.")
    }

    public static func maxRounds(_ runs: [PilotRun]) -> Proposed<Int> {
        let done = ended(runs)
        let pushes = done.count(where: pushed)
        if done.count >= 3, done.count - pushes > pushes {
            return Proposed(2, "\(done.count - pushes) of \(done.count) runs changed nothing or failed: stop sooner.")
        }
        return Proposed(3, "The default.")
    }

    /// The agent and model whose runs pushed most often (two runs at least).
    public static func agent(_ runs: [PilotRun]) -> (agent: String, model: String, why: String)? {
        var tally: [String: (agent: String, model: String, runs: Int, pushed: Int)] = [:]
        for run in ended(runs) {
            let key = "\(run.agent) \(run.model ?? "")"
            var entry = tally[key] ?? (run.agent, run.model ?? "", 0, 0)
            entry.runs += 1
            if pushed(run) { entry.pushed += 1 }
            tally[key] = entry
        }
        let best = tally.values.filter { $0.runs >= 2 && $0.pushed > 0 }.max { left, right in
            (Double(left.pushed) / Double(left.runs), left.runs, right.agent)
                < (Double(right.pushed) / Double(right.runs), right.runs, left.agent)
        }
        guard let best else { return nil }
        let name = best.model.isEmpty ? best.agent : "\(best.agent) \(best.model)"
        return (best.agent, best.model, "\(name) pushed a fix on \(best.pushed) of \(best.runs) runs.")
    }

    /// When CI failed on lint or format: the repo's lint and format tasks, to run before pushing.
    public static func instructions(_ sample: RepoSetupSample) -> Proposed<String>? {
        let lint = sample.ci.count(.lint)
        guard lint > 0 else { return nil }
        let words = ["lint", "fmt", "format", "style"]
        let tasks = sample.tasks.filter { task in words.contains { task.name.lowercased().contains($0) } }.prefix(2)
        let why = "\(lint) of \(sample.ci.failures.count) failed CI jobs were lint or format."
        guard !tasks.isEmpty else {
            return Proposed("Before you push, run the repo's linter and formatter and fix what they report.", why)
        }
        let commands = tasks.map { "`\($0.command)`" }.joined(separator: " and ")
        return Proposed("Before you push, run \(commands) and fix what they report.", why)
    }
}
