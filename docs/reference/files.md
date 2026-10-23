---
description: Where Heed keeps its configuration, cache and other files.
---

# Files and locations

| Path | |
|---|---|
| `~/.config/heed/config.toml` | Configuration (or under `$XDG_CONFIG_HOME`) |
| `~/Library/Application Support/Heed/domain.json` | Sessions, worktrees and the last GitHub sync, cached for a fast start. `domain.previous.json` is the last launch's copy; a cache that does not read is set aside as `domain.unreadable-<time>.json` |
| `~/Library/Application Support/Heed/heed.sqlite` | The event log (what happened to each session: states, PRs, worktrees, its timeline, its notifications), history (closed sessions), the [ledger](../history/ledger.md) and, when you turn them on, [screen snapshots](../agents/screen-snapshots.md). Kept apart from `domain.json`, so a cache that does not read does not hide history |
| `~/Library/Application Support/Heed/attention.sqlite` | Every [Attention](../github/attention.md) item of the last 30 days, what you did to each (done, snoozed, muted), and the threads and summaries fetched for them |
| `~/Library/Application Support/Heed/log.sqlite` | The call log: commands Heed ran and its GitHub calls, with how long each took and how it ended; never environment variables. Pruned per `[log]` |
| `~/Library/Application Support/Heed/chats` | The scratch folders of [chats](../sessions/chats.md) started without a folder; with cleanup on, the sweep removes a closed chat's 30 days after it closed |
| `~/Library/Application Support/Heed/ghostty-panes.conf` | The few terminal settings Heed sets for its panes |
| `~/Library/Application Support/Heed/heed.sock` | The socket hooks report to |
| `~/Library/Application Support/Heed/hooks.spool` | What hooks reported while Heed was not running; read and emptied on launch |
| `~/Library/Application Support/Heed/claude-hooks.json` | The hook settings passed to claude per run |
| `~/Library/Application Support/Heed/heed-pi.js` | The extension passed to pi |
| `~/Library/Application Support/Heed/heed-opencode.js` | The plugin passed to opencode |
| `~/Library/Caches/Heed/avatars` | Org avatars |
| `~/Library/Caches/Heed/ssh` | The sockets of the shared ssh connections to [hosts](../hosts/index.md) |
| `refs/heed/archive/<branch>` | In a repo: the work of a worktree Heed removed, and its uncommitted changes as `<branch>-wip` (see [Removing](../worktrees/removing.md#saved-first)) |
| `~/.heed` | On a host: the hook, the agents' hook files, zmx's sessions, `events.log` and chats' scratch folders. Heed writes nowhere else there (see [Sessions on a host](../hosts/index.md#sessions-on-a-host)) |
| `<worktree>/.cursor/hooks.json` | cursor's hooks, in worktrees Heed creates; excluded from git |

Deleting the cache is safe: Heed rebuilds it from git and GitHub. Heed keeps no transcripts, only the agent's last
message in each session; agents keep their own.
