---
description: "Autopilot: what heed can do on its own, where it is on, what it is doing now, and what it did this week."
---

# Autopilot

`gw` opens **Autopilot**: the one place that shows what heed can do on your behalf, where each of those is on and
where not, what heed is doing about it right now, and what it has done. Four views, each with its key, the same in all
four:

| View | Key | Count on its tab |
|---|---|---|
| **Can do** | `C` | (where `gw` lands) |
| **Where** | `W` | capabilities off somewhere |
| **Now** | `N` | PRs heed is working on or stopped on |
| **Done** | `D` | what heed did this week |

The strip's right side says how much heed took off your hands this week: the same number as Done's tab.

![Autopilot's tab strip, and what heed did this week](../images/shots/autopilot/tabs.png)

`view.watch` and `:watch`, from when this was the Watch view, open Autopilot too.

## Can do

A card for each thing heed does on its own once it is on. Each card has its icon, its key when it has one, one
sentence, a bar for how much of it is on (an ask-first repo counts half), and how often it acted this week.

![Can do: a card per capability, and the picked one's detail](../images/shots/autopilot/can-do.png)

| Card | What it does | Set where |
|---|---|---|
| **Green** | review comments and failing checks go to the PR's agent; heed checks again after each push | per repo: `green` (`off`, `ask`, `auto`), see [Get it green](watch.md#green) |
| **Merge** | merges green PRs, by GitHub's auto-merge or heed's own rules | per repo: `merge` (`off`, `auto`, `heed`), see [Get it merged](watch.md#get-it-merged) |
| **Copilot** | hands conflicts and review comments to GitHub's Copilot coding agent | per repo: `copilot_conflicts`, `copilot_comments` |
| **Reviewers** | asks the reviewers you name once a PR is ready | per repo: `reviewers` |
| **Cleanup** | removes worktrees idle for `idle_days` whose work is pushed | everywhere: `[cleanup] enabled`, see [Cleanup](../worktrees/cleanup.md) |
| **Goals** | puts new work on its goal, and asks when unsure | everywhere: `[goals] attach` |
| **Summaries** | writes Attention's catch-up summaries ahead of time | everywhere: `[attention] summaries` (`ahead`, `open`, `off`) |
| **Continue** | types `continue_prompt` into agents resumed mid-turn | everywhere: `[sessions] continue_prompt` (empty: off) |
| **Names** | names sessions from what they turn out to be about | everywhere: `[sessions] name_sessions` |

`h` `j` `k` `l` move between cards. The picked card's detail says what changes with it (**without** and **with**), how
it goes step by step, what it **never** does (its real limits: three rounds at most, never typing while you type, never
removing unpushed work), which repos have it on, and, when heed has a number for it, where it would help: *docs-website:
you sent 7 items to its agents by hand this week*.

- `y` turns it on where it would help most: the repo that nudge names, else the first repo where it is off. A global one
  is simply turned on.
- `Y` turns it on everywhere: the `[pilot]` default, with every org and repo override that says otherwise removed.
- `x` turns a global one off. `↩` shows what it did (Done, narrowed to it); `S` opens its Settings page.

The keys write config.toml as Settings does (`[repos."acme/docs-website"] green = "auto"`); a capability with no
ask-first (Merge, Copilot, Reviewers, Goals) says so instead of writing anything.

![The Cleanup card's detail](../images/shots/autopilot/can-do-cleanup.png)

## Where

Every repo against each capability: on (●), asks you first (◐) or off (○), and under it what it did there this week or
why it cannot work, such as *auto-merge off on GitHub* for a repo set to `merge = "auto"` that does not allow it. The
last column is the strongest thing heed saw that would help that repo.

![Where: repos by capability, and the cell under the cursor](../images/shots/autopilot/where.png)

`h` `j` `k` `l` move over the cells; the footer explains the one under the cursor. `y` turns it on, `a` makes it ask
first, `x` turns it off, `C` shows its card. `↩` opens the repo in [Repos](../worktrees/repos.md), `M` sets up merging
there. Cleanup, Goals and Summaries are set once for every repo, so their cells show the same value on every row.

![The footer for markgraph's merge cell](../images/shots/autopilot/where-merge.png)

## Now

What the pilot is doing, by card: **Stalled** first (heed stopped and says why, with the key out: `zr` one more round),
then **Green** (PRs being fixed, with the rounds used so far), **Merge** (PRs with merging on, with what the next run of
their queue does), **Copilot** (PRs Copilot was asked about) and **Not watched**. Merged and closed PRs move to Done.

![Now: the PRs by card, the PR under the cursor, and what else is running](../images/shots/autopilot/now.png)

The middle is the PR under the cursor: its green checklist, merge rules, items and timeline, described in
[Get it green and merged](watch.md). On the right (`zi` hides it), the merge queues with their next run, what cleanup
would remove next, summaries in flight, heed's goal asks, and the pilot's activity across PRs.

The [pilot keys](watch.md#keys) work on the PR under the cursor, `↩` reads it, `A` asks Copilot about it, `R` runs its
merge queue and `gM` shows it.

## Done

What heed did on its own, by day, newest first; each day says how many things, how many PRs merged and how many items
an agent's push fixed. Each line is an outcome with its capability's icon, and its repo and PR on the right.

![Done: what heed did this week, by day](../images/shots/autopilot/done.png)

`t` narrows it to one capability, `r` to one repo (the rail on the left counts each); `{` `}` move between days; `↩`
opens the line's PR, or its session.

![Done narrowed to Merge](../images/shots/autopilot/done-merge.png)

## Where the numbers come from

Autopilot counts only what heed records:

- **Green, Merge, Copilot, Reviewers**: the pilot's log, the same as Now's activity. What you did yourself (a send with
  `s` in the PR overlay, a Copilot ask with `C`, `zv`) is marked *by you* there and is not counted as heed's; sends you
  made by hand are what the Green nudge counts.
- **Goals**: heed's attach decisions that put something on a goal (Goals › Unassigned keeps them).
- **Summaries**: the catch-up summaries Attention keeps, by when each was written (ahead of time and on open alike).
- **Continue**: the line heed adds to a session's timeline when it types `continue_prompt`.
- **Names**: the renames on sessions heed still names (not those you titled yourself).
- **Cleanup**: heed keeps no record of a sweep apart from removing by hand, so the card shows what the next run would
  remove instead of a count.

A week is the last seven days. The pilot's log keeps at least the last 14 days.
