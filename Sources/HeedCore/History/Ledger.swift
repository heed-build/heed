import Foundation

/// One line of History's ledger: a piece of work (a session in its worktrees, or a chat), kept after its worktree is
/// gone, with what a cheap model wrote about it and the facts heed knows without one.
public struct LedgerEntry: Identifiable, Codable, Hashable, Sendable {
    /// The session's id: one entry per session, whatever its worktrees.
    public var id: String
    public var title: String
    /// `org/name` of each repo, the first one first; empty for a chat.
    public var repos: [String]
    public var host: String?
    public var branch: String
    public var chat: Bool
    public var agent: String
    public var startedAt: Date
    /// When the session ended; nil while it runs.
    public var endedAt: Date?
    /// In words: `active`, `PR open`, `merged`, `closed`, `abandoned`, `cleaned up`, `promoted`.
    public var outcome: String
    public var pulls: [PullRef]
    public var diff: DiffStat?
    /// The files the work changed, most changed first (at most `Ledger.fileLimit`).
    public var files: [String]
    /// The agent's working time, from its reported states; `estimated` when some were read from the screen.
    public var agentTime: TimeInterval?
    public var agentTimeEstimated: Bool
    /// The model, tokens and cost the agent reported for the session.
    public var usage: AgentUsage?

    public var summary: String?
    public var decisions: [String]
    public var followUps: [String]
    public var source: Source?
    /// What made heed write it (`PR opened`, `on demand`), and when.
    public var trigger: String?
    public var summarizedAt: Date?
    /// The last attempt failed: why (no agent logged in, the daily cap). The previous summary stays.
    public var failure: String?

    public enum Source: String, Codable, Hashable, Sendable {
        /// Written by heed's cheap model.
        case model
        /// The agent's own `heed-summary:` sign-off; the model only filled in the rest.
        case signOff = "sign-off"
        /// Edited by you.
        case edited
    }

    public init(
        id: String, title: String, repos: [String] = [], host: String? = nil, branch: String = "", chat: Bool = false,
        agent: String = "", startedAt: Date, endedAt: Date? = nil, outcome: String = "active", pulls: [PullRef] = [],
        diff: DiffStat? = nil, files: [String] = [], agentTime: TimeInterval? = nil, agentTimeEstimated: Bool = false,
        usage: AgentUsage? = nil, summary: String? = nil, decisions: [String] = [], followUps: [String] = [],
        source: Source? = nil, trigger: String? = nil, summarizedAt: Date? = nil, failure: String? = nil
    ) {
        self.id = id
        self.title = title
        self.repos = repos
        self.host = host
        self.branch = branch
        self.chat = chat
        self.agent = agent
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.pulls = pulls
        self.diff = diff
        self.files = files
        self.agentTime = agentTime
        self.agentTimeEstimated = agentTimeEstimated
        self.usage = usage
        self.summary = summary
        self.decisions = decisions
        self.followUps = followUps
        self.source = source
        self.trigger = trigger
        self.summarizedAt = summarizedAt
        self.failure = failure
    }

    /// The repo's name, or `chat`.
    public var place: String {
        let name = repos.first.map { String($0.split(separator: "/").last ?? "") } ?? "chat"
        return host.map { "\(name) @\($0)" } ?? name
    }

    /// The newest of its dates: how the ledger is ordered.
    public var updatedAt: Date { [summarizedAt, endedAt, startedAt].compactMap(\.self).max() ?? startedAt }
}

/// `+212 −38 · 9 files`.
public struct DiffStat: Codable, Hashable, Sendable {
    public var files: Int
    public var added: Int
    public var removed: Int

    public init(files: Int, added: Int, removed: Int) {
        self.files = files
        self.added = added
        self.removed = removed
    }

    public var text: String { "+\(added) −\(removed) · \(files) file\(files == 1 ? "" : "s")" }

    /// `git diff --shortstat`: ` 3 files changed, 212 insertions(+), 38 deletions(-)`; nil when it says nothing.
    public static func parse(_ shortstat: String) -> DiffStat? {
        func number(before word: String) -> Int {
            guard let range = shortstat.range(of: #"(\d+) \#(word)"#, options: .regularExpression) else { return 0 }
            return Int(shortstat[range].split(separator: " ").first ?? "") ?? 0
        }
        let files = number(before: "files? changed")
        guard files > 0 else { return nil }
        return DiffStat(files: files, added: number(before: "insertions?"), removed: number(before: "deletions?"))
    }
}

/// What makes heed write a ledger summary on its own (`[summary] when`), and on demand.
public enum LedgerTrigger: String, CaseIterable, Codable, Hashable, Sendable {
    case prOpened = "pr_opened"
    case prMerged = "pr_merged"
    /// Before a worktree is removed: the removal waits for it (or `Ledger.removalWait`).
    case worktreeRemoved = "worktree_removed"
    /// No activity for `[summary] idle_hours`.
    case idle
    case chatClosed = "chat_closed"
    /// You asked (`ledger.summarize`); never off.
    case onDemand = "on_demand"

    public var title: String {
        switch self {
        case .prOpened: "PR opened"
        case .prMerged: "PR merged"
        case .worktreeRemoved: "worktree removed"
        case .idle: "idle"
        case .chatClosed: "chat closed"
        case .onDemand: "on demand"
        }
    }

    /// The ones `[summary] when` can name.
    public static let configurable: [LedgerTrigger] = [.prOpened, .prMerged, .worktreeRemoved, .idle, .chatClosed]
}

/// What a ledger entry includes (`[summary] include`): files come from git, the rest from the model.
public enum LedgerPart: String, CaseIterable, Codable, Hashable, Sendable {
    case summary, decisions
    case followUps = "follow_ups"
    case files

    public var title: String {
        switch self {
        case .summary: "Summary"
        case .decisions: "Decisions"
        case .followUps: "Follow-ups"
        case .files: "Files"
        }
    }
}

/// `[summary]`'s ledger keys.
public struct LedgerSettings: Equatable, Sendable {
    public var when: Set<LedgerTrigger> = [.prOpened, .prMerged, .worktreeRemoved, .idle]
    public var idleHours = 24
    public var include: Set<LedgerPart> = Set(LedgerPart.allCases)

    public init() {}

    public func writes(on trigger: LedgerTrigger) -> Bool { trigger == .onDemand || when.contains(trigger) }
}

/// The ledger answer's sections (`SummaryKind.ledger`).
public enum LedgerText {
    /// Splits the model's answer into summary, decisions and follow-ups. Lenient: headings in any case, with or
    /// without bold; text before any heading is the summary; a section that says none is empty.
    public static func parse(_ text: String) -> (summary: String, decisions: [String], followUps: [String]) {
        var summary: [String] = []
        var decisions: [String] = []
        var followUps: [String] = []
        var section = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            let bare = line.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: .whitespaces).lowercased()
            for (index, heading) in ["summary:", "decisions:", "follow-ups:"].enumerated()
                where bare.hasPrefix(heading) || bare.hasPrefix(heading.replacingOccurrences(of: "-", with: ""))
            {
                section = index
                let rest = bare.hasPrefix(heading) ? heading.count : heading.count - 1
                line = String(line.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "")
                    .trimmingCharacters(in: .whitespaces).dropFirst(rest)).trimmingCharacters(in: .whitespaces)
            }
            guard !line.isEmpty else { continue }
            switch section {
            case 0: summary.append(line)
            default:
                let item = line.hasPrefix("- ") || line.hasPrefix("• ") || line.hasPrefix("* ")
                    ? String(line.dropFirst(2)) : line
                guard !["none", "none.", "n/a"].contains(item.lowercased()) else { continue }
                if section == 1 { decisions.append(item) } else { followUps.append(item) }
            }
        }
        return (summary.joined(separator: " "), decisions, followUps)
    }
}

public enum Ledger {
    /// How long a removal waits for its summary before going ahead.
    public static let removalWait: Duration = .seconds(30)
    public static let fileLimit = 12

    /// The facts heed knows of a session without a model: where, when, how it ended, its PRs and what its agent used.
    /// `previous` keeps what was written before (summary, decisions, diff, files, agent time).
    public static func facts(
        session: Session, closed: HistoryEntry?, pulls: GitHubState, previous: LedgerEntry?
    ) -> LedgerEntry {
        var entry = previous ?? LedgerEntry(id: session.id, title: session.title, startedAt: session.createdAt)
        entry.title = session.title
        entry.repos = session.repos.map(\.slug)
        entry.host = session.host
        entry.branch = session.branch
        entry.chat = session.isChat
        entry.agent = session.agent
        entry.startedAt = session.createdAt
        entry.endedAt = closed?.closedAt
        entry.pulls = session.trackedPRs
        entry.usage = session.usage ?? entry.usage
        entry.outcome = outcome(session: session, closed: closed, pulls: pulls)
        return entry
    }

    /// `merged`, `PR open`, `parked`, `active`, or how it closed.
    static func outcome(session: Session, closed: HistoryEntry?, pulls: GitHubState) -> String {
        if let closed { return closed.outcome.rawValue }
        let states = session.trackedPRs.compactMap { pulls.pull($0)?.state }
        if !states.isEmpty, states.allSatisfy({ $0 == .merged }) { return "merged" }
        if states.contains(.open) { return "PR open" }
        return session.parked ? "parked" : "active"
    }

    /// What the model reads for `session`.
    public static func inputs(session: Session, git: String?, pulls: [PullDetail]) -> SummaryInputs {
        let pull = pulls.map { detail in
            var lines = ["#\(detail.ref.number) \(detail.title) (\(detail.state?.lowercased() ?? "open"))"]
            if !detail.body.isEmpty { lines.append(detail.body) }
            lines += detail.reviews.compactMap { review in
                review.state.isEmpty ? nil : "\(review.author): \(review.state.lowercased())"
            }
            lines += detail.threads.prefix(10)
                .map { "- \($0.author) on \($0.path)\($0.isResolved ? " (resolved)" : ""): \($0.body)" }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
        return SummaryInputs(
            title: session.title, repo: session.repos.first?.slug, branch: session.isChat ? nil : session.branch,
            git: git, pullRequest: pull.isEmpty ? nil : pull,
            timeline: session.timeline.map { "\($0.at.formatted(.iso8601)) \($0.text)" },
            lastMessage: session.lastMessage
        )
    }

    /// The model's part, written into `entry`: the summary and what `include` asks for. A failure keeps what was
    /// there and says why.
    public static func write(
        _ entry: LedgerEntry, inputs: SummaryInputs, include: Set<LedgerPart>, trigger: LedgerTrigger,
        summarizer: Summarizer, instructions: String, now: Date
    ) async -> LedgerEntry {
        var entry = entry
        var extra = instructions
        let left = [LedgerPart.decisions, .followUps].filter { !include.contains($0) }
        if !left.isEmpty {
            extra += (extra.isEmpty ? "" : "\n") + "Leave these sections out: "
                + left.map { $0.title }.joined(separator: ", ") + "."
        }
        do {
            let text = try await summarizer.summarize(
                kind: .ledger, inputs: inputs, instructions: extra, caller: "ledger.\(trigger.rawValue)"
            )
            let parsed = LedgerText.parse(text)
            entry.summary = parsed.summary.isEmpty ? text : parsed.summary
            entry.decisions = include.contains(.decisions) ? parsed.decisions : []
            entry.followUps = include.contains(.followUps) ? parsed.followUps : []
            entry.source = .model
            entry.trigger = trigger.title
            entry.summarizedAt = now
            entry.failure = nil
        } catch {
            entry.failure = "\(error)"
        }
        return entry
    }

    /// Sessions a domain change asks a summary of: a PR newly tracked (opened), a tracked PR newly merged, a chat
    /// closed. Worktree removal and idle are asked for where they happen.
    public static func triggers(before: Domain, after: Domain, settings: LedgerSettings) -> [(String, LedgerTrigger)] {
        var found: [(String, LedgerTrigger)] = []
        let old = Dictionary(before.sessions.map { ($0.id, $0) }) { first, _ in first }
        if settings.when.contains(.prOpened) {
            for session in after.sessions {
                guard let was = old[session.id] else { continue }
                if session.trackedPRs.contains(where: { !was.trackedPRs.contains($0) }) {
                    found.append((session.id, .prOpened))
                }
            }
        }
        if settings.when.contains(.prMerged) {
            let merged = { (domain: Domain, ref: PullRef) in
                domain.github.pull(ref)?.state == .merged || domain.pullDetails[ref.description]?.state == "MERGED"
            }
            for session in after.sessions + after.history.map(\.session)
                where session.trackedPRs.contains(where: { merged(after, $0) && !merged(before, $0) })
            {
                found.append((session.id, .prMerged))
            }
        }
        if settings.when.contains(.chatClosed) {
            for entry in after.history where entry.session.isChat && old[entry.id] != nil {
                found.append((entry.id, .chatClosed))
            }
        }
        var seen: Set<String> = []
        return found.filter { seen.insert($0.0).inserted }
    }

    /// Sessions idle for `settings.idleHours` that have no summary since their last activity.
    public static func idle(
        sessions: [Session], entries: [String: LedgerEntry], settings: LedgerSettings, now: Date
    ) -> [String] {
        guard settings.when.contains(.idle), settings.idleHours > 0 else { return [] }
        let limit = TimeInterval(settings.idleHours) * 3600
        return sessions.filter { session in
            guard now.timeIntervalSince(session.lastActivity) >= limit else { return false }
            guard let written = entries[session.id]?.summarizedAt else { return true }
            return written < session.lastActivity
        }.map(\.id)
    }

    /// Runs `summarize`, then `remove` once it finished or `timeout` passed, whichever is first: a removal never
    /// waits on a model for long, and never starts before the summary had its chance.
    public static func summarizeThenRemove(
        timeout: Duration = removalWait,
        summarize: @escaping @Sendable () async -> Void,
        remove: @Sendable () async -> Void
    ) async {
        // The summary goes on in the background past the timeout; its entry is written whenever it lands.
        let (done, signal) = AsyncStream<Void>.makeStream()
        Task {
            await summarize()
            signal.yield()
        }
        Task {
            try? await Task.sleep(for: timeout)
            signal.yield()
        }
        for await _ in done {
            break
        }
        signal.finish()
        await remove()
    }
}

/// What git says about a piece of work, for the ledger: its commits, its diff against the base, the files it touched.
public struct LedgerGit: Equatable, Sendable {
    /// `git log --oneline`, newest first.
    public var log: String
    public var diff: DiffStat?
    /// Most changed first.
    public var files: [String]

    /// The text the model reads.
    public var text: String {
        [
            log.isEmpty ? nil : "Commits:\n\(log)",
            diff.map { "Diff: \($0.text)" },
            files.isEmpty ? nil : "Files:\n" + files.joined(separator: "\n"),
        ]
        .compactMap(\.self).joined(separator: "\n\n")
    }

    /// Reads `tip` (a worktree's HEAD, a branch, or an archive ref) against `origin/<base>` (or `base`) in the repo at
    /// `path`, where it lives. Nil when git cannot tell (the branch and its archive are gone).
    public static func read(
        path: String, tip: String, base: String, on location: Location = .local
    ) async -> LedgerGit? {
        func git(_ arguments: [String]) async -> String? {
            try? await ProcessRunner.output(
                on: location, "git", ["-C", path] + arguments, timeout: .seconds(15), caller: "ledger.git"
            )
        }
        guard await git(["rev-parse", "--verify", "--quiet", tip + "^{commit}"]) != nil else { return nil }
        let remote = "origin/\(base)"
        let from = await git(["rev-parse", "--verify", "--quiet", remote]) != nil ? remote : base
        let range = "\(from)...\(tip)"
        let log = await git(["log", "--oneline", "--no-decorate", "-n", "50", "\(from)..\(tip)"]) ?? ""
        let short = await git(["diff", "--shortstat", range]) ?? ""
        let numstat = await git(["diff", "--numstat", range]) ?? ""
        return LedgerGit(
            log: log.trimmingCharacters(in: .whitespacesAndNewlines), diff: DiffStat.parse(short),
            files: files(numstat)
        )
    }

    /// `git diff --numstat` lines, most changed first (binary files last), at most `Ledger.fileLimit`.
    static func files(_ numstat: String) -> [String] {
        numstat.split(separator: "\n").compactMap { line -> (String, Int)? in
            let fields = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard fields.count == 3 else { return nil }
            return (fields[2], (Int(fields[0]) ?? 0) + (Int(fields[1]) ?? 0))
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        .prefix(Ledger.fileLimit).map(\.0)
    }
}
