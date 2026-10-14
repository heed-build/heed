---
description: "The Watch view: every PR your sessions track, what heed is doing for each, and what it has done."
---

# Watch

`gw` opens the Watch view: every pull request your sessions track, grouped by what it needs, with what heed is doing
for each and a log of what it has done.

![The Watch view: PRs by state, the selected PR's items and timeline, and the activity log](../images/shots/watch/view.png)

- **Left**, the PRs, most urgent first: *Needs you* (stuck), *Failing* (a check failed, or a conflict), *Changes*,
  *Feeding* (sent to the agent, waiting for its push), *Pending* (checks running, or a draft), *Green*, *Passing* (not
  fetched in detail yet), *Paused*, *Done* (merged or closed) and *Not watched*. `{` `}` jump between groups.
- **Middle**, the PR under the cursor: one line on where it stands, its **green** checklist, its open items, and its
  **timeline**: everything heed noticed and did for it.
- **Right**, the **merge queues** with when each runs next, and the **activity** across all PRs, newest first (`zi`
  hides it).

## Green

A PR is **green** when GitHub has nothing left to object to in the code. The middle pane lists each rule with what it
found, and `:pilot.why` jumps here for the PR you are on:

| Rule | Holds when |
|---|---|
| Open | not merged or closed |
| Ready for review | not a draft |
| No conflicts | it merges cleanly into its base |
| Up to date | not behind the base, when the repo requires branches to be current |
| Checks pass | every required check passed (every check, when the repo requires none) |
| Threads resolved | no review thread is open |
| No changes requested | no reviewer is waiting on changes |

![The green checklist for a PR: which rules hold, and which one holds it back](../images/shots/watch/green.png)

What holds a PR back goes to its agent as an item, the same way review comments do: a failing check, and a conflict
("rebase on main, resolve the conflicts, run the tests and push"). For a failed GitHub Actions check heed saves the
failed step's log and the prompt points the agent at the file, so it reads the error rather than just "lint failed".

### Copilot does the work

Merge conflicts and review comments can go to GitHub's Copilot coding agent instead of your session's agent, so the
work spends Copilot's budget rather than your agent's tokens. Two options, off by default, per org and per repo too:

- `copilot_conflicts`: a PR that conflicts with its base.
- `copilot_comments`: new review comments.

With get it green on (`ask` or `auto`), heed asks on the PR, once per conflict and per comment. When both have
something, one comment asks for both:

> @copilot Please merge in main and resolve the conflicts, then address these review comments:
>
> 1. `RedirectFile.cs:88` (@reviewer): Anchor lookup is case sensitive.
>
> Make sure the build and tests still pass.

Copilot works in its own environment and pushes to the PR's branch. What it was asked shows as sent, so your agent does
not get it as well. Pull in your session's worktree before its agent pushes again. `C` asks Copilot for the PR you are
on, both kinds, whatever the options say.

heed asks only where Copilot can work: it checks that the repo lists Copilot among those an issue can be assigned to,
which is the case when the Copilot coding agent is on for the repo (any paid Copilot plan; on Business and Enterprise an
admin enables it). Elsewhere the work goes to your agent as before. Failing checks stay with your agent, and a branch
that is merely behind is the [merge queue](#get-it-merged)'s.

### Reviewers

`reviewers` names who heed asks to review a PR once it is open and not a draft: logins, teams (`org/team`), and
`copilot` for Copilot code review. Each is asked once per PR, never the PR's author. `:pilot.reviewers` asks now.

## Three levels

Each PR has three levels, each needing the one before:

| Level | Off | On |
|---|---|---|
| **Watch** | only the PR's summary from the regular sync | heed follows it: fetches its review threads and checks as they change, and shows its state everywhere |
| **Green** | items are shown, nothing is sent | `ask`: you queue items to send; `auto`: they go to the agent once it is idle (see [review feedback](review-feedback.md)) |
| **Merge** | nothing is merged | `auto`: heed turns on GitHub's auto-merge, and GitHub merges once its requirements are met (see [below](#get-it-merged)) |

Watching only reads from GitHub, so it is on by default.

## Get it merged

`M` turns merging on for a PR (and watching with it). Each repo with such PRs has a **merge queue**, and a run of the
queue goes through its PRs, oldest first:

| The PR | A run |
|---|---|
| is green | turns GitHub's auto-merge on, with the repo's merge method |
| waits on something GitHub itself requires (a required check, a required review) | turns auto-merge on: GitHub merges once that arrives |
| waits on something GitHub does not hold it for | waits: auto-merge there would merge at once, with checks still running |
| fell behind its base | brings it up to date (`update_branches`) |
| fails a green rule | holds it, and turns auto-merge off if it was on: GitHub might merge what the rule catches |
| is paused | holds it |

GitHub does the merging, so the repo has to allow auto-merge (Settings ▸ General ▸ Allow auto-merge); the queue says so
when it does not. Only PRs your sessions track are merged.

A queue runs every hour (`merge_schedule`), when merging is turned on, when one of its PRs turns green, and after one of
them merges, so the others get brought up to date. `R` in the Watch view runs the PR's queue now, `:merge.run all`
every queue. `gM` shows the PR's queue in the middle: its PRs with what the next run does to each, and every run with
what it did. `gM` again, or moving the cursor, goes back to the PR.

![A repo's merge queue: its PR, the next run, and the runs so far](../images/shots/watch/merge-queue.png)

## Keys

| Key | |
|---|---|
| `↩` | Open the [PR overlay](review-feedback.md) |
| `w` | Watch or stop watching |
| `m` | Cycle green: off, ask, auto |
| `M` | Merge on or off |
| `C` | Ask Copilot to resolve the PR's merge conflicts and address its review comments |
| `zz` | Pause or resume |
| `v` | Select several, then `z` pauses or resumes them all |
| `r` | Sync now |
| `R` | Run the PR's merge queue now |
| `gM` | Show the PR's merge queue |

`w`, `m`, `M` and `zz` work the same in the PRs view and the PR overlay. A choice made with them sticks to that PR; PRs you
never set follow the settings.

## Pausing

A paused PR stays watched and keeps its state up to date, but heed sends nothing for it and it does not count as
needing you, and its merge queue leaves it alone. `zz` pauses for an hour (`[pilot] pause`); `:pilot.pause 4h`, `:pilot.pause forever` and
`:pilot.pause off` choose. The countdown shows on the row, and the pause ends by itself.

![Two PRs selected with v and paused with z](../images/shots/watch/paused.png)

## Elsewhere

The same state shows wherever a PR does: next to a session's PR count in the sidebar, on the inspector's PR card, in
the PRs view's **Watch** column, and by the PR number in Repos.

![The inspector's PR cards, each with what the pilot is doing for it](../images/shots/watch/inspector.png)

## Settings

The settings live in `[pilot]` (the pilot is what does the watching and the merging). `[pilot]` sets the
defaults; an org or a repo overrides any of them, and Settings ▸ Pilot edits the defaults.

```toml
[pilot]
watch = true         # read-only, so on
green = "ask"        # off, ask or auto
max_rounds = 3       # prompts without a new approval before it stops
pause = "1h"         # what zz pauses for
merge = "off"        # off or auto
merge_schedule = "1h" # how often a repo's queue runs, or manual
update_branches = true
copilot_conflicts = false  # Copilot resolves merge conflicts
copilot_comments = false   # Copilot addresses review comments
reviewers = []             # e.g. ["copilot", "alice", "elastic/docs-team"]
# merge_method = "squash"  # unset: the first of squash, merge, rebase the repo allows

[orgs.employer]
watch = false        # not this org's PRs, by default

[repos."employer/main-service"]
watch = true         # but this repo's, yes
green = "auto"
merge = "auto"
```
