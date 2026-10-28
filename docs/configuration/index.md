---
navigation_title: Configuration
description: config.toml, Settings, and how changes apply.
---

# Configuration

Everything Heed can be told lives in one file, `~/.config/heed/config.toml` (or `$XDG_CONFIG_HOME/heed/config.toml`).
Heed writes it with comments the first time it opens, showing every key with its default.

- **Saving applies it.** Heed watches the file; there is nothing to reload.
- **Mistakes never take the rest down.** A value that does not fit is reported in the status bar, and its default
  kept. A syntax error keeps the last good config in use.
- **Settings edits the same file** (`⌘,`), keeping your comments, for everything but key bindings.

![A config problem reported in the status bar](../images/shots/configuration/problem.png)

- [Settings](settings.md): the Settings window, section by section.
- [Inference & decisions](inference.md): which agent takes Heed's model calls, what answers its decisions, and the
  reminder on launch until they are set up.
- [Local learning](local-learning.md): how Hunch learns from your corrections, on this Mac only.
- [config.toml reference](reference.md): every key and its default.
- [Finding git and gh](tools.md): how Heed finds the tools it runs.
- [Updates](updates.md): how Heed updates itself, and how to turn it off.
