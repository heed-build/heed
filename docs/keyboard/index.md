---
navigation_title: Keyboard
description: "How keys work in Heed: modes, sequences, counts and the hint panel."
---

# Keyboard

Everything in Heed is a key or two away, in [modes](../concepts/modes.md) like vim's. In NORMAL every key is a command;
in INSERT your keys go to the focused terminal.

## Sequences

Many commands are two keys: `g` then a letter for views (`gm` Inbox), `⌃w` then a letter for panes (`⌃w v` split).
Press the first key and wait: a panel at the bottom lists every key that can follow, and what it does.

![After g: every key that can follow, and what it does](../images/shots/keyboard/leader.png)

`⎋` drops a sequence you started. A number before a command repeats it (`3j`), as in vim.

## How the keys are laid out

Single keys are kept for what you do many times an hour; anything rarer is two keys, grouped by its first:

| Keys | |
|---|---|
| `j` `k` `h` `l` `G` `/` `f` | Move, filter, jump |
| `⌃d` `⌃u`, `{` `}` | Half a page; the previous or next group (a sidebar group, a repo, a day) |
| `↩` `o` `i` `v` `x` `m` | Open, start work, type into the agent, select, done with it, pin |
| `r` | Refresh the view you are in |
| `g…` | Go somewhere: views (`gm` Inbox), overlays (`go`, `gd`), tabs (`gt`), the browser (`gB`) |
| `z…` | Toggles: `zz` park, `zi` inspector, `zs` sidebar; the pilot's `zw` watch, `zg` green, `zm` merge, `zp` pause |
| `'…` | Jump to a pin (`'1`–`'9`), or back (`''`) |
| `]…` `[…` | Next or previous of a kind: `]p` PR, `]f` file |
| `⌃w…` | Panes |
| `dd` | Remove (it asks first) |

A key means the same thing in every view where it means anything: `x` closes a session, marks an Inbox item read and
dismisses a feedback item; `o` always starts work, picking the repo under the cursor in Repos.

## Views have their own keys

Some keys only mean something in one view: `s` starts a session in the Inbox, `dd` removes a worktree in Repos. Those
come first there; elsewhere the same key is free or means something else. The status bar always lists the keys that
matter in the view you are in, and `?` shows every key.

## In this section

- [Views](views.md) · [Hints](hints.md) · [The command line](command-line.md) · [Selecting](visual.md)
- [Mac shortcuts](mac-shortcuts.md) · [Customizing keys](customizing.md) · [Key reference](reference.md)
