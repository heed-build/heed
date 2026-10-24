import Foundation
@testable import HeedCore
import Testing

/// What Settings writes for the keys that once lived only in config.toml: each value written into the commented
/// default file reads back as that value, with no problem, and the file's comments stay.
struct SettingsRoundTripTests {
    private func written(_ edits: [([String], TOMLValue)]) throws -> (HeedConfig, String) {
        var text = ConfigLoader.defaultSource
        for (path, value) in edits {
            text = try TOMLDocument(text).setting(path, to: value)
        }
        let (config, problems) = ConfigLoader.decode(text)
        #expect(problems.isEmpty, "\(problems)")
        return try (#require(config), text)
    }

    @Test func modelCallsRoundTrip() throws {
        let (config, text) = try written([
            (["llm", "enabled"], .bool(false)),
            (["llm", "timeout_seconds"], .integer(300)),
            (["llm", "concurrency"], .integer(4)),
            (["llm", "backoff_minutes"], .integer(0)),
            (["llm", "daily_calls"], .integer(0)),
            (["llm", "daily_dollars"], .float(2.5)),
        ])
        #expect(!config.llm.enabled)
        #expect(config.llm.timeoutSeconds == 300)
        #expect(config.llm.concurrency == 4)
        #expect(config.llm.backoffMinutes == 0)
        #expect(config.llm.dailyCalls == 0)
        #expect(config.llm.dailyDollars == 2.5)
        #expect(text.contains("# heed's own short model calls"))
        // The master switch back on: the way back Settings now offers.
        let (again, _) = try written([(["llm", "enabled"], .bool(false)), (["llm", "enabled"], .bool(true))])
        #expect(again.llm.enabled)
        #expect(again == HeedConfig.default)
    }

    @Test func wholeDollarsReadBackAsDollars() throws {
        let (config, _) = try written([(["llm", "daily_dollars"], .float(3))])
        #expect(config.llm.dailyDollars == 3)
    }

    @Test func usageUpdatesAndGlobalShortcutsRoundTrip() throws {
        let (config, text) = try written([
            (["usage", "show_cost"], .bool(false)),
            (["updates", "check"], .bool(false)),
            (["updates", "install"], .string("auto")),
            (["keys", "global_start_work"], .string("<C-M-o>")),
            (["keys", "global_activate"], .string("")),
        ])
        #expect(!config.usage.showCost)
        #expect(config.updates == UpdateSettings(check: false, install: .auto))
        #expect(config.globalStartWork == "<C-M-o>")
        #expect(config.globalActivate == "")
        #expect(text.contains("# Brings Heed to the front from any app"))
        #expect(config != HeedConfig.default)
    }

    /// Updates take part in equality, so a config that differs only there is not the default.
    @Test func updatesCountInEquality() throws {
        let (config, _) = try written([(["updates", "install"], .string("auto"))])
        #expect(config != HeedConfig.default)
    }
}

struct GlobalShortcutTests {
    @Test func acceptsOneModifiedKeyAndOff() {
        #expect(GlobalShortcut.problem("") == nil)
        #expect(GlobalShortcut.problem("<C-M-Space>") == nil)
        #expect(GlobalShortcut.problem("<D-S-k>") == nil)
        #expect(GlobalShortcut.problem("<M-h>", other: "<C-M-Space>") == nil)
        #expect(GlobalShortcut.problem("<C-M-Space>", other: "") == nil)
    }

    @Test func refusesWhatCannotWork() {
        #expect(GlobalShortcut.problem("gg")?.contains("not one key") == true)
        #expect(GlobalShortcut.problem("<lt")?.contains("not one key") == true)
        #expect(GlobalShortcut.problem("h")?.contains("needs ⌃, ⌥ or ⌘") == true)
        #expect(GlobalShortcut.problem("<S-Tab>")?.contains("needs ⌃, ⌥ or ⌘") == true)
        #expect(GlobalShortcut.problem("<C-Home>")?.contains("no key code") == true)
        #expect(GlobalShortcut.problem("<C-M-h>", other: "<C-M-h>")?.contains("already") == true)
    }
}
