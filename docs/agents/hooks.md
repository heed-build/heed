---
description: How agents report their state to Heed, and what Heed passes to each one per run.
---

# Hooks

Agents report what they are doing through hooks: small commands the agent runs at moments like "about to use a tool"
or "finished the turn". Heed's hook is its bundled `heed` helper, which sends one line to the app over a local socket
and exits; it never slows the agent down and never fails a tool call.

Heed passes its hooks **per run**, on the command line that starts the agent in its pane. Nothing in your own agent
configuration is edited.

| Agent | What Heed passes |
|---|---|
| claude | `--settings ~/Library/Application Support/Heed/claude-hooks.json` and `--session-id <id>` |
| codex | `-c hooks.<Event>=[…]` for each event, and `--dangerously-bypass-hook-trust` so they run |
| cursor | Writes `.cursor/hooks.json` into every local worktree a session has, whatever agent it started with, excluded from git through `.git/info/exclude` |
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

If you quit a session's agent and start another one in its pane, the session follows the new one as soon as its first
hook arrives: its screen is then read, and its turns judged, as that agent's. Cursor reports from any session's
worktree; Claude and Codex started by hand get their hooks only from heed's own launch, so
[hand the session to them](../sessions/handoff.md) (`gA`) instead, or start them with Start work or `O`.

A turn can end without its end hook: cursor's `stop` does not always arrive, and codex runs `Interrupt` (not `Stop`)
when you stop a turn, which Heed shows as idle. As a safety net for both, when a cursor or codex session has been
working, its screen has not changed and no hook has come for 20 seconds, Heed takes the turn as over and shows it done
(guessed); the agent's next hook puts it right.
A background run waits 60 seconds before it ends that way, so a long silent build is not cut short.

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

Heed also keeps the newest of these per session (its last 4,000 characters): the [summaries](model-calls.md) of a
session read it. A subagent's last words are never kept as the session's. gemini sends none.

Claude also reports these as asking: its `AskUserQuestion` tool ("3 questions"), and in plan mode its plan, waiting
for your approval ("plan to approve"). A Claude turn that ends with background tasks still running stays **working**
(their results start the next turn); one that ends with a scheduled prompt shows **idle** until it fires. Claude's idle
notification, about a minute after a turn, only turns a working session idle: a done, asking or blocked session keeps
what it said.

## Subagents

claude and codex spawn subagents (claude's `Explore`, `Plan`, `general-purpose` and your own agents; codex's
multi-agent workers) and report when each starts and stops (`SubagentStart`, `SubagentStop`). Heed keeps the ones
running per session, in memory only: the sidebar's agent line adds "· 2 subagents" and the
[inspector](../sessions/inspector.md) lists them with their type and age.

A subagent never decides the session's state on its own:

- Its stop changes nothing. Its last words are its answer to the agent that spawned it, so a question there is not one
  to you, and the session's turn is not over.
- A permission prompt inside a subagent blocks the session, as any prompt does. Only that subagent's next step clears
  it; another subagent's tool calls do not, and none clear a prompt or question of the main thread.
- When the main thread ends its turn while subagents still run (in the background), the session stays **working**,
  with the reason "2 subagents running".

A subagent's tool calls carry its id (claude's `agent_id`), which marks it running even when its start was missed. The
list empties when the agent exits, when a Claude turn ends with nothing left in the background, and for any subagent
not heard from in two hours. opencode runs subagents as child sessions, pi and cursor have none: Heed does not track
them for those agents.

| Agent | Subagents |
|---|---|
| claude | `SubagentStart`, `SubagentStop`, and `agent_id` on hooks inside one |
| codex | `SubagentStart`, `SubagentStop` |
| opencode, pi, cursor | not tracked |

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

## Model and usage

The hooks also tell Heed which model the agent runs and what it has used, for the [inspector](../sessions/inspector.md)
and a background run's record. No hook carries all of it, so the helper reads what each agent writes down, and only
the last 256 KB of it, at the end of a turn:

| Agent | Model | Tokens | Cost | Context | Rate limit reset |
|---|---|---|---|---|---|
| claude | `SessionStart`, then the transcript | the transcript's replies (`message.usage`), each request once | estimated from `[usage.prices]` | the last request's input | the limit message in the transcript |
| codex | every hook's `model` | the rollout's latest `token_count` (`total_token_usage`) | estimated from `[usage.prices]` | `last_token_usage` of `model_context_window` | the rate limit window closest to its limit |
| opencode | each finished reply (`message.updated`) | the same replies' tokens | as opencode reports it | | |
| cursor | every hook's `model` | | | | |

Claude Code writes a reply as several transcript lines that share a request id: each request counts once, and one read
again at the next turn is not counted twice. A turn's last lines may still be on their way when it ends; they count at
the next one. pi and gemini report no usage.

A cost is always an estimate, shown with `≈`: what opencode reports, else the session's tokens at its latest model's
price from `[usage.prices]` in [config.toml](../configuration/reference.md). Heed has no prices built in (they change
more often than Heed does), so with none set only opencode shows a cost. `show_cost = false` leaves it out.

```toml
[usage]
show_cost = true
[usage.prices]
# USD per million tokens, by model name prefix: "input / output", or "input / output / cache read / cache write"
"model-a" = "3 / 15"
```

## Inside a pane

Every pane gets the session's id, the socket's path and its own pane id in its environment (`HEED_SESSION_ID`,
`HEED_SOCKET`, `HEED_PANE_ID`), and `HEED_BIN` points at the helper. Run outside a Heed pane, the hook does nothing.
See [The heed CLI](../reference/cli.md).
