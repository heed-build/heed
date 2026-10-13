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

## Views have their own keys

Some keys only mean something in one view: `s` starts a session in the Inbox, `dd` removes a worktree in Repos. Those
come first there; elsewhere the same key is free or means something else. The status bar always lists the keys that
matter in the view you are in, and `?` shows every key.

## In this section

- [Views](views.md) · [Hints](hints.md) · [The command line](command-line.md) · [Selecting](visual.md)
- [Mac shortcuts](mac-shortcuts.md) · [Customizing keys](customizing.md) · [Key reference](reference.md)
