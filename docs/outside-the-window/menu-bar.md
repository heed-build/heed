---
description: "The menu bar owl: what needs you, and Start work from anywhere."
---

# The menu bar

The owl in the menu bar shows how many sessions need you, beside it when there are any.

![The menu bar owl with 2 sessions needing you](../images/shots/outside/menu-bar.png)

Its menu lists the sessions waiting on you (choosing one opens Heed on it), how many are working, and:

![The menu: the waiting sessions, Start work, Open Heed, Settings, Quit](../images/shots/outside/menu.png)

| Item | |
|---|---|
| Start work… | The [Start work panel](../start-work/from-anywhere.md), over the app you are in |
| Open Heed | Heed to the front, reopening its window if it was closed |
| Settings… | Settings |
| Quit Heed | Quit; with agents running, Heed asks first |

With the menu bar item on, **closing the window keeps Heed running**, and every agent with it. Without it, closing the
window quits.

```toml
[ui]
menu_bar = true
```
