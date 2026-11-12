import Foundation

// Configure…'s first step: four starting points, each a handful of values for settings the catalog has. A profile
// only fills what you have not set or decided on; it never changes a value you set.

/// A starting point for Configure….
public enum SettingsProfile: String, CaseIterable, Sendable, Identifiable {
    case handsOn, autopilot, focus, minimal

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .handsOn: "Hands on"
        case .autopilot: "Autopilot"
        case .focus: "Focus"
        case .minimal: "Minimal"
        }
    }

    /// What it does, in a line or two.
    public var summary: String {
        switch self {
        case .handsOn:
            "Notifications for asking and blocked, PRs watched, nothing merges by itself. Model calls on with a small "
                + "budget."
        case .autopilot:
            "Get it green and get it merged on, with a self-review; goals found and reviewers run on their own; the "
                + "menu bar item."
        case .focus:
            "Notifications for blocked only, quiet hours 18:00-09:00, no reminder, no Dock badge, no Attention "
                + "notifications."
        case .minimal:
            "No model calls, no ledger summaries, no screen recording, no GitHub writes by heed. heed watches and shows."
        }
    }

    /// Its values, by catalog entry id, in the order it lists them. `config` decides the few that depend on what you
    /// have: Autopilot's self-review runs `claude -p` only where claude is the default agent.
    public func values(for config: HeedConfig = .default) -> [(id: String, value: SettingValue)] {
        switch self {
        case .handsOn:
            return [
                ("notifications.enabled", .bool(true)),
                ("notifications.asking", .bool(true)),
                ("notifications.blocked", .bool(true)),
                ("pilot.watch", .bool(true)),
                ("pilot.green", .text("ask")),
                ("pilot.merge", .text("off")),
                ("llm.enabled", .bool(true)),
                ("llm.agent", .text(LLMSettings.auto)),
                ("llm.daily_dollars", .number(0.5)),
            ]
        case .autopilot:
            var values: [(id: String, value: SettingValue)] = [
                ("pilot.green", .text("auto")),
                ("pilot.merge", .text("heed")),
            ]
            if config.work.defaultAgent == "claude" { values.append(("pilot.self_review", .text("claude -p"))) }
            values += [
                ("goals.attach", .bool(true)),
                ("goals.auto_review", .bool(true)),
                ("ui.menu_bar", .bool(true)),
            ]
            return values
        case .focus:
            return [
                ("notifications.asking", .bool(false)),
                ("notifications.blocked", .bool(true)),
                ("attention.quiet", .text("18:00-09:00")),
                ("notifications.reminder_minutes", .integer(0)),
                ("ui.dock_state", .bool(false)),
                ("notifications.attention", .bool(false)),
            ]
        case .minimal:
            return [
                ("llm.enabled", .bool(false)),
                ("decisions.decider", .text("off")),
                ("summary.when", .list([])),
                ("local.record_screens", .bool(false)),
                ("pilot.green", .text("off")),
                ("pilot.merge", .text("off")),
                ("goals.mirror", .bool(false)),
            ]
        }
    }

    /// What picking it would do to `config`: the settings it sets, those already at its value (decided on, nothing
    /// written), and those it keeps because you set or decided on them.
    public static func apply(_ profile: SettingsProfile, to config: HeedConfig, chosen: ChosenSettings) -> ProfilePlan {
        var plan = ProfilePlan(profile: profile)
        for (id, value) in profile.values(for: config) {
            guard let entry = SettingsCatalog.entry(id) else { continue }
            let current = SettingsCatalog.value(entry, in: config)
            let planned = PlannedValue(entryID: id, from: current, to: value)
            if chosen.contains(id) || SettingsCatalog.isModified(entry, in: config) {
                plan.keeps.append(planned)
            } else if current == value {
                plan.confirms.append(planned)
            } else {
                plan.sets.append(planned)
            }
        }
        return plan
    }
}

/// One setting a profile names: its value now and the profile's.
public struct PlannedValue: Equatable, Sendable {
    public let entryID: String
    public let from: SettingValue?
    public let to: SettingValue
}

/// What a profile does to a config.
public struct ProfilePlan: Equatable, Sendable {
    public let profile: SettingsProfile
    /// At heed's default and not decided on, with another value in the profile: written on Apply.
    public var sets: [PlannedValue] = []
    /// At heed's default, which is the profile's value too: recorded as decided on, nothing written.
    public var confirms: [PlannedValue] = []
    /// Set by you, or decided on before: left as they are.
    public var keeps: [PlannedValue] = []

    public init(profile: SettingsProfile) {
        self.profile = profile
    }

    /// The settings it decides: those it sets and those it confirms.
    public var decided: [String] { (sets + confirms).map(\.entryID) }

    /// `sets 4 · keeps 1`.
    public var summary: String { "sets \(sets.count) · keeps \(keeps.count)" }
}
