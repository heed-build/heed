import Foundation

/// The fake world's approvals: five requests from four agents, one merged from two, one a screen ask heed can only
/// point at. `approvals` is the main world with those sessions blocked; `approvalAsks` the hook asks waiting.
public extension Fixtures {
    static let approvals: Domain = {
        var domain = main
        let reasons = [
            "s2": "Bash(dotnet publish -c Release)", "s3": "apply_patch(2 files)", "s4": "Bash(git log --oneline -20)",
            "s6": "bash(git push -u origin docs-nav-spike)",
        ]
        for index in domain.sessions.indices {
            guard let reason = reasons[domain.sessions[index].id] else { continue }
            domain.sessions[index].state = ObservedState(.blocked, reason: reason)
            if domain.sessions[index].id == "s6" {
                domain.sessions[index].lastActivity = Clock.now.addingTimeInterval(-5)
            }
        }
        return domain
    }()

    /// The hook asks: codex's patch outside its worktree, claude's read-only log, claude's publish, and the same curl
    /// from two claude sessions.
    static func approvalAsks(now: Date = Clock.now) -> [PermissionAsk] {
        let root = "/Users/you/code/wt"
        let ingest = "\(root)/ingest/ingest-backpressure"
        let markgraph = "\(root)/markgraph/sequence-arrowheads"
        let docs = "\(root)/docs-toolkit/cross-link-validator"
        let curl = "curl -sI https://docs.example.com/redirects/anchors"
        return [
            PermissionAsk(
                id: "ask-codex-patch", session: "s3", pane: "s3-agent", agent: "codex", tool: "apply_patch",
                paths: ["/Users/you/.config/ingest/limits.toml", "docker-compose.yml"],
                patch: "- queue_limit = 512\n+ queue_limit = 2048", why:
                "the burst test needs a bigger queue; the limit lives in the shared config",
                mode: "default", cwd: ingest, askedAt: now.addingTimeInterval(-125)
            ),
            PermissionAsk(
                id: "ask-claude-log", session: "s4", pane: "s4-agent", agent: "claude", tool: "Bash",
                command: "git log --oneline -20 -- src/Layout", why: "See recent changes to the layout code",
                mode: "default", cwd: markgraph, askedAt: now.addingTimeInterval(-40),
                rules: [PermissionRule(toolName: "Bash", ruleContent: "git log:*")]
            ),
            PermissionAsk(
                id: "ask-claude-publish", session: "s2", pane: "s2-agent", agent: "claude", subagent: "general-purpose",
                tool: "Bash", command: "dotnet publish -c Release src/Validator", why: "Build the validator to test it",
                mode: "acceptEdits", cwd: docs, askedAt: now.addingTimeInterval(-30),
                rules: [PermissionRule(toolName: "Bash", ruleContent: "dotnet publish:*")]
            ),
            PermissionAsk(
                id: "ask-claude-curl-1", session: "s2", pane: "s2-agent", agent: "claude", tool: "Bash",
                command: curl, why: "Check where the old anchor redirects", mode: "acceptEdits", cwd: docs,
                askedAt: now.addingTimeInterval(-12)
            ),
            PermissionAsk(
                id: "ask-claude-curl-2", session: "s4", pane: "s4-agent", agent: "claude", tool: "Bash",
                command: curl, why: "Check where the old anchor redirects", mode: "default", cwd: markgraph,
                askedAt: now.addingTimeInterval(-11)
            ),
        ]
    }
}
