import Foundation
@testable import HeedCore
import Testing

/// Show advanced and Only modified: which rows draw, what the tree keeps, what Reset all removes.
struct SettingsFilterTests {
    /// Three changes on Notifications (one a value heed refuses), one on an agent, one advanced one on Model calls.
    static let source = """
    [notifications]
    grace_seconds = 45
    blocked = false
    [attention]
    quiet = "22-7"
    [agents.claude]
    model = "opus"
    [llm]
    timeout_seconds = 60
    """

    static func decoded(_ source: String = source) throws -> (HeedConfig, [ConfigProblem]) {
        let (config, problems) = ConfigLoader.decode(source)
        return try (#require(config), problems)
    }

    static let hiding = SettingsFilter()
    static let showing = SettingsFilter(showAdvanced: true)
    static let onlyModified = SettingsFilter(onlyModified: true)

    // MARK: Show advanced

    @Test func anAdvancedSettingAtItsDefaultHidesCountedUntilShown() {
        let config = HeedConfig.default
        #expect(SettingsCatalog.entry("llm.concurrency")?.level == .advanced)
        #expect(SettingsCatalog.visibility(["llm.concurrency"], in: config, filter: Self.hiding) == .hiddenAdvanced)
        #expect(SettingsCatalog.visibility(["llm.concurrency"], in: config, filter: Self.showing) == .shown)
        // A basic one shows either way.
        #expect(SettingsCatalog.visibility(["llm.enabled"], in: config, filter: Self.hiding) == .shown)
    }

    /// Nothing set or broken is ever out of sight.
    @Test func anAdvancedSettingThatIsSetOrRefusedAlwaysShows() throws {
        let (config, _) = try Self.decoded()
        #expect(SettingsCatalog.visibility(["llm.timeout_seconds"], in: config, filter: Self.hiding) == .shown)
        let (refusedConfig, refused) = try Self.decoded("[llm]\ntimeout_seconds = \"soon\"\n")
        #expect(try !SettingsCatalog.isModified(
            #require(SettingsCatalog.entry("llm.timeout_seconds")),
            in: refusedConfig
        ))
        #expect(SettingsCatalog.visibility(
            ["llm.timeout_seconds"], in: refusedConfig, problems: refused, filter: Self.hiding
        ) == .shown)
        #expect(SettingsCatalog.visibility(
            ["llm.timeout_seconds"], in: refusedConfig, problems: [], filter: Self.hiding
        ) == .hiddenAdvanced)
    }

    /// A row of a basic and an advanced setting is not advanced; a scoped one hides the same way.
    @Test func aRowHidesOnlyWhenAllItsSettingsAreAdvanced() {
        let config = HeedConfig.default
        #expect(SettingsCatalog.visibility(["llm.enabled", "llm.concurrency"], in: config, filter: Self.hiding)
            == .shown)
        #expect(SettingsCatalog.visibility(
            ["agent.model_flag"], at: .agent("claude"), in: config, filter: Self.hiding
        ) == .hiddenAdvanced)
    }

    /// A dependent setting under a parent that is off is hidden, not counted as advanced.
    @Test func aDependentRowUnderAnOffParentIsHiddenNotCounted() throws {
        let (config, _) = try Self.decoded("[cleanup]\nenabled = false\n")
        #expect(SettingsCatalog.visibility(["cleanup.idle_days"], in: config, filter: Self.showing) == .hidden)
        #expect(SettingsCatalog.visibility(["cleanup.idle_days"], in: config, filter: Self.hiding) == .hidden)
    }

    // MARK: Only modified

    @Test func onlyModifiedKeepsChangedAndRefusedRows() throws {
        let (config, problems) = try Self.decoded()
        func visibility(_ id: String, at target: SettingTarget = .global) -> SettingVisibility {
            SettingsCatalog.visibility([id], at: target, in: config, problems: problems, filter: Self.onlyModified)
        }
        #expect(visibility("notifications.grace_seconds") == .shown)
        #expect(visibility("notifications.blocked") == .shown)
        #expect(visibility("attention.quiet") == .shown)
        #expect(visibility("notifications.asking") == .hidden)
        // Advanced ones at their default are hidden, not counted: there is nothing to Show.
        #expect(visibility("llm.concurrency") == .hidden)
        #expect(visibility("agent.model", at: .agent("claude")) == .shown)
        #expect(visibility("agent.model", at: .agent("codex")) == .hidden)
    }

    /// Set under a parent that is off still shows: Only modified shows every change.
    @Test func onlyModifiedShowsAChangeUnderAnOffParent() throws {
        let (config, _) = try Self.decoded("[notifications]\nenabled = false\ngrace_seconds = 45\n")
        #expect(SettingsCatalog.visibility(["notifications.grace_seconds"], in: config, filter: Self.onlyModified)
            == .shown)
        #expect(SettingsCatalog.visibility(["notifications.asking"], in: config, filter: Self.onlyModified)
            == .hidden)
    }

    @Test func onlyModifiedKeepsTheTabsHoldingAChange() {
        let tabs: [SettingsTab] = [.green, .merged, .reviews, .instructions]
        let changed: (SettingsTab) -> Bool = { $0 == .merged || $0 == .reviews }
        let all = SettingsFilter().tabs(tabs, current: .green, changed: changed)
        #expect(all.shown == tabs)
        #expect(all.current == .green)
        let kept = Self.onlyModified.tabs(tabs, current: .green, changed: changed)
        #expect(kept.shown == [.merged, .reviews])
        #expect(kept.current == .merged)
        #expect(Self.onlyModified.tabs(tabs, current: .reviews, changed: changed).current == .reviews)
        #expect(Self.onlyModified.tabs(tabs, current: .green) { _ in false }.shown.isEmpty)
    }

    // MARK: The tree

    @Test func theTreeKeepsOnlyGroupsPagesAndSectionsWithAChange() throws {
        let (config, problems) = try Self.decoded()
        let kept = SettingsCatalog.counts(in: config, problems: problems).changedNodes
        var tree = SettingsTree(page: .general, kept: kept)
        #expect(tree.keptPage == .notifications)
        tree.show(.page(.notifications))
        #expect(tree.visible == [
            .group(.heed), .page(.notifications), .section(.notifications, "Sessions"),
            .section(.notifications, "Quiet hours"),
            .group(.agents), .page(.agents), .page(.modelCalls),
        ])
        // Without Only modified every line shows.
        tree.kept = nil
        #expect(tree.visible.count > 20)
        #expect(tree.keptPage == .notifications)
    }

    @Test func nothingChangedKeepsNoLineAndNoPage() {
        let kept = SettingsCatalog.counts(in: .default).changedNodes
        #expect(kept.isEmpty)
        let tree = SettingsTree(page: .general, kept: kept)
        #expect(tree.visible.isEmpty)
        #expect(tree.keptPage == nil)
    }

    // MARK: Reset all

    @Test func resetAllRemovesEveryChangedKeyOnThePageAndNothingElse() throws {
        let (config, problems) = try Self.decoded()
        let changes = SettingsCatalog.changes(on: .notifications, in: config, problems: problems)
        let paths = SettingsCatalog.resetPaths(changes)
        #expect(paths == [["notifications", "blocked"], ["notifications", "grace_seconds"], ["attention", "quiet"]])
        var text = Self.source
        for path in paths {
            text = try TOMLDocument(text).removing(path)
        }
        let (reset, left) = try Self.decoded(text)
        #expect(SettingsCatalog.changes(on: .notifications, in: reset, problems: left).isEmpty)
        // Other pages keep theirs.
        #expect(SettingsCatalog.changes(on: .agents, in: reset, problems: left).count == 1)
        #expect(SettingsCatalog.changes(on: .modelCalls, in: reset, problems: left).count == 1)
    }

    @Test func resetAllOnAScopedPageRemovesTheKeysUnderItsTables() throws {
        let (config, problems) = try Self.decoded()
        let paths = SettingsCatalog.resetPaths(SettingsCatalog.changes(on: .agents, in: config, problems: problems))
        #expect(paths == [["agents", "claude", "model"]])
        #expect(SettingsCatalog.keyText(["repos", "acme/docs", "watch"]) == "repos.\"acme/docs\".watch")
    }
}
