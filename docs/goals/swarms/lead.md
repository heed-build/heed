---
description: "How a swarm's lead keeps the plan with heed goal: plan show, plan propose, ask, and the plan's JSON."
---

# The lead and heed goal

A swarm's lead keeps the plan with the same `heed goal` command every agent on a goal has ([heed goal](../cli.md)),
taught by the **Leading a swarm** section of the `heed-goal` skill. Codex and other agents without the plugin get the
same rules in their first prompt.

| Command | What it does |
|---|---|
| `heed goal plan show` | The plan: tasks by phase with their ids, the questions and their answers, your re-plan feedback, a change waiting for you or one you said no to |
| `heed goal plan propose --file <path\|-> [--note <text>]` | A plan as JSON; `-` reads it on stdin |
| `heed goal ask <question> [--option <a> --option <b>]` | A question for you, shown in the plan pane |
| `heed goal plan approve` | Approves the plan: only from a terminal outside heed, never from a pane or a background run |

Before you approve a plan, every proposal is the new draft. After, a small change applies and a structural one waits
for you ([Approving](plan.md#approving)). `--json` on any of them answers as JSON.

## The plan's JSON

```json
{
  "note": "first draft",
  "tasks": [
    {"id": "offsets", "title": "Arrowhead offsets per zoom level", "phase": "Measure", "owner": "claude",
     "estimate": "20m", "doneWhen": ["a table of offsets from 50% to 400% zoom"]},
    {"id": "snap", "title": "Snap arrowheads to the lifeline", "phase": "Fix", "owner": "codex:o4",
     "estimate": "45m", "after": ["offsets"], "doneWhen": ["arrowheads meet the lifeline at every zoom"]}
  ],
  "scope": [{"section": "not-the-goal", "text": "new diagram types"}]
}
```

- `id` names a task in `after`. An id of an item already on the goal takes that item into the plan. Without an id a
  task keeps the id of the current plan's task with the same title, or gets one from its title.
- `phase` is the phase it is in; without one, the phase of the task before it.
- `owner` is an agent, `agent:model`, or `{"agent": …, "model": …}`.
- `estimate` is minutes, or `15m`, `1h 30m`, `1.5h`.
- `doneWhen` is one check or a list: what evidence must show for the task to be done.
- `scope` lists changes the goal would need (sections `goal`, `not-the-goal`, `done-when`, `question`, `decision`):
  each becomes a `GOAL.md` proposal that waits for you, never an edit.

A plan is refused, with why, when a task has no title, two tasks have one id, a task waits for something that is
neither a task nor an item, or tasks wait for each other in a circle.
