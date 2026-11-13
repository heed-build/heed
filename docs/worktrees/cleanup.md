---
description: Removing worktrees nobody has touched for a while, automatically or with one button.
---

# Cleanup

Cleanup removes worktrees nobody has touched for a while. It is off until you turn it on, in **Settings › Worktrees ›
Cleanup** (the **Cleanup settings** button at the top of Repos opens it) or in `config.toml`:

```toml
[cleanup]
enabled = false
idle_days = 14
delete_branch = true        # the local branch; the remote is left alone
ask_before_sweep = false    # true: cleanup runs only when you press Clean up worktrees
keep_archive_days = 90      # saved work from removed worktrees; 0 keeps it
```

A worktree is idle when nothing happened in it for `idle_days`: no agent output, keystrokes, hook events, commits or
pull request updates. Dirty, unpushed and pinned work is never removed by cleanup, even though a removal would
[save it first](removing.md#saved-first): cleanup happens without you, so it leaves those to you.

The top of Repos says what cleanup does under your settings, with two buttons: **Cleanup settings** (`⌘,`) and **Clean
up worktrees** (`gC`).

![Cleanup off: worktrees stay until you remove them](../images/shots/worktrees/cleanup-off.png)

With cleanup on, it also says what cleaning up now would do: what goes, and what is kept and why. Cleanup runs hourly
unless `ask_before_sweep` is set; **Clean up worktrees** (`gC`, `:cleanup.run`) runs it now, after a confirmation that
lists every worktree it would remove.

![Cleanup on: what would be removed, what is kept](../images/shots/worktrees/cleanup.png)

`:cleanup.sweep` and `:wt sweep`, the command's former names, still run it, and a `config.toml` binding to
`cleanup.sweep` keeps working.

## Chats' scratch folders

Cleanup also removes the scratch folder of a [chat](../sessions/chats.md) that closed 30 or more days ago. It never
removes the folder of a pinned chat, a folder you picked for a chat, or a chat's folder on a host. The scratch folders
are listed with the worktrees, and nothing is removed while cleanup is off. A removed folder is noted in the chat's
History timeline. Reopening the chat makes the folder again, empty.

![A closed chat's scratch folder in what cleanup would remove](../images/shots/worktrees/cleanup-chats.png)

![The confirmation lists it with the worktrees](../images/shots/worktrees/cleanup-chats-confirm.png)

## Saved work

Every removal saves the worktree as `refs/heed/archive/<branch>` first ([Removing](removing.md#saved-first)). Cleanup
also drops the saved work older than `keep_archive_days`, in every repo, and its confirmation lists each one. Set it to
0 to keep them all. With cleanup off, nothing is dropped.

![The confirmation lists the saved work it drops](../images/shots/worktrees/cleanup-archives.png)

## What runs leave behind

Get it green [runs](../github/watch.md#runs) work in worktrees of their own, on `heed/get-it-green/…` (or
`heed/get-it-merged/…`) branches, and remove both when they end. Anything left over (heed quit mid-run, a removal
failed) is removed by every cleanup and at launch, whether or not cleanup is on, as long as it is safe: no uncommitted
changes, and no commits that are not on the pull request's branch. `heed cleanup runs` does the same from a
terminal. Repos and `I` never list these worktrees.
