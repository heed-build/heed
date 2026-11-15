---
description: The heed command line helper.
---

# The heed CLI

`heed` is the small helper bundled inside the app (`Heed.app/Contents/Helpers/heed`). Agents' hooks call it to tell
Heed what they are doing, and every pane has it on its PATH. It sends one line to the app over a local socket and
exits; if the app is not running, the message is appended to `hooks.spool` beside the socket, and Heed takes it in on
its next launch. It never slows an agent down: whatever happens, it gives up after three seconds.

| Command | |
|---|---|
| `heed state <state> [--reason "…"]` | Report a state: working, idle, blocked, asking, done, limited, exited |
| `heed notify "<message>"` | Show a message in the status bar, prefixed with the session |
| `heed pr add <url>` | Track a pull request in this session |
| `heed issue add <url>` | Link an issue to this session |
| `heed title "<title>"` | Rename the session |
| `heed agent-session <agent> <id>` | Record the agent's own session id, for resuming |
| `heed task-exit <code>` | Report a task tab's exit code |
| `heed hook <agent> <event>` | An agent's hook: reads its JSON on stdin |
| `heed tools` | Where `git` and `gh` are found (see [Finding git and gh](../configuration/tools.md)) |
| `heed cleanup runs [path]` | Removes what get it green and get it merged runs left behind (`heed/get-it-green/*`, `heed/get-it-merged/*` branches and their worktrees) in the repo at `path` or here, when nothing would be lost and no run touched it in the last hour |

It reads `HEED_SESSION_ID` and `HEED_SOCKET` from the environment, which every Heed pane sets; run elsewhere, it does
nothing. `heed tools` and `heed cleanup runs` work anywhere.

## The control socket

Other apps on your Mac, an editor or a script, drive Heed through a second socket, `control.sock` beside the hooks
socket (`HEED_CONTROL` overrides where clients look; only your user can open it). The same commands are on the CLI and
work anywhere while Heed runs:

| Command | |
|---|---|
| `heed sessions` | Every session, one per line: id, state (or "needs you"), agent, title, folder |
| `heed watch` | The session list as JSON lines: now, then each time it changes |
| `heed start [--agent <name>] [--dir <path>] [--arg <word>]... [--focus] "<prompt>"` | Starts an agent on the prompt in `path` (here by default): as work in that worktree when Heed knows it, else as a chat in the folder, with each `--arg` added to its command line (an editor's MCP config, say). It starts off screen; `--focus` brings Heed forward on it. A worktree that already has a session is refused with that session's id |
| `heed send <session> "<text>"` | Hands the text to the session's agent: through its [inbox](../agents/messages.md) when it has one, else typed with Return pressed, only while the agent is idle or done and you have not just typed there; otherwise it says why and sends nothing |
| `heed show [--focus] <session>` | Shows the session in Heed's window; `--focus` also brings Heed forward |
| `heed memory show\|search\|note` | What heed's [Mindmap](../insights/mindmap.md#heed-memory) keeps about the work the calling session continues, from its own org's Mindmap only |
| `heed goal <command>` | The goal the calling session is on: read it, record decisions, questions and items, check criteria with evidence, propose scope changes, spawn work. See [Agents keep the goal](../goals/cli.md) |
| `heed swarm send\|note\|answer` | A swarm's agents: messages to a task, the lead or `@all`, progress notes, answers to questions heed handed them (method `goal` too). See [Steering](../goals/swarms/steering.md) |

Each line on the socket is one JSON object. A request has a `method` (`sessions`, `watch`, `start`, `send`, `show`, `goal`), an
`id` its reply echoes, and the fields the command takes (`directory`, `agent`, `prompt`, `arguments`, `session`, `text`, `focus`, `goal`). A
reply has `ok`, and `error`, `session`, `sessions` or `goal` (`send`'s also says how it went, in `delivery`). After answering `watch`, Heed sends `{"event":"sessions",…}` each
time a session's state, title or group changes.

## `heed goal`

`heed goal` keeps the goal the calling session is on. Add `--goal <id>` to name another goal, and `--json` to get JSON.
Item ids are `<goal>/<slug>` or just `<slug>`. [Agents keep the goal](../goals/cli.md) explains each command.

| Command | What it does |
|---|---|
| `list`, `show` | Read: every goal, or the goal's `GOAL.md`, items, quality bars and scores |
| `attach [<goal>]` | Put the session on a goal, or say which goal it is on |
| `item add\|done\|move\|spawn` | Add, finish, move or start work on an item |
| `decision add`, `question add\|answer` | Record a decision, or an open question and its answer |
| `criterion check <n\|text> --evidence <text>` | Check a done-when line off, with evidence |
| `link pr <url>` | Put a PR on the goal, and on an item |
| `source add\|list\|remove` | A GitHub query the goal's items come from |
| `propose <section> <text>` | A change to what the goal is: it waits for you |
| `review request <kind>` | Ask the goal's reviewer of that kind to look again |
| `plan show\|propose\|approve` | A swarm's plan. Only you approve it, in heed (`A` in the plan pane); `approve` from a terminal says so and exits 5 |
| `ask <question>` | A question for the lead, a peer, heed's controller or you, and wait for the answer |

| Exit code | Means |
|---|---|
| 0 | Done, proposed or answered |
| 1 | heed refused: no such goal, item or column, and nothing changed |
| 2 | The command line is wrong, and the usage was printed |
| 3 | heed is not running, or not reachable from here |
| 4 | No goal: the session is on none, and no `--goal` was given |
| 5 | Held for you in heed: the goal is over its spawn cap (in Attention), or a plan waits for your approval in its plan pane |
| 6 | `ask` waited its timeout and no answer came: the question stays open |

## `heed swarm`

`heed swarm` is for the agents of a goal's swarm. [A swarm's lead](../goals/cli.md#a-swarms-lead) and
[Steering](../goals/swarms/steering.md) explain it. It ends with the same exit codes as `heed goal`, 0 to 4.

| Command | What it does |
|---|---|
| `send <to> <text>` | A message to a task, the lead or `@all` |
| `note <text>` | A one-line progress note on what the agent is doing now |
| `answer <question> <text>` | Answer a question heed handed to the agent |
| `ask …` | The same as `heed goal ask` |
| `summary [--outcome <text>] [--decision <text>]… [--follow-up <text>]…` | The lead's end-of-build summary |

## `heed memory`

`heed memory` reads what the [Mindmap](../insights/mindmap.md#heed-memory) keeps about the work. Run it from a
session's shell. It reads that session's own org's Mindmap only.

| Command | What it does |
|---|---|
| `show` | What heed keeps about the work this session continues |
| `search <words>` | Decisions, follow-ups and campaigns that mention all the words |
| `note <decision>` | Keep a decision on this session's campaign |

