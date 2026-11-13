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
| `session.delete` | `dd` (sessions), `dd` (sessionshelper) | delete session and its worktrees (asks first) |
| `session.import` `[path]` | `Iw` (sessions), `Iw` (sessionshelper) | import a worktree Heed does not manage yet as a session |
| `session.import.path` | `Ip` (sessions), `Ip` (sessionshelper) | import the worktree at a path (any repo, anywhere) |
| `session.pin` | `m` | pin / unpin session |
| `session.rename` `[title]` | `R` (sessions), `R` (sessionshelper) | give the session your title, which heed keeps (no title: the command line opens with it) |
| `session.autoname` |  | let heed name the session again, from what it is doing |
| `session.kind` `[kind]` | `K` (sessions), `K` (sessionshelper) | what the work is: feat, fix, refactor, docs, chore or plan (no argument: the next) |
| `session.back` | `''` | back to previous session |
| `session.agent` | `<CR>` (sessions), `<CR>` (sessionshelper) | INSERT into the session's agent pane (the focused pane when it has none) |
| `session.open` `<words>` |  | go to the session matching these words |
| `pin.jump` `<1-9>` | `'1`, `'2`, `'3`, `'4`, `'5`, `'6`, `'7`, `'8`, `'9` | jump to pinned session |
| `work.start` | `o` | start work |
| `work.start.panel` |  | start work in the floating panel, as the global shortcut does |
| `resume` |  | pick up where you left off: the sessions to resume, as on launch |
| `summary` | `gZ` | while you were away: what still waits on you, and what merged, ran, finished and closed |
| `work.again` | `O` | start work from this session's prompt |
| `chat.new` `[prompt]` | `gc` | start a chat: an agent in a scratch folder or one you pick, no repo or worktree |
| `chat.promote` |  | turn this chat into work: pick a repo, heed makes a worktree and hands the agent the chat |
| `agent.switch` `[agent] [model] [effort]` | `gA` | hand the session to another agent: stop its agent, start that one on a handoff prompt |
| `view.insights` | `gh` | Insights: the dashboard first, then History, the ledger, the Mindmap and standups |
| `view.history` |  | Insights, as view.insights does (the name it had before) |
| `view.autopilot` | `gw` | Autopilot: what heed can do on its own (Can do first), where it is on, what it does now, what it did |
| `goal.jump` | `'g` | go to the session's goal; in Goals, to the goal of the session under the cursor |

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
| `pane.wider` | `<C-w>>` | widen the focused pane |
| `pane.narrower` | `<C-w><lt>` | narrow the focused pane |
| `pane.taller` | `<C-w>+` | make the focused pane taller |
| `pane.shorter` | `<C-w>-` | make the focused pane shorter |
| `pane.equalize` | `<C-w>=` | make every pane in the tab the same size |
| `tab.close` | `<C-w>c` | close the tab, every pane in it |
| `tab.next` | `gt` | next tab |
| `tab.prev` | `gT` | previous tab |
| `tab.new` | `gn` | new tab with shell |
| `tab.move.left` | `g<lt>` | move the tab left |
| `tab.move.right` | `g>` | move the tab right |
| `tab.go` `<n>` |  | go to tab n |
| `task.run` `[name]` | `!` | run a task in a tab of its own: pinned, mise, make, package.json (no name: pick one) |
| `task.refresh` |  | read the session's tasks again (mise, make, package.json) |

## Views & overlays

| Command | Keys | Does |
|---|---|---|
| `view` `<sessions|attention|inbox|issues|prs|watch|repos|insights|history|timeline|ledger|dashboard|mindmap|standup|goals|log>` |  | switch view |
| `view.sessions` | `gs` | sessions |
| `view.attention` `[filter]` | `gm`, `gi`, `gp` | attention: what wants you, with why, the thread beside it (a tab: foryou, reviews, mentions, mine, ...) |
| `view.inbox` |  | Attention's Everything tab, where the inbox went |
| `view.issues` |  | Attention's issues: assigned to you or mentioning you, where the Issues view went |
| `view.prs` |  | pull requests |
| `view.watch` |  | Autopilot, as view.autopilot does (the view was Watch before) |
| `autopilot.cando` | `C` (autopilot), `C` (done), `C` (watch), `C` (watchhelper), `C` (where) | Autopilot's Can do: a card per thing heed can do on its own |
| `autopilot.where` | `W` (autopilot), `W` (done), `W` (watch), `W` (watchhelper), `W` (where) | Autopilot's Where: each repo, and which capabilities are on there |
| `autopilot.now` | `N` (autopilot), `N` (done), `N` (watch), `N` (watchhelper), `N` (where) | Autopilot's Now: stalled PRs first, then what each capability is working on |
| `autopilot.done` | `D` (autopilot), `D` (done), `D` (watch), `D` (watchhelper), `D` (where) | Autopilot's Done: what heed did on its own, by day |
| `view.repos` | `gr` | repos & worktrees |
| `view.log` |  | the call log: every command and GitHub call heed made, how long it took, how it ended |
| `view.timeline` |  | Insights' History with every event as its own line (what the timeline was) |
| `view.dashboard` |  | Insights' dashboard: what the work amounted to over a range |
| `view.ledger` |  | Insights' ledger: a summary of each piece of work, kept after its worktree |
| `view.standup` |  | Insights' standup reports: your questions answered, one report per org |
| `view.mindmap` |  | Insights' Mindmap: the work grouped into campaigns, one Mindmap per org |
| `view.goals` | `gG` | goals: long-running work, what belongs to each goal, and its GOAL.md |
| `goal.overview` |  | Goals: back to the goal's overview from any of its panes |
| `goal.doc` | `E` (goalagents), `E` (goalboard), `E` (goaldoc), `E` (goalevals), `E` (goalmap), `E` (goalpersonas), `E` (goalplan), `E` (goalreviewers), `E` (goals), `E` (unassigned) | Goals: the goal's GOAL.md and its versions (again: the overview) |
| `goal.board` | `B` (goalagents), `B` (goalboard), `B` (goaldoc), `B` (goalevals), `B` (goalmap), `B` (goalpersonas), `B` (goalplan), `B` (goalreviewers), `B` (goals), `B` (unassigned) | Goals: the goal as a board, its items by column (again: the overview) |
| `goal.unassigned` | `U` (goalagents), `U` (goalboard), `U` (goaldoc), `U` (goalevals), `U` (goalmap), `U` (goalpersonas), `U` (goalplan), `U` (goalreviewers), `U` (goals), `U` (unassigned) | Goals › Unassigned: how heed put new work on goals, its asks, and goals it suggests (again: the overview) |
| `goal.reviewers` | `R` (goalagents), `R` (goalboard), `R` (goaldoc), `R` (goalevals), `R` (goalmap), `R` (goalpersonas), `R` (goalplan), `R` (goalreviewers), `R` (goals), `R` (unassigned) | Goals: the goal's reviewers, their scores and objections, and its quality bars (again: the overview) |
| `goal.personas` | `P` (goalagents), `P` (goalboard), `P` (goaldoc), `P` (goalevals), `P` (goalmap), `P` (goalpersonas), `P` (goalplan), `P` (goalreviewers), `P` (goals), `P` (unassigned) | Goals: who the goal needs, why now, how much of their work they have looked at (again: the overview) |
| `goal.evaluations` | `X` (goalagents), `X` (goalboard), `X` (goaldoc), `X` (goalevals), `X` (goalmap), `X` (goalpersonas), `X` (goalplan), `X` (goalreviewers), `X` (goals), `X` (unassigned) | Goals: stranger walks of the goal, their friction logs and scores, by lens (again: the overview) |
| `goal.swarm` | `S` (goalagents), `S` (goalboard), `S` (goaldoc), `S` (goalevals), `S` (goalmap), `S` (goalpersonas), `S` (goalplan), `S` (goalreviewers), `S` (goals), `S` (unassigned) | Goals: the goal's swarm: its plan by phase, the lead's questions, versions and steering (again: the overview) |
| `goal.agents` | `W` (goalagents), `W` (goalboard), `W` (goaldoc), `W` (goalevals), `W` (goalmap), `W` (goalpersonas), `W` (goalplan), `W` (goalreviewers), `W` (goals), `W` (unassigned) | Goals: the swarm's agents: what each does and for how long, stuck or not, its notes and activity, and what needs you; once done, its summary (again: the overview) |
| `goal.map` | `T` (goalagents), `T` (goalboard), `T` (goaldoc), `T` (goalevals), `T` (goalmap), `T` (goalpersonas), `T` (goalplan), `T` (goalreviewers), `T` (goals), `T` (unassigned) | Goals: the swarm as a map: phases as columns, tasks as cards by state, dependencies as edges (again: the overview) |
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
| `open.reader` | `<CR>` | read the item, issue or PR |
| `cleanup.rules` |  | the cleanup settings (Settings › Worktrees › Cleanup) |
| `cleanup.run` | `gC` | clean up worktrees now: remove the ones idle past your cleanup settings (lists them and asks first) |
| `inspector.toggle` | `zi` | collapse / expand the inspector |
| `inspector.tackle` `[text]` |  | hand the session's loose end with this text to its agent (none: all of them) |
| `inspector.resolve` `<node> <text>` |  | mark a loose end done, on the Mindmap node it lives on |
| `inspector.copy` `<path>` |  | copy a path to the pasteboard |
| `sidebar.toggle` | `zs` | collapse / expand the sessions sidebar |
| `sidebar.titles` | `zt` | show session titles / worktree names in the sidebar rows |
| `sessions.group` `[status|campaign|repo|none]` | `zG` (sessions), `zG` (sessionshelper) | group the sessions by status, campaign, repo or not at all (no argument: the next) |
| `sessions.sort` `[attention|touched|idle|started|size]` | `T` (sessions), `T` (sessionshelper) | sort the sessions: attention, you recent first, idle longest, started, size (no argument: next) |
| `sessions.rows` `[one|two]` | `zR` (sessions), `zR` (sessionshelper) | one line or two per session in the sidebar |
| `sessions.close.ready` | `X` (sessions) | close every session in Can close (its PRs merged or closed, nothing left open), after asking |
| `config.edit` |  | open config.toml in $EDITOR |
| `tutor` `[lesson]` | `<D-T>`, `<D-T>` (INSERT) | the tutor: pick a lesson, or start one by name (tour, sessions, prs…) |
| `tutor.hide` `[all]` |  | hide the title bar's tutor reminder for this lesson (all: every reminder) |
| `host.open` | `gH` | hosts: the ones heed drives over ssh, and ones from ~/.ssh/config to add |
| `host.filter` `[host]` | `@` | narrow the view to one host (@devbox) |
| `host.roots` `[host]` |  | choose where heed looks for repos on a host |
| `agents.stop` |  | stop every agent and shell in every pane (with [sessions] persist = "zmx") |
| `tutor.back` |  | the tutor's previous step, the world as it was then |
| `tutor.skip` |  | skip the tutor's step |
| `tutor.exit` | `<D-.>`, `<D-.>` (INSERT) | leave the tutor; your sessions come back as they were |
| `update.check` |  | look for a new version of heed now (also :update) |
| `tools.detect` |  | find git and gh again (login shell PATH, usual places, [tools]) |
| `app.quit` |  | quit Heed |
| `settings.open` `[page] [tab]` | `<D-,>` | open Settings, on a page (general, notifications, updates, agents, model-calls, decisions, worktrees, goals, history, github, pilot, orgs, attention, hosts, tools, keys; the old colors, cleanup, inference still work); orgs and pilot take a tab (green, merged, reviews, instructions), agents an agent and a tab (sessions, model-calls) |
| `settings.advanced` |  | Settings: show or hide the advanced settings (a set or refused one always shows) |
| `settings.modified` |  | Settings: show only what differs from heed's defaults, or every setting again |
| `settings.find` `<words>` |  | Settings: search every setting by name, description, page or config key (grace_seconds), every word matching |
| `whatsnew.show` |  | what's new in heed: the features and new settings since the version you last opened |
| `nudges.hide` `[always]` |  | hide the title bar's settings-worth-a-look pill until the next launch (always: for good) |
| `settings.configure` |  | Settings: Configure…, a profile, then the settings still worth deciding, then the changes to apply |
| `inference.setup` |  | set up heed's model calls and decisions (Settings › Model calls) |
| `inference.hide` `[always]` |  | hide the title bar's model call setup reminder until the next launch (always: for good) |
| `hunch.download` `[checkpoint]` |  | download (or resume) Hunch's model, english by default; says its size and license first |
| `hunch.cancel` `[checkpoint]` |  | stop Hunch's model download; hunch.download resumes it |
| `hunch.delete` `[checkpoint]` |  | delete Hunch's downloaded model and the head trained on it |
| `hunch.retrain` |  | train Hunch on your corrections now, in the background |
| `hunch.reset` |  | put Hunch back on its checkpoint's own head (the training set stays) |
| `hunch.screen` |  | have Hunch read the agent pane under the cursor now: working, waiting for input, stuck or done |
| `app.activate` |  | bring Heed's window to the front, as the global shortcut does |
| `welcome` |  | show the getting-started checks again |
| `history.list` | `H` (dashboard), `H` (history), `H` (ledger), `H` (mindmap), `H` (standup) | Insights' History: the work that ended, by day, each with its story (again: the dashboard) |
| `history.timeline` |  | History with every event as its own line (again: folded), as history.events |
| `history.ledger` | `L` (dashboard), `L` (history), `L` (ledger), `L` (mindmap), `L` (standup) | Insights' ledger: a summary of each piece of work (again: back to the dashboard) |
| `history.dashboard` | `D` (dashboard), `D` (history), `D` (ledger), `D` (mindmap), `D` (standup) | Insights' dashboard: what shipped, agent time, your bests, goals; where Insights opens |
| `history.standup` | `U` (dashboard), `U` (history), `U` (ledger), `U` (mindmap), `U` (standup) | Insights' standup: your questions answered per org (again: back to the dashboard) |
| `history.mindmap` | `M` (dashboard), `M` (history), `M` (ledger), `M` (mindmap), `M` (standup) | Insights' Mindmap: the work grouped into campaigns, per org (again: back to the dashboard) |

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
| `autopilot.move` `<h|j|k|l>` | `h` (autopilot), `j` (autopilot), `k` (autopilot), `l` (autopilot), `<Left>` (autopilot), `<Down>` (autopilot), `<Up>` (autopilot), `<Right>` (autopilot), `h` (where), `j` (where), `k` (where), `l` (where), `<Left>` (where), `<Down>` (where), `<Up>` (where), `<Right>` (where) | Autopilot: move between cards (Can do) or cells (Where) |
| `autopilot.on` `[capability] [repo]` | `y` (autopilot), `y` (where) | Autopilot: turn the capability on here (the repo in Where; its default on Can do) |
| `autopilot.ask` | `a` (where) | Autopilot: have the capability ask you first here |
| `autopilot.off` | `x` (autopilot), `x` (where) | Autopilot: turn the capability off here |
| `autopilot.everywhere` | `Y` (autopilot) | Autopilot: turn the capability on in every repo |
| `autopilot.open` | `<CR>` (autopilot), `<CR>` (done), `<CR>` (watch), `<CR>` (watchhelper), `<CR>` (where) | Autopilot: what the card did (Can do), the repo in Repos (Where), read the PR (Now and Done) |
| `autopilot.settings` | `S` (autopilot), `S` (where) | Autopilot: open the Settings page of the capability |
| `autopilot.what` `[capability]` | `t` (done) | Done: every capability, or the next one (or one by name) |
| `autopilot.repo` `[repo]` | `r` (done) | Done: every repo, or the next one (or one by name) |
| `select.toggle` | `<Space>` (VISUAL), `<Space>` (attention), `<Space>` (attentionhelper), `<Space>` (prs), `<Space>` (swarmask), `<Space>` (watch), `<Space>` (watchhelper) | toggle row |
| `history.reopen` | `R` (dashboard), `R` (history), `<CR>` (history), `R` (ledger), `<CR>` (ledger) | reopen: resume, recreating the worktree if needed |
| `history.again` | `O` (history) | start a new session from this prompt |
| `history.outcome` `[outcome]` | `t` (history) | History: the next outcome filter, or one by name (all, merged, …) |
| `history.events` | `e` (history) | History: every event as its own line, or folded into its piece of work again |
| `timeline.kind` `[kind]` | `K` (history) | History: every kind, or one (sessions, worktrees, prs, questions, chats) |
| `timeline.repo` `[name]` | `r` (history) | History: every repo, or the next one |
| `timeline.where` `[local|host]` | `w` (history) | History: everywhere, this Mac, or a host |
| `timeline.gone` | `c` (history) | History: show or hide removed worktrees |
| `standup.run` | `S` (standup) | standup: write a report for this org now |
| `standup.copy` `[plain]` | `y` (standup) | standup: copy the answer to the question shown (all with none), as markdown |
| `standup.copy.all` `[plain]` | `Y` (standup) | standup: copy the whole report, as markdown |
| `standup.question` | `t` (standup) | standup: show one question's answers, the next, or all again |
| `standup.org.next` | `]o` (standup) | standup: the next org's reports (personal last) |
| `standup.org.prev` | `[o` (standup) | standup: the previous org's reports |
| `dashboard.range` `[days]` | `r` (dashboard) | dashboard: the next range (7 days, 4 weeks, 12 weeks), or one in days or weeks (2w) |
| `goal.new` `[title]` | `n` (goals) | new goal: a title and what it is (on a session: from its prompt, and the session on it) |
| `goal.attach` `<goal>` |  | put the session or chat on a goal (no goal: the command line opens to pick one) |
| `goal.detach` | `x` (goaldoc), `x` (goals) | take the session or chat off its goal |
| `goal.archive` | `a` (goaldoc), `a` (goals) | archive the goal (again: bring it back) |
| `goal.open` | `<CR>` (goaldoc), `<CR>` (goalevals), `<CR>` (goalpersonas), `<CR>` (goalplan), `<CR>` (goalreviewers), `<CR>` (goals), `<CR>` (unassigned) | Goals: what belongs to the goal; on a session or chat, go to it |
| `goal.focus` | `<Tab>` (goalagents), `<S-Tab>` (goalagents), `<Tab>` (goaldoc), `<S-Tab>` (goaldoc), `<Tab>` (goalevals), `<S-Tab>` (goalevals), `<Tab>` (goalpersonas), `<S-Tab>` (goalpersonas), `<Tab>` (goalplan), `<S-Tab>` (goalplan), `<Tab>` (goalreviewers), `<S-Tab>` (goalreviewers), `<Tab>` (goals), `<S-Tab>` (goals) | Goals: between the goals and what belongs to the goal |
| `goal.edit` | `e` (goaldoc), `e` (goals) | edit the goal's GOAL.md in place; each save is a new version |
| `goal.restore` `<version>` |  | make one of the goal's GOAL.md versions current again (as a new version) |
| `goal.item.add` `[title]` | `a` (goalboard), `n` (goalboard) | Goals: add an item to the goal (on the board: in the column under the cursor) |
| `goal.item.done` | `D` (goalboard) | Goals: the item under the cursor is done (its card to Done) |
| `goal.item.move` `<left|right|explore|planned|working|verify|done>` | `H` (goalboard), `L` (goalboard) | Goals: move the card under the cursor a column left or right, or to a column by name |
| `goal.item.column` `<-1|1>` | `h` (goalboard), `l` (goalboard) | Goals board: the cursor a column left or right |
| `goal.item.split` `<titles>` | `-` (goalboard) | Goals: split the item into smaller ones (titles separated by ;) |
| `goal.item.work` | `s` (goalboard), `o` (goalboard) | Goals: start work on the item, Start work filled in from it |
| `goal.item.open` | `<CR>` (goalboard) | Goals: open what the card is (its session, chat or PR); a question: GOAL.md |
| `goal.plan` |  | Goals: ask the planner for the goal's items now |
| `goal.proposal.accept` | `y` (goaldoc) | GOAL.md: yes to the first change waiting (or the one clicked) |
| `goal.proposal.reject` | `n` (goaldoc) | GOAL.md: no to the first change waiting (or the one clicked) |
| `goal.proposal.edit` `[text]` | `c` (goaldoc) | GOAL.md: reword the first change waiting, then accept it (no text: the command line) |
| `goal.undo` | `u` (goaldoc) | GOAL.md: take back the last change heed made on its own |
| `goal.sharpen` | `w` (goaldoc), `w` (goals) | GOAL.md: ask a model to sharpen the goal; what it suggests waits for you |
| `goal.guide` |  | Goals: hide the goal's next-steps card (it comes back if a step it ticked off goes back), or show it again |
| `goal.ask.yes` | `y` (attention), `y` (swarmask), `y` (unassigned) | yes: on the goal heed proposed (on a suggested goal: make it) |
| `goal.ask.no` | `n` (attention), `n` (swarmask), `n` (unassigned) | no: not on that goal, and heed learns it (on a suggested goal: drop it) |
| `goal.ask.move` `<goal>` | `m` (attention), `m` (attentionhelper), `m` (swarmask), `m` (unassigned) | on another goal instead, and heed learns it was not the one it proposed |
| `goal.ask.ignore` | `i` (attention), `i` (unassigned) | leave things like this on no goal, and heed learns to (an ignore rule) |
| `goal.unassigned.how` | `g?` (unassigned) | Unassigned: show or hide how heed puts work on goals (shown on its own only while nothing waits for you) |
| `goal.attach.undo` | `u` (goals), `u` (unassigned) | take heed's last attachment off again, and heed learns it (a never rule) |
| `goal.attach.find` |  | look for the session's goal now: rules, signals, the model when unsure |
| `goal.bar` `<lens> <bar|off|auto>` |  | pin a quality bar for the goal: a lens and 0–10, off to drop the lens, auto for the profile's |
| `goal.bars.accept` | `y` (goalreviewers) | Reviewers: these quality bars are right for the goal (recorded as yours; the first steps tick off on it) |
| `goal.mirror` | `M` (goalagents), `M` (goalboard), `M` (goaldoc), `M` (goalevals), `M` (goalmap), `M` (goalpersonas), `M` (goalplan), `M` (goalreviewers), `M` (goals), `M` (unassigned) | mirror the goal to GitHub (its tracker checked first; heed keeps it up to date); again: stop |
| `goal.tracker` `[org/name|none]` |  | the repo the goal mirrors to on GitHub, checked read-only first (none: no tracker) |
| `goal.mirror.sync` |  | sync the goal's GitHub issues now and read them back |
| `goal.mirror.open` |  | open the goal's meta issue on GitHub (on a card: its sub-issue) |
| `goal.mirror.yes` | `Y` (goalagents), `Y` (goalboard), `Y` (goaldoc), `Y` (goalevals), `Y` (goalmap), `Y` (goalpersonas), `Y` (goalplan), `Y` (goalreviewers), `Y` (goals), `Y` (unassigned) | a colleague's change on GitHub: yes, the item follows it |
| `goal.mirror.no` | `K` (goalagents), `K` (goalboard), `K` (goaldoc), `K` (goalevals), `K` (goalmap), `K` (goalpersonas), `K` (goalreviewers), `K` (goals), `K` (unassigned) | a colleague's change on GitHub: no, heed puts the sub-issue back |
| `goal.source.add` `[query]` |  | a GitHub query the goal's items come from, one item per PR or issue (prs org/repo, issues org/repo, label <name>, reviews, milestone <title> org/repo, or a search); none: the source dialog |
| `goal.source.remove` `[id]` |  | take a source off the goal (its items stay, marked) |
| `goal.source.edit` `<id> [query]` |  | change a source's query and rule (its items stay; none: the source dialog) |
| `goal.source.rule` `<id> <rule>` |  | what done means for a source's items: merged, closed, reviewed (by you) or green |
| `goal.source.accept` | `y` (goals) | yes to the source heed proposes for the goal |
| `goal.source.dismiss` |  | no to the source heed proposes (not proposed again) |
| `goal.source.sync` |  | sync the goal's sources with GitHub now |
| `goal.reopen` |  | not done yet: undo heed marking the goal done (held until something new) |
| `swarm.new` `[title]` |  | new swarm: a goal, where it works, its lead and team, its limits; the lead drafts a plan for you to approve |
| `swarm.start` |  | swarm this goal: a lead drafts a plan for its work (the form first) |
| `swarm.stop` |  | stop the goal's swarm: nothing more starts, its plan and steering stay readable |
| `swarm.pause` |  | pause the goal's swarm (again: resume): nothing more starts, workers at work finish their turn |
| `swarm.approve` | `A` (goalplan) | approve the swarm's plan (or the change waiting for you): its tasks become items |
| `swarm.accept` | `y` (goalplan) | yes to the plan change waiting for you: it becomes the approved plan |
| `swarm.task.pause` | `p` (goalagents), `p` (goalmap), `p` (goalplan) | pause the swarm task under the cursor (again: resume): its worker stops, its worktree stays |
| `swarm.task.swap` `<agent[:model]>` | `t` (goalagents), `t` (goalmap), `t` (goalplan) | hand the swarm task under the cursor to another agent; a working worker hands over its worktree |
| `swarm.task.host` `<host|local|->` |  | where the swarm task under the cursor runs: a host, local for this Mac, or - for where the swarm runs |
| `swarm.host` `<host|local>` |  | where the new swarm runs, in its form: a host, or local for this Mac |
| `swarm.task.open` | `s` (goalagents), `<CR>` (goalagents), `s` (goalmap), `<CR>` (goalmap), `s` (goalplan) | the swarm task under the cursor's worker: its tab |
| `swarm.land` | `b` (goalplan) | move the task under the cursor's stacked PR to where the PR it stacks on merged (again after gh refused) |
| `swarm.order` | `m` (goalplan) | the swarm's plan in merge order (what each task waits for merges first), or by phase again |
| `swarm.reject` `[why]` | `n` (goalplan) | no to the plan change waiting for you; the lead hears why |
| `swarm.task.edit` | `e` (goalmap), `e` (goalplan) | edit the plan's task under the cursor: a new plan version |
| `swarm.task.add` `[title]` | `a` (goalplan) | add a task after the one under the cursor, in its phase: a new plan version |
| `swarm.task.move` `<1|-1>` | `J` (goalplan), `K` (goalplan) | move the plan's task down (1) or up (-1); past its phase, into the next |
| `swarm.task.drop` | `x` (goalplan) | drop the plan's task under the cursor; nothing waits for it any more |
| `swarm.replan` `[feedback]` | `r` (goalplan) | ask the swarm's lead to re-plan, with your feedback |
| `swarm.answer` `[answer]` | `i` (goalagents), `i` (goalplan), `i` (swarmask) | answer the swarm question under the cursor (Needs you, the plan's log), else the first open one; on one someone else answered, an overrule |
| `swarm.answer.option` `<n>` | `1` (goalagents), `2` (goalagents), `3` (goalagents), `4` (goalagents), `5` (goalagents), `6` (goalagents), `7` (goalagents), `8` (goalagents), `9` (goalagents), `1` (goalplan), `2` (goalplan), `3` (goalplan), `4` (goalplan), `5` (goalplan), `6` (goalplan), `7` (goalplan), `8` (goalplan), `9` (goalplan), `1` (swarmask), `2` (swarmask), `3` (swarmask), `4` (swarmask), `5` (swarmask), `6` (swarmask), `7` (swarmask), `8` (swarmask), `9` (swarmask) | answer the swarm question under the cursor (else the first open one) with its option n (1 is the first) |
| `swarm.controller` | `c` (goalagents), `c` (goalplan), `c` (swarmask) | hand the swarm question under the cursor to heed's controller: it answers what is within its authority and suggests an answer for what is yours |
| `swarm.similar` | `A` (swarmask) | make your next answer to the swarm question under the cursor the answer to similar questions too |
| `swarm.overrule` `[answer]` |  | answer again the swarm question under the cursor that someone else answered |
| `swarm.log.who` `[actor]` | `w` (goalplan) | the steering log by who decided: everyone, you, the controller, the lead, agents, heed |
| `swarm.log.jump` | `q` (goalplan) | from a steering row to the question it is about, from a question to its answer; elsewhere to the log |
| `swarm.send` `<to> <text>` |  | a message to a swarm agent (a task's number, lead, or @all), typed in once it is idle |
| `swarm.diff` | `d` (goalplan) | the plan version under the cursor's whole diff against the one before (again: short) |
| `swarm.restore` `[version]` | `u` (goalplan) | make a plan version current again, as a new version |
| `swarm.map.move` `<h|j|k|l>` | `h` (goalmap), `l` (goalmap), `j` (goalmap), `k` (goalmap), `<Left>` (goalmap), `<Right>` (goalmap), `<Down>` (goalmap), `<Up>` (goalmap) | the swarm map's cursor: h l between columns, j k between the cards of one |
| `swarm.followup` | `F` (goalagents), `F` (goaldoc), `F` (goalmap), `F` (goalplan), `F` (goals) | start a follow-up swarm on the goal: the last one's team and limits, its follow-ups for the lead (the form first) |
| `swarm.summary` |  | the swarm's end-of-build summary: written again from its record, and the lead asked to write its part |
| `swarm.stuck` `<estimate|errors|quiet|peer|you> <value>` |  | when the goal's swarm counts a worker as stuck: estimate (×), errors, quiet, peer and you (minutes) |
| `swarm.merge` `<off|auto|heed|repo>` |  | get it merged for the goal's swarm's PRs: off, auto, heed, or repo (each PR's repo says; the default). In merge order either way |
| `swarm.rule.delete` `[rule number]` |  | delete one of the goal's repeat rules: the controller stops answering with it |
| `review.recheck` `[reviewer]` | `r` (goaldoc), `r` (goalreviewers), `r` (goals) | re-check: the reviewer under the cursor looks again now (elsewhere in Goals: every reviewer the goal needs) |
| `review.accept` | `A` (goalreviewers) | accept the risk of the objection under the cursor (again: open it) |
| `review.fix` | `s` (goalreviewers) | start a session to fix the objection under the cursor: Start work, filled in |
| `review.why` | `c` (goalreviewers) | ask the reviewer why: a chat seeded with its review |
| `reviewer.spawn` `[kind]` | `N` (goalreviewers) | spawn a reviewer on the goal, as the spawn panel says (or of the kind given) |
| `reviewer.remove` |  | take the reviewer under the cursor off the goal (its history stays) |
| `persona.session` | `s` (goalpersonas) | start a session as the persona under the cursor: Start work, filled in |
| `persona.chat` | `c` (goalpersonas) | start a chat with the persona under the cursor, seeded with it, the goal and why |
| `persona.reviewer` | `N` (goalpersonas) | spawn the persona under the cursor as a reviewer: read-only, it looks now |
| `persona.edit` | `e` (goalpersonas) | edit the persona's file in place (again, ⎋ or ⌘S: save it) |
| `persona.derive` | `r` (goalpersonas) | work out again who the goal needs, now (one of the goal's model calls) |
| `persona.share` | `p` (goalpersonas) | copy the persona's file to the shared library, for other goals |
| `persona.use` `<persona>` |  | put a persona from the shared library on the goal (a copy) |
| `eval.fix` | `s` (goalevals) | start a session to fix the friction under the cursor: Start work, filled in |
| `eval.accept` | `A` (goalevals) | accept the friction under the cursor (again: open it) |
| `eval.rewalk` `[lens]` | `r` (goalevals) | walk again now, in a fresh clone: the lens picked (after a fix, to see whether it helped) |
| `eval.lens` `<1|-1|lens>` | `h` (goalevals), `l` (goalevals) | Evaluations: pick a lens, the next (1), the one before (-1) or one by name |
| `ledger.summarize` | `S` (ledger) | write the ledger summary of this work now |
| `mindmap.in` | `l` (mindmap) | Mindmap: into what the node under the cursor holds |
| `mindmap.out` | `h` (mindmap) | Mindmap: out to the node that holds this one |
| `mindmap.less` | `-` (mindmap) | Mindmap: draw one level less to the right |
| `mindmap.more` | `=` (mindmap) | Mindmap: draw one level more to the right |
| `mindmap.org.next` | `]o` (mindmap) | Mindmap: the next org's Mindmap (personal last) |
| `mindmap.org.prev` | `[o` (mindmap) | Mindmap: the previous org's Mindmap |
| `mindmap.accept` | `y` (mindmap) | Mindmap: keep the suggested placement as it is |
| `mindmap.done` | `x` (mindmap) | Mindmap: mark the node's first open follow-up done |
| `mindmap.pin` | `p` (mindmap) | Mindmap: pin the node's first decision so it shows above it (again: unpin) |
| `mindmap.nest` | `>` (mindmap) | Mindmap: put the node in a new group with its next sibling |
| `mindmap.lift` | `<` (mindmap) | Mindmap: lift the node out of what holds it |
| `mindmap.rename` `[title]` | `r` (mindmap) | Mindmap: rename the node (no title: the command line opens with it) |
| `mindmap.move` `[title|top]` | `m` (mindmap) | Mindmap: move the node into a campaign or group by its title (top: to the top) |
| `mindmap.join` `[title]` | `J` (mindmap) | Mindmap: move everything in the node into another by its title, and drop it |
| `mindmap.name` | `S` (mindmap) | Mindmap: name campaigns for the work waiting in Unsorted now |
| `mindmap.open` | `<CR>` (mindmap) | Mindmap: a piece of work's ledger entry |
| `mindmap.goal` | `n` (mindmap) | Mindmap: make a goal of this campaign, its work on it and its GOAL.md drafted |
| `mindmap.link.next` | `]l` (mindmap) | Mindmap: to the next node this one links to (led to, same files) |
| `mindmap.link.prev` | `[l` (mindmap) | Mindmap: to the previous node this one links to |
| `mindmap.session` `[prompt]` | `s` (mindmap) | Mindmap: start a session on this node, told what was decided and what is open here |
| `ledger.edit` `[text]` | `E` (ledger) | edit the ledger entry's summary (no text: the command line opens with it) |
| `log.kind` `[all|kind]` | `t` (log) | call log: all, or one kind (shell, github, llm, decide) |
| `log.failed` | `x` (log) | call log: only calls that failed, or all |
| `log.slow` | `s` (log) | call log: only slow calls (5 s or more), or all |
| `log.writes` | `w` (log) | call log: only GitHub writes, or all |
| `log.caller` | `c` (log) | call log: only the caller of the call under the cursor, or every caller |
| `log.agent` | `a` (log) | call log: only the agent of the call under the cursor, or every agent |
| `log.copy` | `y` (log) | copy the command of the call under the cursor |
| `github.sync` | `r` (attention), `r` (attentionhelper), `r` (pr), `r` (prs), `r` (swarmask), `r` (watch), `r` (watchhelper) | sync GitHub now |
| `items.start` | `s` (attention), `s` (attentionhelper), `s` (issue), `s` (swarmask) | start one session from the picked items |
| `items.add` | `a` (attention), `a` (attentionhelper), `a` (issue), `a` (swarmask) | add the picked items to the current session |
| `attention.done` | `x` (attention), `x` (attentionhelper), `x` (swarmask) | done: mark the thread read on GitHub; it comes back when something new happens |
| `attention.snooze` `[duration]` | `Z` (attention), `Z` (attentionhelper), `Z` (swarmask) | snooze: out of the feed until later (3h, or 30m, 2d, tomorrow) |
| `attention.mute` | `M` (attention), `M` (attentionhelper), `M` (swarmask) | mute the thread on GitHub (no more notifications about it); listed under Muted |
| `attention.reply` | `R` (attention), `R` (attentionhelper), `R` (swarmask) | draft a reply with the model; you read it before anything is posted |
| `attention.session` | `gS` (attention), `gS` (attentionhelper), `gS` (swarmask) | go to the item's session |
| `attention.filter` `[filter]` | `t` (attention), `t` (attentionhelper), `t` (swarmask) | next Attention tab (Muted after Everything), or the one named |
| `attention.done.new` | `X` (attention), `X` (swarmask) | done with everything in For you's New since |
| `attention.fold` | `za` (attention), `za` (attentionhelper), `za` (swarmask) | For you's Mentioned before: list it, or fold it again |
| `attention.reader.down` | `<C-e>` (attention), `<C-e>` (attentionhelper), `<C-e>` (swarmask) | scroll Attention's reader down half its height |
| `attention.reader.up` | `<C-y>` (attention), `<C-y>` (attentionhelper), `<C-y>` (swarmask) | scroll Attention's reader up half its height |
| `attention.sort` | `T` (attention), `T` (attentionhelper), `T` (swarmask) | Attention: recent first, or weight then recent |
| `attention.summarize` | `U` (attention), `U` (attentionhelper), `U` (swarmask) | write the thread's catch-up summary again (↻): what is new since you last looked |
| `attention.coverage` |  | Coverage: what Attention has of each source against GitHub, and where it went |
| `helper.do` | `D` (attention), `D` (attentionhelper), `D` (swarmask) | do heed's next step for the item (review it, draft a reply, get it green, merge, set up Autopilot, start work) |
| `helper.always` | `Y` (attention), `Y` (swarmask) | do heed's next step, and from now on always in this repo (turns its Autopilot capability on) |
| `helper.other` | `.` (attention), `.` (attentionhelper), `.` (swarmask) | propose the item's next other step instead (and back to heed's own) |
| `helper.watch` | `gW` | Watch it: the helper on the session's PR, in a split under its panes |
| `helper.takeover` | `gO` | Take it over: stop the helper and hand its branch to your session as a note |
| `helper.steer` | `i` (attentionhelper), `i` (sessionshelper), `i` (watchhelper) | tell the helper something (it stops its turn and reads it) |
| `helper.pause` | `p` (attentionhelper), `p` (sessionshelper), `p` (watchhelper) | pause the helper (its turn is cancelled), or let it carry on |
| `helper.stop` | `zx` (attentionhelper), `zx` (sessionshelper), `zx` (watchhelper) | stop the helper; its close-out keeps what it did |
| `helper.zoom` | `zo` (attentionhelper), `zo` (sessionshelper), `zo` (watchhelper) | the helper's split takes the whole column, or not |
| `helper.close` | `<Esc>` (attentionhelper), `<Esc>` (sessionshelper), `<Esc>` (watchhelper) | close the helper's split (it keeps working) |
| `helper.allow` | `y` (attentionhelper), `y` (sessionshelper), `y` (watchhelper) | allow what the helper asks to run, once |
| `helper.allow.always` | `Y` (attentionhelper), `Y` (sessionshelper), `Y` (watchhelper) | allow what the helper asks to run, from now on (the agent remembers) |
| `helper.deny` | `n` (attentionhelper), `n` (sessionshelper), `n` (watchhelper) | deny what the helper asks to run |
| `helper.push` | `<D-CR>` (attentionhelper), `<D-CR>` (sessionshelper), `<D-CR>` (watchhelper) | push the helper's work to the PR's branch and post its replies (a review: post it) |
| `helper.push.only` | `P` (attentionhelper), `P` (sessionshelper), `P` (watchhelper) | push the helper's work to the PR's branch, without its replies |
| `helper.throwaway` | `X` (attentionhelper), `X` (sessionshelper), `X` (watchhelper) | throw away what the helper did: its worktree and branch go (twice, to be sure) |
| `helper.diff` | `gd` (attentionhelper), `gd` (sessionshelper), `gd` (watchhelper) | the helper's whole diff, in its close-out |
| `helper.tile.next` | `l` (watch), `<Right>` (watch), `l` (watchhelper), `<Right>` (watchhelper) | Now: the next helper's tile |
| `helper.tile.prev` | `h` (watch), `<Left>` (watch), `h` (watchhelper), `<Left>` (watchhelper) | Now: the previous helper's tile |
| `feedback.queue` | `<Space>` (pr) | queue / unqueue the item |
| `feedback.send` | `s` (pr) | send queued feedback to the session |
| `feedback.mode` |  | pilot.green, by its former name |
| `feedback.watch` |  | pilot.watch, by its former name |
| `pilot.why` | `z?` | what heed will do for the PR, and what holds it back |
| `pilot.watch` | `zw` | watch or stop watching the PR (or the picked PRs) |
| `pilot.green` `[off|ask|auto]` | `zg` | cycle get it green for the PR: off, ask, auto (or set the one named) |
| `pilot.run` | `gb` | show the session's running get it green / get it merged run |
| `pilot.run.stop` | `zx` | stop the session's running get it green / get it merged run |
| `pilot.retry` | `zr` | one more round of get it green for a stalled PR (or the picked PRs) |
| `pilot.copilot` | `C` (pr), `A` (watch), `A` (watchhelper) | ask GitHub's Copilot coding agent to resolve the PR's conflicts and address its comments |
| `pilot.reviewers` | `zv` | ask the PR's configured reviewers ([pilot] reviewers) to review it |
| `pilot.merge` | `zm` | get it merged for the PR (or the picked PRs): off or auto |
| `pilot.merge.now` | `zM` | merge the PR now; past unmet required reviews or checks with --admin when you are an admin (merge_now, force_merge) |
| `pilot.merge.setup` |  | set up get it merged for the PR's repo |
| `merge.run` `[repo|all]` | `R` (watch), `R` (watchhelper) | run a repo's merge queue now (no name: the PR's repo; all: every queue) |
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
| `diff.commit` `[sha|all]` | `c` (diff) | show one commit (cycles; a sha shows that one, all the whole branch) |
| `diff.split` | `t` (diff) | unified / split |
| `diff.ask` | `a` (diff), `<CR>` (diff) | queue feedback on this hunk (or the selected lines) |
| `diff.ask.now` | `A` (diff) | ask the agent about this hunk (or the selected lines) now |
| `diff.copy` | `y` (diff) | copy path:line (path:first-last for selected lines) |
| `diff.edit` | `e` (diff) | open the file in the editor |
| `repo.add` `[path]` | `a` (repos) | add or clone a repo: the dialog, or the repo at a path added (kept in repo_paths outside the roots) |
| `repo.reveal` | `<D-o>` (repos) | show the repo's folder in Finder |
| `repos.focus` `[repos|worktrees]` | `h` (repos), `l` (repos), `<Tab>` (repos), `<S-Tab>` (repos) | Repos: between the repo column and the worktree table (repos, worktrees, or the other one) |
| `repo.scan` | `r` (repos) | refresh: rescan the repo roots |
| `worktree.new` | `o` (repos) | start work in the repo under the cursor |
| `setup.review` | `S` (repos) | the setup heed detected for the repo's new worktrees: approve, edit or never |
| `setup.approve` |  | approve the detected setup for the repo's new worktrees |
| `setup.never` |  | no setup for the repo's new worktrees, and no more proposals |
| `setup.edit` |  | edit the repo's setup commands (Settings, Orgs & repos) |
| `repo.setup` `[repo]` | `M` (repos), `M` (where) | set up get it merged and get it green for the repo: sample its history, propose, validate, write config |
| `select.remove` | `d` (VISUAL), `dd` (repos) | remove the selected worktrees, or the one under the cursor (asks first) |
| `select.pin` | `m` (VISUAL) | pin selected |
| `select.copy` | `y` (VISUAL) | copy paths |
| `select.open` | `o` (VISUAL), `<CR>` (repos) | open the worktree's session, importing it when it has none |
