---
description: "The Watch view: every PR your sessions track, what heed is doing for each, and what it has done."
---

# Watch

`gw` opens the Watch view: every pull request your sessions track, grouped by what it needs, with what heed is doing
for each and a log of what it has done.

![The Watch view: PRs by state, the selected PR's items and timeline, and the activity log](../images/shots/watch/view.png)

- **Left**, the PRs, most urgent first: *Needs you* (stuck), *Failing*, *Changes*, *Feeding* (sent to the agent,
  waiting for its push), *Pending* (checks running), *Passing*, *Paused* and *Not watched*. `{` `}` jump between
  groups.
- **Middle**, the PR under the cursor: one line on where it stands, its open items, and its **timeline**: everything
  heed noticed and did for it.
- **Right**, the **activity** across all PRs, newest first (`zi` hides it).

## Three levels

Each PR has three levels, each needing the one before:

| Level | Off | On |
|---|---|---|
| **Watch** | only the PR's summary from the regular sync | heed follows it: fetches its review threads and checks as they change, and shows its state everywhere |
| **Green** | items are shown, nothing is sent | `ask`: you queue items to send; `auto`: they go to the agent once it is idle (see [review feedback](review-feedback.md)) |
| **Merge** | not built yet | |

Watching only reads from GitHub, so it is on by default.

## Keys

| Key | |
|---|---|
| `↩` | Open the [PR overlay](review-feedback.md) |
| `w` | Watch or stop watching |
| `m` | Cycle green: off, ask, auto |
| `zz` | Pause or resume |
| `v` | Select several, then `z` pauses or resumes them all |
| `r` | Sync now |

`w`, `m` and `zz` work the same in the PRs view and the PR overlay. A choice made with them sticks to that PR; PRs you
never set follow the settings.

## Pausing

A paused PR stays watched and keeps its state up to date, but heed sends nothing for it and it does not count as
needing you. `zz` pauses for an hour (`[pilot] pause`); `:pilot.pause 4h`, `:pilot.pause forever` and
`:pilot.pause off` choose. The countdown shows on the row, and the pause ends by itself.

![Two PRs selected with v and paused with z](../images/shots/watch/paused.png)

## Elsewhere

The same state shows wherever a PR does: next to a session's PR count in the sidebar, on the inspector's PR card, in
the PRs view's **Watch** column, and by the PR number in Repos.

![The inspector's PR cards, each with what the pilot is doing for it](../images/shots/watch/inspector.png)

## Settings

The settings live in `[pilot]` (the pilot is what does the watching, and later the merging). `[pilot]` sets the
defaults; an org or a repo overrides any of them, and Settings ▸ Pilot edits the defaults.

```toml
[pilot]
watch = true         # read-only, so on
green = "ask"        # off, ask or auto
max_rounds = 3       # prompts without a new approval before it stops
pause = "1h"         # what zz pauses for

[orgs.employer]
watch = false        # not this org's PRs, by default

[repos."employer/main-service"]
watch = true         # but this repo's, yes
green = "auto"
```
