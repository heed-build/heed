import Foundation
import HeedCore

/// `Ia`: any agent session kept on this Mac (Claude Code's, codex's) becomes a heed session that resumes it, wherever
/// it ran. On a worktree heed knows it is work there; in a repo heed does not know, the repo is added first; anywhere
/// else it is a chat in that folder.
extension AppModel {
    /// Opens the picker on every agent session heed does not have yet whose folder is still there, newest first. The
    /// transcripts are read off the main actor; a fixture lists made-up ones.
    func openAgentImport() {
        let known = Set(sessions.compactMap(\.agentSessionID))
        let roots = settings.pathRoots
        let keys: @Sendable (Import.AgentSession) -> [String] = { session in
            [
                session.prompt ?? "", session.agent,
                session.directory.map { Paths.split($0, roots: roots).relative } ?? "", session.id,
            ]
        }
        guard !isFixture else {
            agentImport = Typeahead(items: Self.fixtureAgentSessions(worktrees: worktrees), fields: keys)
            return
        }
        flash = "looking for agent sessions…"
        Task {
            // A session whose folder is gone (a removed worktree) cannot be resumed where it ran: not listed.
            let found = await Task.detached(priority: .userInitiated) {
                Import.allSessions(excluding: known).filter {
                    $0.directory.map { FileManager.default.fileExists(atPath: $0) } ?? false
                }
            }.value
            flash = found.isEmpty ? "no agent sessions heed does not have already" : nil
            guard !found.isEmpty else { return }
            agentImport = Typeahead(items: found, fields: keys)
        }
    }

    func cancelAgentImport() { agentImport = nil }

    func pickAgentImport(_ agentSession: Import.AgentSession) {
        agentImport = nil
        importAgentSession(agentSession)
    }

    /// Imports `agentSession` where it ran, after a confirmation that says where; a worktree that has a session already
    /// shows that session instead.
    func importAgentSession(_ agentSession: Import.AgentSession) {
        guard let agent = settings.agent(agentSession.agent) else {
            return flash = "no \(agentSession.agent) agent in config"
        }
        guard let directory = agentSession.directory else {
            return flash = "the transcript does not say which folder it ran in"
        }
        guard !isFixture else { return flash = "fixture: no IO" }
        let path = Self.canonical(directory)
        Task {
            let exists = await Task.detached {
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }.value
            guard exists else { return flash = "folder gone: \(Paths.abbreviate(path))" }
            let worktree: Worktree?
            if let known = worktrees.first(where: { $0.location.isLocal && Self.canonical($0.path) == path }) {
                worktree = known
            } else if await Git.locate(path) != nil {
                guard let (found, listed) = await adoptRepo(at: path) else { return }
                worktree = listed.first { $0.path == found.path } ?? found
            } else {
                worktree = nil
            }
            if let worktree, let existing = session(for: worktree) {
                view = .sessions
                select(sessionID: existing.id)
                return flash = "\(existing.title) already works in \(Paths.abbreviate(worktree.path))"
            }
            let age = agentSession.modified.formatted(.relative(presentation: .named))
            let prompt = agentSession.prompt.map { " · “\($0.prefix(50))”" } ?? ""
            let place = worktree.map { "in \($0.repo.name)/\($0.branch ?? $0.head)" }
                ?? "as a chat in \(Paths.abbreviate(path))"
            ask(Confirmation(
                title: "Import this \(agent.name) session?",
                lines: ["resumes the \(agent.name) session from \(age)\(prompt)", place],
                accept: "Import",
                destructive: false
            ) { [weak self] in
                guard let self else { return }
                let changes = if let worktree {
                    Import.session(for: worktree, agent: agent, resume: agentSession, integration: integration)
                } else {
                    Import.chatSession(folder: path, agent: agent, resume: agentSession, integration: integration)
                }
                commitImported([changes])
                flash = "imported the \(agent.name) session \(place)"
            })
        }
    }

    /// Made-up sessions for a fixture: two on its worktrees (claude, codex), one in a folder with no repo.
    static func fixtureAgentSessions(worktrees: [Worktree]) -> [Import.AgentSession] {
        let now = Clock.now
        let made = [
            ("claude", "Fix the flaky retry test in the sync adapter"),
            ("codex", "Why does the sidebar jump when a PR lands?"),
        ]
        var sessions = zip(worktrees.filter { !$0.isMain }.prefix(2), made).enumerated().map { index, pair in
            Import.AgentSession(
                agent: pair.1.0, id: "fixture-\(index)",
                modified: now.addingTimeInterval(Double(-3600 * (index + 1))), prompt: pair.1.1,
                directory: pair.0.path
            )
        }
        sessions.append(Import.AgentSession(
            agent: "claude", id: "fixture-chat", modified: now.addingTimeInterval(-86400 * 2),
            prompt: "Sort my notes on the Q4 plan into themes", directory: "\(Paths.home)/notes"
        ))
        return sessions
    }
}
