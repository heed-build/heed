import Foundation
@testable import HeedCore
import Testing

struct SettingsLayoutTests {
    // MARK: Pages and sections

    /// A page without tabs shows every section its entries name, so the tree can scroll to each; nothing is lost
    /// between the catalog and the layout.
    @Test func everySectionOfACatalogPageIsLaidOut() {
        for page in SettingsPage.allCases where page.sections.isEmpty == false {
            let missing = SettingsCatalog.sections(of: page).filter { !page.sections.contains($0) }
            #expect(missing.isEmpty, "\(page): sections not laid out: \(missing)")
        }
        // Pages split into tabs or scopes list none: their sections change with the tab.
        for page in [SettingsPage.agents, .pilot, .orgsAndRepos, .hosts] {
            #expect(page.sections.isEmpty)
        }
    }

    @Test func thePilotsTabsHoldEveryPilotEntry() {
        let tabs = Set(SettingsCatalog.entries(on: .pilot).compactMap(\.tab))
        #expect(tabs == Set(SettingsPage.pilot.tabs))
        #expect(SettingsCatalog.entry("pilot.watch")?.tab == .green)
        #expect(SettingsCatalog.entries(on: .agents)
            .allSatisfy { SettingsPage.agents.tabs.contains($0.tab ?? .general) })
    }

    @Test func quietHoursAndTheAttachThresholdsAreOnOnePageEach() {
        #expect(SettingsCatalog.entries.filter { $0.key == ["attention", "quiet"] }.map(\.page) == [.notifications])
        let attach = SettingsCatalog.entries.filter { $0.id.hasPrefix("goals.attach") }
        #expect(attach.count == 4)
        #expect(attach.allSatisfy { $0.page == .decisions })
    }

    // MARK: Names

    /// Every name an earlier Settings took still opens the page that section's settings live on now.
    @Test(arguments: [
        ("general", SettingsPage.general), ("agents", .agents), ("colors", .orgsAndRepos), ("repos", .orgsAndRepos),
        ("orgs", .orgsAndRepos), ("cleanup", .worktrees), ("worktrees", .worktrees), ("keys", .keys),
        ("modes", .keys), ("pilot", .pilot), ("attention", .attention), ("rules", .attention), ("hosts", .hosts),
        ("ssh", .hosts), ("inference", .modelCalls), ("decisions", .decisions), ("llm", .modelCalls),
        ("model-calls", .modelCalls), ("modelCalls", .modelCalls), ("Notifications", .notifications),
        ("history", .history), ("tools", .tools), ("updates", .updates), ("goals", .goals), ("github", .github),
    ])
    func oldAndNewNamesOpenTheirPage(name: String, page: SettingsPage) {
        #expect(SettingsPage.named(name) == page)
    }

    @Test func unknownNamesOpenNothing() {
        #expect(SettingsPage.named("nope") == nil)
        #expect(SettingsTab.named("merged", on: .pilot) == .merged)
        #expect(SettingsTab.named("prompts", on: .pilot) == .instructions)
        #expect(SettingsTab.named("model-calls", on: .agents) == .modelCalls)
        #expect(SettingsTab.named("merged", on: .agents) == nil)
        #expect(SettingsTab.named("sessions", on: .general) == nil)
    }

    @Test func completionOffersEveryPageAndTheOldNames() {
        for page in SettingsPage.allCases {
            #expect(CommandCompletions.settingsSections.contains(page.commandName))
        }
        for alias in ["colors", "cleanup", "inference"] {
            #expect(CommandCompletions.settingsSections.contains(alias))
        }
        for name in CommandCompletions.settingsSections {
            #expect(SettingsPage.named(name) != nil, "\(name) opens nothing")
        }
    }

    // MARK: Dependent settings

    @Test func aDependentSettingSitsWithItsParent() throws {
        for (child, parent) in SettingsCatalog.parents {
            let entry = try #require(SettingsCatalog.entry(child), "\(child)")
            let owner = try #require(SettingsCatalog.entry(parent), "\(parent)")
            #expect(entry.page == owner.page && entry.section == owner.section, "\(child) is not with \(parent)")
            #expect(owner.scope == .global)
            guard case .bool = SettingsCatalog.value(owner, in: .default) else {
                Issue.record("\(parent) is not on/off")
                continue
            }
        }
    }

    @Test func aDependentSettingHidesWhileItsParentIsOffUnlessItIsSet() throws {
        let on = try #require(ConfigLoader.decode("").config)
        #expect(SettingsCatalog.isShown("notifications.grace_seconds", in: on))
        let off = try #require(ConfigLoader.decode("[notifications]\nenabled = false").config)
        #expect(!SettingsCatalog.isShown("notifications.grace_seconds", in: off))
        #expect(SettingsCatalog.isShown("notifications.enabled", in: off))
        let set = try #require(ConfigLoader.decode("[notifications]\nenabled = false\ngrace_seconds = 45").config)
        #expect(SettingsCatalog.isShown("notifications.grace_seconds", in: set))
        // Standup is off by default: its days hide until it is on.
        #expect(!SettingsCatalog.isShown("standup.days", in: on))
        // A refused value shows, so its reason has a row.
        let source = "[notifications]\nenabled = false\ngrace_seconds = 99999"
        let (refused, problems) = ConfigLoader.decode(source)
        #expect(try SettingsCatalog.isShown("notifications.grace_seconds", in: #require(refused), problems: problems))
    }

    // MARK: The tree

    @Test func theTreeListsGroupsPagesAndTheShownPagesSections() {
        let tree = SettingsTree(page: .notifications)
        let lines = tree.visible
        #expect(lines.first == .group(.heed))
        #expect(Array(lines.prefix(8)) == [
            .group(.heed), .page(.general), .page(.notifications), .section(.notifications, "Sessions"),
            .section(.notifications, "Attention"), .section(.notifications, "Quiet hours"),
            .section(.notifications, "Nudges"), .page(.updates),
        ])
        // 5 groups, 16 pages, 4 sections.
        #expect(lines.count == 5 + 16 + 4)
        // A page with one section lists none.
        #expect(SettingsTree(page: .github).children(of: .page(.github)).isEmpty)
    }

    @Test func aFoldedGroupHidesItsPages() {
        var tree = SettingsTree(page: .general, folded: [.group(.agents), .group(.machine)])
        #expect(!tree.visible.contains(.page(.modelCalls)))
        #expect(tree.visible.contains(.group(.agents)))
        tree.toggle(.group(.agents))
        #expect(tree.visible.contains(.page(.modelCalls)))
    }

    @Test func arrowsMoveAndShowThePageTheyReach() {
        var tree = SettingsTree(page: .general)
        var cursor = SettingsNode.page(.general)
        // General's two sections come first.
        cursor = tree.move(cursor, by: 1)
        #expect(cursor == .section(.general, "Sessions"))
        cursor = tree.move(cursor, by: 2)
        #expect(cursor == .page(.notifications))
        #expect(tree.page == .notifications)
        // Notifications' sections now show under it.
        cursor = tree.move(cursor, by: 1)
        #expect(cursor == .section(.notifications, "Sessions"))
        // Kept inside the tree.
        #expect(tree.move(.group(.heed), by: -3) == .group(.heed))
        let last = tree.visible.last!
        #expect(tree.move(last, by: 5) == last)
    }

    @Test func leftFoldsThenClimbsAndRightUnfoldsThenDescends() {
        var tree = SettingsTree(page: .notifications)
        var cursor = SettingsNode.section(.notifications, "Attention")
        cursor = tree.left(cursor)
        #expect(cursor == .page(.notifications))
        cursor = tree.left(cursor)
        #expect(cursor == .page(.notifications))
        #expect(tree.folded.contains(.page(.notifications)))
        #expect(!tree.visible.contains(.section(.notifications, "Sessions")))
        cursor = tree.left(cursor)
        #expect(cursor == .group(.heed))
        cursor = tree.left(cursor)
        #expect(tree.folded.contains(.group(.heed)))
        #expect(!tree.visible.contains(.page(.general)))
        #expect(tree.left(cursor) == .group(.heed))

        cursor = tree.right(cursor)
        #expect(!tree.folded.contains(.group(.heed)))
        cursor = tree.right(cursor)
        #expect(cursor == .page(.general))
        #expect(tree.page == .general)
        cursor = tree.right(cursor)
        #expect(cursor == .section(.general, "Sessions"))
        #expect(tree.right(cursor) == cursor)
        // → on a folded page unfolds it.
        var folded = SettingsTree(page: .general, folded: [.page(.general)])
        #expect(folded.right(.page(.general)) == .page(.general))
        #expect(folded.visible.contains(.section(.general, "Sessions")))
    }

    @Test func showingAPageUnfoldsItsGroup() {
        var tree = SettingsTree(page: .general, folded: [.group(.github)])
        tree.show(.page(.pilot))
        #expect(tree.page == .pilot)
        #expect(!tree.folded.contains(.group(.github)))
    }

    @Test func nodesRoundTripThroughText() {
        for node in [SettingsNode.group(.work), .page(.modelCalls), .section(.history, "Call log")] {
            #expect(SettingsNode(node.description) == node)
        }
        #expect(SettingsNode("page:nope") == nil)
        #expect(SettingsNode("garbage") == nil)
    }

    // MARK: Counts

    /// The marks roll up row → tab → agent → page → group: the agents' tabs add up to the agent, the agents and
    /// the page's own settings to the page, and the pages to the group, folded or not.
    @Test func countsRollUpFromRowsToTheTreeGroup() throws {
        let source = """
        [notifications]
        grace_seconds = 45
        blocked = false
        [agents.claude]
        plan = "--plan"
        model = "opus"
        llm = false
        [llm]
        timeout_seconds = 60
        """
        let config = try #require(ConfigLoader.decode(source).config)
        let counts = SettingsCatalog.counts(in: config)
        #expect(counts.modified(.tab(.agents, .agent("claude"), .sessions)) == 2)
        #expect(counts.modified(.tab(.agents, .agent("claude"), .modelCalls)) == 1)
        #expect(counts.modified(.target(.agents, .agent("claude"))) == 3)
        #expect(counts.modified(.page(.agents)) == 3)
        #expect(counts.modified(.page(.modelCalls)) == 1)
        #expect(counts.modified(.group(.agents)) == 4)
        #expect(counts.modified(.section(.notifications, "Sessions")) == 2)
        #expect(counts.modified(.group(.heed)) == 2)
        #expect(counts.modified(.group(.machine)) == 0)
    }

    @Test func aRefusedValueMarksItsPageAndGroup() throws {
        let (config, problems) = ConfigLoader.decode("[attention]\nquiet = \"22-7\"")
        let counts = try SettingsCatalog.counts(in: #require(config), problems: problems)
        #expect(counts.problems(.page(.notifications)) == 1)
        #expect(counts.problems(.group(.heed)) == 1)
        #expect(counts.problems(.section(.notifications, "Quiet hours")) == 1)
        #expect(counts.problems(.page(.general)) == 0)
    }

    // MARK: Agents

    static func status(_ login: LLMAgentStatus.Login, command: String = "claude") -> LLMAgentStatus {
        LLMAgentStatus(
            name: "claude", command: command, path: login == .notInstalled ? nil : "/bin/claude", login: login,
            detectedModel: nil, checkedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func anAgentIsReadyNotInstalledOrBrokenWithAReason() throws {
        let claude = try #require(AgentProfile.builtIn.first { $0.name == "claude" })
        #expect(AgentReadiness.of(claude, status: Self.status(.loggedIn)) == .ready)
        #expect(AgentReadiness.of(claude, status: Self.status(.unknown)) == .ready)
        #expect(AgentReadiness.of(claude, status: Self.status(.notInstalled)) == .notInstalled)
        #expect(AgentReadiness.of(claude, status: Self.status(.loggedOut)) == .broken("logged out"))
        #expect(AgentReadiness.of(claude, status: Self.status(.loggedIn), lastTestFailed: true)
            == .broken("last test failed"))
        #expect(AgentReadiness.of(claude, status: nil) == .unchecked)
        // Its own command, not found: broken, not "not installed".
        var moved = claude
        moved.command = "/opt/claude-dev/bin/claude"
        #expect(AgentReadiness.of(moved, status: Self.status(.notInstalled, command: moved.command))
            == .broken("command not found"))
        #expect(AgentReadiness.ready.note == nil)
        #expect(AgentReadiness.notInstalled.glyph == "○")
    }

    @Test func theStatusLineSaysWhatIsInstalledItsHooksAndWhatIsModified() throws {
        let claude = try #require(AgentProfile.builtIn.first { $0.name == "claude" })
        let line = AgentReadiness.statusLine(claude, status: Self.status(.loggedIn), readiness: .ready, modified: 2)
        #expect(line == "installed · logged in · full hooks · 2 modified")
        let gemini = try #require(AgentProfile.builtIn.first { $0.name == "gemini" })
        #expect(AgentReadiness.statusLine(
            gemini,
            status: Self.status(.notInstalled),
            readiness: .notInstalled,
            modified: 0
        ) == "not installed · reads the screen")
        let custom = AgentProfile(name: "mytool", command: "mytool")
        #expect(AgentReadiness.statusLine(custom, status: nil, readiness: .unchecked, modified: 1)
            == "custom agent · reads the screen · 1 modified")
    }
}
