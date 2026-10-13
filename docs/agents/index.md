---
navigation_title: Agents
description: The coding agents Heed runs, and how each one tells Heed what it is doing.
---

# Agents

Heed runs coding agents in real terminals and keeps track of what each is doing. Six are built in; any other command
line agent can be added.

| Agent | Command | Reports its state through | Resumes with |
|---|---|---|---|
| claude | `claude` | Hooks passed with `--settings` | `--resume <id>` |
| codex | `codex` | Hooks passed with `-c hooks.<event>=…` | `resume <id>` |
| cursor | `cursor-agent` | A project hooks file Heed writes into the worktree | `--resume <id>` |
| pi | `pi` | An extension passed with `-e` | `--session <id>` |
| opencode | `opencode` | A plugin passed in `OPENCODE_CONFIG_CONTENT` | its own session id |
| gemini | `gemini` | Nothing: Heed reads its screen | `--resume <id>` |

What an agent cannot report, Heed [reads from its screen](screen-reading.md). Each agent's command, prompt delivery,
plan and resume arguments can be changed, and new agents added: see [Custom agents](custom-agents.md).

- [Hooks](hooks.md): what Heed passes to each agent, and why your own agent config never changes.
- [Reading the screen](screen-reading.md): guessed states, and the patterns behind them.
- [Custom agents](custom-agents.md): adding your own.
