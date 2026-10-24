---
description: "The menu bar and right-click menus: every item is a command, with its key beside it."
---

# The mouse, the menu bar and right-click

Heed is keyboard-first, but a click works where you would expect one: a click selects, a double-click opens or types
into the agent (see [the sidebar](../sessions/sidebar.md)). A right-click (or `⌃`-click) opens a menu of what you can do
with the thing under the mouse.

A key hint is a button too: click `zg green` beside a PR, `x done` in Attention or a row of the `?` overlay, and it runs
what the key runs, on what it sits beside. The pointer turns to a hand over it and its tooltip names the command
(`:pilot.green`). So do the filter chips of the [call log](../reference/call-log.md) and the [timeline](../history/timeline.md), the PR overlay's tabs,
its Green modes and the checkbox on a feedback item (it queues or unqueues the item, as `space` does). A row of `:`'s
completions takes the line as `⇥` would, a double-click runs it; a key listed after a pending `g` presses the rest. In
History, its timeline, ledger and dashboard, `↩` and a double-click reopen, as `R` does.

Every item in a right-click menu runs a command, the same one its key runs, and shows that key on the right: the menu
teaches the keys as you use it. A command with no key shows its `:name` instead (`:pr.untrack`), which is what still
runs it from the [command line](command-line.md). The key shown is the one that works where you are, so a key you
rebound in [config](customizing.md) shows as you have it; a command whose key only works somewhere else (in VISUAL, or
in the PR overlay) shows its `:name` too.

A right-click first selects what you clicked, as a click would (without typing into it), then the menu acts on it.
Items that cannot apply are left out (no *Stop run* without a run); items that apply but cannot run now are greyed (the
pilot's items on a merged PR). A check mark shows a setting that is on: watching, get it green, get it merged, paused.

## The menu bar

Every command Heed has is in the menu bar too, so you can find anything with the mouse and learn its key on the way.
As in a right-click menu, each item shows its key on the right as text (or its `:name`, when nothing binds it): the
menus register no shortcuts of their own, because Heed's keys are sequences (`gd`, `⌃w v`) that the mode engine reads,
and a menu that claimed `o` would take it from your terminals. The one exception is `⌘N` for **Start work**, which
works in every mode like the other [Mac shortcuts](mac-shortcuts.md).

| Menu | What is in it |
|---|---|
| File | Start work (`⌘N`), the floating panel, a new chat, importing a worktree, adding a repo, resume and *While you were away…*, syncing GitHub, rescanning repos, the cleanup sweep and rules, `config.toml`, finding git and gh again |
| Session | Type into its agent or the focused pane, pin, park, start again from its prompt, *Hand off to…*, promote a chat, run a task, link or take off an issue, close, delete, stop every agent |
| View | Every view, those without a tab too (Inbox, Issues, PRs, the timeline, ledger, dashboard and call log), hosts, the filter, the sidebar and inspector, and a submenu each for Attention, Inbox and Issues, Repos, History and the call log |
| PR | The PR overlay, the diff, the session's PRs, the browser and links, tracking, everything the pilot does (watch, get it green, get it merged, merge now, pause, one more round, Copilot, reviewers, its run), merge queues, setting up a repo, and submenus for review feedback and the diff |
| Go | The next session needing you (`ga`), back, a session by name, your pinned sessions, hints, VISUAL and the command line |
| Window | Splitting, zooming, closing and moving between panes; new, next, previous and closing tabs, and each tab by number |
| Help | Keys & states (`?`), the [tutor](../getting-started/tutor.md) and its steps, the getting-started checks, these docs |

The menus act on what you are looking at, as a key would: the selected session, or the PR in front (the one open in the
PR overlay or the reader, or the row under the cursor in PRs and Watch). An item is greyed when it cannot run there,
by the same rules as the right-click menus: no pilot items without an open PR, no diff for a chat, no *Stop run* without
a run. A view's own submenu (the call log's filters, the diff's hunks) is greyed outside that view. A check mark shows
what is on: the view you are on, a pinned or parked session, watching, get it green, get it merged, paused, the sidebar
and inspector. An item that needs words (**Track a PR…**, **Session named…**) opens the [command line](command-line.md)
with the command typed, for you to finish.

A few commands are left out of the menus on purpose: moving the cursor (`j`, `k`, `gg`; the mouse clicks and scrolls),
the command line's own keys, closing an overlay (`⎋`), and the app menu's own Settings, Check for Updates and Quit.

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

In the [diff overlay](../diff/index.md), a click on a file shows it, a click on a commit shows that commit alone, a
click on a line moves the cursor there and a double-click writes a note on it (as `↩`). Drag over lines, or shift-click,
to [select them](../diff/index.md#selecting-lines); a click on a hunk's header selects the hunk. Its key hints are
buttons: the scope, unified or split, the next commit, close, and the note, ask, copy and editor actions below the diff.

A right-click on a file in the list, or on a line of the diff, copies its `path:line` (`y`), opens the file in your
editor (`e`), puts a note on the hunk (`a`) or asks the agent about it now (`A`), shows one commit at a time (`c`), or
switches to the split view (`t`). On a selected line, the items act on all the selected lines.

A feedback item in the [PR overlay](../github/review-feedback.md) can be queued or unqueued (`␣`), sent with the rest
of the queue (`s`) or dismissed (`x`); for a PR, you can also start a session from it (`S`) or open it in the browser
(`gB`).

## Not in terminals

A right-click in a terminal pane goes to the program running there, as in any terminal: tmux, vim and others use it.
Heed adds no menu of its own there; right-click the session in the sidebar or its tab instead.
