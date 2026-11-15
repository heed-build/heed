---
description: Resuming sessions when Heed starts, and the continue prompt.
---

# Resuming sessions

When Heed starts, the sessions that were open come back. (With `persist = "zmx"` their agents never stopped, and
their panes reattach instead: see [Agents that outlive Heed](zmx.md).) Whether their agents resume is up to `resume_on_launch`
under `[sessions]`:

| Value | On launch |
|---|---|
| `ask` | List the sessions that were open, all ticked, and let you untick the ones to leave closed (the default) |
| `always` | Resume the ones that were working, blocked or asking; idle and finished ones stay closed |
| `never` | Open plain shells; resume by hand |

![The resume dialog: sessions that were open, which can resume, and which agent sessions are gone](../images/shots/sessions/resume.png)

In the dialog, `space` (or a click on its row) ticks or unticks a session, `↩` or **Resume N sessions** resumes the
ticked ones, and `⎋` or **Start empty** leaves them all closed. A click beside the dialog does nothing, so it never
starts empty by accident.

Resuming uses each agent's own resume (`claude --resume <id>`, `codex resume <id>`, …) with the session id Heed kept.
If the agent no longer has that session, Heed says so and starts the agent fresh with the original prompt.

## Resuming later

Start empty, or skipping a session, leaves it as a plain shell with no agent. So does an agent that exited and left
its shell behind. Neither is lost: while Heed still has the agent's session id and the agent still has that
conversation, a strip across the top of the session's panes says so, and the session's row in the sidebar reads
"agent not running · resume".

![The banner: the agent is not running here, with Resume its conversation, Start fresh and Dismiss](../images/shots/sessions/resume-banner.png)

![A session that came back without its agent: the banner over its panes, and its row saying so](../images/shots/sessions/resume-later.png)

| Key | Button | What it does |
|---|---|---|
| `gu` | **Resume its conversation** | Resumes the agent's conversation, as the dialog does (`claude --resume <id>`, `codex resume <id>`, …). If the agent no longer has it, Heed says so and starts the agent fresh with the original prompt. |
| `gf` | **Start fresh** | Starts the agent again from the session's original prompt, as a new conversation. |
| `gq` | **Dismiss** | Hides the banner for this session until Heed restarts. The keys, the menus and the row keep working. |

The same two actions are in the session's right-click menu (**Resume its agent**, **Start its agent fresh**) and the
Session menu in the menu bar. They are on while the banner would show and off otherwise. Resuming replaces the pane's
shell with the agent, as the launch dialog does.

The banner shows when all of these are true:

- the session is not parked and not on a host (an agent on a host stays alive in zmx there);
- its agent can resume, and Heed kept its session id, and the agent still has that conversation (for claude, its
  transcript is on disk; a session whose agent never got as far as a first turn has none, so there is nothing to offer);
- no agent pane or shell pane of the session has an agent running. An agent Heed started or resumed, one whose hooks
  report in, one that survived in zmx, and an agent you started by hand in a split all count as running; a task's or a
  helper's agent does not. The session's saved state (working, done) is not used: after a restart it only says what
  was true then.

A chat with a conversation to continue gets the banner like any session; one with nothing to resume does not.

## The continue prompt

A session that was mid-turn when Heed quit gets a nudge once its agent is idle again: `continue_prompt`, by default
"Continue where you left off.". Set it to `""` to turn it off.
