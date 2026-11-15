---
description: "History: the sessions and chats that ended, by day, each with its story; filters, every event, and reopening."
---

# History

`H` (or `:history`, `history.list`) shows History: the sessions and chats that ended, grouped by day,
newest first. Each day's header says what the day came to (`2 merged · 1 abandoned · 2 questions answered`).

![History: the filter column, the work that ended by day with its story under each, and the selected one in full](../images/shots/history/history.png)

A row is a piece of work: how it ended, its title and PR, repo, agent, how long it was open and its outcome in words.
The line under a row is its story, from heed's event log: started, PR opened, you answered, merged, worktree removed, each with its time. A chat that ended gets a quiet line of its own. So does anything that belongs to no session (a worktree made by hand). Events of a session that is still open stay in Sessions until the session ends.

| Outcome | |
|---|---|
| merged | Its PR merged |
| closed | You closed it, with a PR |
| abandoned | Closed without a PR |
| cleaned up | Cleanup removed its worktree |
| promoted | A [chat](../sessions/chats.md) that became work (`:promote`) |

The detail on the right shows the work under the cursor in full. It holds the prompt, what happened as a timeline, and how long the agent worked (from the states its hooks reported; `about` when heed read some from the screen). It also holds the [ledger](ledger.md)'s summary when there is one, and the agent's resume command. Heed keeps the prompt, the agent's
session id, the story and the agent's last message; the transcript belongs to the agent.

![A piece of work in full: its prompt, what happened, the ledger's summary and the resume command](../images/shots/history/detail.png)

## Filters

The column on the left narrows the list, and a click on any of it does what its key does.

![The filter column: what to show, outcome with counts, repo, where, removed worktrees](../images/shots/history/filters.png)

| Key | |
|---|---|
| `e` | Every event as its own line, or folded into its work again |
| `t` | Every outcome, then each one alone |
| `r` | Every repo, then each one |
| `w` | Everywhere, then this Mac, then each host |
| `K` | Every kind, then each one alone: sessions, worktrees, PRs, questions, chats |
| `c` | Show or hide removed worktrees |
| `{` `}` | The previous and next day |
| `/` | Search titles, prompts, branches and lines |

Each takes a name on the command line too: `:history.outcome merged`, `:timeline.kind worktrees`,
`:timeline.repo docs-toolkit`, `:timeline.where devbox`, `all` to go back.

## Every event

`e` unfolds every event of the last 30 days as its own line, on one vertical rule per day. This is what the timeline was (`:timeline` and `history.timeline` open History this way). `e` again folds them back into their work.

![Every event as its own line](../images/shots/history/every-event.png)

| Line | When |
|---|---|
| Session started, ended, parked, reopened | A session's life; ended says how (merged, closed, abandoned, cleaned up) |
| Worktree created, removed | A worktree appeared or went away, here or on a host |
| PR tracked, merged | A session started following a PR; the PR merged |
| You answered | You answered a question an agent asked |
| Chat started, closed | A [chat](../sessions/chats.md)'s life |

A solid ring is something that still exists. A **dashed ring** and a **struck-through name** mark a worktree that no
longer does. When heed [saved its work](../worktrees/removing.md#saved-first) before removing it, the line says so
("work saved") and the detail names the ref.

![Only worktrees: the removed ones struck through, one with its work saved](../images/shots/history/every-event-worktrees.png)

![A removed worktree's session in full: the work it saved, in its story](../images/shots/history/every-event-detail.png)

`R` (or `↩`) reopens the work under the cursor, or the session of the event under the cursor, as [Reopening](reopening.md) describes. `O` starts a new session from the work's prompt. Right-click a line for the same actions.
