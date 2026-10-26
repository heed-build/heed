---
navigation_title: Home
description: Keep an eye on every agent. A keyboard-first macOS command center for agentic coding.
---

# Heed

Keep an eye on every agent.

Heed is a native macOS app for working with coding agents. It runs agents and shells in real terminals, gives each
task its own git worktree, and keeps the GitHub issues and pull requests around that task in view. It tells you which
agent needs you, and it gets you there in a keystroke. Everything else that wants you, on GitHub or from an agent, is
one feed: Attention. Work that outlives a session has a goal. What ended stays in History, with a timeline, a short
summary of each piece of work and a dashboard.

![The Sessions view: sessions grouped by what they need, an agent and a shell side by side, the inspector on the right](images/shots/home/sessions.png)

## Goals

Some work outlives one session: a feature, a migration, a cleanup. A [goal](goals/index.md) holds it. Its sessions,
chats and PRs belong to it, and its `GOAL.md` says what the goal is, what it is not and when it is done. `gG` opens
Goals.

- New work finds its goal on its own, and heed asks with one key when it is unsure
  ([How work finds its goal](goals/attach.md)).
- Items move across a board on evidence: a session on one, a review, a PR, a merge
  ([Items and the board](goals/items.md)).
- What the work records goes into `GOAL.md` as a new version you can undo; a change to what the goal is waits for you.
- Reviewers score the work against bars that fit the goal, and stranger walks time a first run; heed marks the goal
  done when every criterion and bar is met ([Quality bars](goals/quality.md)).
- Agents (claude and codex) read the goal first and keep it with `heed goal` ([Agents keep the goal](goals/cli.md));
  colleagues can follow it on GitHub, one issue with a sub-issue per item ([GitHub mirror](goals/github.md)).

## Also in Heed

- Start work guesses the repo and the branch name, with Apple's on-device model where it is available
  ([Smart guesses](start-work/repos.md#smart-guesses)).
- PRs that could merge say **Ready to merge**, and `zM` merges one now; the setup wizard proposes a repo's merge and
  green settings from its own history ([Setting up a repo](github/repo-setup.md)).
- Every command is in the menu bar and the right-click menus, with its key beside it; key hints are buttons, tabs drag
  and panes resize ([The mouse](keyboard/mouse.md)).
- Other apps and scripts drive Heed through its [control socket](reference/cli.md#the-control-socket).

## Where to go next

| | |
|---|---|
| [Getting started](getting-started/index.md) | Install Heed, see what the first run finds, learn the keys with the tutor, and walk through a first session. |
| [Concepts](concepts/index.md) | Sessions, agent states, worktrees and modes: the four ideas the rest builds on. |
| [Sessions](sessions/index.md) | The main view: moving around, typing into agents, panes and tabs, and chats. |
| [Start work](start-work/index.md) | From a sentence to a running agent in its own worktree. |
| [Agents](agents/index.md) | The agents Heed runs, how they report their state, and Heed's own model calls through them. |
| [GitHub](github/index.md) | Attention and its rules, pull requests watched until green and merged, and review feedback fed back to the agent. |
| [Worktrees](worktrees/index.md) | Every worktree of every repo, set up before the agent starts, removed when quiet. |
| [Goals](goals/index.md) | Work that outlives a session: `GOAL.md`, items on a board, reviewers and quality bars, personas, evaluations, the `heed goal` command and the GitHub mirror. |
| [History](history/index.md) | What ended: outcomes, a timeline by day, a ledger of summaries, a dashboard, and reopening. |
| [Keyboard](keyboard/index.md) | Every key, how keys work, and how to change them. |
| [Configuration](configuration/index.md) | `config.toml`, the Settings window, and every key with its default. |
