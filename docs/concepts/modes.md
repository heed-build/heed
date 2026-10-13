---
description: NORMAL, INSERT, VISUAL, COMMAND and HINT, and who gets your keys in each.
---

# Modes

Like vim, Heed has modes. The status bar always shows which one you are in.

| Mode | Your keys go to | Enter | Leave |
|---|---|---|---|
| **NORMAL** | Heed: every key is a command | (the default) | |
| **INSERT** | The focused terminal | `i`, or click a pane | `⇧⎋` or `⌃\` |
| **VISUAL** | Selecting rows to act on | `v` | `⎋` |
| **COMMAND** | The command line | `:` | `⎋`, or `↩` to run |
| **HINT** | Jump labels | `f` (`F` jumps into INSERT) | type a label, or `⎋` |

![NORMAL in the status bar](../images/shots/concepts/mode-normal.png)

![INSERT](../images/shots/concepts/mode-insert.png)

![VISUAL](../images/shots/concepts/mode-visual.png)

![COMMAND](../images/shots/concepts/mode-command.png)

![HINT](../images/shots/concepts/mode-hint.png)

In NORMAL no key ever reaches a terminal, so nothing you type there can end up in an agent by accident. The standard
Mac shortcuts (`⌘W`, `⌘Q`, `⌘H`, `⌘M`) work in every mode; see [Mac shortcuts](../keyboard/mac-shortcuts.md).
