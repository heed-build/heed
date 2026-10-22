---
description: The Settings window, section by section.
---

# Settings

`⌘,` opens Settings. It edits `config.toml` in place, keeping its comments; anything you change in the file shows up
here, and the other way round. Key bindings live only in the file.

![Settings: General](../images/shots/configuration/settings.png)

| Section | Holds |
|---|---|
| **General** | Default agent, resume on launch, the continue prompt, shell split, menu bar item, Dock state, notifications, GitHub poll interval, issues default, how long the [call log](../reference/call-log.md) keeps each kind of call, and where `git` and `gh` are |
| **Agents** | Each agent's command, prompt delivery, plan and resume arguments |
| **Orgs & repos** | Per org and per repo: colour, issues, and every Pilot setting, with which ones override the defaults (see below) |
| **Worktrees & cleanup** | Where worktrees go, the repo roots, and the cleanup rules |
| **Pilot** | The defaults every PR starts from: watching, get it green, get it merged and their rules, and extra instructions for heed's prompts |
| **Attention** | The [rules](../github/attention-rules.md) as a list and as text, what an edit would change before you save it, and quiet hours |
| **Keys & modes** | The INSERT escape chord and every binding as it stands, read-only: bindings are edited in `config.toml` |

## Orgs & repos

Every org and repo heed knows, from the repo list and from `config.toml` (ones you have not cloned here say so). A
marked one, `● 3`, overrides three settings; **Only overridden** hides the rest.

![Orgs & repos: elastic/docs-builder overrides four settings and inherits two from its org](../images/shots/configuration/orgs-repos.png)

For the selected org or repo, each setting shows the value that applies and where it comes from: `default` (heed's,
or `[pilot]`), `org` or `repo`. Overridden rows are marked. Changing a value writes the override
(`[orgs.elastic] reviewers = ["copilot"]`, `[repos."elastic/docs-builder"] quiet_minutes = 15`); ↺ removes it, and
the value falls back to the org's, then the default. A repo's tasks show here and are edited in the file.

Problems in the file show at the top of Settings as well as in the status bar.
