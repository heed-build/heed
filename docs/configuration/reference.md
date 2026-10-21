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
# [repos."org/name"] admin_merge = true retries a refused merge with --admin, bypassing branch protection. Repo only.
# Extra instructions heed adds to its prompts, per org and per repo too (a repo's "" clears its org's): after get it
# green's feedback items, to the self-review's criteria, and after the issue text Start work begins from. They add to
# what heed sends, and the agent still reads the repo's own AGENTS.md or CLAUDE.md.
# green_instructions = "Resolve the review threads your changes addressed, and any that no longer apply."
# review_instructions = ""
# start_instructions = ""

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
# A macOS notification when a session starts needing you, unless Heed is in front showing that session. Several
# within a few seconds come as one. Open brings Heed forward on the session; a Claude permission prompt also gets
# Allow. Per state: asking (questions, a plan to approve) and blocked (a permission prompt).
enabled = true
asking = true
blocked = true

[summary]
# While you were away: what still waits on you, then what merged, how background runs ended, which agents
# finished, the reviews that arrived and the sessions that closed, by day. It opens on its own when you come back
# after this many hours away from the Mac or with heed quit (0: never on its own); gZ opens it any time.
away_hours = 8

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
# agent's session id), and [agents.<name>.profiles] of name = command line.
[agents.claude]
command = "claude"
plan = "--permission-mode plan"
resume = "--resume {id}"

# [agents.mytool]
# command = "mytool"
# prompt = "argument"
# Agents without hooks get their state read from the screen; patterns per state refine it (regex):
# [agents.mytool.patterns]
# blocked = "Allow this\?"
# working = "Thinking"

# Org and repo colors: teal, pink, lime, orange, periwinkle, sky. Repos inherit their org's.
# [orgs.elastic]
# color = "teal"
# issues = "all"

# Setup per repo (or per org): commands each new worktree runs before its agent starts, joined with &&. Unset, heed
# proposes what it detects (mise install when the repo uses mise, else its lockfiles' installs) and runs nothing
# until you approve it in Repos (S); [] runs nothing and stops the proposal. Files .worktreeinclude names (gitignored
# ones only) are copied from the main checkout into each new worktree either way.
# [repos."elastic/docs-builder"]
# setup = ["pnpm install"]

# Pinned tasks per repo, each run in its own pane; the exit code sets the tab's glyph. New sessions open them as
# tabs; ! picks one to run, from these and what the worktree offers (mise tasks, make targets, package.json scripts).
# [repos."elastic/docs-builder".tasks]
# test = "dotnet test"

# Hosts: machines heed drives over your own ssh (gH adds them from ~/.ssh/config or your tailnet). A host whose
# machine is on your tailnet goes over it, its ssh alias pointed at the machine's MagicDNS name; a machine running
# Tailscale SSH needs no key of yours. transport = "ssh" keeps a host off the tailnet.
# [hosts.devbox]
# ssh = "devbox"                   # an alias from ~/.ssh/config, or user@address; the name by default
# tailscale = "devbox"             # the machine on your tailnet, when its name differs
# transport = "ssh"                # ssh | tailscale; unset prefers the tailnet
# user = "you"                     # who to log in as over the tailnet, without an ssh alias
# repo_roots = ["~/code"]
# worktree_root = "~/code/wt"
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
