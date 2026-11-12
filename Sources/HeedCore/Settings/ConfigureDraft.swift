import Foundation

// Configure… (`:settings.configure`): a profile, then the gaps (the settings that matter and that you have not set or
// decided on), then the changes to write. Everything is kept here until Apply: nothing reaches config.toml or the
// chosen list before it.

/// What a gap needs that a value cannot give: something to do first. heed never installs anything itself.
public enum GapAction: Equatable, Sendable {
    /// Persistent panes without a working zmx: the lines to install it, and Check again.
    case installZmx(commands: [String])
    /// Model calls: Set up & test, from what this Mac has (as Settings › Model calls' Set up does).
    case setUpModelCalls
}

/// What Configure… knows about this Mac, for the gaps that need an action.
public struct GapFacts: Equatable, Sendable {
    /// zmx is installed and passes its check.
    public var zmxWorks: Bool

    public init(zmxWorks: Bool = false) {
        self.zmxWorks = zmxWorks
    }
}

/// One gap: the setting, and what it needs done when a value is not enough.
public struct SettingsGap: Identifiable, Sendable {
    public let entry: SettingsEntry
    public let action: GapAction?

    public var id: String { entry.id }
}

public extension SettingsCatalog {
    /// The gaps, ranked as `gaps(in:chosen:)` ranks them, each with the action it needs on this Mac.
    static func gaps(in config: HeedConfig, chosen: ChosenSettings, facts: GapFacts) -> [SettingsGap] {
        gaps(in: config, chosen: chosen).map { SettingsGap(entry: $0, action: action(for: $0, facts: facts)) }
    }

    /// The action a gap needs: persistent panes while zmx is missing or broken, and model calls' setup.
    static func action(for entry: SettingsEntry, facts: GapFacts) -> GapAction? {
        switch entry.id {
        case "sessions.persist": facts.zmxWorks ? nil : .installZmx(commands: ZmxInstall.mac)
        case "llm.agent": .setUpModelCalls
        default: nil
        }
    }

    /// The global entry whose key is `path` (`["notifications", "enabled"]`).
    static func entry(at path: [String]) -> SettingsEntry? {
        entries.first { $0.scope == .global && $0.key == path }
    }
}

/// Configure… as it stands: the step shown, the profile picked, and what each gap was given.
public struct ConfigureDraft: Equatable, Sendable {
    public enum Step: Int, CaseIterable, Sendable {
        case profile, gaps, review

        public var title: String {
            switch self {
            case .profile: "Profile"
            case .gaps: "Gaps"
            case .review: "Review"
            }
        }
    }

    public var step: Step
    public private(set) var profile: SettingsProfile?
    /// Values given on the gaps step, by entry id; nil: the key removed (heed's default).
    public private(set) var edits: [String: SettingValue?] = [:]
    /// Gaps given Keep default.
    public private(set) var kept: Set<String> = []
    /// Values typed on the gaps step that heed refused, by entry id: the reason, shown on the row; not drafted.
    public private(set) var refused: [String: String] = [:]

    public init(step: Step = .profile, profile: SettingsProfile? = nil) {
        self.step = step
        self.profile = profile
    }

    /// Picks a profile, or none (Skip profile).
    public mutating func pick(_ profile: SettingsProfile?) {
        self.profile = profile
    }

    /// A value for a gap, given with its control.
    public mutating func set(_ id: String, _ value: SettingValue?) {
        edits[id] = .some(value)
        kept.remove(id)
        refused[id] = nil
    }

    /// A value heed would not take (`SettingsCatalog.validate`): said on its row, and nothing drafted.
    public mutating func refuse(_ id: String, _ reason: String) {
        refused[id] = reason
    }

    /// Keep default: decided on, at heed's default.
    public mutating func keepDefault(_ id: String) {
        edits[id] = nil
        kept.insert(id)
    }

    /// Back to undecided.
    public mutating func reopen(_ id: String) {
        edits[id] = nil
        kept.remove(id)
        refused[id] = nil
    }

    /// The profile's plan for `config`; nil with none picked.
    public func plan(_ config: HeedConfig, chosen: ChosenSettings) -> ProfilePlan? {
        profile.map { SettingsProfile.apply($0, to: config, chosen: chosen) }
    }

    /// The gaps step's rows: the gaps, less those the profile decides.
    public func gaps(_ config: HeedConfig, chosen: ChosenSettings, facts: GapFacts) -> [SettingsGap] {
        let decided = Set(plan(config, chosen: chosen)?.decided ?? [])
        return SettingsCatalog.gaps(in: config, chosen: chosen, facts: facts).filter { !decided.contains($0.id) }
    }

    /// The value a gap shows: what it was given here, else the profile's, else what config.toml has.
    public func value(_ entry: SettingsEntry, in config: HeedConfig, chosen: ChosenSettings) -> SettingValue? {
        if let edit = edits[entry.id] { return edit ?? SettingsCatalog.defaultValue(entry) }
        if let planned = plan(config, chosen: chosen)?.sets.first(where: { $0.entryID == entry.id }) {
            return planned.to
        }
        return SettingsCatalog.value(entry, in: config)
    }

    /// What Apply writes, in catalog order: the profile's values, then the gaps' (a gap's wins), less any that would
    /// not change config.toml's value.
    public func changes(_ config: HeedConfig, chosen: ChosenSettings) -> [SettingChange] {
        var wanted: [String: SettingValue?] = [:]
        for planned in plan(config, chosen: chosen)?.sets ?? [] {
            wanted[planned.entryID] = .some(planned.to)
        }
        for (id, value) in edits {
            wanted[id] = .some(value)
        }
        return SettingsCatalog.entries.compactMap { entry in
            guard let value = wanted[entry.id], let path = entry.path(at: .global) else { return nil }
            let current = SettingsCatalog.value(entry, in: config)
            let target = value ?? SettingsCatalog.defaultValue(entry)
            guard target != current else { return nil }
            return SettingChange(entry: entry, path: path, from: current, to: value)
        }
    }

    /// The entries Apply records as decided on: the profile's (set or confirmed), every gap given a value, and every
    /// Keep default.
    public func decided(_ config: HeedConfig, chosen: ChosenSettings) -> Set<String> {
        Set(plan(config, chosen: chosen)?.decided ?? []).union(edits.keys).union(kept)
    }

    /// Gaps given a value or Keep default here.
    public func isDecided(_ id: String) -> Bool { edits[id] != nil || kept.contains(id) }
}

/// One key Apply writes.
public struct SettingChange: Sendable {
    public let entry: SettingsEntry
    public let path: [String]
    public let from: SettingValue?
    /// nil: the key is removed.
    public let to: SettingValue?

    /// `notifications.asking`.
    public var key: String { SettingsCatalog.keyText(path) }
}

public extension SettingValue {
    /// A value as config.toml has it; nil for an inline table or a list with anything but strings.
    init?(_ toml: TOMLValue) {
        switch toml {
        case let .bool(flag): self = .bool(flag)
        case let .integer(number): self = .integer(number)
        case let .float(number): self = .number(number)
        case let .string(text): self = .text(text)
        case let .array(items):
            let strings = items.compactMap(\.string)
            guard strings.count == items.count else { return nil }
            self = .list(strings)
        case .table: return nil
        }
    }
}
