---
description: Every key in config.toml with its default. Generated from the code.
---

# config.toml reference

`~/.config/heed/config.toml`, as Heed writes it the first time it opens: every key with its default and what
it does. Saving the file applies it right away; a mistake is reported in the status bar and the last good
config stays in use.

This page is generated from the code (`mise run shots`).

```toml
# Heed configuration. Saved changes apply right away; mistakes are reported in the status bar and the last good
# config stays in use. Settings (⌘,) edits this file too, except key bindings, which live only here.

[worktrees]
# Worktrees are created at <root>/<repo>/<name>.
root = "~/code/wt"
# Directories scanned (two levels deep) for repositories.
repo_roots = ["~/Projects", "~/code"]
# Repos outside the roots, added when you import one of their worktrees by path (I in Sessions, :import <path>).
repo_paths = []
# Branches get a prefix picked by the prompt's first word ("Fix broken anchors" → fix/broken-anchors), else this.
# "" means no prefix. The worktree folder uses - for /.
default_prefix = "feature"
# When heed first starts an agent in a repo, offer (once per repo) to trust it ahead of time: for Claude Code, so it
# does not ask in every new worktree, and for mise when the repo's config sets [env]. Local repos only.
offer_trust = true

[worktrees.prefixes]
fix = ["fix", "bug", "broken", "crash", "repair", "resolve"]
bump = ["bump", "upgrade", "update"]
chore = ["chore", "cleanup", "tidy", "remove", "rename"]
refactor = ["refactor", "restructure", "simplify"]
docs = ["docs", "doc", "document", "readme"]
test = ["test", "tests", "cover"]
perf = ["perf", "speed", "optimize", "faster"]
feature = ["add", "implement", "support", "create", "introduce", "build", "feature"]

[start_work]
# Where the Mac has Apple's on-device model (Apple Intelligence, macOS 26): it suggests the repo when the prompt
# names none, the branch name's words, and the prefix when the first word picks none. On this Mac only, never sent
# anywhere; your own picks and typing always win. Elsewhere, or false: the rules above alone.
smart_guesses = true

[sessions]
default_agent = "claude"
# On launch: ask which sessions to resume, resume them all, or none.
resume_on_launch = "ask"           # ask | always | never
# Typed into a resumed session that was mid-turn, once the agent is idle. "" turns it off.
continue_prompt = "Continue where you left off."
# Open a shell split beside the agent in new sessions (Start work can still toggle it per session).
shell_split = false
# Keep every pane's terminal alive in a zmx session, so agents keep running when heed quits, restarts or updates,
# and come back as they were: auto (zmx when it is installed and works; Settings > General shows its check),
# zmx, or none (panes end with heed).
persist = "auto"

[cleanup]
# Automatic cleanup, off by default. When on, worktrees with no activity (agent output, keystrokes, commits, PR
# events) for idle_days are removed, wherever they live. Dirty or unpushed work is never removed, nor a pinned
# session's.
enabled = false
idle_days = 14
delete_branch = true               # the local branch; the remote is left alone
ask_before_sweep = false
# Removing a worktree saves its commits (and uncommitted changes) as refs/heed/archive/<branch> first, so R in
# History can bring it back. Sweeps drop those older than this many days; 0 keeps them.
keep_archive_days = 90

[github]
# How often the view on screen refreshes from GitHub; the others refresh five times less often.
poll_seconds = 60

[pilot]
# Follow the PRs your sessions track: their review threads and failing checks, shown in the Watch view (gw).
# Read-only, so on; turn it off for an org or a repo under [orgs.<name>] or [repos."org/name"] (watch = false).
watch = true
# What happens to what a watched PR collects: off (shown only), ask (you queue it) or auto (sent to the agent
# once it is idle). Also per org and per repo.
green = "ask"
# Prompts sent without a new approval before get it green stops.
max_rounds = 3
# Where each round of get it green (or get it merged) goes: background (an agent in its own tab, worktree and branch,
# heed/get-it-green/<branch>, all removed when it is done) or session (the session's own agent, once it is idle and
# you have not typed in it for five minutes). Also per org and per repo.
run_in = "background"
# Which agent and model background runs use; empty: the session's agent and that agent's default model. Also per
# org and per repo.
agent = ""
model = ""
# Merge conflicts with the base are usually simple: background runs for them can use a cheaper agent and model.
# Empty: agent and model above. Also per org and per repo.
merge_agent = ""
merge_model = ""
# A run still working after this long is stopped.
run_timeout = "30m"
# How long zp pauses a PR: 30m, 1h, 4h, 1d, or forever.
pause = "1h"
# Get it merged: off; auto (heed turns on GitHub's auto-merge for a PR, and GitHub merges it once its own
# requirements are met); or heed (heed merges it itself once the rules below hold). Per org and per repo too, and M
# cycles one PR.
merge = "off"
# squash, merge or rebase; unset takes the first the repo allows, in that order.
# merge_method = "squash"
# How often a repo's merge queue runs (15m, 1h, ...), or manual (only :merge.run).
merge_schedule = "1h"
# Bring the queue's PRs that fell behind their base up to date on each run.
update_branches = true
# Hand work on a watched PR to GitHub's Copilot coding agent instead of your session's agent, sparing its tokens:
# merge conflicts, review comments, or both (one comment on the PR asks for both). Only where Copilot can work in
# the repo; elsewhere, and with these off, your agent gets them. Per org and per repo too.
copilot_conflicts = false
copilot_comments = false
# Who heed asks to review a PR once it is open and not a draft, once per PR: logins, "org/team", or "copilot".
reviewers = []
# merge = "heed" merges a PR when it is green, reviewed after its last push (a human approval, or a trusted AI
# reviewer's), quiet for quiet_minutes, its gate_checks passed, without a hold label, and, with self_review set,
# approved by that command. Each per org and per repo too.
quiet_minutes = 5
# AI reviewers whose review counts: an approval, a comment review with none of its threads open, or no review at
# all once its review check (named in gate_checks) passed on the head commit.
trusted_reviewers = []    # e.g. ["copilot-pull-request-reviewer"]
gate_checks = []
hold_labels = ["hold", "do-not-merge", "wip"]
# A command that reads the prompt and the PR's diff on stdin and answers APPROVE, or REQUEST_CHANGES: <why>.
# self_review = "claude -p"
# [repos."org/name"] admin_merge = true retries a refused merge with --admin, bypassing branch protection. Repo only,
# and only heed's own merges (merge = "heed"); merging now by hand follows force_merge below.
# Merging a PR now by hand (zM, or merge now on a PR that is ready to merge): ask shows the PR, the method and
# anything not met first; auto merges at once. Per org and per repo too.
merge_now = "ask"
# Merging now past what GitHub enforces (a required review, a required check), with --admin: offered only when you
# are an admin of the repo. off never offers it; ask lists exactly what is bypassed first; auto does not ask. Per
# org and per repo too.
force_merge = "ask"
# Extra instructions heed adds to its prompts, per org and per repo too (a repo's "" clears its org's): after get it
# green's feedback items, to the self-review's criteria, after the issue text Start work begins from, and to what
# heed asks its model calls ([llm]) for in a summary. They add to what heed sends, and the agent still reads the
# repo's own AGENTS.md or CLAUDE.md.
# green_instructions = "Resolve the review threads your changes addressed, and any that no longer apply."
# review_instructions = ""
# start_instructions = ""
# summary_instructions = ""
# Ask agents (claude, codex) to end their final message with a "heed-summary: ..." line, which then is the ledger's
# summary (History, L). Off by default; per org and per repo too.
summary_sign_off = false

[issues]
# Which issues the Issues view shows per repo: "involved" (assigned to you or mentioning you) or "all" open
# issues. Override per org ([orgs.<org>] issues = "all") or per repo ([repos."org/name"] issues = "involved");
# the most specific wins. w in Issues (I in Repos) flips the repo under the cursor.
default = "involved"

[ui]
# A menu bar item: an owl that shows how many sessions need you, with those sessions, Start work and Open Heed.
menu_bar = true
# The Dock icon shows the same: a badge in the state's colour (blocked, else asking) with the count.
dock_state = true

[notifications]
# A macOS notification when a session starts needing you (its agent, a helper tab, or a PR the pilot cannot send
# feedback for), unless Heed is in front showing that session. Several within a few seconds come as one. Open brings
# Heed forward on the session; a Claude permission prompt also gets Allow. Per state: asking (questions, a plan to
# approve) and blocked (a permission prompt).
enabled = true
asking = true
blocked = true
# Attention items a rule says to notify about (notify, or boost 3), several from one sync as one notification.
attention = true
# Only once it has needed you this long, so a prompt that clears itself stays quiet; 0 notifies at once.
grace_seconds = 30
# One reminder if it still needs you this long after the notification, then nothing until it comes back; 0: none.
reminder_minutes = 15

[attention]
# Quiet hours: no notifications from start to end, local time, 24-hour ("22:00-07:00"); "" for none. What needed
# you meanwhile is not notified when they end: Needs you and the Dock badge show it. macOS Focus applies as well.
quiet = ""
# What matters in Attention, one rule a line, first match wins: what to match, then boost 1-3, lower, ignore, pin
# or notify. Inputs: mention, review, assigned, ci, mine, agent, user:me, team:org/slug (team:? when unknown),
# requested:me|team, author (a login, me, bot, bot:name, human), label, repo, branch, kind, draft, ready,
# size >n, age >7d, turn mine|theirs, reason, any. Globs (*, ?) and a|b work in values. Ignored items stay
# under Muted for 30 days. Settings › Attention edits them and shows what an edit would change.
# rules = [
#   "mention user:me             boost 3",
#   "review requested:me         boost 2",
#   "mention team:acme/docs-eng  boost 2",
#   "mention team:acme/everyone  ignore",
#   "author bot:dependabot       ignore",
#   "label "blocker"             pin",
#   "agent blocked|asking        boost 3",
#   "ci branch:main              lower",
# ]

[summary]
# While you were away: what still waits on you, then what merged, how background runs ended, which agents
# finished, the reviews that arrived and the sessions that closed, by day. It opens on its own when you come back
# after this many hours away from the Mac or with heed quit (0: never on its own); gZ opens it any time.
away_hours = 8
# History's ledger (L in History): a short summary of each piece of work, kept after its worktree is gone, written
# by a cheap model through heed's model calls ([llm]). When: "pr_opened", "pr_merged", "worktree_removed" (the
# removal waits for it, 30 s at most), "idle" (no activity for idle_hours), "chat_closed". ledger.summarize writes
# one any time. Include: "summary", "decisions", "follow_ups", "files" (from git, no model).
when = ["pr_opened", "pr_merged", "worktree_removed", "idle"]
idle_hours = 24
include = ["summary", "decisions", "follow_ups", "files"]

[updates]
# Look for a new version of heed once a day (on GitHub, heed's releases). Each update is signed; heed installs
# only what its key signed, and Apple has notarized.
check = true
# ask: show what is new and install when you say so. auto: download in the background and install on quit.
install = "ask"                    # ask | auto

[usage]
# The inspector shows each session's model and tokens, as its agent's hooks report them, and a cost marked ≈: what
# the agent reported (opencode), else an estimate from the prices below. false leaves the cost out.
show_cost = true
# USD per million tokens, by model name prefix (the longest match wins): "input / output", or
# "input / output / cache read / cache write" (cache defaults: a tenth of input to read, 1.25× to write). None are
# built in, so with none set only reported costs show.
[usage.prices]
# "model-a" = "3 / 15"

[log]
# The call log (:log): every command heed runs, its GitHub calls and (later) its model runs, with how long each
# took and how it ended. Kept this many days per kind, and at most max_rows rows of each kind; pruned hourly.
shell_days = 7
github_read_days = 3
github_write_days = 90
llm_days = 30
decide_days = 30
max_rows = 50000

[llm]
# heed's own short model calls (summaries, typed decisions), made headless through the agent CLIs you are logged
# in to (claude, codex, gemini, opencode, pi, cursor), each with a cheap model, taking turns. No API keys: your
# logins are used as they are. Each call runs in an empty temporary directory with tools off and nothing saved, and
# shows in :log with which agent took it and why others were skipped. false: heed makes no model calls at all.
enabled = true
# A call still running after this long is stopped; this many run at once (more wait, the ones you asked for first).
timeout_seconds = 120
concurrency = 2
# An agent whose call failed is skipped for this long; one rate limited in a session, until its limit resets.
backoff_minutes = 10
# Per agent per day: background calls stop until tomorrow at this many calls, or once this many dollars were spent
# (counted where a cost is known: reported by the agent, or estimated from [usage.prices]). 0: no cap.
daily_calls = 100
daily_dollars = 1.0
# Which agent takes the calls: "auto" (every usable one, taking turns) or one name ("claude"). Unset: not chosen
# yet; calls take turns, and the title bar reminds you to set it up (Settings › Inference & decisions).
# agent = "auto"
# false: no reminder on launch while model calls or decisions are not set up, or their last test failed.
setup_reminder = true

[decisions]
# Who answers heed's typed questions (Attention's suggested weights, goal items, quality profiles): "local"
# (Apple's on-device model, free and on this Mac only, macOS 26 with Apple Intelligence), "hunch" (a Laya
# checkpoint on this Mac, see [hunch]), "model" (a model call through [llm]) or "off". Unset: a model call, and the
# title bar reminds you to choose.
# decider = "local"

[hunch]
# The Laya checkpoint Hunch runs, downloaded from Settings › Inference & decisions: "english" (the default) or
# "multilingual".
# checkpoint = "english"
# Learn from your corrections (Attention actions, goal attach answers, labelled screen snapshots): a head trained
# on this Mac, adopted only when it does no worse on examples it never saw. Unset: on once a model is downloaded.
# learn = true

[local]
# Screen snapshots for a local decision model to learn from: at each state an agent's hooks report (working,
# asking, blocked, idle, done), the cleaned last 30 lines of its pane, the agent and the state; now and then one
# while it works; and, unlabelled, states read from the screen. Kept in heed.sqlite on this Mac only, never sent
# anywhere and never in the call log; dropped after keep_days, the oldest first past 64 MB. Off by default.
record_screens = false
keep_days = 30

[goals]
# Sessions and chats on a goal are told so when they start or resume (claude, codex): which goal, and to read its
# GOAL.md first and keep to its Not the goal list. Claude gets heed's plugin (--plugin-dir) with the heed-goal
# skill, codex the same guidance in its instructions: keep the goal with the heed goal command. false: agents are
# not told.
tell_agents = true
# New sessions and chats find their goal on their own: from free signals (worktree and branch family, files, PRs,
# the prompt against GOAL.md, repo, recency), and a cheap model call when those are unsure. At attach_auto or
# more heed attaches (u undoes); from attach_ask it asks with one key in Attention; below, the work stays in
# Unassigned. Your corrections become lines in goals/attach.rules. attach_model = false: signals only.
attach = true
attach_auto = 0.85
attach_ask = 0.5
attach_model = true
# Reviewers look at a goal's work on their own when it changes (a PR opened, updated or merged, a new GOAL.md
# version) and nightly, only for the lenses the goal requires, and go quiet once at their bar until something
# new. This many runs per goal per day; past it heed asks in Attention. false: only when you press re-check.
auto_review = true
reviewer_runs_per_day = 6
# The agent reviewers run as. Empty: the agent of the goal's session the run's tab opens in.
reviewer_agent = ""
# heed goal item spawn: sessions (or background runs) an agent may start on a goal's items, at once and per day.
# Past either, heed asks in Attention (y starts them, n drops them).
spawn_concurrent = 2
spawn_per_day = 6
# The GitHub mirror (docs: goals/github): a goal can follow along as a meta issue with a sub-issue per item, in a
# tracker repo of its own (any repo you can triage, not necessarily one the work is in). heed writes there on its
# own once a goal's mirror is on (one key, M); colleagues' changes come back as asks and proposals. tracker: the
# repo a new goal gets ("org/name"); per org or repo: goals_tracker under [orgs.<name>] or [repos."org/name"].
# mirror: new goals mirror from the start (goals_mirror per org or repo). mirror_label: put on heed's issues.
tracker = ""
mirror = false
mirror_label = ""

[goals.bars]
# The lenses each kind of goal requires and the bar (0-10) each must reach before heed calls the goal done. A
# goal's profile is its stakes plus the flags that apply; it gets the highest bar of every row that applies. A row
# here replaces the built-in one. Per goal, pins in the Reviewers pane override these.
spike = "plan 5, code 6"
internal = "plan 6, code 7, tests 6"
product = "plan 7, code 7.5, tests 7, docs 6"
public-api = "plan 7, code 8, tests 7.5, docs 7, dx 8, security 7"
user-facing = "ux 7"
perf-sensitive = "perf 7"
security-sensitive = "security 8"

[goals.reviewers]
# The model each reviewer kind runs on: "best" (the agent's default) or "cheap" (its cheap model).
plan-critic = "best"
implementation = "best"
security = "best"
perf-prober = "cheap"
test-architect = "cheap"
docs-reader = "cheap"

[tools]
# Where git and gh are. Empty means detect: your login shell's PATH (fish, zsh, bash, nu), then the usual places
# (Homebrew, mise, nix, ~/.local/bin), then /usr/bin. Set a path when detection picks the wrong one.
git = ""                           # e.g. "/opt/homebrew/bin/git"
gh = ""
# The tailscale CLI, for hosts on your tailnet. Empty: the search path, then the Tailscale app's own binary.
tailscale = ""
# Directories searched first, for git, gh and agent commands alike.
path = []

# Agents. Built-ins (claude, codex, cursor, pi, opencode, gemini) can be overridden field by field; any other name
# is a custom agent. Fields: command, prompt (argument | stdin | paste | file), plan, resume ("{id}" is the
# agent's session id), and [agents.<name>.profiles] of name = command line. For heed's own model calls ([llm]):
# llm = false leaves an agent out, and llm_model picks its model (empty: a cheap one heed detects, haiku for claude).
[agents.claude]
command = "claude"
plan = "--permission-mode plan"
resume = "--resume {id}"
# llm = true
# llm_model = "haiku"

# [agents.mytool]
# command = "mytool"
# prompt = "argument"
# Agents without hooks get their state read from the screen; patterns per state refine it (regex):
# [agents.mytool.patterns]
# blocked = "Allow this\?"
# working = "Thinking"

# Org and repo colors: teal, pink, lime, orange, periwinkle, sky. Repos inherit their org's.
# [orgs.acme]
# color = "teal"
# issues = "all"

# Setup per repo (or per org): commands each new worktree runs before its agent starts, joined with &&. Unset, heed
# proposes what it detects (mise install when the repo uses mise, else its lockfiles' installs) and runs nothing
# until you approve it in Repos (S); [] runs nothing and stops the proposal. Files .worktreeinclude names (gitignored
# ones only) are copied from the main checkout into each new worktree either way.
# [repos."acme/docs-toolkit"]
# setup = ["pnpm install"]

# Pinned tasks per repo, each run in its own pane; the exit code sets the tab's glyph. New sessions open them as
# tabs; ! picks one to run, from these and what the worktree offers (mise tasks, make targets, package.json scripts).
# [repos."acme/docs-toolkit".tasks]
# test = "dotnet test"

# Hosts: machines heed drives over your own ssh (gH adds them from ~/.ssh/config or your tailnet). A host whose
# machine is on your tailnet goes over it, its ssh alias pointed at the machine's MagicDNS name; a machine running
# Tailscale SSH needs no key of yours. transport = "ssh" keeps a host off the tailnet.
# [hosts.devbox]
# ssh = "devbox"                   # an alias from ~/.ssh/config, or user@address; the name by default
# tailscale = "devbox"             # the machine on your tailnet, when its name differs
# transport = "ssh"                # ssh | tailscale; unset prefers the tailnet
# user = "you"                     # who to log in as over the tailnet, without an ssh alias
# repo_roots = ["~/code"]          # where its repos are, two levels deep; unset, heed asks after the first check
# worktree_root = "~/code/wt"      # where its worktrees go; :host.roots (ctrl-r in gH) asks again
# color = "teal"                   # teal, periwinkle, pink or sky

[keys]
# Leaves INSERT. It is also the terminal's quit signal, so pick something else if you need that.
insert_escape = "<C-\\>"
# Opens Start work in a floating panel over any app, wherever you are; "" turns it off. The panel's window title is
# "Heed Start Work", for window manager rules (yabai: app="^Heed$" title="^Heed Start Work$" manage=off).
global_start_work = "<C-M-Space>"
# Brings Heed to the front from any app; "" turns it off.
global_activate = "<C-M-h>"
# Shift+Escape leaves INSERT too; a plain Escape always goes to the terminal. [keys.insert] "<S-Esc>" = "" unbinds.

# Bindings per mode ([keys.normal], [keys.visual], ...) or per view ([keys.repos], [keys.inbox], [keys.history],
# [keys.diff], [keys.pr]), in vim notation, each naming a command (the same names : completes). "" unbinds.
# [keys.normal]
# "gC" = ""
# "<C-j>" = "row.next"
```
