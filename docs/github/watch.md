---
description: "The Watch view: every PR your sessions track, what heed is doing for each, and what it has done."
---

# Watch

`gw` opens the Watch view: every pull request your sessions track, grouped by what it needs, with what heed is doing
for each and a log of what it has done.

![The Watch view: PRs by state, the selected PR's items and timeline, and the activity log](../images/shots/watch/view.png)

- **Left**, the PRs, most urgent first: *Needs you* (feedback and no session to send it to), *Stalled* (out of
  rounds: see below), *Failing* (a check failed, or a conflict), *Changes*,
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
| **Merge** | nothing is merged | `auto`: heed turns on GitHub's auto-merge, and GitHub merges once its requirements are met; `heed`: heed merges once [its rules](#heed-merges) hold (see [below](#get-it-merged)) |

Watching only reads from GitHub, so it is on by default.

## Get it merged

`zm` cycles merging for a PR: off, `auto`, `heed` (and turns watching on with it). Each repo with such PRs has a **merge queue**, and a run of the
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

### heed merges

With `merge = "heed"` heed does not hand the PR to GitHub's auto-merge (it turns it off if it is on) and merges itself,
once every rule holds. A run checks them again on the PR as it is then, and merges only that head commit
(`--match-head-commit`), so a push in between holds it for the next run.

| Rule | Holds when |
|---|---|
| Green | every [green rule](#green) holds |
| Reviewed after push | a human approved the head commit, or a trusted AI reviewer reviewed it (below) |
| Quiet | no new commit or review for `quiet_minutes` (5) |
| Gate checks | every check named in `gate_checks` passed on the head commit, required by GitHub or not |
| No hold label | none of `hold_labels` (`hold`, `do-not-merge`, `wip`) is on the PR |
| Self-review | with `self_review` set: the command approved the diff of the head commit |

A **trusted AI reviewer** (`trusted_reviewers`, e.g. `copilot-pull-request-reviewer`) counts as a review of the head
commit when it approved it, when it left a comment review none of whose threads is still open, or when it left no review
at all but its review check, named in `gate_checks`, passed on that commit.

The **self-review** is a command you choose, such as `claude -p`. heed passes it a prompt with the PR's description and
diff (`gh pr diff`, nothing is checked out) on stdin, and merges when its first line is `APPROVE`; `REQUEST_CHANGES:
<why>` holds the PR with that reason. It runs last, once every other rule holds, and once per head commit.

After merging, heed comments on the PR with each rule and what it found. When GitHub refuses the merge (branch
protection), the PR is held with GitHub's reason; `admin_merge = true` under `[repos."org/name"]`, and only there, retries
with `--admin`.

![A PR heed merges: the rules, and the one holding it](../images/shots/watch/heed.png)

## Keys

| Key | |
|---|---|
| `↩` | Open the [PR overlay](review-feedback.md) |
| `zw` | Watch or stop watching |
| `zg` | Cycle green: off, ask, auto |
| `zm` | Cycle merging: off, auto, heed |
| `C` | Ask Copilot to resolve the PR's merge conflicts and address its review comments |
| `zr` | Another round for a stalled PR |
| `zp` | Pause or resume |
| `v` | Select several, then `zp` pauses or resumes them all |
| `r` | Sync now |
| `R` | Run the PR's merge queue now |
| `gM` | Show the PR's merge queue |

The pilot keys are the same everywhere: in Watch, the PRs view and the PR overlay they act on that PR, and in
Sessions on every PR the session tracks. A choice made with them sticks to that PR; PRs you
never set follow the settings.

## While you work in a session

Heed sends nothing to a session you are working in. On its own it waits until you have not typed in the session for
`send_after_idle` (5 minutes; `0` for 20 seconds) and its agent is idle, so it never takes your agent between your own
prompts. While it holds back, the row says *waiting for you to step away*, and it sends once you have. `zg` with
items queued sends at once: asking for it yourself does not wait.

## A tab of its own

With `send_to = "tab"`, a PR's feedback goes to a dedicated agent instead of the session's: heed opens a tab next to
the session's own, named **get it green** (failing checks, review threads) or **get it merged** (conflicts with the
base), and starts the session's agent there with the feedback as its prompt.

![A get it green tab working beside the session's agent](../images/shots/sessions/helper-tab.png)

- It never takes your focus: the tab appears, the one you are on stays selected, and INSERT stays where it was. Its
  glyph in the tab strip is the helper's own state. `:pilot.helper` goes to it.
- It works in the session's worktree, so it takes turns with the session's agent: it starts once that agent is idle
  and you have stepped away (as above), and later rounds are typed into it once it is idle.
- Its state is its own. The session stays where it was in the sidebar, except that a helper asking you something, or
  blocked on a permission, puts the session in Needs you.
- When its PR is green (get it green) or merged (get it merged), and the helper is not mid-turn, heed closes the tab
  and logs it. A PR that turns green but then conflicts gets a get it merged tab next.
- Helper tabs do not come back after a relaunch; a PR that still needs work gets a fresh one on its next round.

## Stalled

Get it green sends up to `max_rounds` prompts (3) without a new approval; then it stops, and the PR is **stalled**.
It shows in its own group in Watch and in the sidebar, in red, with how many rounds it used.

![A stalled PR in the Watch view](../images/shots/watch/stalled.png)

A new approval starts the count again. `zr` gives the PR one more round now: heed sends what is open (on `auto`), and
stops again if that round brings no approval either. Stalled does not count toward what needs you in the Dock and the
menu bar: it waits on a reviewer.

## Pausing

A paused PR stays watched and keeps its state up to date, but heed sends nothing for it and it does not count as
needing you, and its merge queue leaves it alone. `zp` pauses for an hour (`[pilot] pause`); `:pilot.pause 4h`, `:pilot.pause forever` and
`:pilot.pause off` choose. The countdown shows on the row, and the pause ends by itself.

![Two PRs selected with v and paused with z](../images/shots/watch/paused.png)

## Elsewhere

The same state shows wherever a PR does: next to a session's PR count in the sidebar, on the inspector's PR card, in
the PRs view's **Watch** column, and by the PR number in Repos.

![The inspector's PR cards, each with what the pilot is doing for it](../images/shots/watch/inspector.png)

## Settings

The settings live in `[pilot]` (the pilot is what does the watching and the merging). `[pilot]` sets the
defaults; an org or a repo overrides any of them. Settings ▸ Pilot edits the defaults, and Settings ▸ Orgs & repos
the overrides.

```toml
[pilot]
watch = true         # read-only, so on
green = "ask"        # off, ask or auto
max_rounds = 3       # prompts without a new approval before it stops
send_after_idle = "5m" # nothing is sent while you work in the session: this long after your last keystroke
send_to = "session"  # session (its agent) or tab (a dedicated agent in its own tab)
pause = "1h"         # what zp pauses for
merge = "off"        # off, auto or heed
merge_schedule = "1h" # how often a repo's queue runs, or manual
update_branches = true
copilot_conflicts = false  # Copilot resolves merge conflicts
copilot_comments = false   # Copilot addresses review comments
reviewers = []             # e.g. ["copilot", "alice", "elastic/docs-team"]
quiet_minutes = 5          # merge = "heed": the rules
trusted_reviewers = []     # e.g. ["copilot-pull-request-reviewer"]
gate_checks = []
hold_labels = ["hold", "do-not-merge", "wip"]
# self_review = "claude -p"
# merge_method = "squash"  # unset: the first of squash, merge, rebase the repo allows

[orgs.employer]
watch = false        # not this org's PRs, by default

[repos."employer/main-service"]
admin_merge = true   # per repo only: retry a refused heed merge with --admin
watch = true         # but this repo's, yes
green = "auto"
merge = "auto"
```
