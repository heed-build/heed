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
    /// Setup commands per repo and org (`setup = [...]`), run in each new worktree before its agent.
    public var setup = SetupRules()
    /// Offer to trust a repo for agents (Claude Code, mise) the first time one starts there (`[worktrees]
    /// offer_trust`).
    public var offerTrust = true
    /// On launch: ask which sessions to resume, resume them all, or none.
    public var resumeOnLaunch: ResumePolicy
    /// Typed into a resumed session that was mid-turn, once the agent is idle again. Empty turns it off.
    public var continuePrompt: String
    /// New sessions open a shell split beside the agent (`[sessions] shell_split`); off means one pane.
    public var shellSplit = false
    /// Whether panes outlive heed: `zmx` keeps each pane's terminal in a zmx session that heed reattaches to.
    public var persist: PanePersistence = .auto
    /// Which repos' sessions are asked to sign off with a summary (`[pilot] summary_sign_off`, per org and repo).
    public var signOff = SignOffRule()
    /// What sessions on a goal are told (`GoalPointer`), by session id; empty unless `[goals] tell_agents`. Not
    /// config: the app sets it from the goals it holds.
    public var goalPointers: [String: String] = [:]
    /// heed's plugin folder (`HeedPlugin`), for claude sessions on a goal; nil unless `[goals] tell_agents`. Not
    /// config: the app sets it.
    public var goalPlugin: String?

    /// The launch arguments carrying what `agent` is told: the sign-off when it applies in `repo`, and, when
    /// `session` is on a goal, the goal (`GoalLaunch`). `host`: where the session runs; heed's plugin is on this Mac.
    public func signOffArguments(agent: AgentProfile, repo: Repo?, session: String? = nil, host: String? = nil)
        -> [String]
    {
        GoalLaunch.arguments(
            agent: agent.name, signOff: signOff.applies(to: repo) ? SignOff.instruction : nil,
            pointer: session.flatMap { goalPointers[$0] }, plugin: host == nil ? goalPlugin : nil
        )
    }

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

    /// Where worktrees and repos live: what `Paths.split` takes off before a filter looks at a path.
    public var pathRoots: [String] { [worktreeRoot] + repoRoots }

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

/// A task a worktree can run in a tab of its own: test, build, docs preview. Pinned ones come from config; the others
/// are discovered in the worktree (mise tasks, make targets, package.json scripts).
public struct TaskSpec: Hashable, Sendable, Codable {
    public var name: String
    public var command: String
    /// Where it comes from, shown beside it in the picker.
    public var source: TaskSource
    /// What it does, when its source says (a mise description, a make target's `## comment`).
    public var detail: String?

    public init(name: String, command: String, source: TaskSource = .config, detail: String? = nil) {
        self.name = name
        self.command = command
        self.source = source
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey { case name, command, source, detail }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        source = try container.decodeIfPresent(TaskSource.self, forKey: .source) ?? .config
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
    }

    /// The pane that runs it: its exit code reported to heed, which sets the tab's glyph.
    public func pane(directory: String, location: Location = .local) -> PaneSpec {
        PaneSpec(
            role: .task, title: name, directory: directory,
            command: ShellCommand([.line(command), .reportExit]), location: location
        )
    }
}

/// Where a task comes from.
public enum TaskSource: String, Sendable, Codable, CaseIterable {
    /// `[repos."org/name".tasks]`.
    case config
    case mise
    case make
    case packageJSON = "package.json"
}

public enum Paths {
    public static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    /// `/Users/me/code/x` as `~/code/x`, for display.
    public static func abbreviate(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    /// A path split at the root it lives under: the longest of `roots` that contains it, else the home folder.
    /// `~/code/wt/docs-toolkit/fix-x` under `~/code/wt` is `("~/code/wt/", "docs-toolkit/fix-x")`. Filters match the
    /// relative part only, so a root's own words (`code`, `Projects`) do not match every row.
    /// The home folder `split` measures from: the real one, or the fake world's in screenshots.
    public nonisolated(unsafe) static var home = NSHomeDirectory()

    public static func split(_ path: String, roots: [String], home: String = Paths.home) -> (
        root: String, relative: String
    ) {
        let tilde = { (text: String) in text.hasPrefix("~") ? home + text.dropFirst() : text }
        let full = tilde(path)
        let candidates = (roots.map(tilde) + [home]).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        guard let root = candidates.filter({ !$0.isEmpty && full.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count })
        else { return ("", full.hasPrefix(home + "/") ? "~" + full.dropFirst(home.count) : full) }
        let shown = root == home ? "~" : root.hasPrefix(home + "/") ? "~" + root.dropFirst(home.count) : root
        return (shown + "/", String(full.dropFirst(root.count + 1)))
    }
}

/// A repo Start work suggests for a prompt, with why.
public struct RepoGuess: Hashable, Sendable {
    public let repo: RepoRecord
    /// 0...100.
    public let confidence: Int
    public let reason: String
    /// The prompt names this repo: the strongest signal, which the model's pick never overrides.
    public var named = false
    /// Start work was opened from something in this repo (a session, worktree, PR or issue): kept like a named one.
    public var opened = false
    /// Named or opened from: the model's pick never overrides it.
    public var settled: Bool { named || opened }
    /// The on-device model picked it (`StartWork.merge`).
    public var advised = false
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
    /// A chat: no repos, a folder instead of worktrees.
    public var chat: ChatPlan?
    /// A chat becoming this work (`chat.promote`): its conversation is handed to the new agent.
    public var promotion: Promotion?
    /// The repo's `start_instructions`, for a promotion's handoff prompt.
    public var instructions = ""
    /// The sign-off's launch arguments (`SignOff`), when it applies to the work's repo.
    public var signOff: [String] = []
    /// More words for the agent's command line, from whoever asked for the session (an editor's MCP config).
    public var arguments: [String] = []
    /// The model the agent runs on (its `modelFlag`); nil: the agent's own default.
    public var model: String?

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

    /// Where the work runs: this Mac, or the host its repos (or its chat) are on (a session's repos are all in one
    /// place).
    public var location: Location { chat?.location ?? repos.first?.location ?? .local }

    /// The line typed into the agent pane's shell (in its syntax), shown in sh syntax in the dialog.
    public var command: ShellCommand? {
        guard autostart, let agent else { return nil }
        let env = integration.map { AgentIntegration.launchEnvironment(agent: agent, files: $0) } ?? [:]
        if let promotion, let id = promotion.resuming(with: agent) {
            // Claude continues the chat's own session, told where it is now.
            let hooks = integration.map {
                AgentIntegration.launchArguments(
                    agent: agent, sessionID: sessionID, files: $0, resuming: true, signOff: signOff
                )
            } ?? []
            let told = Handoff.promotionResumed(promotion, task: prompt, branch: name, instructions: instructions)
            return agent.resumeCommand(id: id, extraArguments: hooks, environment: env, prompt: told)
        }
        let extra = (integration.map {
            AgentIntegration.launchArguments(agent: agent, sessionID: sessionID, files: $0, signOff: signOff)
        } ?? []) + arguments
        let text = promotion.map { Handoff.promotion($0, task: prompt, branch: name, instructions: instructions) }
            ?? prompt
        return agent.launchCommand(
            prompt: text, planFirst: planFirst, extraArguments: extra, environment: env, model: model
        )
    }

    public var title: String {
        if chat != nil, prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "chat" }
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
    /// Links and `org/repo#12` references point at an issue or PR, not at where the work happens: they do not count.
    static func referencesRemoved(_ text: String) -> String {
        text.replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[\w.\-/]*#\d+"#, with: " ", options: .regularExpression)
    }

    /// "just now", "2 hours ago": how long before `now` (a date after it counts as now).
    static func ago(_ date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "-_./".contains(character)
    }

    /// When you last worked in each repo, where it is: the latest activity of its sessions, active or closed, keyed by
    /// repo record id.
    public static func lastWorked(sessions: [Session], closed: [HistoryEntry] = []) -> [String: Date] {
        var result: [String: Date] = [:]
        func note(_ session: Session, _ date: Date) {
            for repo in session.repos {
                let id = StartContext.id(repo, session.location)
                if date > result[id] ?? .distantPast { result[id] = date }
            }
        }
        for session in sessions {
            note(session, session.lastActivity)
        }
        for entry in closed {
            note(entry.session, entry.closedAt)
        }
        return result
    }

    /// Ranks every repo for a prompt, strongest first, each with why. The signals, in the order they weigh:
    /// - the prompt names the repo (or shares words with its name);
    /// - where Start work was opened: the repos of the session, worktree, PR or issue under the cursor. Strong, but a
    ///   repo the prompt names still wins;
    /// - how recently you worked there, halving every two days. It weighs little (most of your repos may have been
    ///   touched today) and mostly breaks ties.
    public static func guessRepos(
        for prompt: String, in repos: [RepoRecord], lastWorked: [String: Date] = [:], context: StartContext? = nil,
        now: Date = Clock.now
    ) -> [RepoGuess] {
        let text = referencesRemoved(prompt.lowercased())
        let words = Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        // Whole names only: docs must not match inside docs-toolkit.
        let names = Set(text.split(whereSeparator: { !isNameCharacter($0) }).flatMap { token in
            [String(token), String(token.split(separator: "/").last ?? token)]
        })
        let guesses = repos.map { record -> RepoGuess in
            let name = record.repo.name.lowercased()
            var score = 0.0
            var reasons: [String] = []
            let named = names.contains(name)
            var opened = false
            if named {
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
            if let context, let index = context.repos.firstIndex(of: record.id) {
                // The primary repo of what you were on; the others of a cross-repo session count for less.
                score += index == 0 ? 0.45 : 0.25
                reasons.append("Opened from \(context.label).")
                opened = true
            }
            if let last = lastWorked[record.id] {
                let days = max(now.timeIntervalSince(last), 0) / 86400
                let recency = 0.15 * pow(0.5, days / 2)
                if recency >= 0.01 {
                    score += recency
                    reasons.append("You worked here \(ago(last, now: now)).")
                }
            }
            if let host = record.location.hostName { reasons.append("On @\(host).") }
            return RepoGuess(
                repo: record, confidence: Int((min(score, 0.98) * 100).rounded()),
                reason: reasons.joined(separator: " "), named: named, opened: opened
            )
        }
        let order = RepoOrder.recent(repos, lastWorked: lastWorked).map(\.id)
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
        _ plan: StartWorkPlan, settings: WorkSettings, hosts: [String: HostConfig] = [:], now: Date = Date()
    ) async throws -> [DomainChange] {
        if let chat = plan.chat { return try await executeChat(plan, chat: chat, now: now) }
        guard !plan.repos.isEmpty else { throw StartWorkError.noRepo }
        guard Set(plan.repos.map(\.location)).count == 1 else { throw StartWorkError.mixedHosts }
        let created = try await withThrowingTaskGroup(of: (Int, Worktree).self) { group in
            for (index, record) in plan.repos.enumerated() {
                group.addTask {
                    let path = worktreePath(for: record, name: plan.name, settings: settings, hosts: hosts)
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
        // Files `.worktreeinclude` names come along from each main checkout before anything runs there.
        await withTaskGroup(of: Void.self) { group in
            for (record, worktree) in zip(plan.repos, created) {
                group.addTask { await WorktreeInclude.copy(from: record.path, to: worktree.path, on: record.location) }
            }
        }
        // Whatever agent starts here: cursor started by hand in the pane later reports too.
        if plan.location.isLocal, let heed = plan.integration?.heedBinary {
            for worktree in created {
                try? AgentIntegration.installCursorHooks(worktree: worktree.path, heed: heed)
            }
        }
        var session = Session(
            id: plan.sessionID, title: plan.title, prompt: plan.prompt, repos: plan.repos.map(\.repo),
            branch: plan.name,
            agent: plan.agent?.name ?? "shell",
            agentSessionID: plan.promotion?.resuming(with: plan.agent)
                ?? plan.agent.flatMap { AgentIntegration.preassignedSessionID(agent: $0, sessionID: plan.sessionID) },
            state: ObservedState(.idle, source: .guessed),
            activity: plan.command == nil ? "shell" : "starting", lastActivity: now
        )
        session.host = plan.location.hostName
        session.worktreePaths = created.map(\.path)
        let built = layout(
            for: plan, session: session, worktrees: created, tasks: settings.tasks, setup: settings.setup
        )
        let panes = built.tabs.flatMap(\.tree.panes).count
        session.record("started · \(plan.agent?.name ?? "shell") · \(panes) pane\(panes == 1 ? "" : "s")", at: now)
        if let promotion = plan.promotion {
            session.record(
                "promoted from chat “\(promotion.chatTitle)”"
                    + (promotion.resuming(with: plan.agent) != nil ? " · its conversation resumed" : ""),
                at: now
            )
        }
        var changes: [DomainChange] = []
        for record in plan.repos {
            let listed = try await Git.worktrees(of: record)
            changes.append(.worktreesListed(repo: record.repo, listed))
        }
        changes.append(.sessionUpserted(session))
        changes.append(.layoutChanged(session: session.id, built))
        return changes
    }

    /// Makes the chat's scratch folder (a picked one must be there already) and returns the session and its layout:
    /// the agent in the folder, a shell beside it when asked. No setup, tasks or worktree files: there is no repo.
    static func executeChat(_ plan: StartWorkPlan, chat: ChatPlan, now: Date) async throws -> [DomainChange] {
        let location = chat.location
        let path: String
        switch chat.kind {
        case .scratch:
            guard !chat.name.isEmpty else { throw StartWorkError.noFolder }
            let root = Chats.root(on: location)
            if location.isLocal {
                path = Chats.unique(chat.name, in: root) { FileManager.default.fileExists(atPath: $0) }
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            } else {
                path = chat.path
                _ = try await ProcessRunner.output(on: location, "mkdir", ["-p", path], caller: "chat.scratchFolder")
            }
        case .folder:
            path = chat.path
            guard !chat.name.isEmpty else { throw StartWorkError.noFolder }
            if location.isLocal {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
                else { throw StartWorkError.notAFolder(path) }
            } else {
                _ = try await ProcessRunner.output(on: location, "test", ["-d", path], caller: "chat.folderCheck")
            }
        }
        // Cursor's hooks file goes into a folder heed made, never into one you picked.
        if chat.kind == .scratch, location.isLocal, plan.agent?.name == "cursor",
           let heed = plan.integration?.heedBinary
        {
            try? AgentIntegration.installCursorHooks(worktree: path, heed: heed)
        }
        return chatChanges(plan, chat: chat, path: path, now: now)
    }

    /// The new chat's session and layout, once its folder is there: the agent in it, a shell beside it when asked.
    public static func chatChanges(_ plan: StartWorkPlan, chat: ChatPlan, path: String, now: Date) -> [DomainChange] {
        let location = chat.location
        var session = Session(
            id: plan.sessionID, title: plan.title, prompt: plan.prompt, repos: [], branch: "",
            agent: plan.agent?.name ?? "shell",
            agentSessionID: plan.agent.flatMap {
                AgentIntegration.preassignedSessionID(agent: $0, sessionID: plan.sessionID)
            },
            state: ObservedState(.idle, source: .guessed),
            activity: plan.command == nil ? "shell" : "starting", lastActivity: now,
            workspace: .chat(ChatFolder(chat.kind, path: path))
        )
        session.host = location.hostName
        let agentPane = PaneSpec(
            role: plan.command == nil ? .shell : .agent, title: plan.agent?.name ?? "zsh", directory: path,
            command: plan.command, location: location
        )
        var main = PaneTab(title: plan.command == nil ? "shell" : "agent", tree: .leaf(agentPane))
        if plan.shellSplit {
            main.split(.horizontal, with: PaneSpec(role: .shell, title: "zsh", directory: path, location: location))
            main.focused = agentPane.id
        }
        session.record(
            "started chat · \(plan.agent?.name ?? "shell") · \(chat.kind == .scratch ? "scratch folder" : "in \(Paths.abbreviate(path))")",
            at: now
        )
        return [.sessionUpserted(session), .layoutChanged(session: session.id, SessionLayout(tabs: [main]))]
    }

    /// Where a new worktree goes: under `[worktrees] root` here, under the host's `worktree_root` there (`~` is the
    /// host's home).
    public static func worktreePath(
        for record: RepoRecord, name: String, settings: WorkSettings, hosts: [String: HostConfig]
    ) -> String {
        guard let host = record.location.hostName else { return settings.worktreePath(repo: record.repo, name: name) }
        let root = hosts[host]?.worktreeRoot ?? "~/code/wt"
        return "\(root)/\(record.repo.name)/\(name.replacingOccurrences(of: "/", with: "-"))"
    }

    /// The new session's tabs: the agent (or a shell) in the first repo's worktree, a shell split beside it when asked,
    /// and a shell tab per extra repo of a cross-repo session. Each worktree's approved setup runs first in its pane:
    /// before the agent in the first, on its own in the others.
    public static func layout(
        for plan: StartWorkPlan, session: Session, worktrees: [Worktree], tasks: [String: [TaskSpec]] = [:],
        setup: SetupRules = SetupRules()
    ) -> SessionLayout {
        let primary = worktrees.first?.path ?? NSHomeDirectory()
        // Every pane runs where its worktree is.
        let location = worktrees.first?.location ?? .local
        let agentPane = PaneSpec(
            role: plan.command == nil ? .shell : .agent, title: plan.agent?.name ?? "zsh",
            directory: primary,
            command: WorktreeSetup.paneCommand(
                setup: worktrees.first.flatMap { setup.commands(for: $0.repo) } ?? [], then: plan.command
            ),
            location: location
        )
        var main = PaneTab(title: plan.command == nil ? "shell" : "agent", tree: .leaf(agentPane))
        if plan.shellSplit {
            main.split(.horizontal, with: PaneSpec(
                role: .shell, title: "zsh \(session.branch)", directory: primary, location: location
            ))
            main.focused = agentPane.id
        }
        let primaryRepo = worktrees.first?.repo
        let taskTabs = (primaryRepo.flatMap { tasks[$0.slug] } ?? []).map { task in
            PaneTab(title: task.name, tree: .leaf(task.pane(directory: primary, location: location)))
        }
        let extra = worktrees.dropFirst().map { worktree in
            PaneTab(title: worktree.repo.name, tree: .leaf(PaneSpec(
                role: .shell, title: "zsh \(worktree.repo.name)", directory: worktree.path,
                command: WorktreeSetup.paneCommand(setup: setup.commands(for: worktree.repo) ?? [], then: nil),
                location: worktree.location
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
        hosts: [String: HostConfig] = [:], now: Date = Date()
    ) async throws -> [DomainChange] {
        var session = entry.session
        var paths: [String] = []
        var changes: [DomainChange] = []
        if let chat = session.chat {
            try reopenFolder(chat, session: &session, now: now)
            // Cursor's hooks file goes into a folder heed made, never into one you picked.
            if chat.kind == .scratch { paths = [chat.path] }
        }
        var recreated = false
        // A chat runs where its folder is, a session where its worktrees are: here, or on its host. Its archive refs
        // are in the host's clone too.
        let location = session.location
        for repo in session.repos {
            let id = StartContext.id(repo, location)
            guard let record = domain.repo(id) else { throw ReopenError.unknownRepo(id) }
            let existing = domain.worktrees.first {
                $0.repo == repo && $0.location == location && $0.branch == session.branch
            }
            // A host's listing is what there is; here the directory can have gone since.
            if let existing, !location.isLocal || FileManager.default.fileExists(atPath: existing.path) {
                paths.append(existing.path)
            } else {
                let path = StartWork.worktreePath(for: record, name: session.branch, settings: settings, hosts: hosts)
                let restored = try await Git.restoreWorktree(record, path: path, branch: session.branch)
                paths.append(restored.worktree.path)
                session.record("worktree recreated from \(restored.archive ?? session.branch)", at: now)
                if restored.changes { session.record("uncommitted changes put back from the archive", at: now) }
                if repo == session.repos.first { recreated = true }
            }
            try await changes.append(.worktreesListed(repo: repo, Git.worktrees(of: record)))
        }
        guard let directory = session.chat?.path ?? paths.first else { throw ReopenError.nowhere }
        // Reopening is explicit, so the only question is whether the agent can still resume its session.
        var command: ShellCommand?
        if let agent = settings.agent(session.agent) {
            let signOff = settings.signOffArguments(
                agent: agent, repo: session.repos.first, session: session.id, host: session.host
            )
            let hooks = { (resuming: Bool) in
                integration.map {
                    AgentIntegration.launchArguments(
                        agent: agent, sessionID: session.id, files: $0, resuming: resuming, signOff: signOff
                    )
                } ?? []
            }
            let stillThere = session.agentSessionID.map {
                AgentIntegration.hasSession(agent: agent.name, id: $0, directory: directory) != false
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
        // A worktree made again is a new checkout: it gets the repo's setup first, as a new session's does.
        let setup = recreated ? session.repos.first.flatMap { settings.setup.commands(for: $0) } ?? [] : []
        let agentPane = PaneSpec(
            role: command == nil ? .shell : .agent, title: command == nil ? "zsh" : session.agent,
            directory: directory, command: WorktreeSetup.paneCommand(setup: setup, then: command), location: location
        )
        var main = PaneTab(title: command == nil ? "shell" : "agent", tree: .leaf(agentPane))
        if settings.shellSplit {
            main.split(.horizontal, with: PaneSpec(
                role: .shell, title: session.isChat ? "zsh" : "zsh \(session.branch)", directory: directory,
                location: location
            ))
            main.focused = agentPane.id
        }
        changes += [
            .historyRemoved(session.id), .sessionUpserted(session),
            .layoutChanged(session: session.id, SessionLayout(tabs: [main])),
        ]
        return changes
    }
}

public extension Reopen {
    /// A chat's folder, before its agent starts there again: a scratch folder heed removed (or you did) is made again,
    /// empty; a folder you picked that is gone is not, since heed never makes or removes those. A chat on a host is
    /// left to the host.
    static func reopenFolder(_ chat: ChatFolder, session: inout Session, now: Date) throws {
        guard session.location.isLocal, !FileManager.default.fileExists(atPath: chat.path) else { return }
        guard chat.kind == .scratch else { throw ReopenError.folderGone(chat.path) }
        try FileManager.default.createDirectory(atPath: chat.path, withIntermediateDirectories: true)
        session.record("scratch folder made again, empty", at: now)
    }
}

public enum ReopenError: Error, CustomStringConvertible {
    case unknownRepo(String)
    /// A chat's picked folder is not there any more.
    case folderGone(String)
    /// A session with neither a repo nor a chat folder: nothing to reopen it in.
    case nowhere

    public var description: String {
        switch self {
        case let .unknownRepo(slug): "\(slug) is not a known repo any more"
        case let .folderGone(path): "\(Paths.abbreviate(path)) is not there any more"
        case .nowhere: "it has no repo or folder to reopen in"
        }
    }
}

public enum StartWorkError: Error, Equatable, CustomStringConvertible {
    case noRepo
    /// A session's repos are all in one place: here, or on one host.
    case mixedHosts
    /// A chat with no folder named.
    case noFolder
    /// A chat's picked folder is not a folder.
    case notAFolder(String)

    public var description: String {
        switch self {
        case .noRepo: "pick at least one repo"
        case .mixedHosts: "a session's repos must all be on this Mac or all on the same host"
        case .noFolder: "name the chat's folder first"
        case let .notAFolder(path): "\(Paths.abbreviate(path)) is not a folder"
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

/// Where Start work was opened: the repos of what the cursor was on, a hint of where the work goes.
public struct StartContext: Equatable, Sendable {
    /// Repo record ids (`org/name`, or `org/name@host`), the primary one first.
    public var repos: [String]
    /// What the cursor was on, as the reason names it: a session, a worktree, `docs-toolkit#12`.
    public var label: String

    public init(repos: [String], label: String) {
        self.repos = repos
        self.label = label
    }

    /// The record id of `repo` where it is.
    public static func id(_ repo: Repo, _ location: Location) -> String {
        location.hostName.map { "\(repo.slug)@\($0)" } ?? repo.slug
    }
}
