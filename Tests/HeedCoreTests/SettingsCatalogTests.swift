import Foundation
@testable import HeedCore
import Testing

struct SettingsCatalogTests {
    /// Where each scope's entries are tried.
    static func sample(_ scope: SettingScope) -> SettingTarget {
        switch scope {
        case .global: .global
        case .agent: .agent("claude")
        case .org, .orgAndRepo: .org("acme")
        case .repo: .repo("acme/docs-toolkit")
        case .host: .host("devbox")
        }
    }

    /// Every key the shipped config.toml has: the ones set, and the ones shown commented out (`# merge_method =
    /// "squash"`, `# [hosts.devbox]`), each with the table it sits under.
    static func templateKeys() throws -> [[String]] {
        var keys: [[String]] = []
        func walk(_ table: TOMLTable, _ path: [String]) {
            for key in table.keys {
                if case let .table(inner) = table[key] { walk(inner, path + [key]) } else { keys.append(path + [key]) }
            }
        }
        try walk(TOMLDocument(ConfigLoader.defaultSource).root, [])

        var header: [String] = []
        for raw in ConfigLoader.defaultSource.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let isComment = line.hasPrefix("#")
            let body = isComment ? line.dropFirst().trimmingCharacters(in: .whitespaces) : line
            if body.hasPrefix("["), body.hasSuffix("]"), let document = try? TOMLDocument(body) {
                // The header's path: down the one table at each level.
                var path: [String] = []
                var table = document.root
                while let key = table.keys.first, let inner = table[key]?.table {
                    path.append(key)
                    table = inner
                }
                header = path
                continue
            }
            guard isComment, body.range(of: #"^("[^"]+"|[A-Za-z0-9_-]+)\s*="#, options: .regularExpression) != nil
            else { continue }
            if let document = try? TOMLDocument(body), let key = document.root.keys.first {
                keys.append(header + [key])
            } else if body.hasSuffix("= ["), let key = body.split(separator: "=").first {
                // A commented multi-line array (`# rules = [`).
                keys.append(header + [key.trimmingCharacters(in: .whitespaces)])
            }
        }
        return keys
    }

    @Test func everyKeyOfTheShippedConfigHasAnEntry() throws {
        let keys = try Self.templateKeys()
        #expect(keys.count > 150)
        #expect(keys.contains(["pilot", "merge_method"]))
        #expect(keys.contains(["hosts", "devbox", "color"]))
        #expect(keys.contains(["attention", "rules"]))
        var missing: [String] = []
        for key in keys where SettingsCatalog.owner(of: key.joined(separator: ".")) == nil {
            missing.append(key.joined(separator: "."))
        }
        #expect(missing.isEmpty, "keys without a catalog entry: \(missing)")
    }

    /// The keys Settings writes today, as literal paths in its views: each has an entry.
    @Test func everyKeySettingsWritesHasAnEntry() throws {
        let views = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/HeedApp/Views")
        let files = ["SettingsView", "InferenceSettings", "OrgRepoSettings", "AttentionRuleSettings", "HunchSettings"]
        var paths: Set<String> = []
        for file in files {
            let text = try String(contentsOf: views.appendingPathComponent("\(file).swift"), encoding: .utf8)
            let pattern = try NSRegularExpression(pattern: #"\["([a-z_]+)", "([a-z_]+)"\]"#)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let table = Range(match.range(at: 1), in: text), let key = Range(match.range(at: 2), in: text)
                else { continue }
                paths.insert("\(text[table]).\(text[key])")
            }
        }
        #expect(paths.count > 60)
        let missing = paths.filter { SettingsCatalog.owner(of: $0) == nil }.sorted()
        #expect(missing.isEmpty, "written by Settings, not in the catalog: \(missing)")
    }

    @Test func idsAreUniqueAndEveryPageHasEntries() {
        let ids = SettingsCatalog.entries.map(\.id)
        #expect(Set(ids).count == ids.count)
        for page in SettingsPage.allCases {
            #expect(!SettingsCatalog.entries(on: page).isEmpty, "\(page) has no entries")
        }
        for entry in SettingsCatalog.entries {
            #expect(!entry.label.isEmpty && !entry.detail.isEmpty && !entry.section.isEmpty, "\(entry.id)")
            let parts = entry.since.split(separator: ".").compactMap { Int($0) }
            #expect((2 ... 3).contains(parts.count), "\(entry.id) since \(entry.since)")
        }
    }

    /// Each entry's key is one heed reads: its example is taken without a problem, and a value of the wrong type is
    /// refused with a reason, on this entry and at this target.
    @Test func everyKeyParsesAndAWrongValueIsRefused() throws {
        for entry in SettingsCatalog.entries {
            let target = Self.sample(entry.scope)
            let example = try TOMLDocument(entry.example).root
            let key = try #require(example.keys.first, "\(entry.id) example")
            let good: TOMLValue = entry.isTable ? .table(example) : try #require(example[key])
            let problem = SettingsCatalog.validate(entry, good, at: target)
            #expect(problem == nil, "\(entry.id): \(entry.example) refused: \(problem?.reason ?? "")")

            // The innermost value swapped for one of another type.
            func wrong(_ value: TOMLValue) -> TOMLValue {
                guard case var .table(table) = value, let first = table.keys.first, let inner = table[first] else {
                    return value.string != nil ? .integer(7) : .string("not this")
                }
                table[first] = wrong(inner)
                return .table(table)
            }
            let refused = SettingsCatalog.validate(entry, wrong(good), at: target)
            #expect(refused?.entryID == entry.id, "\(entry.id): a wrong value is not refused")
            #expect(refused?.target == target)
            #expect(refused?.reason.isEmpty == false)
            #expect(refused?.example == entry.example)
        }
    }

    @Test func nothingIsModifiedInTheDefaultsOrTheShippedConfig() throws {
        #expect(SettingsCatalog.states(in: .default).allSatisfy { !$0.isModified })
        let (shipped, problems) = ConfigLoader.decode(ConfigLoader.defaultSource)
        #expect(problems.isEmpty)
        let config = try #require(shipped)
        let modified = SettingsCatalog.states(in: config).filter(\.isModified).map { "\($0.entry.id)@\($0.target)" }
        #expect(modified.isEmpty, "the shipped config.toml counts as modified: \(modified)")
    }

    /// A value set away from the default is modified; set back to it, it is not, for each kind of value.
    @Test(arguments: [
        ("ui.menu_bar", SettingTarget.global, "[ui]\nmenu_bar = false", "[ui]\nmenu_bar = true"),
        (
            "notifications.grace_seconds",
            .global,
            "[notifications]\ngrace_seconds = 45",
            "[notifications]\ngrace_seconds = 30"
        ),
        ("llm.daily_dollars", .global, "[llm]\ndaily_dollars = 2.5", "[llm]\ndaily_dollars = 1"),
        (
            "sessions.continue_prompt",
            .global,
            "[sessions]\ncontinue_prompt = \"Go on.\"",
            "[sessions]\ncontinue_prompt = \"Continue where you left off.\""
        ),
        (
            "worktrees.repo_roots",
            .global,
            "[worktrees]\nrepo_roots = [\"~/src\"]",
            "[worktrees]\nrepo_roots = [\"~/Projects\", \"~/code\"]"
        ),
        ("pilot.merge_schedule", .global, "[pilot]\nmerge_schedule = \"4h\"", "[pilot]\nmerge_schedule = \"60m\""),
        ("usage.prices", .global, "[usage.prices]\n\"model-a\" = \"3 / 15\"", "[usage.prices]"),
        ("llm.agent", .global, "[llm]\nagent = \"auto\"", ""),
        (
            "agent.plan",
            .agent("claude"),
            "[agents.claude]\nplan = \"--plan\"",
            "[agents.claude]\nplan = \"--permission-mode plan\""
        ),
        ("override.green", .org("acme"), "[orgs.acme]\ngreen = \"auto\"", "[orgs.acme]\ncolor = \"teal\""),
        ("override.admin_merge", .repo("acme/api"), "[repos.\"acme/api\"]\nadmin_merge = true", "[repos.\"acme/api\"]"),
        ("host.color", .host("devbox"), "[hosts.devbox]\ncolor = \"pink\"", "[hosts.devbox]\nssh = \"devbox\""),
    ])
    func modifiedRoundTrips(id: String, target: SettingTarget, changed: String, back: String) throws {
        let entry = try #require(SettingsCatalog.entry(id))
        let set = try #require(ConfigLoader.decode(changed).config)
        #expect(SettingsCatalog.isModified(entry, at: target, in: set))
        #expect(SettingsCatalog.value(entry, at: target, in: set) != SettingsCatalog.defaultValue(entry, at: target))
        let reset = try #require(ConfigLoader.decode(back).config)
        #expect(!SettingsCatalog.isModified(entry, at: target, in: reset))
    }

    @Test func defaultsReadAsTheyShip() throws {
        #expect(SettingsCatalog.entry("notifications.grace_seconds")?.defaultValue == .integer(30))
        #expect(SettingsCatalog.entry("llm.daily_dollars")?.defaultValue == .number(1))
        #expect(SettingsCatalog.entry("pilot.hold_labels")?.defaultValue == .list(["hold", "do-not-merge", "wip"]))
        #expect(SettingsCatalog.entry("llm.agent")?.defaultValue == nil)
        #expect(SettingsCatalog.entry("agent.resume")?.defaultValue == .text("--resume {id}"))
        #expect(SettingsCatalog.entry("override.watch")?.defaultValue == nil) // inherits
        #expect(SettingsCatalog.entry("host.ssh")?.defaultValue == .text("host"))
        // A custom agent's default is a fresh agent with its own command: the command is not a change.
        let config = try #require(ConfigLoader.decode("[agents.mytool]\ncommand = \"mytool\"").config)
        let command = try #require(SettingsCatalog.entry("agent.command"))
        #expect(!SettingsCatalog.isModified(command, at: .agent("mytool"), in: config))
    }

    @Test func aRefusedValueIsAProblemWithAReasonAndAnExample() throws {
        let source = """
        [notifications]
        grace_seconds = 99999
        [orgs.acme]
        green = "sometimes"
        [pilot]
        admin_merge = true
        """
        let (config, found) = ConfigLoader.decode(source)
        let (matched, unmatched) = SettingsCatalog.problems(found)
        let grace = try #require(matched.first { $0.entryID == "notifications.grace_seconds" })
        #expect(grace.target == .global)
        #expect(grace.reason == "expected a number from 0 to 3600")
        #expect(grace.example == "grace_seconds = 30")
        let green = try #require(matched.first { $0.entryID == "override.green" })
        #expect(green.target == .org("acme"))
        #expect(green.reason == "expected off, ask or auto")
        // admin_merge is per repo only: no global row has it, so it stays for the banner.
        #expect(unmatched.map(\.path) == ["pilot.admin_merge"])

        // The org the refused value names gets a row, though nothing of it was taken.
        let entry = try #require(SettingsCatalog.entry("override.green"))
        let decoded = try #require(config)
        #expect(SettingsCatalog.targets(for: entry, in: decoded, problems: found).contains(.org("acme")))
        #expect(SettingsCatalog.problems(for: entry, at: .org("acme"), in: found).count == 1)

        // Checked before writing: refused against the file it would go into, taken when it fits.
        let attachAsk = try #require(SettingsCatalog.entry("goals.attach_ask"))
        #expect(SettingsCatalog.validate(attachAsk, .float(0.9))?.reason.contains("above attach_auto") == true)
        #expect(SettingsCatalog.validate(attachAsk, .float(0.9), in: "[goals]\nattach_auto = 0.95\n") == nil)
        let syntax = SettingsCatalog.validate(attachAsk, .float(0.4), in: "[goals\n")
        #expect(syntax?.path == "")
    }

    @Test func aRepoNamedWithDotsIsFound() throws {
        let (_, found) = ConfigLoader.decode("[repos.\"acme/site.io\"]\nmerge = \"never\"\n")
        let problem = try #require(SettingsCatalog.problems(found).matched.first)
        #expect(problem.entryID == "override.merge")
        #expect(problem.target == .repo("acme/site.io"))
    }

    @Test func searchFindsByLabelKeyPageAndDetail() {
        func ids(_ query: String) -> [String] { SettingsCatalog.search(query).map(\.id) }
        #expect(ids("persistent panes").first == "sessions.persist")
        #expect(ids("grace_seconds") == ["notifications.grace_seconds"])
        #expect(ids("llm.timeout_seconds") == ["llm.timeout_seconds"])
        #expect(ids("TIMEOUT").prefix(2).contains("llm.timeout_seconds"))
        #expect(ids("hunch").contains("hunch.learn")) // the section and page
        #expect(ids("[orgs.<org>] watch") == ["override.watch"])
        #expect(ids("sha256") == ["hunch.checkpoint"]) // only in its detail
        #expect(ids("quiet hours").first == "attention.quiet")
        #expect(ids("").isEmpty)
        #expect(ids("nothing matches this").isEmpty)
        // A label match comes before a match only in the detail.
        let zmx = ids("zmx")
        #expect(zmx.first == "tools.zmx")
        #expect(zmx.contains("sessions.persist"))
    }

    @Test func countsRollUpFromRowsToTheTree() throws {
        let source = """
        [ui]
        menu_bar = false
        [notifications]
        grace_seconds = 45
        reminder_minutes = 99999
        [orgs.acme]
        green = "auto"
        merge = "heed"
        [repos."acme/api"]
        watch = false
        [agents.claude]
        model = "opus"
        """
        let (decoded, problems) = ConfigLoader.decode(source)
        let counts = try SettingsCatalog.counts(in: #require(decoded), problems: problems)
        #expect(counts.modified(.page(.general)) == 1)
        #expect(counts.modified(.page(.notifications)) == 1)
        #expect(counts.problems(.page(.notifications)) == 1)
        #expect(counts.modified(.section(.notifications, "Sessions")) == 1)
        #expect(counts.modified(.group(.heed)) == 2)
        #expect(counts.problems(.group(.heed)) == 1)
        #expect(counts.modified(.target(.orgsAndRepos, .org("acme"))) == 2)
        #expect(counts.modified(.tab(.orgsAndRepos, .org("acme"), .green)) == 1)
        #expect(counts.modified(.tab(.orgsAndRepos, .org("acme"), .merged)) == 1)
        #expect(counts.modified(.target(.orgsAndRepos, .repo("acme/api"))) == 1)
        #expect(counts.modified(.page(.orgsAndRepos)) == 3)
        #expect(counts.modified(.target(.agents, .agent("claude"))) == 1)
        #expect(counts.modified(.tab(.agents, .agent("claude"), .sessions)) == 1)
        #expect(counts.modified(.group(.github)) == 3)
        #expect(counts.modified(.group(.agents)) == 1)
        #expect(counts.problems(.group(.github)) == 0)
        // Every group is the sum of its pages.
        for group in SettingsGroup.allCases {
            #expect(counts.modified(.group(group)) == group.pages.map { counts.modified(.page($0)) }.reduce(0, +))
        }
    }

    @Test func chosenSettingsRoundTripThroughPreferences() throws {
        let name = "heed.tests.chosen.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(ChosenSettings.load(from: defaults) == ChosenSettings())

        var chosen = ChosenSettings()
        chosen.choose("sessions.persist")
        chosen.choose("ui.menu_bar")
        chosen.save(to: defaults)
        #expect(ChosenSettings.load(from: defaults) == chosen)
        #expect(defaults.data(forKey: ChosenSettings.defaultsKey).map { String(decoding: $0, as: UTF8.self) }
            == #"["sessions.persist","ui.menu_bar"]"#)

        chosen.forget("ui.menu_bar")
        chosen.save(to: defaults)
        #expect(ChosenSettings.load(from: defaults).ids == ["sessions.persist"])

        defaults.set(Data("not json".utf8), forKey: ChosenSettings.defaultsKey)
        #expect(ChosenSettings.load(from: defaults) == ChosenSettings())
    }

    @Test func gapsAreUnsetAndUnchosenHighImpactFirst() throws {
        let all = SettingsCatalog.gaps(in: .default, chosen: ChosenSettings())
        #expect(all.first?.impact == .high)
        #expect(zip(all, all.dropFirst()).allSatisfy { $0.impact >= $1.impact })
        #expect(all.map(\.id).contains("sessions.persist"))

        let chosen = ChosenSettings(["sessions.persist"])
        #expect(!SettingsCatalog.gaps(in: .default, chosen: chosen).map(\.id).contains("sessions.persist"))
        let set = try #require(ConfigLoader.decode("[ui]\nmenu_bar = false").config)
        #expect(!SettingsCatalog.gaps(in: set, chosen: ChosenSettings()).map(\.id).contains("ui.menu_bar"))
    }
}
