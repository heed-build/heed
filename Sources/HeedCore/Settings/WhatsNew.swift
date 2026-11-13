import Foundation

// What's new: the features each version brought, written by hand, and the settings it added, which come from the
// catalog's `since` on their own. After an update heed shows once what is new since the version you last opened
// (NudgePolicy decides when); `:whatsnew.show` shows it any time.

/// A release version, `0.37.0`: major, minor, patch. A build that is not a release (`0.1.0-dev`) has none.
public struct HeedVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// `0.37.0`, `v0.37.0`, `0.37`; nil for a pre-release or dev build (`0.1.0-dev`) and for anything else.
    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2 ... 3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { part in part.allSatisfy(\.isASCII) ? Int(part) : nil }
        guard numbers.count == parts.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        self.init(numbers[0], numbers[1], numbers.count == 3 ? numbers[2] : 0)
    }

    public static func < (lhs: HeedVersion, rhs: HeedVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// `0.37.0`.
    public var description: String { "\(major).\(minor).\(patch)" }

    /// As titles say it: `0.37`, or `0.37.1` for a patch release.
    public var short: String { patch == 0 ? "\(major).\(minor)" : description }
}

/// Where a feature's Show me goes.
public enum WhatsNewTarget: Hashable, Sendable {
    /// A command line, as `:` takes it (`view.standup`, `settings.open history`).
    case command(String)
    /// A Settings catalog entry id: Settings, on its page.
    case setting(String)
}

/// One feature a version brought: a title, one line about it, and where Show me goes.
public struct WhatsNewFeature: Hashable, Sendable {
    public let version: HeedVersion
    public let title: String
    public let line: String
    public let showMe: WhatsNewTarget?

    public init(_ version: String, _ title: String, _ line: String, showMe: WhatsNewTarget? = nil) {
        self.version = HeedVersion(version) ?? HeedVersion(0, 0)
        self.title = title
        self.line = line
        self.showMe = showMe
    }
}

/// What one "New in heed X" shows: the features and new settings after `since`, up to `version`.
public struct WhatsNewContent: Sendable {
    /// The version it is about (the one running).
    public let version: HeedVersion
    /// The version last opened; nil when heed does not know it (an update from before what's new existed): then
    /// only this version's own.
    public let since: HeedVersion?
    /// Newest version first, each version's in the order written.
    public let features: [WhatsNewFeature]
    /// Settings that shipped in that range, newest version first, each version's in catalog order.
    public let settings: [SettingsEntry]

    public var isEmpty: Bool { features.isEmpty && settings.isEmpty }
}

public enum WhatsNew {
    /// Every feature entry, newest version first. Written in the docs' voice: what you can do now, in a line.
    public static let features: [WhatsNewFeature] = [
        // 0.39: Attention catches you up on a thread.
        WhatsNewFeature(
            "0.39.0", "Catch up on a thread",
            "The reader's card says what is new since you last looked, written ahead for New and on open for the "
                + "rest; it always says its state (up to date, stale, failed and why), and U writes it again.",
            showMe: .setting("attention.summaries")
        ),
        // 0.39: the readers render threads as GitHub does.
        WhatsNewFeature(
            "0.39.0", "Threads read like GitHub",
            "The PR and issue readers, and Attention's detail, show the description and every comment as GitHub "
                + "renders them: code, tables, task lists, images. Links open in your browser.",
            showMe: .command("view.attention")
        ),
        WhatsNewFeature(
            "0.39.0", "Attention says what it has",
            "Every unread notification and read ones for 30 days, old mentions folded, done until someone else acts; "
                + "a line at the foot says how much of GitHub's it has, :attention.coverage per source.",
            showMe: .command("attention.coverage")
        ),
        WhatsNewFeature(
            "0.39.0", "Attention, split",
            "Tabs over the list, For you in New since you looked, Waiting on you and Mentioned before, and the thread "
                + "beside it with what you read folded. :inbox is its Everything tab.",
            showMe: .command("view.attention")
        ),
        // 0.37: the Settings redesign, and what merged alongside it.
        WhatsNewFeature(
            "0.37.0", "Settings as a tree",
            "Five groups and 16 pages, each setting on one page, and an amber bar on every row you changed, with ↺ "
                + "to put it back.",
            showMe: .command("settings.open")
        ),
        WhatsNewFeature(
            "0.37.0", "Search every setting",
            "⌘F in Settings, or :settings.find, matches names, descriptions and config keys like grace_seconds, "
                + "and edits the rows where they are found.",
            showMe: .command("settings.find")
        ),
        WhatsNewFeature(
            "0.37.0", "Show advanced and Only modified",
            "Tuning stays out of sight until you ask for it; Only modified keeps what differs from heed's defaults, "
                + "with Reset all.",
            showMe: .command("settings.open")
        ),
        WhatsNewFeature(
            "0.37.0", "Configure…",
            "Pick a profile, then go through the settings that add the most and are still at their default. "
                + "Nothing is written until you apply.",
            showMe: .command("settings.configure")
        ),
        WhatsNewFeature(
            "0.37.0", "What's new, after each update",
            "This, once per update: the features and new settings since the version you last opened. Settings › "
                + "Notifications turns it off.",
            showMe: .setting("nudges.whats_new")
        ),
        WhatsNewFeature(
            "0.37.0", "Start work: a kind row",
            "feat, fix, docs, chore or plan under the prompt sets the branch prefix; one repo per start, and branch "
                + "names from the task's own words.",
            showMe: .command("work.start")
        ),
        WhatsNewFeature(
            "0.37.0", "Editing at the cursor",
            "← → move through what you type in Start work, the : line, filters and pickers; ⌥ by word, ⇧ selects, "
                + "⌘V pastes where the cursor is.",
            showMe: .command("work.start")
        ),
        // 0.36
        WhatsNewFeature(
            "0.36.0", "Standup",
            "Your own questions answered per org on the days you choose, one report per Mindmap. History › Standup.",
            showMe: .command("view.standup")
        ),
        WhatsNewFeature(
            "0.36.0", "The Mindmap places work itself",
            "Nothing waits for y or m any more; a quiet ✓ or ↦ on what heed placed says whether it was right.",
            showMe: .command("view.mindmap")
        ),
        WhatsNewFeature(
            "0.36.0", "Mindmap links",
            "Links between nodes, the wires between columns, and n makes a goal of a campaign.",
            showMe: .command("view.mindmap")
        ),
        WhatsNewFeature(
            "0.36.0", "Chips read as dropdowns",
            "Start work's model and effort, and the goal plan's agent chips, have a raised fill and a ⌄.",
            showMe: .command("work.start")
        ),
    ]

    /// The newest version the features know.
    public static var newest: HeedVersion { features.map(\.version).max() ?? HeedVersion(0, 0) }

    /// What is new after `lastSeen`, up to `current`. With no `lastSeen` (not known): `current`'s minor version
    /// alone (0.37.0 up to 0.37.2). A `current` that is not a release shows the newest features' version.
    public static func items(since lastSeen: String?, upTo current: String) -> WhatsNewContent {
        let version = HeedVersion(current) ?? newest
        let since = lastSeen.flatMap(HeedVersion.init)
        func inRange(_ shipped: HeedVersion) -> Bool {
            guard shipped <= version else { return false }
            if let since { return shipped > since }
            return shipped.major == version.major && shipped.minor == version.minor
        }
        let features = features.enumerated().filter { inRange($0.element.version) }
            .sorted { lhs, rhs in
                lhs.element.version == rhs.element.version
                    ? lhs.offset < rhs.offset : lhs.element.version > rhs.element.version
            }
            .map(\.element)
        var dated: [(offset: Int, version: HeedVersion, entry: SettingsEntry)] = []
        for (offset, entry) in SettingsCatalog.entries.enumerated() {
            if let shipped = HeedVersion(entry.since), inRange(shipped) { dated.append((offset, shipped, entry)) }
        }
        let settings = dated.sorted { lhs, rhs in
            lhs.version == rhs.version ? lhs.offset < rhs.offset : lhs.version > rhs.version
        }
        .map(\.entry)
        return WhatsNewContent(version: version, since: since, features: features, settings: settings)
    }
}
