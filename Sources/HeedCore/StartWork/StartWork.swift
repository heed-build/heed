import Foundation

/// Settings Start work and the repo scan need. Config (`config.toml`) will fill these; until then, defaults.
public struct WorkSettings: Hashable, Sendable, Codable {
    /// Worktrees go to `<root>/<repo>/<name>`.
    public var worktreeRoot: String
    /// Directories scanned (two levels deep) for repositories.
    public var repoRoots: [String]
    public var agents: [AgentProfile]
    public var defaultAgent: String

    public init(
        worktreeRoot: String = "~/code/wt", repoRoots: [String] = ["~/Projects", "~/code"],
        agents: [AgentProfile] = AgentProfile.builtIn, defaultAgent: String = "claude"
    ) {
        self.worktreeRoot = worktreeRoot
        self.repoRoots = repoRoots
        self.agents = agents
        self.defaultAgent = defaultAgent
    }

    public static let `default` = WorkSettings()

    public func agent(_ name: String) -> AgentProfile? { agents.first { $0.name == name } }

    public func worktreePath(repo: Repo, name: String) -> String {
        "\(Paths.expand(worktreeRoot))/\(repo.name)/\(name)"
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
    public var shellSplit = true
    /// The new session's id, decided up front so hooks and the agent's own session id can use it.
    public var sessionID: String
    /// Where the agents' hook files live; nil launches agents without Heed's hooks (tests).
    public var integration: IntegrationFiles?

    public init(
        prompt: String, repos: [RepoRecord], name: String, base: String? = nil, agent: AgentProfile?,
        sessionID: String = UUID().uuidString, integration: IntegrationFiles? = nil
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
        return agent.launchCommand(prompt: prompt, planFirst: planFirst, extraArguments: extra)
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
    public static func name(for prompt: String, maxWords: Int = 4) -> String {
        let words = prompt.lowercased()
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
        let name = words.prefix(maxWords).joined(separator: "-")
        return name.isEmpty ? "work-\(Int(Date().timeIntervalSince1970) % 100_000)" : String(name.prefix(48))
    }

    // MARK: Guessing repos

    /// Repos ranked for a prompt: named in it (strongest), words in common with the repo name, and where recent
    /// sessions ran. Every guess says why.
    public static func guessRepos(for prompt: String, in repos: [RepoRecord], history: [Session]) -> [RepoGuess] {
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
            return RepoGuess(
                repo: record, confidence: Int((min(score, 0.98) * 100).rounded()),
                reason: reasons.joined(separator: " ")
            )
        }
        return guesses.sorted {
            $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.repo.id < $1.repo.id
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
        let session = Session(
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
        var changes: [DomainChange] = []
        for record in plan.repos {
            let listed = try await Git.worktrees(of: record)
            changes.append(.worktreesListed(repo: record.repo, listed))
        }
        changes.append(.sessionUpserted(session))
        changes.append(.layoutChanged(session: session.id, layout(for: plan, session: session, worktrees: created)))
        return changes
    }

    /// The new session's tabs: the agent (or a shell) in the first repo's worktree, a shell split beside it, and a
    /// shell tab per extra repo of a cross-repo session.
    public static func layout(for plan: StartWorkPlan, session: Session, worktrees: [Worktree]) -> SessionLayout {
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
        let extra = worktrees.dropFirst().map { worktree in
            PaneTab(title: worktree.repo.name, tree: .leaf(PaneSpec(
                role: .shell, title: "zsh \(worktree.repo.name)", directory: worktree.path
            )))
        }
        return SessionLayout(tabs: [main] + extra)
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
