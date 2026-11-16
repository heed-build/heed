import Foundation

/// Bringing a worktree Heed did not create into a session: `↩` on a Repos row without one. When an agent kept a
/// session there (Claude Code's `~/.claude/projects/<cwd>/<id>.jsonl`, codex's `~/.codex/sessions/…/rollout-*.jsonl`),
/// the new session resumes the newest of them. `Ia` imports any one of them, wherever it ran.
public enum Import {
    /// An agent session found on disk.
    public struct AgentSession: Hashable, Sendable {
        public let agent: String
        public let id: String
        public let modified: Date
        /// The first prompt typed in it, for the session's title.
        public let prompt: String?
        /// The folder it ran in (the transcript's `cwd`), when the transcript says.
        public let directory: String?

        public init(agent: String, id: String, modified: Date, prompt: String?, directory: String? = nil) {
            self.agent = agent
            self.id = id
            self.modified = modified
            self.prompt = prompt
            self.directory = directory
        }
    }

    /// Claude Code sessions kept for `directory`, newest first.
    public static func claudeSessions(directory: String, home: String = NSHomeDirectory()) -> [AgentSession] {
        let folder = AgentIntegration.claudeProjectFolder(directory)
        let root = URL(fileURLWithPath: "\(home)/.claude/projects/\(folder)")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        return files.filter { $0.pathExtension == "jsonl" }.compactMap { file -> AgentSession? in
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return AgentSession(
                agent: "claude", id: file.deletingPathExtension().lastPathComponent,
                modified: modified ?? .distantPast, prompt: firstPrompt(in: file)
            )
        }
        .sorted { $0.modified > $1.modified }
    }

    /// Every Claude Code session kept on this Mac, whatever folder it ran in, newest first: the top-level transcripts
    /// of each project folder (a subagent's are in a folder of their own), without those in `excluding` (sessions
    /// heed has already) and those nobody typed a prompt in. Only the newest `limit` transcripts are read.
    public static func allClaudeSessions(
        home: String = NSHomeDirectory(), excluding: Set<String> = [], limit: Int = 300
    ) -> [AgentSession] {
        let root = URL(fileURLWithPath: "\(home)/.claude/projects")
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let files = folders.flatMap { folder in
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        }
        .filter { $0.pathExtension == "jsonl" && !excluding.contains($0.deletingPathExtension().lastPathComponent) }
        .compactMap { file -> (URL, Date)? in
            let values = try? file.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { return nil }
            return (file, values?.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.1 > $1.1 }
        return files.prefix(limit).compactMap { file, modified in
            let head = head(of: file)
            guard let prompt = head.prompt else { return nil }
            return AgentSession(
                agent: "claude", id: file.deletingPathExtension().lastPathComponent, modified: modified,
                prompt: prompt, directory: head.cwd
            )
        }
    }

    /// Every agent session kept on this Mac that heed can resume, Claude Code's and codex's, newest first, without
    /// those in `excluding` (the agent session ids heed has already).
    public static func allSessions(
        home: String = NSHomeDirectory(), excluding: Set<String> = [], limit: Int = 300
    ) -> [AgentSession] {
        let found = allClaudeSessions(home: home, excluding: excluding, limit: limit)
            + allCodexSessions(home: home, excluding: excluding, limit: limit)
        return Array(found.sorted { $0.modified > $1.modified }.prefix(limit))
    }

    /// The newest agent session, of any agent, kept for each of `directories`: Claude Code's by its project folder,
    /// codex's by the folder its transcript says it ran in. Codex's are listed once for all of them.
    public static func newestSessions(
        for directories: [String], home: String = NSHomeDirectory()
    ) -> [String: AgentSession] {
        let codex = allCodexSessions(home: home)
        var newest: [String: AgentSession] = [:]
        for directory in directories {
            let candidates = claudeSessions(directory: directory, home: home).prefix(1)
                + codex.filter { $0.directory == directory }.prefix(1)
            newest[directory] = candidates.max { $0.modified < $1.modified }
        }
        return newest
    }

    /// Codex sessions kept on this Mac (`~/.codex/sessions/<yyyy>/<mm>/<dd>/rollout-<time>-<id>.jsonl`; archived ones
    /// are left where you put them), newest first, without those in `excluding` and those nobody typed a prompt in.
    /// heed's own codex calls are `--ephemeral` and leave none. Only the newest `limit` transcripts are read.
    public static func allCodexSessions(
        home: String = NSHomeDirectory(), excluding: Set<String> = [], limit: Int = 300
    ) -> [AgentSession] {
        let root = URL(fileURLWithPath: "\(home)/.codex/sessions")
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        let files = walk.compactMap { $0 as? URL }
            .filter {
                $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-")
                    && !excluding.contains(codexID(fromFileName: $0))
            }
            .compactMap { file -> (URL, Date)? in
                let values = try? file.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true else { return nil }
                return (file, values?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
        return files.prefix(limit).compactMap { file, modified in
            let head = codexHead(of: file)
            guard let prompt = head.prompt else { return nil }
            let id = head.id ?? codexID(fromFileName: file)
            guard !excluding.contains(id) else { return nil }
            return AgentSession(agent: "codex", id: id, modified: modified, prompt: prompt, directory: head.cwd)
        }
    }

    /// The session id at the end of a rollout's name (`rollout-2026-10-16T15-12-54-<uuid>.jsonl`).
    static func codexID(fromFileName file: URL) -> String {
        String(file.deletingPathExtension().lastPathComponent.suffix(36))
    }

    /// What the start of a codex rollout says: the session's id and folder (its `session_meta` line) and the first
    /// prompt typed in it, the first user turn that is not context codex adds itself (`<environment_context>` and
    /// other tags, the `# AGENTS.md` instructions). Only its first 256KB are read.
    static func codexHead(of file: URL) -> (id: String?, prompt: String?, cwd: String?) {
        var id: String?
        var cwd: String?
        for line in headLines(of: file) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = json["payload"] as? [String: Any]
            else { continue }
            if json["type"] as? String == "session_meta" {
                id = id ?? payload["id"] as? String
                cwd = cwd ?? payload["cwd"] as? String
                continue
            }
            guard json["type"] as? String == "response_item", payload["type"] as? String == "message",
                  payload["role"] as? String == "user", let content = payload["content"] as? [[String: Any]]
            else { continue }
            for part in content where part["type"] as? String == "input_text" {
                guard let text = (part["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty, !text.hasPrefix("<"), !text.hasPrefix("# AGENTS.md")
                else { continue }
                return (id, text, cwd)
            }
        }
        return (id, nil, cwd)
    }

    /// The lines of a transcript's first 256KB.
    private static func headLines(of file: URL) -> [Data.SubSequence] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        return ((try? handle.read(upToCount: 256 * 1024)) ?? Data()).split(separator: 0x0A)
    }

    /// The first real user prompt in a Claude Code transcript; only its first 256KB are read.
    static func firstPrompt(in file: URL) -> String? {
        head(of: file).prompt
    }

    /// What the start of a Claude Code transcript says: its first real user prompt and the folder it ran in. Only its
    /// first 256KB are read. The folder comes from the transcript, never from the project folder's name, which loses
    /// every character that is not a letter or digit.
    static func head(of file: URL) -> (prompt: String?, cwd: String?) {
        var cwd: String?
        for line in headLines(of: file) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if cwd == nil, let folder = json["cwd"] as? String, !folder.isEmpty { cwd = folder }
            guard json["type"] as? String == "user", let message = json["message"] as? [String: Any] else { continue }
            let text: String? = if let content = message["content"] as? String {
                content
            } else {
                (message["content"] as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String
            }
            // Skip what Claude Code records as user turns but nobody typed: commands, caveats, tool results.
            guard let prompt = text?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty,
                  !prompt.hasPrefix("<")
            else { continue }
            return (prompt, cwd)
        }
        return (nil, cwd)
    }

    /// The changes that make `worktree` a session: resuming `resume` when given, else starting `agent` fresh (or a
    /// shell when `agent` is nil), told `prompt` when there is one (a session started over the control socket).
    public static func session(
        for worktree: Worktree, agent: AgentProfile?, resume: AgentSession?, integration: IntegrationFiles?,
        prompt: String = "", arguments: [String] = [], now: Date = Date()
    ) -> [DomainChange] {
        let told = resume?.prompt ?? (prompt.isEmpty ? nil : prompt)
        var session = Session(
            title: title(told) ?? worktree.branch ?? "worktree",
            prompt: told ?? "", repos: [worktree.repo], branch: worktree.branch ?? worktree.head,
            agent: agent?.name ?? "shell", agentSessionID: resume?.id, state: ObservedState(.idle, source: .guessed),
            lastActivity: now, createdAt: now
        )
        session.host = worktree.location.hostName
        session.worktreePaths = [worktree.path]
        let command = agentCommand(
            agent: agent, resume: resume, session: &session, integration: integration, prompt: prompt,
            arguments: arguments, now: now
        )
        // Cursor reads hooks from a file in the worktree, which heed writes here only (not on hosts yet), whatever
        // agent starts: cursor started by hand later reports too.
        if agent != nil, worktree.location.isLocal, let heed = integration?.heedBinary {
            try? AgentIntegration.installCursorHooks(worktree: worktree.path, heed: heed)
        }
        let pane = PaneSpec(
            role: command == nil ? .shell : .agent, title: agent?.name ?? "zsh", directory: worktree.path,
            command: command, location: worktree.location
        )
        let layout = SessionLayout(tabs: [PaneTab(title: command == nil ? "shell" : "agent", tree: .leaf(pane))])
        return [.sessionUpserted(session), .layoutChanged(session: session.id, layout)]
    }

    /// The changes that make an agent session that ran in `folder`, outside any git repo, a chat there that resumes
    /// it. heed never writes into a folder you picked, so cursor's hooks file is not put there.
    public static func chatSession(
        folder: String, agent: AgentProfile, resume: AgentSession, integration: IntegrationFiles?, now: Date = Date()
    ) -> [DomainChange] {
        var session = Session(
            title: title(resume.prompt) ?? (folder as NSString).lastPathComponent, prompt: resume.prompt ?? "",
            repos: [], branch: "", agent: agent.name, agentSessionID: resume.id,
            state: ObservedState(.idle, source: .guessed), lastActivity: now, createdAt: now,
            workspace: .chat(ChatFolder(.folder, path: folder))
        )
        let command = agentCommand(
            agent: agent, resume: resume, session: &session, integration: integration, prompt: "", arguments: [],
            now: now
        )
        let pane = PaneSpec(
            role: command == nil ? .shell : .agent, title: agent.name, directory: folder, command: command
        )
        let layout = SessionLayout(tabs: [PaneTab(title: command == nil ? "shell" : "agent", tree: .leaf(pane))])
        return [.sessionUpserted(session), .layoutChanged(session: session.id, layout)]
    }

    /// A session title from a prompt: its first line, at most 60 characters.
    static func title(_ prompt: String?) -> String? {
        prompt?.split(separator: "\n").first.map(String.init).map { $0.count > 60 ? String($0.prefix(59)) + "…" : $0 }
    }

    /// The agent pane's command: resuming `resume` when the agent can, else `agent` started fresh (told `prompt`), or
    /// nil for a shell. Records on `session` which it was.
    private static func agentCommand(
        agent: AgentProfile?, resume: AgentSession?, session: inout Session, integration: IntegrationFiles?,
        prompt: String, arguments: [String], now: Date
    ) -> ShellCommand? {
        guard let agent else {
            session.record("imported · shell only", at: now)
            return nil
        }
        let env = integration.map { AgentIntegration.launchEnvironment(agent: agent, files: $0) } ?? [:]
        let id = session.id
        let hooks = { (resuming: Bool) in
            integration.map {
                AgentIntegration.launchArguments(agent: agent, sessionID: id, files: $0, resuming: resuming)
            } ?? []
        }
        if let resume, let line = agent.resumeCommand(id: resume.id, extraArguments: hooks(true), environment: env) {
            session.record("imported · resumed \(agent.name) session", at: now)
            return line
        }
        session.record(prompt.isEmpty ? "imported · \(agent.name) started fresh" : "started by another app", at: now)
        return agent.launchCommand(prompt: .owner(prompt), extraArguments: hooks(false) + arguments, environment: env)
    }
}
