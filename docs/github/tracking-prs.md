---
description: Which pull requests a session tracks, and how to add one.
---

# Tracking PRs

A session tracks the pull requests opened from its branches: Heed picks them up as GitHub reports them. A tracked PR
shows in the session's sidebar row ("2 PR"), the [inspector](../sessions/inspector.md), and the [PR overlay](review-feedback.md).

| Key | |
|---|---|
| `gU` | Track a pull request by URL (or `:track <url>`) |
| `]p` / `[p` | In the PR overlay, the session's next / previous PR |
| `gS` | From a pull request, jump to its session |

An agent can add one too, from inside its pane: `heed pr add <url>` (see [The heed CLI](../reference/cli.md)).
