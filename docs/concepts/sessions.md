---
description: A session is an agent, its terminals, its worktree and the pull requests around one task.
---

# Sessions

A session is one task: an agent working in a git worktree, the terminals around it, and the pull requests it opens.

![A session: its row in the sidebar, its panes, and the inspector with its worktree and pull requests](../images/shots/concepts/session.png)

A session has:

- **A prompt and a title.** What you asked for, kept for History and for starting again.
- **An agent.** claude, codex, cursor, pi, opencode, gemini or your own, with its own session id so it can resume.
- **One worktree per repo.** Usually one repo; a cross-repo session gets a worktree in each, on the same branch.
- **Panes and tabs.** The agent's terminal, and any shells or tasks you open beside it.
- **Tracked pull requests.** Picked up from what the agent opens, or added by URL.
- **A state.** Working, blocked, asking, done… See [Agent states](agent-states.md).

Heed keeps a record of each session (its prompt, timeline and outcome); the agent keeps its own transcript.

Closing a session keeps its worktree; deleting it removes the worktree too. Either way it moves to
[History](../history/index.md), where it can be reopened.
