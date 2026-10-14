---
description: Which pull requests a session tracks, and how to add one.
---

# Tracking PRs

A session tracks the pull requests that are part of its work. A tracked PR shows in the session's sidebar row
("2 PR"), the [inspector](../sessions/inspector.md), the [Watch view](watch.md) and the
[PR overlay](review-feedback.md). The session's timeline says why each one is tracked.

## How a session picks them up

- **Its branches.** A PR opened from one of the session's branches, in one of its repos. The session follows its
  worktrees from branch to branch: merge the first PR, `git switch -c next` in the same worktree, and a PR from `next`
  is the session's too (the timeline says "now on next").
- **What its agent opened.** When the agent opens a PR (`gh pr create`, or a GitHub MCP `create_pull_request`), its
  hooks tell Heed at once, in any repo, so a companion change elsewhere is tracked without a sync. Only an opened PR
  counts: one the agent reads or links to is not. See [Hooks](../agents/hooks.md).
- **What links back.** A PR that mentions one the session tracks (GitHub's cross-reference), when it is yours, open,
  and newer than the session. Someone else's PR that mentions it is listed in the PR overlay under *Also mentions it*,
  with the `:pr.track` to add it.
- **By hand.** `gU`, or `heed pr add <url>` from inside a pane (see [The heed CLI](../reference/cli.md)).

| Key | |
|---|---|
| `gU` | Track a pull request by URL (or `:pr.track <url>`) |
| `:pr.untrack [url]` | Stop tracking one (the overlay's PR, or the session's only one); no rule adds it back |
| `]p` / `[p` | In the PR overlay, the session's next / previous PR |
| `gS` | From a pull request, jump to its session |
