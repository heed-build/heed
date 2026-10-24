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
rebound in [config](customizing.md) shows as you have it; a command whose key only works somewhere else (in VISUAL, or
in the PR overlay) shows its `:name` too.

A right-click first selects what you clicked, as a click would (without typing into it), then the menu acts on it.
Items that cannot apply are left out (no *Stop run* without a run); items that apply but cannot run now are greyed (the
pilot's items on a merged PR). A check mark shows a setting that is on: watching, get it green, get it merged, paused.

## Sessions

Right-click a session in the sidebar, or in the collapsed rail:

| Item | Key |
|---|---|
| Type into its agent | `↩` |
| Open PR overlay, Diff, Open in browser, Open repo on GitHub | `go`, `gd`, `gB`, `gR` |
| Get it green, Get it merged, Pause | `zg`, `zm`, `zp` |
| One more round (when a PR stalled) | `zr` |
| What will heed do? | `z?` |
| Go to its run, Stop run (while a run works on it) | `gb`, `zx` |
| Pin, Park, Start again from its prompt | `m`, `zz`, `O` |
| Hand off to…, a submenu of the other agents ([handing off](../sessions/handoff.md)) | `gA` |
| Close, keep worktree; Delete with worktrees… | `x`, `dd` |

The pilot's items act on all the session's PRs, as their keys do in the sidebar. A [chat](../sessions/chats.md) leaves
out the PR, diff, repo and pilot items and adds **Promote to work…** (`:chat.promote`); its prompt starts **New chat
from its prompt** (`O`), and closing is **Close**, or **Delete with its scratch folder…** (`dd`) for a scratch chat.

## The inspector

A right-click on a **PR card** acts on that PR alone, not on every PR of the session: open it here (the PR overlay) or
in the browser, go to its session, watch it, get it green, get it merged, pause it, give it one more round, ask Copilot
or its [reviewers](../github/watch.md) (`zv`), see what heed will do, or stop tracking it (`:pr.untrack`).

An **issue** opens in the [reader](../github/reading.md) or the browser, or comes off the session (`:issue.remove`). A
**run** goes to its tab or stops while it works, and opens in the reader once it ended.

## PRs and Watch

A right-click on a row in [PRs](../github/pull-requests.md) or [Watch](../github/watch.md) offers that PR: open it,
open it in the browser or its repo on GitHub, go to its session, and the pilot's items for it alone. In Watch it also
runs or shows the PR's [merge queue](../github/watch.md) (`R`, `gM`).

## Attention

A right-click on a row offers to open it (`↩`), open it in the browser, go to its session (`gS`), draft a reply (`R`),
start a session from it (`s`) or add it to the selected session (`a`), and be done with it (`x`), snooze it for an hour
or until tomorrow, or mute its thread (`M`). An agent's row offers only its session, done and snooze. Picked rows
(`␣`) work as in the Inbox below.

## Inbox and Issues

A right-click on a row offers to open it (`↩`), open it in the browser or its repo on GitHub, start a session from it
(`s`) or add it to the selected session (`a`); in the Inbox, mark it read (`x`); in Issues, show all of its repo's
issues or only yours (`w`). With rows picked (`␣`), a right-click on one of them acts on all the picked rows, and the
items say how many; a right-click on a row that is not picked acts on that row alone.

A repo in the Issues repo column shows its issues, flips between all issues and only yours, or opens on GitHub.

## Repos and History

A worktree in Repos goes to its session or imports it (`↩`), starts work in its repo (`o`), copies its path, pins its
session, opens its repo on GitHub, flips its repo's issues (`w`), runs the cleanup sweep (`gC`), reviews the repo's
setup (`S`), or removes it (`dd`, which asks first; never offered for the repo's own checkout). Selected worktrees
(VISUAL) work as picked rows do above.

A session in History reopens (`R`), starts again from its prompt (`O`), or opens its repo on GitHub. A row of History's
[timeline](../history/timeline.md), [ledger](../history/ledger.md) or [dashboard](../history/dashboard.md) reopens its
session (`R`) or opens its repo on GitHub, and goes back to the list; the timeline also shows only the row's kind, and
the ledger writes the summary again (`S`) or edits it (`E`).

## The call log

A call in the [call log](../reference/call-log.md) copies its command (`y`), or narrows the log to its caller (`c`) or
its agent (`a`), and widens it again.

## Tabs

A right-click on a tab selects it and offers a new tab (`gn`), splitting (`⌃w v`, `⌃w s`), zooming the pane (`⌃w z`)
and closing the tab (`⌃w c`); a run's tab can also stop its run (`zx`), and the agent's tab can hand the session to
another agent (**Hand off to…**, `gA`).

## The diff and the PR overlay

In the [diff overlay](../diff/index.md), a right-click on a file in the list, or on a line of the diff, copies its
`path:line` (`y`), opens the file in your editor (`e`), puts a note on the hunk (`a`) or asks the agent about it now
(`A`), shows one commit at a time (`c`), or switches to the split view (`t`).

A feedback item in the [PR overlay](../github/review-feedback.md) can be queued or unqueued (`␣`), sent with the rest
of the queue (`s`) or dismissed (`x`); for a PR, you can also start a session from it (`S`) or open it in the browser
(`gB`).

## Not in terminals

A right-click in a terminal pane goes to the program running there, as in any terminal: tmux, vim and others use it.
Heed adds no menu of its own there; right-click the session in the sidebar or its tab instead.
