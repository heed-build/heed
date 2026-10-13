import Foundation

/// Settings Start work and the repo scan need. Config (`config.toml`) will fill these; until then, defaults.
public struct WorkSettings: Hashable, Sendable, Codable {
    /// Worktrees go to `<root>/<repo>/<name>`.
    public var worktreeRoot: String
    /// Directories scanned (two levels deep) for repositories.
    public var repoRoots: [String]
    /// Repos added by path from outside the roots (importing a worktree from elsewhere), kept across scans.
    public var repoPaths: [String] = []
    public var agents: [AgentProfile]
    public var defaultAgent: String
    /// Branch prefixes picked from the prompt's first word (`[worktrees.prefixes]`).
    public var prefixes: BranchPrefixes = .default
    /// Pinned tasks per repo slug (`[repos."org/name".tasks]`), opened as tabs in new sessions.
    public var tasks: [String: [TaskSpec]] = [:]
    /// On launch: ask which sessions to resume, resume them all, or none.
    public var resumeOnLaunch: ResumePolicy
    /// Typed into a resumed session that was mid-turn, once the agent is idle again. Empty turns it off.
    public var continuePrompt: String
    /// New sessions open a shell split beside the agent (`[sessions] shell_split`); off means one pane.
    public var shellSplit = false

    public init(
        worktreeRoot: String = "~/code/wt", repoRoots: [String] = ["~/Projects", "~/code"],
        agents: [AgentProfile] = AgentProfile.builtIn, defaultAgent: String = "claude",
        resumeOnLaunch: ResumePolicy = .ask, continuePrompt: String = "Continue where you left off."
    ) {
        self.resumeOnLaunch = resumeOnLaunch
        self.continuePrompt = continuePrompt
        self.worktreeRoot = worktreeRoot
        self.repoRoots = repoRoots
        self.agents = agents
        self.defaultAgent = defaultAgent
    }

    public static let `default` = WorkSettings()

    public func agent(_ name: String) -> AgentProfile? { agents.first { $0.name == name } }

    /// `<root>/<repo>/<branch with / as ->`: `fix/broken-anchors` lives in `fix-broken-anchors`.
    public func worktreePath(repo: Repo, name: String) -> String {
        "\(Paths.expand(worktreeRoot))/\(repo.name)/\(name.replacingOccurrences(of: "/", with: "-"))"
    }
}

/// Branch prefixes: a prompt starting with one of a prefix's words gets that prefix (`fix/…`), else `defaultPrefix`.
public struct BranchPrefixes: Hashable, Sendable, Codable {
    /// Prefix → the first words that pick it, in order.
    public var prefixes: [String: [String]]
    /// Used when no word matches; empty means no prefix.
    public var defaultPrefix: String

    public init(prefixes: [String: [String]], defaultPrefix: String) {
        self.prefixes = prefixes
        self.defaultPrefix = defaultPrefix
    }

    public static let `default` = BranchPrefixes(
        prefixes: [
            "fix": ["fix", "bug", "broken", "crash", "repair", "resolve"],
            "bump": ["bump", "upgrade", "update"],
            "chore": ["chore", "cleanup", "tidy", "remove", "rename"],
            "refactor": ["refactor", "restructure", "simplify"],
            "docs": ["docs", "doc", "document", "readme"],
            "test": ["test", "tests", "cover"],
            "perf": ["perf", "speed", "optimize", "faster"],
            "feature": ["add", "implement", "support", "create", "introduce", "build", "feature"],
        ],
        defaultPrefix: "feature"
    )

    public func prefix(forWord word: String) -> String? {
        prefixes.keys.sorted().first { prefixes[$0]?.contains(word) == true }
    }
}

/// A repo's pinned task: test, build, docs preview.
public struct TaskSpec: Hashable, Sendable, Codable {
    public var name: String
    public var command: String

    public init(name: String, command: String) {
        self.name = name
        self.command = command
    }
}

public enum Paths {
    public static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    /// `/Users/me/code/x` as `~/code/x`, for display.
    public static func abbreviate(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}

/// A repo Start work suggests for a prompt, with why.
public struct RepoGuess: Hashable, Sendable {
    public let repo: RepoRecord
    /// 0...100.
    public let confidence: Int
    public let reason: String
}

/// Everything Start work will do, decided before anything runs, so the dialog can show it and the user can change it.
public struct StartWorkPlan: Hashable, Sendable {
    public var prompt: String
    public var repos: [RepoRecord]
    public var name: String
    /// Base branch; nil uses each repo's default branch.
    public var base: String?
    /// Nil starts a shell only.
    public var agent: AgentProfile?
    public var autostart = true
    public var planFirst = false
    public var shellSplit = false
    /// The new session's id, decided up front so hooks and the agent's own session id can use it.
    public var sessionID: String
    /// Where the agents' hook files live; nil launches agents without Heed's hooks (tests).
    public var integration: IntegrationFiles?

    public init(
        prompt: String, repos: [RepoRecord], name: String, base: String? = nil, agent: AgentProfile?,
        sessionID: String = UUID().uuidString.lowercased(), integration: IntegrationFiles? = nil
    ) {
        self.sessionID = sessionID
        self.integration = integration
        self.prompt = prompt
        self.repos = repos
        self.name = name
        self.base = base
        self.agent = agent
    }

    public func base(for record: RepoRecord) -> String { base ?? record.defaultBranch ?? "main" }

    /// The line typed into the agent pane's shell, shown verbatim in the dialog.
    public var command: String? {
        guard autostart, let agent else { return nil }
        let extra = integration.map {
            AgentIntegration.launchArguments(agent: agent, sessionID: sessionID, files: $0)
        } ?? []
        let env = integration.map { AgentIntegration.launchEnvironment(agent: agent, files: $0) } ?? [:]
        return agent.launchCommand(prompt: prompt, planFirst: planFirst, extraArguments: extra, environment: env)
    }

    public var title: String {
        let firstLine = prompt.split(separator: "\n").first.map(String.init) ?? prompt
        let sentence = firstLine.split(separator: ".").first.map(String.init) ?? firstLine
        let trimmed = sentence.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 60 ? String(trimmed.prefix(59)) + "…" : trimmed
    }
}

public enum StartWork {
    // MARK: Naming

    private static let stopWords: Set<String> = [
        "a", "an", "the", "in", "on", "to", "of", "for", "and", "or", "should", "be", "must", "is", "are", "with",
        "that", "this", "it", "we", "needs", "need", "make", "so", "still", "can", "into", "from", "by", "as", "at",
        "all", "every", "please", "also", "when", "then", "there", "their", "our", "my", "your", "its", "not",
    ]

    /// A branch-safe worktree name from the prompt's first meaningful words: "Fix broken anchors in redirects.yml"
    /// becomes `fix-broken-anchors-redirects`.
    /// A branch name from the prompt: a prefix picked by its first word (`fix/`, `bump/`, `feature/`, ...), then its
    /// first meaningful words. "Fix broken anchors in redirects.yml" becomes `fix/broken-anchors-redirects`.
    public static func branchName(
        for prompt: String,
        prefixes: BranchPrefixes = .default,
        maxWords: Int = 4
    ) -> String {
        let words = slugWords(prompt)
        guard let first = words.first else { return name(for: prompt, maxWords: maxWords) }
        if let prefix = prefixes.prefix(forWord: first) {
            let rest = words.dropFirst().prefix(maxWords).joined(separator: "-")
            return rest.isEmpty ? "\(prefix)/\(first)" : "\(prefix)/\(String(rest.prefix(48)))"
        }
        return prefixes.defaultPrefix.isEmpty
            ? name(for: prompt, maxWords: maxWords)
            : "\(prefixes.defaultPrefix)/\(name(for: prompt, maxWords: maxWords))"
    }

    public static func name(for prompt: String, maxWords: Int = 4) -> String {
        let words = slugWords(prompt)
        let name = words.prefix(maxWords).joined(separator: "-")
        return name.isEmpty ? "work-\(Int(Date().timeIntervalSince1970) % 100_000)" : String(name.prefix(48))
    }

    static func slugWords(_ prompt: String) -> [String] {
        prompt.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "." })
            .map { word -> String in
                // `redirects.yml` → `redirects`; keep version-like words (`0.17`) whole.
                let parts = word.split(separator: ".")
                if parts.count > 1, parts.last.map({ !$0.allSatisfy(\.isNumber) }) ?? false {
                    return String(parts.dropLast().joined(separator: "-"))
                }
                return String(word).replacingOccurrences(of: ".", with: "-")
            }
            .filter { !$0.isEmpty && !stopWords.contains($0) }
    }

    // MARK: Guessing repos

    /// Repos ranked for a prompt: named in it (strongest), words in common with the repo name, where recent sessions
    /// ran, and how many worktrees each already has (the repos you work in most). Every guess says why.
    public static func guessRepos(
        for prompt: String, in repos: [RepoRecord], history: [Session], worktrees: [String: Int] = [:]
    ) -> [RepoGuess] {
        let busiest = worktrees.values.max() ?? 0
        let text = prompt.lowercased()
        let words = Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let recent = history.sorted { $0.lastActivity > $1.lastActivity }.prefix(5)
        let guesses = repos.map { record -> RepoGuess in
            let name = record.repo.name.lowercased()
            var score = 0.0
            var reasons: [String] = []
            if text.contains(name) {
                score += 0.8
                reasons.append("Prompt names \(record.repo.name).")
            } else {
                let parts = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                let shared = parts.filter { $0.count > 2 && words.contains($0) }
                if !shared.isEmpty {
                    score += 0.35 * Double(shared.count) / Double(max(parts.count, 1))
                    reasons.append("Prompt mentions \(shared.joined(separator: ", ")).")
                }
            }
            let ranHere = recent.count { $0.repos.contains(record.repo) }
            if ranHere > 0 {
                score += 0.15 * Double(ranHere)
                reasons.append("\(ranHere) of your last \(recent.count) sessions ran here.")
            }
            if let count = worktrees[record.id], count > 0, busiest > 0 {
                score += 0.15 * Double(count) / Double(busiest)
                reasons.append("\(count) worktree\(count == 1 ? "" : "s") already.")
            }
            return RepoGuess(
                repo: record, confidence: Int((min(score, 0.98) * 100).rounded()),
                reason: reasons.joined(separator: " ")
            )
        }
        let order = RepoOrder.sorted(repos, counts: worktrees).map(\.id)
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return guesses.sorted {
            $0.confidence != $1.confidence ? $0.confidence > $1.confidence
                : (rank[$0.repo.id] ?? 0) < (rank[$1.repo.id] ?? 0)
        }
    }

    // MARK: Executing

    /// Creates the plan's worktrees (concurrently, off the main actor) and returns the domain changes for the new
    /// session: the worktrees, the session, and its layout with the agent pane typing `plan.command`.
    public static func execute(
        _ plan: StartWorkPlan, settings: WorkSettings, now: Date = Date()
    ) async throws -> [DomainChange] {
        guard !plan.repos.isEmpty else { throw StartWorkError.noRepo }
        let created = try await withThrowingTaskGroup(of: (Int, Worktree).self) { group in
            for (index, record) in plan.repos.enumerated() {
                group.addTask {
                    let path = settings.worktreePath(repo: record.repo, name: plan.name)
                    let worktree = try await Git.addWorktree(
                        record, path: path, branch: plan.name, base: plan.base(for: record)
                    )
                    return (index, worktree)
                }
            }
            var result: [(Int, Worktree)] = []
            for try await item in group {
                result.append(item)
            }
            return result.sorted { $0.0 < $1.0 }.map(\.1)
        }
        if plan.agent?.name == "cursor", let heed = plan.integration?.heedBinary {
            for worktree in created {
                try? AgentIntegration.installCursorHooks(worktree: worktree.path, heed: heed)
            }
        }
        var session = Session(
            id: plan.sessionID, title: plan.title, prompt: plan.prompt, repos: plan.repos.map(\.repo),
            branch: plan.name,
            agent: plan.agent?.name ?? "shell",
            agentSessionID: plan.agent.flatMap { AgentIntegration.preassignedSessionID(
                agent: $0,
                sessionID: plan.sessionID
            ) },
            state: ObservedState(.idle, source: .guessed),
            activity: plan.command == nil ? "shell" : "starting", lastActivity: now
        )
        let built = layout(for: plan, session: session, worktrees: created, tasks: settings.tasks)
        let panes = built.tabs.flatMap(\.tree.panes).count
        session.record("started · \(plan.agent?.name ?? "shell") · \(panes) pane\(panes == 1 ? "" : "s")", at: now)
        var changes: [DomainChange] = []
        for record in plan.repos {
            let listed = try await Git.worktrees(of: record)
            changes.append(.worktreesListed(repo: record.repo, listed))
        }
        changes.append(.sessionUpserted(session))
        changes.append(.layoutChanged(session: session.id, built))
        return changes
    }

    /// The new session's tabs: the agent (or a shell) in the first repo's worktree, a shell split beside it when asked,
    /// and a
    /// shell tab per extra repo of a cross-repo session.
    public static func layout(
        for plan: StartWorkPlan, session: Session, worktrees: [Worktree], tasks: [String: [TaskSpec]] = [:]
    ) -> SessionLayout {
        let primary = worktrees.first?.path ?? NSHomeDirectory()
        let agentPane = PaneSpec(
            role: plan.command == nil ? .shell : .agent, title: plan.agent?.name ?? "zsh",
            directory: primary, command: plan.command
        )
        var main = PaneTab(title: plan.command == nil ? "shell" : "agent", tree: .leaf(agentPane))
        if plan.shellSplit {
            main.split(.horizontal, with: PaneSpec(role: .shell, title: "zsh \(session.branch)", directory: primary))
            main.focused = agentPane.id
        }
        let primaryRepo = worktrees.first?.repo
        let taskTabs = (primaryRepo.flatMap { tasks[$0.slug] } ?? []).map { task in
            PaneTab(title: task.name, tree: .leaf(PaneSpec(
                role: .task, title: task.name, directory: primary,
                command: "\(task.command); \"${HEED_BIN:-true}\" task-exit $?"
            )))
        }
        let extra = worktrees.dropFirst().map { worktree in
            PaneTab(title: worktree.repo.name, tree: .leaf(PaneSpec(
                role: .shell, title: "zsh \(worktree.repo.name)", directory: worktree.path
            )))
        }
        return SessionLayout(tabs: [main] + taskTabs + extra)
    }
}

/// Bringing a closed session back (`R` in History).
public enum Reopen {
    /// Recreates missing worktrees from the session's branch, then returns the changes that restore the session with
    /// an agent pane that resumes it (or starts fresh from the prompt when the agent dropped it).
    public static func execute(
        _ entry: HistoryEntry, domain: Domain, settings: WorkSettings, integration: IntegrationFiles?,
        now: Date = Date()
    ) async throws -> [DomainChange] {
        var session = entry.session
        var paths: [String] = []
        var changes: [DomainChange] = []
        for repo in session.repos {
            guard let record = domain.repo(repo.slug) else { throw ReopenError.unknownRepo(repo.slug) }
            let existing = domain.worktrees.first { $0.repo == repo && $0.branch == session.branch }
            if let existing, FileManager.default.fileExists(atPath: existing.path) {
                paths.append(existing.path)
            } else {
                let path = settings.worktreePath(repo: repo, name: session.branch)
                try await paths.append(Git.restoreWorktree(record, path: path, branch: session.branch).path)
                session.record("worktree recreated from \(session.branch)", at: now)
            }
            try await changes.append(.worktreesListed(repo: repo, Git.worktrees(of: record)))
        }
        // Reopening is explicit, so the only question is whether the agent can still resume its session.
        var command: String?
        if let agent = settings.agent(session.agent) {
            let hooks = { (resuming: Bool) in
                integration.map {
                    AgentIntegration.launchArguments(agent: agent, sessionID: session.id, files: $0, resuming: resuming)
                } ?? []
            }
            let stillThere = session.agentSessionID.map {
                AgentIntegration.hasSession(agent: agent.name, id: $0, directory: paths[0]) != false
            } ?? false
            let env = integration.map { AgentIntegration.launchEnvironment(agent: agent, files: $0) } ?? [:]
            if agent.name == "cursor", let heed = integration?.heedBinary {
                for path in paths {
                    try? AgentIntegration.installCursorHooks(worktree: path, heed: heed)
                }
            }
            if stillThere, let id = session.agentSessionID,
               let resume = agent.resumeCommand(id: id, extraArguments: hooks(true), environment: env)
            {
                command = resume
                session.record("reopened", at: now)
            } else {
                command = agent.launchCommand(prompt: session.prompt, extraArguments: hooks(false), environment: env)
                session.record("reopened · started fresh", at: now)
            }
        } else {
            session.record("reopened · shell only", at: now)
        }
        session.state = ObservedState(.idle, source: .guessed)
        session.parked = false
        session.lastActivity = now
        let agentPane = PaneSpec(
            role: command == nil ? .shell : .agent, title: command == nil ? "zsh" : session.agent, directory: paths[0],
            command: command
        )
        var main = PaneTab(title: command == nil ? "shell" : "agent", tree: .leaf(agentPane))
        if settings.shellSplit {
            main.split(.horizontal, with: PaneSpec(role: .shell, title: "zsh \(session.branch)", directory: paths[0]))
            main.focused = agentPane.id
        }
        changes += [
            .historyRemoved(session.id), .sessionUpserted(session),
            .layoutChanged(session: session.id, SessionLayout(tabs: [main])),
        ]
        return changes
    }
}

public enum ReopenError: Error, CustomStringConvertible {
    case unknownRepo(String)

    public var description: String {
        switch self {
        case let .unknownRepo(slug): "\(slug) is not a known repo any more"
        }
    }
}

public enum StartWorkError: Error, CustomStringConvertible {
    case noRepo

    public var description: String {
        switch self {
        case .noRepo: "pick at least one repo"
        }
    }
}

/// Finds repositories under the configured roots, two levels deep, without descending into them.
public enum RepoScanner {
    public static func scan(roots: [String], depth: Int = 2) async -> [RepoRecord] {
        let paths = await Task.detached(priority: .utility) {
            roots.flatMap { candidates(in: Paths.expand($0), depth: depth) }
        }.value
        return await withTaskGroup(of: RepoRecord?.self) { group in
            for path in Set(paths) {
                group.addTask { await Git.record(at: path) }
            }
            var records: [RepoRecord] = []
            for await record in group {
                if let record { records.append(record) }
            }
            return records.sorted { $0.id < $1.id }
        }
    }

    /// Directories with a `.git` directory (a main checkout; a `.git` file marks a worktree, skipped).
    static func candidates(in root: String, depth: Int) -> [String] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: root + "/.git", isDirectory: &isDirectory) {
            return isDirectory.boolValue ? [root] : []
        }
        guard depth > 0, let children = try? fileManager.contentsOfDirectory(atPath: root) else { return [] }
        return children.filter { !$0.hasPrefix(".") }.flatMap { child -> [String] in
            let path = root + "/" + child
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return []
            }
            return candidates(in: path, depth: depth - 1)
        }
    }
}
