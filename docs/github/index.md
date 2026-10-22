---
navigation_title: GitHub
description: Your inbox, issues and pull requests, synced through the GitHub CLI.
---

# GitHub

Heed talks to GitHub only through the [GitHub CLI](https://cli.github.com): it never asks for a token. Sign in once
with `gh auth login` and Heed keeps it in sync: what the view on screen shows every minute (`poll_seconds` under
`[github]`), the rest every five, and `r` syncs everything now. A tracked PR's details are fetched when you open it and
when its checks or review threads change.

| View | Key | Shows |
|---|---|---|
| [Attention](attention.md) | `gm` | Everything that wants you, one feed: notifications, issues, your PRs and agents waiting on you. `gi` opens it on Issues, `gp` on My PRs |
| [Inbox](inbox.md) | `:inbox` | Your notifications |
| [Issues](issues.md) | `:issues` | Issues assigned to you or mentioning you, and every issue in repos you watch |
| [Pull requests](pull-requests.md) | `:prs` | Your open pull requests and the ones your sessions track |
| [Watch](watch.md) | `gw` | The PRs your sessions track, what heed is doing for each, and what it has done |

From any of them you can [read](reading.md) an item in the app, [start a session](../start-work/from-github.md) from
it, and feed [review feedback](review-feedback.md) back to the agent working on it.

## When GitHub can't be reached

Heed keeps the last sync and keeps working. A banner says when the data was synced and why it is stale.

![Offline: showing what was synced, and why](../images/shots/github/offline.png)

Items in orgs your `gh` token is not authorized for (SAML single sign-on) are counted in the title bar ("· 49 hidden")
rather than shown. `gh auth refresh`, or authorizing the GitHub CLI for that org, brings them in.
