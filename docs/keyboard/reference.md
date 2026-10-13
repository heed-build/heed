---
description: Every command and its default keys. Generated from the code.
---

# Key reference

Every command Heed has, with its default keys. Keys in parentheses apply in that mode or view only. Any
command can also be run by name on the command line (`:`), and any key changed in `config.toml`; see
[Customizing keys](customizing.md).

This page is generated from the code (`mise run shots`).

## Move & sessions

| Command | Keys | Does |
|---|---|---|
| `row.next` | `j`, `<Down>`, `j` (VISUAL) | next session / row |
| `row.prev` | `k`, `<Up>`, `k` (VISUAL) | previous session / row |
| `row.first` | `gg`, `gg` (VISUAL) | first session / row |
| `row.last` | `G`, `G` (VISUAL) | last session / row |
| `row.halfpage.down` | `<C-d>` | half a page down (ten rows) |
| `row.halfpage.up` | `<C-u>` | half a page up (ten rows) |
| `group.next` | `}` | first row of the next group (sidebar group, repo) |
| `group.prev` | `{` | first row of this group, or of the one before |
| `session.filter` | `/` | filter the current view (typed in the status bar) |
| `session.attention` | `ga` | next session needing you |
| `session.park` | `zz` | park session |
| `session.close` | `x` | close session, keep worktree |
| `session.delete` | `dd` (sessions) | delete session and its worktrees (asks first) |
| `session.import` `[path]` | `Iw` (sessions) | import a worktree Heed does not manage yet as a session |
| `session.import.path` | `Ip` (sessions) | import the worktree at a path (any repo, anywhere) |
| `session.pin` | `m` | pin / unpin session |
| `session.back` | `''` | back to previous session |
| `pin.jump` `<1-9>` | `'1`, `'2`, `'3`, `'4`, `'5`, `'6`, `'7`, `'8`, `'9` | jump to pinned session |
| `work.start` | `o` | start work |
| `work.again` | `O` | start work from this session's prompt |
| `view.history` | `gh` | history |

## Panes & tabs

| Command | Keys | Does |
|---|---|---|
| `pane.left` | `h`, `<C-w>h` | focus pane left |
| `pane.right` | `l`, `<C-w>l` | focus pane right |
| `pane.up` | `<C-w>k` | focus pane above |
| `pane.down` | `<C-w>j` | focus pane below |
| `pane.split.right` | `<C-w>v` | split right |
| `pane.split.below` | `<C-w>s` | split below |
| `pane.zoom` | `<C-w>z` | zoom pane |
| `pane.close` | `<C-w>q` | close pane |
| `tab.next` | `gt` | next tab |
| `tab.prev` | `gT` | previous tab |
| `tab.new` | `gn` | new tab with shell |

## Views & overlays

| Command | Keys | Does |
|---|---|---|
| `view` `<sessions|inbox|issues|prs|repos|history>` |  | switch view |
| `view.sessions` | `gs` | sessions |
| `view.inbox` | `gm` | inbox |
| `view.issues` | `gi` | issues |
| `view.prs` | `gp` | pull requests |
| `view.repos` | `gr` | repos & worktrees |
| `overlay.pr` |  | PR overlay for this session (toggle) |
| `overlay.item` | `go` | open the PR or issue under the cursor; in Sessions, the session's PR (toggle) |
| `overlay.diff` | `gd` | diff overlay: commits, staged, unstaged |
| `overlay.help` | `?`, `<D-/>`, `?` (VISUAL), `<D-/>` (VISUAL), `<D-/>` (INSERT), `<D-/>` (COMMAND) | keys & states |
| `overlay.close` | `<Esc>`, `<Esc>` (diff), `<Esc>` (issue), `<Esc>` (pr) | close overlay |
| `pr.next` | `]p` | next PR of this session |
| `pr.prev` | `[p` | previous PR of this session |
| `pr.session` | `gS` | jump from a PR to its session |
| `pr.track` `<url>` | `gU` | track a PR by URL |
| `jump.back` | `<C-o>` | back |
| `open.browser` | `gB` | open in browser |
| `open.reader` | `<CR>` | read inbox item, issue or PR |
| `cleanup.rules` |  | show the cleanup rules (Repos, with its rules panel) |
| `cleanup.sweep` | `gC` | run the cleanup sweep now |
| `inspector.toggle` | `zi` | collapse / expand the inspector |
| `sidebar.toggle` | `zs` | collapse / expand the sessions sidebar |
| `config.edit` |  | open config.toml in $EDITOR |
| `tutor` `[lesson]` | `<D-T>`, `<D-T>` (INSERT) | the tutor: pick a lesson, or start one by name (tour, sessions, prs…) |
| `tutor.back` |  | the tutor's previous step, the world as it was then |
| `tutor.skip` |  | skip the tutor's step |
| `tutor.exit` | `<D-.>`, `<D-.>` (INSERT) | leave the tutor; your sessions come back as they were |
| `tools.detect` |  | find git and gh again (login shell PATH, usual places, [tools]) |
| `app.quit` |  | quit Heed |
| `settings.open` | `<D-,>` | open Settings |
| `welcome` |  | show the getting-started checks again |

## Modes

| Command | Keys | Does |
|---|---|---|
| `mode.normal` | `<Esc>` (VISUAL), `<C-\\>` (INSERT), `<S-Esc>` (INSERT), `<Esc>` (COMMAND) | back to NORMAL |
| `mode.insert` | `i` | INSERT into the focused pane |
| `mode.visual` | `v`, `V` | VISUAL: select, then act |
| `mode.command` | `:` | COMMAND line |
| `mode.hint` | `f` | HINT: jump to anything |
| `hint.insert` | `F` | jump and enter INSERT |
| `command.submit` | `<CR>` (COMMAND) | run the command line |
| `command.complete` | `<Tab>` (COMMAND) | complete |

## Selection

| Command | Keys | Does |
|---|---|---|
| `select.toggle` | `<Space>` (VISUAL), `<Space>` (inbox), `<Space>` (issues) | toggle row |
| `history.reopen` | `R` (history) | reopen: resume, recreating the worktree if needed |
| `history.again` | `O` (history) | start a new session from this prompt |
| `history.outcome` | `t` (history) | cycle the outcome filter |
| `github.sync` | `r` (inbox), `r` (issues), `r` (pr), `r` (prs) | sync GitHub now |
| `items.start` | `s` (inbox), `s` (issue), `s` (issues) | start one session from the picked items |
| `items.add` | `a` (inbox), `a` (issue), `a` (issues) | add the picked items to the current session |
| `items.read` | `x` (inbox) | mark read |
| `items.filter` | `t` (inbox), `t` (issues) | cycle the filter chips |
| `issues.repo.next` | `<Tab>` (issues) | next repo in the Issues repo column |
| `issues.repo.prev` | `<S-Tab>` (issues) | previous repo in the Issues repo column |
| `issues.visibility` | `w` (issues), `w` (repos) | flip the repo under the cursor between all issues and only yours |
| `feedback.queue` | `<Space>` (pr) | queue / unqueue the item |
| `feedback.send` | `s` (pr) | send queued feedback to the session |
| `feedback.mode` | `m` (pr) | cycle auto-feed: off, ask, auto when idle |
| `feedback.watch` | `w` (pr) | pause / resume watching |
| `feedback.dismiss` | `x` (pr) | dismiss the item |
| `feedback.session` | `S` (pr) | start a new session from this PR |
| `diff.hunk.next` | `n` (diff) | next hunk |
| `diff.hunk.prev` | `N` (diff) | previous hunk |
| `diff.file.next` | `]f` (diff) | next file |
| `diff.file.prev` | `[f` (diff) | previous file |
| `diff.scope.next` | `<Tab>` (diff) | next scope: all, committed, staged, unstaged |
| `diff.scope.prev` | `<S-Tab>` (diff) | previous scope |
| `diff.commit` | `c` (diff) | show one commit (cycles) |
| `diff.split` | `t` (diff) | unified / split |
| `diff.ask` | `a` (diff) | ask the agent about this hunk |
| `diff.copy` | `y` (diff) | copy path:line |
| `diff.edit` | `e` (diff) | open the file in the editor |
| `repo.add` `<path>` |  | add a repo outside the scanned roots (kept in repo_paths) |
| `repo.scan` | `r` (repos) | refresh: rescan the repo roots |
| `worktree.new` | `o` (repos) | start work in the repo under the cursor |
| `select.remove` | `d` (VISUAL), `dd` (repos) | remove the selected worktrees, or the one under the cursor (asks first) |
| `select.pin` | `m` (VISUAL) | pin selected |
| `select.copy` | `y` (VISUAL) | copy paths |
| `select.open` | `o` (VISUAL), `<CR>` (repos) | open the worktree's session, importing it when it has none |
