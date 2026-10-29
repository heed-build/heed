---
description: "Swarms: a goal worked by several agents at once. A lead agent drafts a plan, you change and approve it, and workers run its tasks side by side."
---

# Swarms

A swarm is a burst of parallel work on a goal: a lead agent breaks the goal into a plan, you read it, change it and
approve it, and a team of agents works the plan's tasks side by side, each in a worktree of its own. A swarm is not
something next to Goals: it is a goal in swarm mode. It reuses the goal's `GOAL.md`, its items and board, its
evidence, reviewers and done rule, the GitHub mirror and `heed goal`.

The goal outlives the swarm. A goal has at most one swarm going at a time; when it ends the goal carries on as a
normal goal, and a follow-up swarm is the next run on the same goal. Old runs stay readable with their plans and
steering.

:::{note}
A swarm plans, approves, runs and lands: workers start on ready tasks and open their pull requests
([Running](running.md)), the PRs merge in a merge order, stacked ones moved on as their parents merge
([Landing](landing.md)), and you steer it: agents' questions go to whoever may answer them, heed's controller answers
what is within its authority, and what is yours waits in Needs you ([Steering](steering.md)). You watch it in the
agents pane and on its map, where a stuck worker is nudged and helped on its own ([Watching](watching.md)), and a done
swarm writes its end-of-build summary, from which one key starts a follow-up ([The summary](summary.md)).
:::

## Starting one

There are three ways in:

- `n` in Goals, with **start as a swarm** ticked: ⌘↩ goes on to the swarm form with the title and goal you typed.
- `:swarm.new` (on a session: from its prompt) opens the swarm form for a new goal.
- `:swarm.start`, or **Swarm this goal** in an empty swarm pane, swarms the goal under the cursor.

![The new swarm form](../../images/shots/goals/swarm-new.png)

| Field | What it is |
|---|---|
| Goal | A title and what done looks like (for a new goal; an existing one keeps its `GOAL.md`) |
| Where | The repos on this Mac it works in; the lead starts in the first |
| Team | The lead's agent and model, and the workers: agents, their models and how many of each |
| How much say you want | Approve the plan, then check in per phase; ask only when the plan changes (the default); or run to the end |
| Limits | Agents at once, hours, dollars. Reaching one pauses new work and asks you |

A click on an agent picks the next one; the model field is free text (empty: the agent's default). ⌘↩ makes the goal
if it is new, starts the swarm, and starts its lead; ⎋ leaves.

## The lead

The lead is a real session: heed starts it with Start work's machinery in the swarm's first repo, on the goal
(attached with origin `swarm`, never asked about), with the chosen agent and model, and with the `heed-goal` skill.
Its first prompt tells it to read `GOAL.md`, draft the plan with `heed goal plan propose` and ask what it cannot
decide with `heed goal ask` ([The lead and heed goal](lead.md)). While a swarm is going, the lead plans the goal
instead of the cheap-model planner, which comes back when the swarm ends.

The lead never changes the goal or the limits, and never approves its own plan. When the plan needs the goal to
change (a new criterion, a new non-goal) it says so, and that becomes a `GOAL.md` proposal that waits for you like any
other.

## On the goal's page

The goal's overview shows its swarm: its state and plan version, the tasks and estimate, what waits for you, and past
runs; once it runs, its progress (tasks done of all) and its agents at work against the cap. `S` opens the swarm's
plan ([The plan](plan.md)); `S` again goes back. The goal's row in the list says `swarm planning`, `swarm approved`,
`swarm running` and so on while one is going.

![A goal's swarm on its overview](../../images/shots/goals/swarm-goal-page.png)

`:swarm.stop` ends the goal's swarm: nothing more starts, its workers' tabs close (their worktrees stay), and its plan
and steering stay readable.
