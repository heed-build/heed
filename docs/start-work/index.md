---
navigation_title: Start work
description: From a sentence to a running agent in its own worktree.
---

# Start work

`o` opens Start work. Describe the task; Heed picks the repo, names the branch, makes the worktree, opens a session and
starts the agent on your words.

![The Start work dialog: the prompt, the guessed repo, the worktree name, the agent, options and the command it will run](../images/shots/start-work/dialog.png)

The dialog has its own small modes, like Heed itself:

- **Typing** (INSERT, the default): keys go into the prompt or the worktree name. `⇥` moves to the next field.
- **Moving** (NORMAL, after `⎋`): `j` `k` or `⇥` move between fields, `h` `l` choose within one, `space` toggles,
  `i` or `↩` edits again.

| Key | |
|---|---|
| `⌘↩` | Start |
| `⌃n` / `⌃p` | Cycle the repo guess (or the agent, on the agent row) |
| `⌘V` | Paste into the prompt |
| `⎋` | Stop typing; again to cancel |

| Field | |
|---|---|
| **Prompt** | What you want done. It grows with what you type, up to a third of the window, then scrolls. |
| **Repo** | The guessed repo, and any others for a cross-repo session. See [Choosing repos](repos.md). The last chip makes it a [chat](../sessions/chats.md). |
| **Worktree** | The branch and folder name, from your first word. See [Branch names](branch-names.md). |
| **Agent** | Which agent starts, or a shell only. See [Agent and options](agent-and-options.md). |
| **Options** | Autostart, plan first, shell split. |

The bottom of the dialog shows the exact command the agent pane will run, and **Cancel** and **Start** buttons that do
what `⎋` and `⌘↩` do.

## With the mouse

Every part of the dialog takes a click, in either mode. Clicking the prompt or the worktree name edits it; clicking a
chip picks it as `space` would (a repo, `other repo…`, the chat chip, an agent, a folder kind or host); clicking a
switch flips it; clicking a row of the repo search adds that repo. Clicking a field's label moves there. Clicking
outside the dialog cancels it, as it does for the [floating panel](from-anywhere.md).

## Other ways in

- [From anywhere](from-anywhere.md): `⌃⌥Space` opens it over any app.
- [From GitHub](from-github.md): `s` on Attention items, issues or inbox items starts a session from them.
- [Starting again](again.md): `O` starts from a previous session's prompt.
