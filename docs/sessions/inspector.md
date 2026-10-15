---
description: "The inspector: the selected session's worktrees, its links (pull requests and issues) and agent events."
---

# The inspector

The inspector, on the right of the Sessions view, shows the selected session's surroundings.

![The inspector: worktrees with their upstream and status, links to pull requests and issues, agent events](../images/shots/sessions/inspector.png)

- **Worktrees**: each worktree's path, its upstream, how far ahead and behind it is, and whether it has uncommitted
  changes.
- **Links**: the session's pull requests, then its issues. Open PRs come first, then merged, then closed; each shows
  its checks bar, its review state, and what heed is doing about it. A merged or closed PR shrinks to its name and
  title: there is nothing left to watch. Issues show their title and whether they are open.
- **Agent events**: the latest states the agent reported, newest first. A turn's working steps show while it runs and
  fold away once it ends, leaving how it ended.

## Links

**Click a link** to open it here: a PR in the [PR overlay](../github/review-feedback.md), an issue in the
[reader](../github/reading.md). **⌘-click** opens it on GitHub. `go` opens the PR overlay from the keyboard. A
**right-click** on a PR card offers the pilot's commands for that PR alone ([right-click](../keyboard/mouse.md)).

A session's issues come from three places:

- its prompt's closing words: `Fixes #12`, `Closes org/repo#3`, `Resolves <issue URL>`. Start work from
  [Issues](../github/issues.md) writes these for you;
- the issues its PRs close, as GitHub reports them;
- `heed issue add <url>` from the agent, or `gI` (`:issue.add <url>`; the copied URL when you give none).
  `:issue.remove` takes one off.

With no PR and no issue yet, the inspector says what comes next. A pushed branch offers **Open a PR on GitHub**, the
compare page for the branch.

### Opening them in the browser

| Key | |
|---|---|
| `gB` | One link opens it. Several open a picker: `1`–`9` opens one, `j` `k` `↩` too, `a` opens all, `⎋` closes. None opens the repo. |
| `gl` | The same picker, even with one link |
| `gR` | The repo on GitHub (a session in several repos asks which) |

![gB on a session with three PRs and two issues](../images/shots/sessions/links-picker.png)

In the other views `gB` opens the item under the cursor and `gR` its repo.

Worktrees, links and runs each scroll on their own once they outgrow their share of the column, so a session with many
PRs never pushes its runs or agent events out of sight.

`zi` collapses and expands the inspector. It also gives way first when the window is narrow.
