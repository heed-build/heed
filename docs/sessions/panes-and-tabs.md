---
description: Splitting, moving between, zooming and closing panes, and tabs.
---

# Panes and tabs

A session's terminals are panes, arranged in tabs. Pane keys start with `⌃w`, as in vim.

| Key | |
|---|---|
| `⌃w v` | Split right |
| `⌃w s` | Split below |
| `⌃w h` `⌃w j` `⌃w k` `⌃w l` | Focus the pane left, below, above, right (`h` and `l` alone work too) |
| `⌃w z` | Zoom the focused pane (again to unzoom) |
| `⌃w q` | Close the focused pane; the agent's pane asks first |
| `gt` / `gT` | Next / previous tab |
| `gn` | New tab with a shell (or click `+`) |
| `:tab.close` | Close the tab and every pane in it (or click its `×`); a tab with the agent asks first |

![After ⌃w v: the agent pane split, a new shell on the right](../images/shots/sessions/split.png)

![The tab strip: agent, shell and a tests task](../images/shots/sessions/tab-strip.png)

## When terminals end

A pane closes when its terminal ends: `exit` or `⌃D` in a shell, or a command that finishes. The last pane of a tab
takes the tab with it.

When a session has no terminal left, whether by `exit`, `×` or `⌃w q`, heed asks what to do with it:

- **Delete** (`y`): the session moves to History and its worktree is removed, with its local branch. A worktree with
  work not saved anywhere else is kept, and the dialog says so.
- **Close, keep the worktree** (`c`): the session moves to History; the worktree stays.
- **Keep** (`n`): the session stays, with a new shell in its worktree.

![Every terminal of a session closed: delete, close, or keep](../images/shots/sessions/all-closed.png)

New sessions open with the agent alone; set `shell_split = true` under `[sessions]` for a shell beside it.

## Task tabs

Pinned tasks open as tabs in new sessions, one each, running their command. The tab's glyph shows the last run: done
when it passed, a red square when it failed.

```toml
[repos."elastic/docs-builder".tasks]
test = "dotnet test"
```

## Zoom

![⌃w z: the agent pane filling the center](../images/shots/sessions/zoom.png)
