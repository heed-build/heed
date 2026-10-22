---
description: Shortcuts that work from any app.
---

# Global shortcuts

Two shortcuts work whichever app is in front:

| Key | |
|---|---|
| `⌃⌥Space` | [Start work](../start-work/from-anywhere.md) in a floating panel over the app you are in |
| `⌃⌥H` | Heed to the front, reopening its window if it was closed |

```toml
[keys]
global_start_work = "<C-M-Space>"
global_activate = "<C-M-h>"
```

`""` turns one off. Each needs at least one of ⌃, ⌥ or ⌘, so it never swallows ordinary typing. Neither needs
Accessibility permission. If another app already owns the combination, or both are set to the same keys, the status
bar says so.

Heed never takes focus by itself: these, clicking a session in the menu bar, and Open on a notification are the only
times it comes forward.
