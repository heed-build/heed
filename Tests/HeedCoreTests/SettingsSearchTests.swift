import Foundation
@testable import HeedCore
import Testing

/// Settings' search: what a query finds, at which agent, org, repo or host, in which order, and what the tree keeps.
struct SettingsSearchTests {
    static func decoded(_ source: String) throws -> (HeedConfig, [ConfigProblem]) {
        let (config, problems) = ConfigLoader.decode(source)
        return try (#require(config), problems)
    }

    static func ids(_ search: SettingsSearch) -> [String] { search.matches.map(\.entry.id) }

    @Test func everyWordMustMatchSomewhere() {
        let search = SettingsCatalog.search("quiet hours", in: .default)
        #expect(Self.ids(search).contains("attention.quiet"))
        // "hours" alone is in more places than "quiet hours".
        let hours = SettingsCatalog.search("hours", in: .default)
        #expect(hours.matches.count >= search.matches.count)
        // A word that is nowhere empties it, whatever the others find.
        #expect(SettingsCatalog.search("quiet zzzz", in: .default).isEmpty)
        #expect(SettingsCatalog.search("   ", in: .default).isEmpty)
        // Words can come from different fields: the page ("notifications") and the label ("grace").
        #expect(Self.ids(SettingsCatalog.search("Notifications GRACE", in: .default)) == [
            "notifications.grace_seconds",
        ])
    }

    /// Where an entry lives (page, group, section, tab) makes it match only when nothing matches on its own text,
    /// or when the query names the place outright.
    @Test func placeNamesCountOnlyWithoutOwnMatchesOrWhenNamed() {
        func ids(_ query: String) -> [String] { SettingsCatalog.search(query).map(\.id) }
        // "model" is in Model calls' page name, but At once says nothing of models: not found.
        let model = ids("model")
        #expect(model.contains("llm.enabled"))
        #expect(model.contains("agent.model"))
        #expect(!model.contains("llm.concurrency"))
        #expect(!model.contains("llm.daily_calls"))
        // Naming the page lists it whole.
        let page = ids("Model calls")
        #expect(page.contains("llm.concurrency"))
        #expect(page.contains("llm.daily_calls"))
        #expect(page.first == "llm.enabled")
        // A section named outright too.
        #expect(ids("limits").contains("llm.concurrency"))
        // Words found in no entry's own text fall back to the places: page and section together.
        let fallback = ids("decisions & hunch local decisions")
        #expect(fallback == ["local.record_screens", "local.keep_days"])
    }

    @Test func configKeysAsWrittenMatch() {
        #expect(Self.ids(SettingsCatalog.search("grace_seconds", in: .default)) == ["notifications.grace_seconds"])
        #expect(Self.ids(SettingsCatalog.search("notifications.grace_seconds", in: .default)) == [
            "notifications.grace_seconds",
        ])
        let timeout = SettingsCatalog.search("llm.timeout_seconds", in: .default)
        #expect(Self.ids(timeout) == ["llm.timeout_seconds"])
        // Found by its key, so the row says the key.
        let entry = timeout.matches[0].entry
        #expect(timeout.matchesKey(entry))
        #expect(!SettingsCatalog.search("timeout", in: .default).matchesKey(
            SettingsCatalog.entry("llm.enabled")!
        ))
    }

    /// The page with a label match comes first, then pages by their best match; each page in its own order.
    @Test func pagesWithALabelMatchComeFirst() {
        let search = SettingsCatalog.search("zmx", in: .default)
        // tools.zmx is labelled zmx; sessions.persist only says it in its detail.
        #expect(search.pages.first == .tools)
        #expect(search.pages.contains(.general))
        #expect(search.pages.firstIndex(of: .tools)! < search.pages.firstIndex(of: .general)!)
        // Within a page, the catalog's order: the pane draws the page's rows as the page does.
        let modelCalls = search.matches(on: .modelCalls).map(\.entry.id)
        let order = SettingsCatalog.entries(on: .modelCalls).map(\.id).filter(modelCalls.contains)
        #expect(modelCalls == order)
    }

    /// Advanced settings are found whatever Show advanced says.
    @Test func advancedSettingsAreFound() {
        let search = SettingsCatalog.search("timeout", in: .default)
        let timeout = search.matches.first { $0.entry.id == "llm.timeout_seconds" }
        #expect(timeout?.entry.level == .advanced)
    }

    @Test func onlyModifiedKeepsTheChangedMatches() throws {
        let (config, problems) = try Self.decoded("""
        [notifications]
        grace_seconds = 45
        reminder_minutes = 99999
        [agents.codex]
        model = "gpt-5"
        """)
        let all = SettingsCatalog.search("notifications", in: config, problems: problems)
        #expect(all.matches.count > 2)
        let changed = SettingsCatalog.search("notifications", in: config, problems: problems, onlyModified: true)
        // One modified, one refused (heed reads 99999 minutes as a problem).
        #expect(Set(Self.ids(changed)) == ["notifications.grace_seconds", "notifications.reminder_minutes"])
        // Nothing changed matches: empty, not everything.
        #expect(SettingsCatalog.search("hunch", in: config, problems: problems, onlyModified: true).isEmpty)
        // A scoped one: only the agent it is set on.
        let model = SettingsCatalog.search("model", in: config, problems: problems, onlyModified: true)
        #expect(model.matches.filter { $0.entry.id == "agent.model" }.map(\.target) == [.agent("codex")])
    }

    /// A scoped setting shows where it is set, else where its page opens.
    @Test func scopedSettingsShowWhereTheyAreSetElseAtHome() throws {
        let plain = SettingsCatalog.search("prompt delivery", in: .default)
        #expect(plain.matches.map(\.target) == [.agent(HeedConfig.default.work.defaultAgent)])

        let (config, problems) = try Self.decoded("""
        [agents.codex]
        prompt = "stdin"
        [agents.cursor]
        prompt = "paste"
        """)
        let set = SettingsCatalog.search("prompt delivery", in: config, problems: problems)
        #expect(set.matches.map(\.target) == [.agent("codex"), .agent("cursor")])

        // An org setting with no org in config.toml: the first org the repo list has.
        let watch = SettingsCatalog.search("[orgs.<org>] watch", in: .default, known: [.org("acme"), .org("globex")])
        #expect(watch.matches.map(\.target) == [.org("acme")])
        // A host setting with no host: listed, with nowhere to show it yet.
        let ssh = SettingsCatalog.search("[hosts.<name>] worktree_root", in: .default)
        #expect(ssh.matches.count == 1)
        #expect(ssh.matches[0].target == nil)
    }

    @Test func rowsAndSectionsKnowTheyMatched() {
        let search = SettingsCatalog.search("grace", in: .default)
        #expect(search.contains(["notifications.grace_seconds"], at: .global))
        #expect(search.contains(["notifications.enabled", "notifications.grace_seconds"], at: .global))
        #expect(!search.contains(["notifications.enabled"], at: .global))
        #expect(!search.contains(["notifications.grace_seconds"], at: .agent("claude")))
        #expect(search.contains(page: .notifications, section: "Sessions"))
        #expect(!search.contains(page: .notifications, section: "Quiet hours"))
        #expect(search.count(.notifications) == 1)
        #expect(search.count(SettingsGroup.heed) == 1)
        #expect(search.count(SettingsGroup.github) == 0)
    }

    /// The tree keeps the groups and pages with matches, those groups open; the fold state itself is kept.
    @Test func theTreeKeepsMatchesAndItsFolds() {
        let search = SettingsCatalog.search("grace", in: .default)
        let tree = SettingsTree(page: .general, folded: [.group(.heed), .group(.machine)])
        let shown = tree.searching(search)
        #expect(shown.visible == [.group(.heed), .page(.notifications)])
        #expect(shown.folded == [.group(.machine)])
        // The tree it came from is unchanged.
        #expect(tree.folded == [.group(.heed), .group(.machine)])
        #expect(tree.searching(SettingsCatalog.search("zzzz", in: .default)).visible.isEmpty)
    }

    @Test func rangesHighlightEveryWordIgnoringCase() {
        let search = SettingsCatalog.search("model ODEL calls", in: .default)
        let text = "Model calls: a model"
        let ranges = search.ranges(in: text).map { String(text[$0]) }
        // "model" and "odel" overlap into one.
        #expect(ranges == ["Model", "calls", "model"])
    }

    /// The field editor's commands the search takes; the rest stay the text's.
    @Test func theFieldHandsOnlyItsFourKeysToTheSearch() {
        #expect(SettingsSearchKey(command: "moveUp:") == .up)
        #expect(SettingsSearchKey(command: "moveDown:") == .down)
        #expect(SettingsSearchKey(command: "insertNewline:") == .open)
        #expect(SettingsSearchKey(command: "cancelOperation:") == .clear)
        #expect(SettingsSearchKey(command: "moveLeft:") == nil)
        #expect(SettingsSearchKey(command: "deleteBackward:") == nil)
        #expect(SettingsSearchKey(command: "insertTab:") == nil)
    }
}
