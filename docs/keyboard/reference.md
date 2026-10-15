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
| `filter.clear` |  | clear the current view's filter |
| `session.attention` | `ga` | next session needing you |
| `session.park` | `zz` | park session |
| `session.close` | `x` | close session, keep worktree |
| `session.delete` | `dd` (sessions) | delete session and its worktrees (asks first) |
| `session.import` `[path]` | `Iw` (sessions) | import a worktree Heed does not manage yet as a session |
| `session.import.path` | `Ip` (sessions) | import the worktree at a path (any repo, anywhere) |
| `session.pin` | `m` | pin / unpin session |
| `session.back` | `''` | back to previous session |
| `session.open` `<words>` |  | go to the session matching these words |
| `pin.jump` `<1-9>` | `'1`, `'2`, `'3`, `'4`, `'5`, `'6`, `'7`, `'8`, `'9` | jump to pinned session |
| `work.start` | `o` | start work |
| `work.start.panel` |  | start work in the floating panel, as the global shortcut does |
| `resume` |  | pick up where you left off: the sessions to resume, as on launch |
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
| `tab.close` | `<C-w>c` | close the tab, every pane in it |
| `tab.next` | `gt` | next tab |
| `tab.prev` | `gT` | previous tab |
| `tab.new` | `gn` | new tab with shell |
| `tab.go` `<n>` |  | go to tab n |
| `task.run` `[name]` | `!` | run a task in a tab of its own: pinned, mise, make, package.json (no name: pick one) |
| `task.refresh` |  | read the session's tasks again (mise, make, package.json) |

## Views & overlays

| Command | Keys | Does |
|---|---|---|
| `view` `<sessions|inbox|issues|prs|watch|repos|history>` |  | switch view |
| `view.sessions` | `gs` | sessions |
| `view.inbox` | `gm` | inbox |
| `view.issues` | `gi` | issues |
| `view.prs` | `gp` | pull requests |
| `view.watch` | `gw` | watch: the PRs your sessions track, what heed does for each and has done |
| `view.repos` | `gr` | repos & worktrees |
| `overlay.pr` |  | PR overlay for this session (toggle) |
| `overlay.item` | `go` | open the PR or issue under the cursor; in Sessions, the session's PR (toggle) |
| `overlay.diff` | `gd` | diff overlay: commits, staged, unstaged |
| `overlay.help` | `?`, `<D-/>`, `?` (VISUAL), `<D-/>` (VISUAL), `<D-/>` (INSERT), `<D-/>` (COMMAND) | keys & states |
| `overlay.close` | `<Esc>`, `<Esc>` (diff), `<Esc>` (issue), `<Esc>` (pr) | close overlay |
| `pr.next` | `]p`, `l` (pr), `<Right>` (pr) | next PR of this session |
| `pr.prev` | `[p`, `h` (pr), `<Left>` (pr) | previous PR of this session |
| `pr.session` | `gS` | jump from a PR to its session |
| `pr.track` `<url>` | `gU` | track a PR by URL |
| `pr.untrack` `[url]` |  | stop tracking a PR in this session (no rule adds it back) |
| `jump.back` | `<C-o>` | back |
| `open.browser` | `gB` | open in the browser: the item under the cursor; in Sessions its PR or issue (a picker when there are several, its repo when there are none) |
| `open.repo` | `gR` | open the repo under the cursor on GitHub |
| `links.pick` | `gl` | pick one of the session's PRs and issues to open in the browser |
| `issue.add` `[url]` | `gI` | link an issue to the session (its URL, or the copied one) |
| `issue.remove` `[url]` |  | take an issue off the session |
| `open.reader` | `<CR>` | read inbox item, issue or PR |
| `cleanup.rules` |  | show the cleanup rules (Repos, with its rules panel) |
| `cleanup.sweep` | `gC` | run the cleanup sweep now |
| `inspector.toggle` | `zi` | collapse / expand the inspector |
| `sidebar.toggle` | `zs` | collapse / expand the sessions sidebar |
| `config.edit` |  | open config.toml in $EDITOR |
| `tutor` `[lesson]` | `<D-T>`, `<D-T>` (INSERT) | the tutor: pick a lesson, or start one by name (tour, sessions, prs…) |
| `tutor.hide` `[all]` |  | hide the title bar's tutor reminder for this lesson (all: every reminder) |
| `host.open` | `gH` | hosts: the ones heed drives over ssh, and ones from ~/.ssh/config to add |
| `host.filter` `[host]` | `@` | narrow the view to one host (@devbox) |
| `agents.stop` |  | stop every agent and shell in every pane (with [sessions] persist = "zmx") |
| `tutor.back` |  | the tutor's previous step, the world as it was then |
| `tutor.skip` |  | skip the tutor's step |
| `tutor.exit` | `<D-.>`, `<D-.>` (INSERT) | leave the tutor; your sessions come back as they were |
| `update.check` |  | look for a new version of heed now (also :update) |
| `tools.detect` |  | find git and gh again (login shell PATH, usual places, [tools]) |
| `app.quit` |  | quit Heed |
| `settings.open` `[section]` | `<D-,>` | open Settings, on a section (general, agents, colors, cleanup, pilot, keys) |
| `app.activate` |  | bring Heed's window to the front, as the global shortcut does |
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
| `command.complete` | `<Tab>` (COMMAND), `<Down>` (COMMAND) | complete, or the next match |
| `command.complete.prev` | `<S-Tab>` (COMMAND), `<Up>` (COMMAND) | the previous match |

## Selection

| Command | Keys | Does |
|---|---|---|
| `select.toggle` | `<Space>` (VISUAL), `<Space>` (inbox), `<Space>` (issues), `<Space>` (prs), `<Space>` (watch) | toggle row |
| `history.reopen` | `R` (history) | reopen: resume, recreating the worktree if needed |
| `history.again` | `O` (history) | start a new session from this prompt |
| `history.outcome` | `t` (history) | cycle the outcome filter |
| `github.sync` | `r` (inbox), `r` (issues), `r` (pr), `r` (prs), `r` (watch) | sync GitHub now |
| `items.start` | `s` (inbox), `s` (issue), `s` (issues) | start one session from the picked items |
| `items.add` | `a` (inbox), `a` (issue), `a` (issues) | add the picked items to the current session |
| `items.read` | `x` (inbox) | mark read |
| `items.filter` | `t` (inbox), `t` (issues) | cycle the filter chips |
| `issues.repo.next` | `<Tab>` (issues) | next repo in the Issues repo column |
| `issues.repo.prev` | `<S-Tab>` (issues) | previous repo in the Issues repo column |
| `issues.repo` `[name]` |  | show one repo's issues (no name: every repo) |
| `issues.visibility` | `w` (issues), `w` (repos) | flip the repo under the cursor between all issues and only yours |
| `feedback.queue` | `<Space>` (pr) | queue / unqueue the item |
| `feedback.send` | `s` (pr) | send queued feedback to the session |
| `feedback.mode` |  | pilot.green, by its former name |
| `feedback.watch` |  | pilot.watch, by its former name |
| `pilot.why` | `z?` | what holds the PR back from green, rule by rule (in the Watch view) |
| `pilot.watch` | `zw` | watch or stop watching the PR (or the picked PRs) |
| `pilot.green` | `zg` | cycle get it green for the PR: off, ask, auto |
| `pilot.run` | `gb` | show the session's running get it green / get it merged run |
| `pilot.run.stop` | `zx` | stop the session's running get it green / get it merged run |
| `pilot.retry` | `zr` | one more round of get it green for a stalled PR (or the picked PRs) |
| `pilot.copilot` | `C` (pr), `C` (watch) | ask GitHub's Copilot coding agent to resolve the PR's conflicts and address its comments |
| `pilot.reviewers` | `zv` | ask the PR's configured reviewers ([pilot] reviewers) to review it |
| `pilot.merge` | `zm` | get it merged for the PR (or the picked PRs): off or auto |
| `merge.run` `[repo|all]` | `R` (watch) | run a repo's merge queue now (no name: the PR's repo; all: every queue) |
| `merge.queue` `[repo]` | `gM` | show a repo's merge queue and its runs (no name: the PR's repo) |
| `pilot.pause` `[duration]` | `zp`, `zp` (VISUAL) | pause the PR (or the picked PRs), or resume: 30m, 1h, 4h, 1d, forever, off |
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
| `setup.review` | `S` (repos) | the setup heed detected for the repo's new worktrees: approve, edit or never |
| `setup.approve` |  | approve the detected setup for the repo's new worktrees |
| `setup.never` |  | no setup for the repo's new worktrees, and no more proposals |
| `setup.edit` |  | edit the repo's setup commands (Settings, Orgs & repos) |
| `select.remove` | `d` (VISUAL), `dd` (repos) | remove the selected worktrees, or the one under the cursor (asks first) |
| `select.pin` | `m` (VISUAL) | pin selected |
| `select.copy` | `y` (VISUAL) | copy paths |
| `select.open` | `o` (VISUAL), `<CR>` (repos) | open the worktree's session, importing it when it has none |
