# Get it green, get it merged

Status: **design, for review.** Nothing here is built beyond what "Today" describes.

Two flows over a session's pull requests:

- **Get it green**: keep a PR moving until GitHub would let it merge. Review comments and failing checks go to the
  agent that wrote the code, when it is idle, until the checks pass and the threads are resolved.
- **Get it merged**: once a PR is green, merge it, or make sure GitHub will. It never acts on a PR that is not green.
  It runs in batches, per repo, in a session of its own.

## Today

Most of get it green exists, as the PR "feedback pipeline" (`Sources/HeedCore/GitHub/Feedback.swift`):

- Every review thread and failing check of a tracked PR becomes an item: New → Queued → Sent → Addressed (the agent
  pushed) → Resolved (thread resolved, check passing).
- Auto-feed per PR: Off, Ask, Auto when idle. Queued items go to the agent as one prompt, only when it is idle and you
  have not typed in its pane in the last 20 seconds.
- It stops after three rounds without a new approval.
- A watched PR's details are fetched when its checks or threads move.

What is missing:

0. **Everything is watched, silently.** A new pipeline starts with watching on (`PullFeedback(watching: true)`), and a
   PR without one counts as watched. That default is right (watching only reads and shows; it never sends or changes
   anything), but nothing says so, and nothing lets an org or repo turn it off.
1. **You cannot see it.** The inspector's PR card always says "watching" (the word is hardcoded, whatever the state).
   Nothing in the sidebar, the PRs view or Repos shows which PRs are watched, in what mode, or what is happening.
2. **No green verdict.** Nothing says "this PR is done: checks pass, threads resolved, mergeable".
3. **Settings exist only per PR.** There is no default, and no org or repo level.
4. **No merging at all.**

## Three levels: watch, green, merge

Each needs the one before it:

| Level | Off | On |
|---|---|---|
| **watch** | heed shows the PR's summary (state, checks, review) from the regular sync, nothing more | heed follows it: fetches its detail when it moves, collects review threads and failing checks as items, computes the green verdict, shows its state everywhere |
| **green** | items are collected and shown, nothing is sent | `ask`: you queue items to send; `auto`: they go to the agent when it is idle |
| **merge** | a green PR shows "ready to merge" | `auto` or `heed`, below |

**Auto-watch.** Whether a PR is watched when a session starts tracking it comes from the settings: **on by default**,
because watching only reads from GitHub and shows what it finds; it never sends anything to an agent or touches the
PR. An org or a repo can turn it off (a huge repo you only track now and then), and it toggles per PR at any time (`w`
in the PR overlay, as today).
Turning green or merge on for a PR turns watching on with it; turning watching off pauses green and merge for that PR
without forgetting their modes.

## Green, precisely

A PR is **green** when all of these hold:

| | |
|---|---|
| Open, not a draft | |
| Mergeable | no conflicts with the base |
| Checks | every required check passed (GitHub's branch protection), or every check when none are required |
| Reviews | no unresolved review threads, and no "changes requested" outstanding |
| Up to date | when the repo requires branches to be up to date: not behind the base |

Every other PR is in one of these states, each shown with what it is waiting on:

| State | Meaning | What get it green does |
|---|---|---|
| **pending** | checks running | waits |
| **failing** | a check failed | feeds the failure to the agent (with the log's tail, see below) |
| **changes** | unresolved threads or changes requested | feeds the comments |
| **conflicted** | merge conflict, or behind when that is required | feeds "rebase on main and resolve" |
| **feeding** | items sent, waiting for the agent's push | waits |
| **stuck** | three rounds without progress, or no session to feed | says so; needs you |
| **green** | all of the above hold | nothing; hands over to get it merged |

## Get it green

The existing pipeline, made visible and given a verdict:

- **The verdict** above is computed on every detail fetch (needs `mergeable`, `mergeStateStatus`, required checks and
  `isDraft` added to the PR detail query).
- **Failing checks with their reason.** For GitHub Actions checks, the last lines of the failed step's log
  (`gh run view <id> --log-failed`, tail ~60 lines) go into the item, so the agent gets the error and not just
  "build failed".
- **Conflicts** become an item of their own: "rebase on the base branch and resolve the conflicts".
- **Modes:** `off`, `ask` (items wait for you to queue them: today's Ask), `auto` (today's Auto when idle).
- **No session to feed** (a PR you track, but no agent session works on it): the PR shows **stuck: no session**, and
  `S` in the PR overlay starts one from the PR, as it does today.

## Get it merged

Requires get it green to be on for the PR (any mode but `off`), and only ever acts on a **green** PR. Three modes:

| Mode | What heed does once the PR is green |
|---|---|
| `off` | nothing; the PR shows "green, ready to merge" and counts as needing you |
| `auto` | makes sure **GitHub auto-merge** is enabled (`gh pr merge --auto --<method>`), and reports when GitHub merged it. GitHub keeps the final say; branch protection is respected |
| `heed` | heed merges itself, when the merge rules below pass |

`auto` can be set as soon as get it green is on: GitHub only merges once its own requirements are met. If a repo does
not allow auto-merge, the PR says so and heed does nothing.

### Merge rules for `heed`

All must hold, checked again just before merging:

1. **Green** (above).
2. **Reviewed after the last push.** At least one approving review on the current head commit, from a human, or from
   one of the repo's `trusted_reviewers` (for AI reviewers such as Copilot or CodeRabbit; a trusted reviewer's
   COMMENTED review with no unresolved threads counts as approval). With no trusted reviewers configured, only humans
   count.
3. **Quiet.** No new comment, review or push for `quiet_minutes` (default 5), so a reviewer still writing is not
   merged over.
4. **Gate checks**, when set: named checks (for example an AI review check) that must have run and passed on the head
   commit, in addition to the required ones.
5. **Not held.** No `hold` or `do-not-merge` label (configurable).
6. **Self-review**, when on: a local agent reads the diff and answers APPROVE or BLOCK (below). BLOCK keeps the PR out
   until its next push.

Then `gh pr merge --<method>` (the repo's allowed method: squash, merge or rebase, from `merge_method` or what the
repo allows). Branch protection still applies: if it refuses (for example a missing human approval), the PR shows
why. Only with `admin_merge = true` for that repo does heed retry with `--admin` to bypass it: **off by default, and
only per repo**, never as an org default.

After merging: the PR's session records it, the merge session logs it, and a comment goes on the PR saying what
merged it and why ("green; approved by copilot after the last push; quiet 5m; self-review approved"), so the history
explains itself.

### Self-review

Optional (`self_review = "claude"`, or any configured agent). Heed runs the agent once, headless, in the merge
session's pane, with the PR's diff (`gh pr diff`) and a fixed prompt: review for correctness, security and scope; end
with `APPROVE` or `BLOCK: <reason>`. Five minutes at most; no answer counts as BLOCK. It is shown in the merge session,
so you can read what it thought. Agents that cannot run headless are not offered.

## The merge session

Get it merged runs as **one session per repo**, created when a repo first has a PR with merging on:
`Merge queue · elastic/docs-builder`.

- It sits in the sidebar in a **Merging** group, with the next run's time ("next 14:00") and what it did last
  ("merged 2, waiting on 1").
- Its main pane is a **run log** heed writes: per run, a table of the repo's PRs with merging on, each with its
  verdict, the rule that held it back if any, and what was done. A second pane is where self-reviews run.
- **Batches:** a run takes every PR of the repo with merging on (tracked by a session or not), oldest first. For each:
  re-check green and the merge rules, then act (enable auto-merge, merge, or skip with the reason). After a merge, the
  others are often behind; with `update_branches = true` heed updates them (`gh pr update-branch`), their checks run
  again, and they are picked up next run.
- **Schedule:** hourly by default (`merge_schedule`), per repo, staggered so repos do not all run at :00. A run also
  happens when a PR in the repo turns green, if the last run is more than `quiet_minutes` ago (so a green PR does not
  wait an hour, but a busy repo is not rerun on every event).
- **Now:** `:merge.run` runs the current repo's queue (`:merge.run all` every repo), `r` in the merge session too.
- Closing the merge session pauses merging for that repo; it comes back with `:merge.queue`.

## Settings

The same shape as `issues` today: a default, then `[orgs.<org>]`, then `[repos."org/name"]`, then a per-PR override
set in the PR overlay. The most specific wins, for every key (`watch`, `green`, `merge` and the merge rules).

A per-PR choice sticks: changing a repo's settings later does not undo a PR you turned on or off by hand. PRs you never
touched follow the settings as they change. (Today's pipelines have no such mark; on upgrade they are treated as
untouched. With `watch = true` the default, nothing changes for them unless an org or repo turns watching off.)

```toml
[pilot]
watch = true                  # follow newly tracked PRs; read-only, so on unless an org or repo turns it off
green = "ask"                 # off | ask | auto (only for watched PRs)
max_rounds = 3
merge = "off"                 # off | auto | heed
merge_method = "squash"       # squash | merge | rebase (falls back to what the repo allows)
merge_schedule = "hourly"     # hourly | every 15m | manual
quiet_minutes = 5
trusted_reviewers = []        # e.g. ["copilot-pull-request-reviewer[bot]", "coderabbitai[bot]"]
gate_checks = []              # checks that must pass on the head commit, beyond the required ones
hold_labels = ["hold", "do-not-merge"]
self_review = "off"           # off | claude | codex | …
update_branches = true

[orgs.elastic]
green = "auto"
merge = "auto"                # GitHub auto-merge, GitHub decides

[orgs.employer]
watch = false                 # an org that should not be followed by default

[repos."elastic/kibana"]
watch = false                 # a repo overrides its org: too big to follow every PR

[repos."employer/main-service"]
watch = true                  # a main working repo, though its org says off

[repos."nullean/heed"]
merge = "heed"
trusted_reviewers = ["copilot-pull-request-reviewer[bot]"]
self_review = "claude"
# admin_merge = true          # only ever per repo
```

Settings gets a **Pilot** section that edits these, and Repos' cleanup-rules panel gains the repo's pilot settings
when the cursor is on it.

## Seeing it

The part missing today, in every place a PR shows:

- **Not watched** is visible too: an unwatched PR shows its summary dimmed with "not watched · w to watch", so it is
  never unclear whether heed is following it.
- **Sidebar:** a session row with a watched PR gets a small state mark after the PR count: `● green`, `⟳ feeding`,
  `✕ failing`, `⚠ stuck`, `⇢ merging`. Stuck counts as needing you.
- **Inspector:** the PR card's hardcoded "watching" becomes the real line: the green mode and state, what is queued or
  sent, the round ("round 1 of 3"), and the merge mode and next run ("merge: heed · next run 14:00").
- **PRs view:** three columns, **Watch**, **Green** and **Merge**, with mode and state; a `watched` chip filters to
  watched PRs.
- **Repos:** a worktree row shows its PR's state mark.
- **Title bar:** next to "1 blocked · 1 asking": "2 green · 1 stuck" when any are watched.
- **Menu bar and Dock:** "merged nullean/heed#12" as a notification line; stuck PRs count with what needs you.

## Commands and keys

All are named commands (`:` reaches them, config can bind them):

| Command | Key | |
|---|---|---|
| `pilot.watch` | `w` in the PR overlay (today's key), and in the PRs view | watch or stop watching the PR |
| `pilot.green` | `m` in the PR overlay and PRs view (today's auto-feed key) | cycle the PR's green mode |
| `pilot.merge` | `M` in the PR overlay and PRs view | cycle the PR's merge mode |
| `pilot.why` | `?` on a PR row, or `:pilot.why` | what holds the PR back, rule by rule |
| `merge.run [repo\|all]` | `r` in a merge session | run a repo's merge queue now |
| `merge.queue [repo]` | `gM` | go to (or start) the repo's merge session |

`gM` and `M` are free today; `m` in the PR overlay already cycles auto-feed, so it keeps its meaning.

## What it will not do

- Merge anything not green, a draft, or a PR with a hold label.
- Bypass branch protection unless that repo has `admin_merge = true`.
- Merge PRs it does not track: only PRs of your sessions, or PRs you track (`gU`), in repos where merging is on.
- Push to the base branch, or resolve conflicts itself; conflicts go to the agent.

## Phases

1. **Seeing it** and the settings hierarchy: the real inspector line, sidebar and PRs view marks, `[pilot]` with org
   and repo levels, `watch` on by default and switchable per org and repo, green modes replacing auto-feed (same
   behaviour). Small; fixes today's complaint.
2. **Green verdict**: mergeability, required checks and conflicts in the detail query; failing check logs; the
   conflicts item; `pilot.why`.
3. **Merge: `auto`** with merge sessions, the scheduler, `merge.run`, the run log.
4. **Merge: `heed`**: the merge rules, trusted reviewers, gate checks, quiet window, self-review, `admin_merge`, the
   explaining PR comment.

## Open questions

1. **Names.** `pilot` for the settings and commands ("autopilot for PRs"), or plain `green` / `merge` sections?
2. **Trusted reviewer comments.** Is a trusted AI reviewer's COMMENTED review (no threads) enough, or only APPROVED?
3. **Self-review in its own worktree?** Reading `gh pr diff` needs no checkout; a checkout would let it run tests too,
   at the cost of time and disk.
4. **Non-session PRs.** Should merging also cover your open PRs that no session tracks (merging works without an
   agent; greening does not)?
