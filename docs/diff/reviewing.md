---
description: The split view, and asking the agent about a hunk.
---

# Reviewing changes

`t` switches between the unified and the split view.

![The split view: old on the left, new on the right](../images/shots/diff/split.png)

From the line under the cursor:

| Key | |
|---|---|
| `a` | Ask the agent about this hunk: its location and lines go to the agent's pane |
| `e` | Open the file at that line in your editor |
| `y` | Copy `path:line` |

Changed words within a line are highlighted, so a one-character fix stands out in a long line.
