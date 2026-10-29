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

Heed starts an agent as the pane's own process, never by typing into a shell: your login shell runs the agent's
command line, interactive so your config is read, then becomes the pane's shell when the agent exits:

```text
fish -l -i -c 'claude --session-id … "$HEED_PROMPT"
exec fish -l'
```

The line is written in your shell's own syntax: sh, bash and zsh get one quoting, fish (3.1 or later) its own. The
agent runs in your shell by the name you configured, so your aliases, functions and environment for it apply. The
prompt is never on the line: it is in the pane's environment as `HEED_PROMPT`, so a prompt over several lines, with
quotes, `$` or backticks, reaches the agent exactly as you wrote it. Only a worktree's
[setup](../worktrees/setup.md) runs under `sh -c`, before the agent. Heed reads your login shell each time a pane
starts, so a shell changed with `chsh` is picked up. A shell Heed does not write the syntax of (nu, for one) gets the
line run by `sh`, then the pane is handed to it.

What an agent cannot report, Heed [reads from its screen](screen-reading.md). Each agent's command, prompt delivery,
plan and resume arguments can be changed, and new agents added: see [Custom agents](custom-agents.md).

- [Hooks](hooks.md): what Heed passes to each agent, and why your own agent config never changes.
- [Reading the screen](screen-reading.md): guessed states, and the patterns behind them.
- [Custom agents](custom-agents.md): adding your own.
- [Models and effort](models.md): the models and reasoning efforts heed offers per agent, and how each takes them.
- [Model calls](model-calls.md): Heed's own short calls (summaries, decisions), through the agents you are logged in to.
- [Screen snapshots](screen-snapshots.md): an opt-in, local-only record of what a pane showed at each reported state.
