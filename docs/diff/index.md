---
navigation_title: Diff
description: "The diff overlay: what the agent changed, by scope, file and hunk."
---

# Diff

`gd` opens the diff overlay for the session's worktree: what changed, file by file, hunk by hunk, with word-level
highlights.

![The diff overlay: files on the left, the hunks of the current file on the right](../images/shots/diff/overlay.png)

| Key | |
|---|---|
| `⇥` / `⇧⇥` | Scope: **all**, **committed**, **staged**, **unstaged** |
| `c` | One commit at a time (cycles through the branch's commits) |
| `]f` / `[f` | Next / previous file |
| `n` / `N` | Next / previous hunk |
| `j` / `k` | Move by line |
| `gd` or `⎋` | Close |

See [Reviewing changes](reviewing.md) for the split view and acting on a hunk.
