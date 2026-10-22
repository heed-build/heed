---
description: Switching between Heed's seven views.
---

# Views

Heed has seven views, named along the top with their keys. Every view key starts with `g`.

![The title bar: the views with their keys](../images/shots/keyboard/view-tabs.png)

| Key | View |
|---|---|
| `gs` | [Sessions](../sessions/index.md) |
| `gw` | [Watch](../github/watch.md) |
| `gm` | [Attention](../github/attention.md) |
| `gi` | [Attention](../github/attention.md), on Issues |
| `gp` | [Attention](../github/attention.md), on My PRs |
| `gr` | [Repos](../worktrees/index.md) |
| `gh` | [History](../history/index.md) |

Clicking a view's name works too, and `:inbox`, `:prs` and the rest switch by name. The middle of the title bar shows
what you are looking at: the session's branch and PR, or the item under the cursor. On narrow windows the view keys
are hidden first, never the names.

One more view has no key and no name along the top: `:log`, the [call log](../reference/call-log.md) of every
command and GitHub call Heed made.

`⎋` closes an overlay or a reader, but never changes the view: views are places of their own.
