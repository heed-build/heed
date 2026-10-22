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
