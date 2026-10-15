---
description: How agents report their state to Heed, and what Heed passes to each one per run.
---

# Hooks

Agents report what they are doing through hooks: small commands the agent runs at moments like "about to use a tool"
or "finished the turn". Heed's hook is its bundled `heed` helper, which sends one line to the app over a local socket
and exits; it never slows the agent down and never fails a tool call.

Heed passes its hooks **per run**, on the command line it types into the agent's pane. Nothing in your own agent
configuration is edited.

| Agent | What Heed passes |
|---|---|
| claude | `--settings ~/Library/Application Support/Heed/claude-hooks.json` and `--session-id <id>` |
| codex | `-c hooks.<Event>=[…]` for each event, and `--dangerously-bypass-hook-trust` so they run |
| cursor | Writes `.cursor/hooks.json` into worktrees it creates, excluded from git through `.git/info/exclude` |
| pi | `-e …/heed-pi.js`, an extension that calls the helper |
| opencode | `OPENCODE_CONFIG_CONTENT` with a plugin, `…/heed-opencode.js` |

The command preview at the bottom of [Start work](../start-work/agent-and-options.md) shows exactly what will run.

## What each reports

| State | claude | opencode | codex | pi | cursor |
|---|---|---|---|---|---|
| working | ✓ | ✓ | ✓ | ✓ | ✓ |
| idle | ✓ | ✓ | ✓ | ✓ | |
| blocked | ✓ | ✓ | ✓ | | |
| asking | ✓ | ✓ | ✓ ¹ | ✓ ¹ | ✓ ¹ |
| done | ✓ | ✓ | ✓ | ✓ | ✓ |
| limited | ✓ | ✓ | | | |

¹ Only a question in the turn's last words (below); other questions are read from the screen.

Anything left blank is [read from the screen](screen-reading.md).

## Questions at the end of a turn

An agent that ends its turn with a question in plain text ("Should I also update the docs?") is waiting on you, but its
hooks only say the turn is done. So Heed reads the turn's last words as the turn ends, and when they ask you something
the session shows **asking**, with the reason "asked a question". It is a guess read from text, so it is drawn with a
dotted ring; it still sorts into Needs you, and clears when you answer (the next prompt or tool call).

Only the end counts: code blocks at the very end are skipped, then the last two lines are read. A question mark at the
end, a question to you in those lines, or a phrase that waits on you ("should I", "want me to", "would you like",
"please confirm", "before I proceed") counts. The sign-offs agents end finished turns with ("let me know if you need
anything else", "hope this helps") do not.

| Agent | Where the last words come from |
|---|---|
| claude | `Stop`: `last_assistant_message` |
| codex | `Stop`: `last_assistant_message` |
| cursor | `afterAgentResponse`: `text` (the `stop` after it keeps the question) |
| opencode | the plugin sends the last assistant text with the session's idle |
| pi | the extension sends the last assistant message's text with `agent_settled` |

Claude also reports these as asking: its `AskUserQuestion` tool ("3 questions"), and in plan mode its plan, waiting
for your approval ("plan to approve"). A Claude turn that ends with background tasks still running stays **working**
(their results start the next turn); one that ends with a scheduled prompt shows **idle** until it fires. Claude's idle
notification, about a minute after a turn, only turns a working session idle: a done, asking or blocked session keeps
what it said.

## Pull requests the agent opens

The same hooks tell Heed when the agent opens a pull request, so its session tracks it at once, in whatever repo it is
(see [Tracking PRs](../github/tracking-prs.md)). Heed reads the output of the tool call that ran `gh pr create` (or
`hub pull-request`, or `gh api …/pulls` as a POST), or of a GitHub MCP `create_pull_request`, and takes the PR link
from it. A PR the agent only reads or links to is not taken.

| Agent | Where it comes from |
|---|---|
| claude, codex | `PostToolUse`: the tool's input and response |
| cursor | `afterShellExecution` (command and output), `afterMCPExecution`, `postToolUse` |
| pi | the extension's `tool_result` handler |
| opencode | the plugin's `tool.execute.before` / `tool.execute.after` hooks |

## Inside a pane

Every pane gets the session's id, the socket's path and its own pane id in its environment (`HEED_SESSION_ID`,
`HEED_SOCKET`, `HEED_PANE_ID`), and `HEED_BIN` points at the helper. Run outside a Heed pane, the hook does nothing.
See [The heed CLI](../reference/cli.md).
