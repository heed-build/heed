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
| `heed start [--agent <name>] [--dir <path>] [--focus] "<prompt>"` | Starts an agent on the prompt in `path` (here by default): as work in that worktree when Heed knows it, else as a chat in the folder. It starts off screen; `--focus` brings Heed forward on it. A worktree that already has a session is refused with that session's id |
| `heed send <session> "<text>"` | Types the text into the session's agent and presses Return, only while the agent is idle or done and you have not just typed there; otherwise it says why and sends nothing |
| `heed show [--focus] <session>` | Shows the session in Heed's window; `--focus` also brings Heed forward |

Each line on the socket is one JSON object. A request has a `method` (`sessions`, `watch`, `start`, `send`, `show`), an
`id` its reply echoes, and the fields the command takes (`directory`, `agent`, `prompt`, `session`, `text`, `focus`). A
reply has `ok`, and `error`, `session` or `sessions`. After answering `watch`, Heed sends `{"event":"sessions",…}` each
time a session's state, title or group changes.
