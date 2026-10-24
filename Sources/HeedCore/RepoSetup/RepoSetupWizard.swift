import Foundation

/// The lines the wizard writes under `[repos."org/name"]`, shown first exactly as they will be written, then written
/// in place: comments, order and every other key in config.toml stay as they are.
public enum RepoSetupConfig {
    public struct Edit: Equatable, Sendable {
        public var key: String
        public var value: TOMLValue

        public init(_ key: String, _ value: TOMLValue) {
            self.key = key
            self.value = value
        }
    }

    /// The fields that are ticked, in order.
    public static func edits(_ fields: [SetupField]) -> [Edit] {
        fields.filter(\.include).map { Edit($0.id, $0.toml) }
    }

    /// `[repos."acme/docs-toolkit"]`, then a `key = value` line per edit.
    public static func preview(_ repo: Repo, _ edits: [Edit]) -> [String] {
        guard !edits.isEmpty else { return [] }
        return ["[repos.\(TOMLValue.key(repo.slug))]"] + edits.map { "\(TOMLValue.key($0.key)) = \($0.value.literal)" }
    }

    /// `source` with each edit set under the repo's table (added where missing, replaced in place where present).
    public static func apply(_ edits: [Edit], repo: Repo, to source: String) throws(TOMLError) -> String {
        var text = source
        for edit in edits {
            text = try TOMLDocument(text).setting(["repos", repo.slug, edit.key], to: edit.value)
        }
        return text
    }

    /// `current` with the fields' values in place, for validation.
    public static func applied(_ fields: [SetupField], to current: PilotSettings) -> PilotSettings {
        var settings = current
        for field in fields where field.include {
            let names = field.items.filter(\.on).map(\.name)
            switch field.id {
            case "merge": settings.merge = MergeMode.named(field.value) ?? settings.merge
            case "merge_method": settings.mergeMethod = field.value.isEmpty ? nil : field.value
            case "trusted_reviewers": settings.trustedReviewers = names
            case "gate_checks": settings.gateChecks = names
            case "hold_labels": settings.holdLabels = names
            case "quiet_minutes": settings.quietMinutes = Int(field.value) ?? settings.quietMinutes
            case "green": settings.green = AutoFeed.named(field.value) ?? settings.green
            case "max_rounds": settings.maxRounds = Int(field.value) ?? settings.maxRounds
            case "agent": settings.agent = field.value.isEmpty ? nil : field.value
            case "model": settings.model = field.value.isEmpty ? nil : field.value
            case "green_instructions": settings.greenInstructions = field.value
            case "merge_now": settings.mergeNow = MergeNowConfirm.named(field.value) ?? settings.mergeNow
            case "force_merge": settings.forceMerge = ForceMerge.named(field.value) ?? settings.forceMerge
            default: break
            }
        }
        return settings
    }
}

/// The per-repo setup wizard (`repo.setup`): sample the repo, propose settings for get it merged and get it green
/// with why, validate them against the sample and GitHub's settings, then preview and write the config lines. A value:
/// the app feeds it keys and the sample, the view draws it.
public struct RepoSetupWizard: Equatable, Sendable {
    public enum Step: Int, CaseIterable, Sendable {
        case sample, propose, validate, write

        public var title: String {
            switch self {
            case .sample: "Sample"
            case .propose: "Propose"
            case .validate: "Validate"
            case .write: "Write"
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        case handled
        /// ⎋: closed, nothing written.
        case close
        /// ↩ on the last step: write these.
        case write([RepoSetupConfig.Edit])
        /// A link to the GitHub setting a check is about.
        case open(String)
    }

    public enum Progress: Equatable, Sendable {
        case waiting, running, done
    }

    /// A row of the proposal: a setting, or one item of a list setting.
    public enum Row: Hashable, Sendable {
        case field(Int)
        case item(Int, Int)
    }

    public let repo: Repo
    public private(set) var step: Step = .sample
    public private(set) var progress: [GitHub.SampleStep: Progress] = [:]
    public private(set) var sample: RepoSetupSample?
    public private(set) var failure: String?
    public private(set) var fields: [SetupField] = []
    public private(set) var notes: [String] = []
    /// The row under the cursor: a proposal row, or a check on the validation step.
    public private(set) var cursor = 0
    /// What applies now for the repo, to validate the proposal on top of.
    public let current: PilotSettings
    public let agents: [String]

    public init(repo: Repo, current: PilotSettings, agents: [String] = []) {
        self.repo = repo
        self.current = current
        self.agents = agents
    }

    // MARK: Sampling

    public mutating func began(_ part: GitHub.SampleStep) { progress[part] = .running }
    public mutating func finished(_ part: GitHub.SampleStep) { progress[part] = .done }

    public mutating func sampled(_ sample: RepoSetupSample) {
        self.sample = sample
        failure = nil
        for part in GitHub.SampleStep.allCases {
            progress[part] = .done
        }
        fields = RepoSetupProposal.fields(sample, current: current, agents: agents)
        notes = RepoSetupProposal.notes(sample)
    }

    public mutating func failed(_ reason: String) { failure = reason }

    // MARK: What it shows

    public var rows: [Row] {
        fields.indices.flatMap { index in
            [Row.field(index)] + fields[index].items.indices.map { Row.item(index, $0) }
        }
    }

    public var validation: RepoSetupValidation? {
        guard let sample else { return nil }
        let force = fields.first { $0.id == "force_merge" && $0.include }.flatMap { ForceMerge.named($0.value) }
        return RepoSetupValidation.validate(
            sample, settings: RepoSetupConfig.applied(fields, to: current), forceMerge: force
        )
    }

    public var edits: [RepoSetupConfig.Edit] { RepoSetupConfig.edits(fields) }
    public var preview: [String] { RepoSetupConfig.preview(repo, edits) }

    /// The checks with a link to the setting to change, which the cursor walks on the validation step.
    public var fixes: [RepoSetupValidation.Check] {
        validation?.checks.filter { $0.level != .ok && $0.url != nil } ?? []
    }

    // MARK: Keys

    public mutating func handle(_ stroke: KeyStroke) -> Outcome {
        switch stroke {
        case .escape, KeyStroke("q"):
            return .close
        case KeyStroke("CR"), KeyStroke("Tab"):
            return next()
        case KeyStroke("BS"), KeyStroke("Tab", .shift):
            back()
        case KeyStroke("j"), KeyStroke("Down"), KeyStroke("n", .control):
            move(by: 1)
        case KeyStroke("k"), KeyStroke("Up"), KeyStroke("p", .control):
            move(by: -1)
        case KeyStroke("l"), KeyStroke("Right"):
            change(by: 1)
        case KeyStroke("h"), KeyStroke("Left"):
            change(by: -1)
        case KeyStroke("Space"):
            if step == .propose { toggle(row: cursor) }
        case KeyStroke("o"):
            if step == .validate, fixes.indices.contains(cursor), let url = fixes[cursor].url { return .open(url) }
        default:
            break
        }
        return .handled
    }

    /// ↩: the next step; on the last, write.
    public mutating func next() -> Outcome {
        switch step {
        case .sample:
            guard sample != nil else { return .handled }
            go(to: .propose)
        case .propose: go(to: .validate)
        case .validate: go(to: .write)
        case .write: return .write(edits)
        }
        return .handled
    }

    public mutating func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        go(to: previous)
    }

    /// A step's tab, clicked: any step once sampled.
    public mutating func go(to target: Step) {
        guard target == .sample || sample != nil else { return }
        step = target
        cursor = 0
    }

    public mutating func move(by delta: Int) {
        let count = step == .propose ? rows.count : step == .validate ? fixes.count : 0
        guard count > 0 else { return }
        cursor = min(max(cursor + delta, 0), count - 1)
    }

    public mutating func point(at row: Int) {
        cursor = row
    }

    /// ← → on a setting: its previous or next value.
    public mutating func change(by delta: Int) {
        guard step == .propose, rows.indices.contains(cursor), case let .field(index) = rows[cursor] else { return }
        fields[index].cycle(by: delta)
    }

    /// A value clicked.
    public mutating func choose(field index: Int, choice: Int) {
        guard fields.indices.contains(index), fields[index].choices.indices.contains(choice) else { return }
        fields[index].choice = choice
        fields[index].include = true
    }

    /// Space on a setting writes it or leaves it out; on a list item, turns the item on or off.
    public mutating func toggle(row: Int) {
        guard rows.indices.contains(row) else { return }
        cursor = row
        switch rows[row] {
        case let .field(index):
            fields[index].include.toggle()
        case let .item(index, item):
            fields[index].items[item].on.toggle()
            fields[index].include = true
        }
    }
}
