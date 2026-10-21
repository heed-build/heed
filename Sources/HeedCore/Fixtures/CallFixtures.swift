import Foundation

public extension Fixtures {
    /// The `:log` view's fake world: the main fixture's repos and sessions as a morning of calls would log them. Every
    /// name, path and number is invented.
    static var calls: [LoggedCall] {
        let now = Clock.now
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let root = "/Users/you/code"
        let wt = "/Users/you/code/wt/docs-builder"
        let searchQuery = "is:open is:pr author:@me archived:false"
        func shell(
            _ minutes: Double, _ caller: String, _ command: String, cwd: String? = nil, host: String? = nil,
            took: TimeInterval = 0.04, exit: Int = 0, stdout: String? = nil, stderr: String? = nil
        ) -> LoggedCall {
            LoggedCall(
                at: ago(minutes), kind: .shell, caller: caller, host: host, command: command, cwd: cwd, duration: took,
                exitCode: exit, failed: exit != 0, stdout: stdout, stderr: stderr
            )
        }
        func github(
            _ minutes: Double, _ caller: String, _ operation: String, _ command: String, took: TimeInterval,
            write: Bool = false, items: Int? = nil, hidden: Int? = nil, cost: Int? = nil, remaining: Int? = nil,
            variables: [String: String] = [:]
        ) -> LoggedCall {
            LoggedCall(
                at: ago(minutes), kind: .github, caller: caller, command: command, duration: took, exitCode: 0,
                operation: operation, write: write, items: items, hidden: hidden, rateCost: cost,
                rateRemaining: remaining, detail: variables
            )
        }
        var rows: [LoggedCall] = [
            github(
                0.4, "github.sync", "graphql pullSearch",
                "gh api graphql -f query=@pullSearch -f 'q=\(searchQuery)'", took: 1.84, items: 7, hidden: 0,
                cost: 1, remaining: 4812, variables: ["q": searchQuery]
            ),
            github(
                0.5,
                "github.sync",
                "GET notifications",
                "gh api 'notifications?per_page=50'",
                took: 0.71,
                items: 12
            ),
            shell(1.2, "git.status", "git -C \(wt)/fix-anchors-redirects status --porcelain=v2 --branch", took: 0.06),
            shell(
                1.2, "git.status", "git -C ~/code/ingest status --porcelain=v2 --branch", host: "devbox", took: 0.31
            ),
            LoggedCall(
                at: ago(2), kind: .llm, caller: "summary.ledger", command: "claude -p --model claude-haiku-4-5",
                duration: 6.2, exitCode: 0, operation: "summarize session", agent: "claude", model: "claude-haiku-4-5",
                tokens: TokenCounts(input: 3840, output: 212, cacheRead: 1024), cost: 0.0052, costEstimated: true,
                detail: [
                    "prompt": "Summarize this session for the ledger: git log, the PR, the timeline, its last message.",
                    "response": "Fixed broken anchors in redirects.yml; every target now resolves. PR #2841 is green.",
                ]
            ),
            github(
                3, "heedMerge", "pr merge",
                "gh pr merge 2836 --squash --match-head-commit 9f3c2e1 -R elastic/docs-builder", took: 2.4, write: true
            ),
            shell(
                4, "git.fastForward", "git -C \(root)/docs-builder merge --ff-only '@{u}'", took: 0.42, exit: 128,
                stdout: "Updating 41c9a0e..9f3c2e1\n",
                stderr: "error: Your local changes to the following files would be overwritten by merge:\n"
                    + "\tsrc/Navigation/TableOfContents.cs\nPlease commit your changes or stash them.\n"
            ),
            LoggedCall(
                at: ago(5), kind: .decide, caller: "attention.rank", command: "decide: does this need you?",
                duration: 0.9, exitCode: 0, operation: "needs you?", agent: "codex", model: "gpt-5-mini",
                detail: ["question": "Is the agent asking you something?", "answer": "yes · 0.92"]
            ),
            github(
                6, "pilot.failedLog", "run view --log-failed",
                "gh run view --job 51873310 --log-failed -R elastic/docs-builder", took: 7.9
            ),
            shell(
                7, "hosts.events", "sh -c 'exec tail -c +18322 -F \"$HOME/.heed/events.log\" 2>/dev/null'",
                host: "devbox", took: 0
            ),
            LoggedCall(
                at: ago(9), kind: .llm, caller: "summary.ledger", command: "codex exec --model gpt-5-mini",
                duration: 4.1,
                exitCode: 0, operation: "summarize session", agent: "codex", model: "gpt-5-mini",
                tokens: TokenCounts(input: 2960, output: 180), cost: 0.0019
            ),
            github(
                11, "github.sync", "graphql issueSearch",
                "gh api graphql -f query=@issueSearch -f 'q=is:open is:issue archived:false assignee:@me'", took: 1.2,
                items: 4, hidden: 2, cost: 1, remaining: 4818
            ),
            shell(
                12, "git.addWorktree",
                "git -C \(root)/docs-builder worktree add -b fix/toc-ordering \(wt)/fix-toc-ordering origin/main",
                took: 1.1
            ),
            github(
                14,
                "copilot.ask",
                "pr comment",
                "gh pr comment 412 --body … -R editorconfig/editorconfig",
                took: 1.6,
                write: true
            ),
            shell(
                16, "git.fetch", "git -C \(root)/mermaider fetch origin heed/get-it-green/fix-arrows", took: 12.4,
                exit: 128,
                stderr: "fatal: unable to access 'https://github.com/nullean/mermaider/': Could not resolve host\n"
            ),
            shell(18, "zmx.list", "zmx list --short", took: 0.02),
            shell(19, "tasks.mise", "mise -C \(root)/ingest tasks ls --json", took: 0.38),
        ]
        for index in rows.indices {
            rows[index].id = Int64(rows.count - index)
        }
        return rows
    }
}
