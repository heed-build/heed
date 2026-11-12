import Foundation
@testable import HeedCore
import Testing

struct ConfigureTests {
    static func config(_ source: String) throws -> HeedConfig {
        try #require(ConfigLoader.decode(source).config)
    }

    /// config.toml with these values written, read back as heed reads it.
    static func written(_ values: [(path: [String], value: TOMLValue)], over source: String = "") throws
        -> (HeedConfig, [ConfigProblem])
    {
        var text = source
        for (path, value) in values {
            text = try TOMLDocument(text).setting(path, to: value)
        }
        let (config, problems) = ConfigLoader.decode(text)
        return try (#require(config), problems)
    }

    // MARK: Profiles

    @Test(arguments: SettingsProfile.allCases)
    func everyProfileValueIsASettingHeedTakesAndReadsBack(_ profile: SettingsProfile) throws {
        let values = profile.values()
        #expect(!values.isEmpty)
        #expect(Set(values.map(\.id)).count == values.count, "a key named twice")
        let entries = try values.map { try #require(SettingsCatalog.entry($0.id), "no entry \($0.id)") }
        #expect(entries.allSatisfy { $0.scope == .global })
        let (config, problems) = try Self.written(zip(entries, values).map { ($0.key, $1.value.toml) })
        #expect(problems.isEmpty, "\(problems)")
        for (entry, planned) in zip(entries, values) {
            #expect(SettingsCatalog.value(entry, in: config) == planned.value, "\(entry.id)")
        }
    }

    @Test func aProfileSetsOnlyWhatIsAtItsDefaultAndUndecided() throws {
        let plan = SettingsProfile.apply(.focus, to: .default, chosen: ChosenSettings())
        // notifications.blocked is on already: confirmed, not written.
        #expect(plan.confirms.map(\.entryID) == ["notifications.blocked"])
        #expect(plan.sets.map(\.entryID) == [
            "notifications.asking", "attention.quiet", "notifications.reminder_minutes", "ui.dock_state",
            "notifications.attention",
        ])
        #expect(plan.keeps.isEmpty)
        #expect(plan.summary == "sets 5 · keeps 0")
        #expect(plan.sets.first?.from == .bool(true))
        #expect(plan.sets.first?.to == .bool(false))
    }

    @Test func aProfileNeverTouchesWhatYouSetOrDecided() throws {
        let config = try Self.config("[notifications]\nasking = true\nreminder_minutes = 30\n[ui]\ndock_state = true\n")
        // reminder_minutes is yours (30, not 15); dock_state was decided on (Keep default) though at its default.
        let chosen = ChosenSettings(["ui.dock_state"])
        let plan = SettingsProfile.apply(.focus, to: config, chosen: chosen)
        #expect(Set(plan.keeps.map(\.entryID)) == ["notifications.reminder_minutes", "ui.dock_state"])
        #expect(!plan.sets.map(\.entryID).contains("notifications.reminder_minutes"))
        #expect(!plan.sets.map(\.entryID).contains("ui.dock_state"))
        #expect(plan.summary == "sets 3 · keeps 2")
        // A value written out at heed's default (the shipped config.toml lists most) is not yours: asking still goes.
        #expect(plan.sets.map(\.entryID).contains("notifications.asking"))

        let draft = ConfigureDraft(profile: .focus)
        let keys = draft.changes(config, chosen: chosen).map(\.key)
        #expect(!keys.contains("notifications.reminder_minutes"))
        #expect(!keys.contains("ui.dock_state"))
    }

    @Test func autopilotsSelfReviewIsClaudesOnlyWhereClaudeIsTheDefaultAgent() throws {
        #expect(SettingsProfile.autopilot.values().contains { $0.id == "pilot.self_review" })
        let codex = try Self.config("[sessions]\ndefault_agent = \"codex\"\n")
        #expect(!SettingsProfile.autopilot.values(for: codex).contains { $0.id == "pilot.self_review" })
    }

    // MARK: Gaps

    /// The ranking, on a fresh config: high, then medium, then low, each in page order.
    @Test func gapsRankHighThenMediumThenLow() {
        let ids = SettingsCatalog.gaps(in: .default, chosen: ChosenSettings()).map(\.id)
        #expect(ids == [
            "sessions.persist", "notifications.enabled", "llm.agent",
            "ui.menu_bar", "decisions.decider", "goals.tracker", "pilot.green", "keys.global_start_work",
            "attention.quiet", "updates.install", "cleanup.enabled", "standup.enabled", "pilot.merge",
        ])
    }

    @Test func gapsThatNeedSomethingDoneSayWhat() throws {
        let missing = SettingsCatalog.gaps(in: .default, chosen: ChosenSettings(), facts: GapFacts(zmxWorks: false))
        #expect(missing.first { $0.id == "sessions.persist" }?.action == .installZmx(commands: ZmxInstall.mac))
        #expect(missing.first { $0.id == "llm.agent" }?.action == .setUpModelCalls)
        #expect(missing.first { $0.id == "ui.menu_bar" }?.action == nil)
        let works = SettingsCatalog.gaps(in: .default, chosen: ChosenSettings(), facts: GapFacts(zmxWorks: true))
        #expect(works.first { $0.id == "sessions.persist" }?.action == nil)
    }

    @Test func theGapsStepLeavesOutWhatTheProfileDecides() {
        let draft = ConfigureDraft(profile: .autopilot)
        let ids = draft.gaps(.default, chosen: ChosenSettings(), facts: GapFacts()).map(\.id)
        #expect(!ids.contains("pilot.green"))
        #expect(!ids.contains("pilot.merge"))
        // Already on, so confirmed by the profile: no longer asked.
        #expect(!ids.contains("ui.menu_bar"))
        #expect(ids.contains("sessions.persist"))
    }

    // MARK: Draft

    @Test func nothingIsAChangeUntilItDiffersFromConfigToml() {
        var draft = ConfigureDraft()
        #expect(draft.changes(.default, chosen: ChosenSettings()).isEmpty)
        draft.keepDefault("sessions.persist")
        draft.set("ui.menu_bar", .bool(true))
        #expect(draft.changes(.default, chosen: ChosenSettings()).isEmpty)
        #expect(draft.decided(.default, chosen: ChosenSettings()) == ["sessions.persist", "ui.menu_bar"])
    }

    @Test func aGapsValueWinsOverTheProfilesAndApplyWritesInCatalogOrder() throws {
        var draft = ConfigureDraft(profile: .focus)
        draft.set("attention.quiet", .text("22:00-07:00"))
        draft.set("sessions.persist", .text("zmx"))
        let changes = draft.changes(.default, chosen: ChosenSettings())
        #expect(changes.map(\.key) == [
            "sessions.persist", "ui.dock_state", "notifications.asking", "notifications.reminder_minutes",
            "notifications.attention", "attention.quiet",
        ])
        #expect(changes.first { $0.key == "attention.quiet" }?.to == .text("22:00-07:00"))
        #expect(try draft.value(
            #require(SettingsCatalog.entry("attention.quiet")),
            in: .default,
            chosen: ChosenSettings()
        ) == .text("22:00-07:00"))

        // Written, every change reads back, and what was decided stops being a gap.
        let (config, problems) = try Self.written(changes.map { try ($0.path, #require($0.to).toml) })
        #expect(problems.isEmpty)
        for change in changes {
            #expect(SettingsCatalog.value(change.entry, in: config) == change.to)
        }
        let chosen = ChosenSettings(draft.decided(.default, chosen: ChosenSettings()))
        let left = SettingsCatalog.gaps(in: config, chosen: chosen).map(\.id)
        #expect(!left.contains("sessions.persist"))
        #expect(!left.contains("attention.quiet"))
        #expect(left.contains("llm.agent"))
    }

    @Test func keepDefaultAndReopenUndoAValue() {
        var draft = ConfigureDraft()
        draft.set("pilot.green", .text("auto"))
        #expect(draft.changes(.default, chosen: ChosenSettings()).map(\.key) == ["pilot.green"])
        draft.keepDefault("pilot.green")
        #expect(draft.changes(.default, chosen: ChosenSettings()).isEmpty)
        #expect(draft.isDecided("pilot.green"))
        draft.reopen("pilot.green")
        #expect(!draft.isDecided("pilot.green"))
        #expect(draft.decided(.default, chosen: ChosenSettings()).isEmpty)
    }

    @Test func aRemovedKeyIsAChangeOnlyWhenConfigTomlHasAnotherValue() throws {
        var draft = ConfigureDraft()
        draft.set("decisions.decider", nil)
        #expect(draft.changes(.default, chosen: ChosenSettings()).isEmpty)
        let set = try Self.config("[decisions]\ndecider = \"local\"\n")
        let changes = draft.changes(set, chosen: ChosenSettings())
        #expect(changes.map(\.key) == ["decisions.decider"])
        #expect(changes.first?.to == nil)
    }

    @Test func entriesAreFoundByTheirKey() {
        #expect(SettingsCatalog.entry(at: ["notifications", "enabled"])?.id == "notifications.enabled")
        #expect(SettingsCatalog.entry(at: ["command"]) == nil)
        #expect(SettingValue(TOMLValue.array([.string("a")])) == .list(["a"]))
        #expect(SettingValue(TOMLValue.float(0.5)) == .number(0.5))
        #expect(SettingValue(TOMLValue.array([.integer(1)])) == nil)
    }
}
