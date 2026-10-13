---
description: The Settings window, section by section.
---

# Settings

`⌘,` opens Settings. It edits `config.toml` in place, keeping its comments; anything you change in the file shows up
here, and the other way round. Key bindings live only in the file.

![Settings: General](../images/shots/configuration/settings.png)

| Section | Holds |
|---|---|
| **General** | Default agent, resume on launch, the continue prompt, shell split, menu bar item, Dock state, GitHub poll interval, issues default, and where `git` and `gh` are |
| **Agents** | Each agent's command, prompt delivery, plan and resume arguments |
| **Repos & colors** | Each org's colour, and whether its repos show all issues or only yours |
| **Worktrees & cleanup** | Where worktrees go, the repo roots, and the cleanup rules |
| **Keys & modes** | The INSERT escape chord and every binding as it stands, read-only: bindings are edited in `config.toml` |

Problems in the file show at the top of Settings as well as in the status bar.
