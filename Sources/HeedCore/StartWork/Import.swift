import Foundation

/// Bringing a worktree Heed did not create into a session: `↩` on a Repos row without one. When the agent kept a
/// session there (Claude Code's `~/.claude/projects/<cwd>/<id>.jsonl`), the new session resumes the newest of them.
public enum Import {
    /// An agent session found on disk for a worktree.
    public struct AgentSession: Hashable, Sendable {
        public let agent: String
        public let id: String
        public let modified: Date
        /// The first prompt typed in it, for the session's title.
        public let prompt: String?

        public init(agent: String, id: String, modified: Date, prompt: String?) {
            self.agent = agent
            self.id = id
            self.modified = modified
            self.prompt = prompt
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

    /// The first real user prompt in a Claude Code transcript; only its first 256KB are read.
    static func firstPrompt(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        for line in data.split(separator: 0x0A) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  json["type"] as? String == "user",
                  let message = json["message"] as? [String: Any]
            else { continue }
            let text: String? = if let content = message["content"] as? String {
                content
            } else {
                (message["content"] as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String
            }
            // Skip what Claude Code records as user turns but nobody typed: commands, caveats, tool results.
            guard let prompt = text?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty,
                  !prompt.hasPrefix("<")
            else { continue }
            return prompt
        }
        return nil
    }

    /// The changes that make `worktree` a session: resuming `resume` when given, else starting `agent` fresh (or a
    /// shell when `agent` is nil).
    public static func session(
        for worktree: Worktree, agent: AgentProfile?, resume: AgentSession?, integration: IntegrationFiles?,
        now: Date = Date()
    ) -> [DomainChange] {
        let firstLine = resume?.prompt?.split(separator: "\n").first.map(String.init)
        var session = Session(
            title: firstLine.map { $0.count > 60 ? String($0.prefix(59)) + "…" : $0 } ?? worktree.branch ?? "worktree",
            prompt: resume?.prompt ?? "", repos: [worktree.repo], branch: worktree.branch ?? worktree.head,
            agent: agent?.name ?? "shell", agentSessionID: resume?.id, state: ObservedState(.idle, source: .guessed),
            lastActivity: now, createdAt: now
        )
        session.host = worktree.location.hostName
        session.worktreePaths = [worktree.path]
        var command: ShellCommand?
        if let agent {
            let env = integration.map { AgentIntegration.launchEnvironment(agent: agent, files: $0) } ?? [:]
            let hooks = { (resuming: Bool) in
                integration.map {
                    AgentIntegration.launchArguments(agent: agent, sessionID: session.id, files: $0, resuming: resuming)
                } ?? []
            }
            // Cursor reads hooks from a file in the worktree, which heed writes here only (not on hosts yet), whatever
            // agent starts: cursor started by hand later reports too.
            if worktree.location.isLocal, let heed = integration?.heedBinary {
                try? AgentIntegration.installCursorHooks(worktree: worktree.path, heed: heed)
            }
            if let resume,
               let line = agent.resumeCommand(id: resume.id, extraArguments: hooks(true), environment: env)
            {
                command = line
                session.record("imported · resumed \(agent.name) session", at: now)
            } else {
                command = agent.launchCommand(prompt: "", extraArguments: hooks(false), environment: env)
                session.record("imported · \(agent.name) started fresh", at: now)
            }
        } else {
            session.record("imported · shell only", at: now)
        }
        let pane = PaneSpec(
            role: command == nil ? .shell : .agent, title: agent?.name ?? "zsh", directory: worktree.path,
            command: command, location: worktree.location
        )
        let layout = SessionLayout(tabs: [PaneTab(title: command == nil ? "shell" : "agent", tree: .leaf(pane))])
        return [.sessionUpserted(session), .layoutChanged(session: session.id, layout)]
    }
}
