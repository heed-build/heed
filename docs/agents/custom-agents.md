---
description: Changing the built-in agents and adding your own.
---

# Custom agents

Every agent is an `[agents.<name>]` table. The built-in ones (claude, codex, cursor, pi, opencode, gemini) can be
changed field by field; any other name adds an agent.

```toml
[agents.claude]
command = "claude"
plan = "--permission-mode plan"
resume = "--resume {id}"

[agents.mytool]
command = "mytool --model fast"
prompt = "argument"
```

| Field | |
|---|---|
| `command` | The command line that starts the agent. |
| `prompt` | How the prompt reaches it: `argument` (appended), `stdin` (piped in), `paste` or `file`. |
| `plan` | Arguments for **Plan first** in Start work. |
| `resume` | Arguments that resume a session; `{id}` is the agent's session id. Without it, a resumed session starts fresh. |
| `model_flag` | The flag that picks a model (`--model`). Without it, nothing can pick one. |
| `effort_flag` | How it takes a reasoning effort: a flag the level follows (`--effort`), or arguments with `{level}` in them (`-c model_reasoning_effort={level}`). Without it, no effort is passed. |
| `model`, `effort` | What its sessions start on when nothing else picks one; see [Models and effort](models.md). |
| `llm` | `false` leaves the agent out of Heed's own [model calls](model-calls.md). Built-in agents only. |
| `llm_model` | The model it uses for them; empty, a cheap one Heed detects. |
| `[agents.<name>.profiles]` | Named command lines, `name = "command"`. |
| `[agents.<name>.patterns]` | Screen patterns per state; see [Reading the screen](screen-reading.md). |

`default_agent` under `[sessions]` picks the agent Start work selects first. Settings (`⌘,`) edits the same fields.
