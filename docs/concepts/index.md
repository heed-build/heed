---
navigation_title: Concepts
description: Sessions, agent states, worktrees and modes, the four ideas the rest of heed builds on.
---

# Concepts

Four ideas explain how heed works. Read them once, and the rest of the docs makes sense.

The sidebar shows all four at work. Each row is a session. Its glyph is the agent's state, and heed groups the rows by
that state. Each session works in its own worktree. The mode in the status bar says who gets your keys.

![The sidebar grouped by state: pinned, needs you, working, parked](../images/shots/concepts/states.png)

- [Sessions](sessions.md): an agent, its terminals and its worktree, with a state.
- [Agent states](agent-states.md): what each agent is doing, and whether the agent needs you.
- [Worktrees](worktrees.md): one per task, so agents never step on each other.
- [Modes](modes.md): who gets your keys, heed or the terminal.

The ideas connect in this order. A session holds an agent and a worktree. The agent has a state, and the state decides
where the session sits in the sidebar. The mode decides whether your next key goes to heed or to the agent's terminal.

The [glossary](../reference/glossary.md) defines every other term the docs use.

**Next:** [Start work](../start-work/index.md).
