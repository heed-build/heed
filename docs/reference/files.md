---
description: Where Heed keeps its configuration, cache and other files.
---

# Files and locations

| Path | |
|---|---|
| `~/.config/heed/config.toml` | Configuration (or under `$XDG_CONFIG_HOME`) |
| `~/Library/Application Support/Heed/domain.json` | Sessions, worktrees and the last GitHub sync, cached for a fast start |
| `~/Library/Application Support/Heed/heed.sock` | The socket hooks report to |
| `~/Library/Application Support/Heed/claude-hooks.json` | The hook settings passed to claude per run |
| `~/Library/Application Support/Heed/heed-pi.js` | The extension passed to pi |
| `~/Library/Application Support/Heed/heed-opencode.js` | The plugin passed to opencode |
| `~/Library/Caches/Heed/avatars` | Org avatars |
| `<worktree>/.cursor/hooks.json` | cursor's hooks, in worktrees Heed creates; excluded from git |

Deleting the cache is safe: Heed rebuilds it from git and GitHub. Heed keeps no transcripts; agents keep their own.
