---
description: "Right-click menus: every item is a command, with its key beside it."
---

# The mouse and right-click

Heed is keyboard-first, but a click works where you would expect one: a click selects, a double-click opens or types
into the agent (see [the sidebar](../sessions/sidebar.md)). A right-click (or `⌃`-click) opens a menu of what you can do
with the thing under the mouse.

Every item in a right-click menu runs a command, the same one its key runs, and shows that key on the right: the menu
teaches the keys as you use it. A command with no key shows its `:name` instead (`:pr.untrack`), which is what still
runs it from the [command line](command-line.md). The key shown is the one that works where you are, so a key you
rebound in [config](customizing.md) shows as you have it.

A right-click first selects what you clicked, as a click would (without typing into it), then the menu acts on it.
Items that cannot apply are left out (no *Stop run* without a run); items that apply but cannot run now are greyed (the
pilot's items on a merged PR). A check mark shows a setting that is on: watching, get it green, get it merged, paused.

## Sessions

Right-click a session in the sidebar, or in the collapsed rail:

| Item | Key |
|---|---|
| Open PR overlay, Diff, Open in browser, Open repo on GitHub | `go`, `gd`, `gB`, `gR` |
| Get it green, Get it merged, Pause | `zg`, `zm`, `zp` |
| One more round (when a PR stalled) | `zr` |
| What will heed do? | `z?` |
| Go to its run, Stop run (while a run works on it) | `gb`, `zx` |
| Pin, Park, Start again from its prompt | `m`, `zz`, `O` |
| Close, keep worktree; Delete with worktrees… | `x`, `dd` |

The pilot's items act on all the session's PRs, as their keys do in the sidebar.

## The inspector

A right-click on a **PR card** acts on that PR alone, not on every PR of the session: open it here (the PR overlay) or
in the browser, go to its session, watch it, get it green, get it merged, pause it, give it one more round, ask Copilot
(`C`) or its [reviewers](../github/watch.md) (`zv`), see what heed will do, or stop tracking it (`:pr.untrack`).

An **issue** opens in the [reader](../github/reading.md) or the browser, or comes off the session (`:issue.remove`). A
**run** goes to its tab or stops while it works, and opens in the reader once it ended.

## PRs and Watch

A right-click on a row in [PRs](../github/pull-requests.md) or [Watch](../github/watch.md) offers that PR: open it,
open it in the browser or its repo on GitHub, go to its session, and the pilot's items for it alone. In Watch it also
runs or shows the PR's [merge queue](../github/watch.md) (`R`, `gM`).
