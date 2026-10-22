---
description: Choosing the agent, and the options that change how a session starts.
---

# Agent and options

The agent row lists every agent Heed knows, plus **none, shell only**. `default_agent` under `[sessions]` picks the
one selected first.

![The agent row and options, and the command the agent pane will run](../images/shots/start-work/agent-options.png)

| Option | |
|---|---|
| **Autostart agent with prompt** | Start the agent in its pane on the prompt. Off opens the pane with a plain shell. |
| **Plan first** | Start the agent in its planning mode where it has one (claude's `--permission-mode plan`). |
| **Open shell split** | A shell beside the agent. Defaults to `shell_split` under `[sessions]`. |

## The command preview

**Will run in pane 1** shows the exact command line: the agent, the hook wiring Heed passes for this run (see
[Hooks](../agents/hooks.md)), the session id it will resume by, and your prompt.
