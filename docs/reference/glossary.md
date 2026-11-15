---
description: Every term the heed docs use, in one or two lines, with a link to the page that explains it.
---

# Glossary

Each term means one thing, everywhere in the docs. The page that explains a term is linked.

## Work

| Term | Meaning |
|---|---|
| **Session** | One task: an agent working in a git worktree, the terminals around it, and the PRs it opens. [Sessions](../concepts/sessions.md) |
| **Chat** | A session with no repo and no worktree, for talking to an agent. [Chats](../sessions/chats.md) |
| **Worktree** | A git worktree. Every task gets its own, so agents never share a checkout. [Worktrees](../concepts/worktrees.md) |
| **Repo** | A git repository heed knows. Repos lists every repo with its worktrees. [Repos](../worktrees/index.md) |
| **Host** | A machine heed reaches over ssh or your tailnet. Agents there appear in the same window. [Hosts](../hosts/index.md) |
| **Agent** | A coding agent heed runs in a terminal: claude, codex, cursor, pi, opencode, gemini, or any command line agent. [Agents](../agents/index.md) |
| **Agent state** | What an agent is doing: working, blocked, asking, done, idle, limited or exited. [Agent states](../concepts/agent-states.md) |
| **Attention** | The one feed of everything on GitHub and from your agents that wants you. [Attention](../github/attention.md) |

## Goals

| Term | Meaning |
|---|---|
| **Goal** | Work that outlives one session. Sessions, chats and PRs belong to it, and its `GOAL.md` says what it is. [Goals](../goals/index.md) |
| **Item** | One piece of a goal's work, on a board. Evidence moves it through its stages. [Items and the board](../goals/items.md) |
| **Lane** | One task's row in a swarm's plan and summary: the worker that runs it, its waits and its stuck stretches. [The summary](../goals/swarms/summary.md) |
| **Swarm** | A goal worked by several agents at once, with a lead that keeps the plan. [Lanes and swarms](../goals/swarms/index.md) |
| **Lead** | The agent that drafts a swarm's plan and keeps it. [A swarm's lead](../goals/cli.md#a-swarms-lead) |
| **Persona** | A kind of person heed asks for a view: the Skeptic, the newcomer, the maintainer of your docs site. [Personas](../personas/index.md) |
| **Panel** | The personas that read a goal's plan in the wizard, each giving a verdict. [Your first goal](../goals/first-goal.md) |
| **Helper** | An agent heed starts for one PR, in a worktree of its own, beside your sessions. [Helpers](../autopilot/helpers.md) |

## Autopilot

| Term | Meaning |
|---|---|
| **Autopilot** | What heed does on its own: get PRs green, merge them, tidy up. `gw` shows where it is on and what it did. [Autopilot](../autopilot/index.md) |
| **Capability** | One thing Autopilot can do once it is on, such as getting PRs green or merging them. [Can do](../autopilot/index.md#can-do) |
| **Approval** | A permission an agent asks for. `gy` gathers the asks from every session. [Approvals](../autopilot/approvals.md) |

## Insights and memory

| Term | Meaning |
|---|---|
| **Ledger** | A short summary of each piece of work, kept after its worktree is gone. [Ledger](../insights/ledger.md) |
| **Campaign** | What a run of work was for. The Mindmap groups pieces of work into campaigns. [Mindmap](../insights/mindmap.md) |
| **Mindmap** | The ledger's work grouped into areas and campaigns, one Mindmap per org. [Mindmap](../insights/mindmap.md) |
| **Standup** | A report that answers your own questions from a Mindmap, on the days you choose. [Standup](../insights/standup.md) |
| **Audit** | What heed and your agents did outside this Mac (pushes, merges, comments, reviews, publishes), each with its cause, and the grants heed gave for good. [Audit](../insights/audit.md) |
| **Cause** | What started an action: you and a key, an Autopilot rule, a helper, a PR event, and the session it ran in. [Audit](../insights/audit.md#the-cause) |

## Decisions

| Term | Meaning |
|---|---|
| **Decider (System 1)** | The fast, small model that makes heed's quick calls (which repo, which branch, what next): Apple's on-device model, Hunch, or a model call. [Inference and decisions](../configuration/inference.md) |
| **Hunch** | A small model on your Mac that learns from your corrections. [Inference and decisions](../configuration/inference.md#hunch) |
