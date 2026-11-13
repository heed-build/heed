import Foundation

/// The Repos view's two sides: the repo column (All, then each repo) and the worktree table. `h` and `l` move between
/// them; `j` `k` move within the one that has focus.
public enum ReposFocus: String, Sendable, CaseIterable {
    case repos
    case worktrees
}

/// The repo column is a filter: picking a repo narrows the worktree table to it; All (nil) shows every worktree.
public enum RepoFilter {
    /// The rows of the picked repo, in the order given; every row for All.
    public static func rows(_ rows: [Worktree], repo: Repo?) -> [Worktree] {
        guard let repo else { return rows }
        return rows.filter { $0.repo == repo }
    }

    /// The column's index of `repo`: 0 is All, then the repos in order. A repo no longer listed is All.
    public static func index(of repo: Repo?, in repos: [Repo]) -> Int {
        guard let repo, let index = repos.firstIndex(of: repo) else { return 0 }
        return index + 1
    }

    /// The repo at column index `index`, clamped to the column: 0 (or less) is All.
    public static func repo(at index: Int, in repos: [Repo]) -> Repo? {
        let clamped = min(max(index, 0), repos.count)
        return clamped == 0 ? nil : repos[clamped - 1]
    }

    /// The pick after moving `delta` rows down the column (up when negative), stopping at its ends.
    public static func moved(_ repo: Repo?, by delta: Int, in repos: [Repo]) -> Repo? {
        Self.repo(at: index(of: repo, in: repos) + delta, in: repos)
    }

    /// Where the table's rows split into repos, for All: the index of each repo's first row and the repo.
    public static func groups(_ rows: [Worktree]) -> [(index: Int, repo: Repo)] {
        var groups: [(index: Int, repo: Repo)] = []
        for (index, row) in rows.enumerated() where groups.last?.repo != row.repo {
            groups.append((index, row.repo))
        }
        return groups
    }
}

/// What the repo column and the repo's card say about a repo, from what heed already has: its main checkout's status
/// against origin (as of the last fetch), when you last worked there, the hosts it is also on, and what its setup
/// lacks.
/// Nothing here asks git or GitHub.
public struct RepoSummary: Hashable, Sendable {
    public enum Tone: Hashable, Sendable {
        case plain
        case good
        case warning
        case dim
    }

    public struct Part: Hashable, Sendable {
        public var text: String
        public var tone: Tone

        public init(_ text: String, _ tone: Tone = .plain) {
            self.text = text
            self.tone = tone
        }
    }

    /// The main checkout against origin, short (`main ↓3`, `main ✓`); nil when heed has not read it.
    public var main: Part?
    /// The same at length for the card: `main ↓3 behind origin · clean`.
    public var mainLong: String?
    /// When you last worked there: `today`, `yesterday`, `Fri`, `3 weeks`.
    public var lastWorked: String?
    /// The hosts it is also on, `@devbox`.
    public var hosts: [String]
    /// What setup lacks: `not set up`, `green not set up`, or `merging ⚠` when it has a problem.
    public var setup: Part?
    /// A repo with no GitHub remote.
    public var noRemote: Bool

    public init(
        main: Part? = nil, mainLong: String? = nil, lastWorked: String? = nil, hosts: [String] = [],
        setup: Part? = nil, noRemote: Bool = false
    ) {
        self.main = main
        self.mainLong = mainLong
        self.lastWorked = lastWorked
        self.hosts = hosts
        self.setup = setup
        self.noRemote = noRemote
    }

    /// The column's line, in order: main, when, hosts, setup.
    public var parts: [Part] {
        var parts: [Part] = []
        if noRemote { parts.append(Part("no remote", .dim)) } else if let main { parts.append(main) }
        if let lastWorked { parts.append(Part(lastWorked, .dim)) }
        if !hosts.isEmpty { parts.append(Part("also " + hosts.map { "@\($0)" }.joined(separator: " "), .dim)) }
        if let setup { parts.append(setup) }
        return parts
    }

    public var line: String { parts.map(\.text).joined(separator: " · ") }

    /// The summary of `record`. `main`: its main checkout as last listed (nil before the first scan); `lastWorked`:
    /// `StartWork.lastWorked` for it; `hosts`: the hosts that also have it; `setup`: get it merged and get it green,
    /// for a GitHub repo.
    public static func of(
        _ record: RepoRecord, main: Worktree?, lastWorked: Date?, hosts: [String], setup: RepoSetupStatus?,
        now: Date
    ) -> RepoSummary {
        let branch = main?.branch ?? record.defaultBranch ?? "main"
        var summary = RepoSummary(hosts: hosts, noRemote: record.repo.org == "local")
        if let status = main?.status {
            summary.main = mainPart(branch: branch, status: status)
            summary.mainLong = mainLong(branch: branch, status: status)
        }
        summary.lastWorked = lastWorked.map { when($0, now: now) }
        if let setup, !summary.noRemote { summary.setup = setupPart(setup) }
        return summary
    }

    /// `main ✓` when level with origin and clean; else the arrows, and `*` when dirty.
    static func mainPart(branch: String, status: WorktreeStatus) -> Part {
        guard status.upstream != nil else { return Part("\(branch) · no upstream", .dim) }
        var text = branch
        if status.ahead > 0 { text += " ↑\(status.ahead)" }
        if status.behind > 0 { text += " ↓\(status.behind)" }
        if status.isDirty { text += " *" }
        if text == branch { return Part("\(branch) ✓", .dim) }
        return Part(text, status.isDirty || status.ahead > 0 ? .warning : .plain)
    }

    /// `main ↓3 behind origin · clean`, `main up to date with origin · 2 files changed`.
    static func mainLong(branch: String, status: WorktreeStatus) -> String {
        guard let upstream = status.upstream else { return "\(branch) has no upstream" }
        let origin = upstream.split(separator: "/").first.map(String.init) ?? "origin"
        var against: [String] = []
        if status.ahead > 0 { against.append("↑\(status.ahead) ahead of") }
        if status.behind > 0 { against.append("↓\(status.behind) behind") }
        let level = against.isEmpty ? "\(branch) up to date with \(origin)"
            : "\(branch) " + against.joined(separator: ", ") + " \(origin)"
        let files = status.changedFiles + status.untrackedFiles
        return level + " · " + (files == 0 ? "clean" : "\(files) file\(files == 1 ? "" : "s") changed")
    }

    /// A problem first (amber), then whatever is not set up yet (dim); nothing once both are decided.
    static func setupPart(_ setup: RepoSetupStatus) -> Part? {
        let lines = [("merging", setup.merging), ("green", setup.green)]
        if let problem = lines.first(where: { $0.1.state == .warning }) {
            return Part("\(problem.0) ⚠", .warning)
        }
        let missing = lines.filter { $0.1.state == .notSetUp }.map(\.0)
        guard !missing.isEmpty else { return nil }
        return Part(missing.count == 2 ? "not set up" : "\(missing[0]) not set up", .dim)
    }

    /// When, for a day: `today`, `yesterday`, the weekday within a week, then `N weeks`, `N months`.
    public static func when(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day ?? 0
        switch days {
        case ...0: return "today"
        case 1: return "yesterday"
        case 2 ... 6:
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE"
            return formatter.string(from: date)
        case 7 ... 55: return "\(days / 7) week\(days / 7 == 1 ? "" : "s")"
        case 365...:
            let years = days / 365
            return "\(years) year\(years == 1 ? "" : "s")"
        default:
            let months = max(days / 30, 1)
            return "\(months) month\(months == 1 ? "" : "s")"
        }
    }

    /// A worktree's age in the table: `12 m`, `4 h`, `2 d`, `5 w`.
    public static func age(_ date: Date, now: Date) -> String {
        let minutes = max(Int(now.timeIntervalSince(date) / 60), 0)
        if minutes < 60 { return "\(minutes) m" }
        if minutes < 24 * 60 { return "\(minutes / 60) h" }
        let days = minutes / (24 * 60)
        return days < 14 ? "\(days) d" : "\(days / 7) w"
    }
}
