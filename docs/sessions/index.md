---
navigation_title: Sessions
description: The Sessions view, part by part.
---

# Sessions

Every agent you run is a session, and the Sessions view shows all of them at once. The view is where heed opens (`gs`
from anywhere). It has four parts.

![The Sessions view with its sidebar, center and inspector highlighted](../images/shots/sessions/anatomy.png)

1. **The sidebar**: every session, grouped by what it needs from you. See [The sidebar](sidebar.md).
2. **The center**: the selected session's tabs and panes, real terminals running the agent and anything else.
   See [Panes and tabs](panes-and-tabs.md).
3. **The inspector**: the session's worktrees, pull requests and agent events. See [The inspector](inspector.md).
4. **The status bar**: the mode, the branch and pane, and the keys that matter right now.

Across the top, the title bar names the views with their keys, shows what you are looking at in the middle, and counts
the sessions waiting on you on the right.

## In this section

- [The sidebar](sidebar.md): every session, grouped by what it needs from you.
- [Moving around](moving-around.md): `j` and `k`, counts, pins and the jump to the next session that needs you.
- [Typing into agents](typing-into-agents.md): INSERT mode, and getting the keyboard back.
- [Panes and tabs](panes-and-tabs.md): split, move, zoom and close panes and tabs.
- [The inspector](inspector.md): a session's PRs, issues and what heed learned around it.
- [Pin, park, close, delete](pin-park-close-delete.md): what each one keeps.
- [Resuming sessions](resume.md): how sessions come back when heed starts.
- [Handing off](handoff.md): give a session to another agent when one hits its limit.
- [Chats](chats.md): sessions with no repo, for talking to an agent.
- [Away](away.md): what happened while you were gone.
- [Agents that outlive heed](zmx.md): zmx keeps agents running when heed quits.
- [Filtering](filtering.md): narrow the list with `/`.

**Next:** [Repos](../worktrees/index.md).
