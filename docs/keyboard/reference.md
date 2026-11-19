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
| `session.filter` | `/`, `<D-f>` (browse), `<D-f>` (browsebulk) | filter the current view (typed in the status bar) |
| `filter.clear` |  | clear the current view's filter |
| `session.attention` | `ga` | next session needing you |
| `session.park` | `zz` | park session |
| `session.close` | `x` | close session, keep worktree |
| `session.delete` | `dd` (sessions), `dd` (sessionshelper), `dd` (sessionshelpers), `dd` (sessionsoffer), `dd` (sessionspanel), `dd` (sessionspanelchat), `dd` (sessionspanelpr), `dd` (sessionspromote) | delete session and its worktrees (asks first) |
| `session.import` `[path]` | `Iw` (sessions), `Iw` (sessionshelper), `Iw` (sessionshelpers), `Iw` (sessionsoffer), `Iw` (sessionspanel), `Iw` (sessionspanelchat), `Iw` (sessionspanelpr), `Iw` (sessionspromote) | import a worktree Heed does not manage yet as a session |
| `session.import.path` | `Ip` (sessions), `Ip` (sessionshelper), `Ip` (sessionshelpers), `Ip` (sessionsoffer), `Ip` (sessionspanel), `Ip` (sessionspanelchat), `Ip` (sessionspanelpr), `Ip` (sessionspromote) | import the worktree at a path (any repo, anywhere) |
| `session.import.agent` | `Ia` (sessions), `Ia` (sessionshelper), `Ia` (sessionshelpers), `Ia` (sessionsoffer), `Ia` (sessionspanel), `Ia` (sessionspanelchat), `Ia` (sessionspanelpr), `Ia` (sessionspromote) | import an agent session (Claude Code, codex; any folder) and resume it |
| `session.pin` | `m` | pin / unpin session |
| `session.rename` `[title]` | `R` (sessions), `R` (sessionshelper), `R` (sessionshelpers), `R` (sessionsoffer), `R` (sessionspanel), `R` (sessionspanelchat), `R` (sessionspanelpr), `R` (sessionspromote) | give the session your title, which heed keeps (no title: the command line opens with it) |
| `session.autoname` |  | let heed name the session again, from what it is doing |
| `session.kind` `[kind]` | `K` (sessions), `K` (sessionshelper), `K` (sessionshelpers), `K` (sessionsoffer), `K` (sessionspanel), `K` (sessionspanelchat), `K` (sessionspanelpr), `K` (sessionspromote) | what the work is: feat, fix, refactor, docs, chore or plan (no argument: the next) |
| `session.back` | `''` | back to previous session |
| `session.agent` | `<CR>` (sessions), `<CR>` (sessionshelper), `<CR>` (sessionsoffer), `<CR>` (sessionspanelchat) | INSERT into the session's agent pane (the focused pane when it has none) |
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
| `agent.resume` | `gu` (sessions), `gu` (sessionshelper), `gu` (sessionshelpers), `gu` (sessionsoffer), `gu` (sessionspanel), `gu` (sessionspanelchat), `gu` (sessionspanelpr), `gu` (sessionspromote) | resume the agent's conversation in a session: its own resume, or the latest conversation in the directory when heed kept no id; greyed out while an agent runs in it |
| `agent.resume.copy` | `gY` (sessions), `gY` (sessionshelper), `gY` (sessionshelpers), `gY` (sessionsoffer), `gY` (sessionspanel), `gY` (sessionspanelchat), `gY` (sessionspanelpr), `gY` (sessionspromote) | copy the exact command heed would run to resume this session's agent, with its injected hooks, to the clipboard |
| `agent.fresh` | `gf` (sessions), `gf` (sessionshelper), `gf` (sessionshelpers), `gf` (sessionsoffer), `gf` (sessionspanel), `gf` (sessionspanelchat), `gf` (sessionspanelpr), `gf` (sessionspromote) | start the agent again from the session's original prompt; greyed out while an agent runs in it |
| `agent.resume.dismiss` | `gq` (sessions), `gq` (sessionshelper), `gq` (sessionshelpers), `gq` (sessionsoffer), `gq` (sessionspanel), `gq` (sessionspanelchat), `gq` (sessionspanelpr), `gq` (sessionspromote) | hide the "agent is not running" banner for this session until heed restarts |
| `session.reconnect` | `gk` (sessions), `gk` (sessionshelper), `gk` (sessionshelpers), `gk` (sessionsoffer), `gk` (sessionspanel), `gk` (sessionspanelchat), `gk` (sessionspanelpr), `gk` (sessionspromote) | restart the agent of a session heed can't hear (its pane has no token it can check): the pane's process ends and the agent resumes in a new terminal |
| `view.insights` | `gh` | Insights: the dashboard first, then History, the ledger, the Mindmap and standups |
| `view.history` |  | Insights, as view.insights does (the name it had before) |
| `view.autopilot` | `gw` | Autopilot: what heed can do on its own (Can do first), where it is on, what it does now, what it did |
| `goal.jump` | `'g` | go to the session's goal; in Goals, to the goal of the session under the cursor |
| `trace.turn.next` | `j` (trace), `<Down>` (trace) | trace: the next turn |
| `trace.turn.prev` | `k` (trace), `<Up>` (trace) | trace: the previous turn |
| `trace.span.next` | `l` (trace), `<Right>` (trace) | trace: the next span in the turn |
| `trace.span.prev` | `h` (trace), `<Left>` (trace) | trace: the previous span in the turn |
| `wizard.row` `<delta>` | `j` (wizardcareful), `k` (wizardcareful), `<Down>` (wizardcareful), `<Up>` (wizardcareful), `j` (wizarddone), `k` (wizarddone), `<Down>` (wizarddone), `<Up>` (wizarddone), `j` (wizardinvite), `k` (wizardinvite), `<Down>` (wizardinvite), `<Up>` (wizardinvite), `j` (wizardpanel), `k` (wizardpanel), `<Down>` (wizardpanel), `<Up>` (wizardpanel), `j` (wizardplan), `k` (wizardplan), `<Down>` (wizardplan), `<Up>` (wizardplan) | wizard: the persona or criterion below (1) or above (-1) |
| `go.row` `<delta>` | `j` (wizardgo), `k` (wizardgo), `<Down>` (wizardgo), `<Up>` (wizardgo) | wizard: Go: the row below (1) or above (-1) |
| `split.move` `<h|j|k|l>` | `h` (splitfold), `l` (splitfold), `j` (splitfold), `k` (splitfold), `<Left>` (splitfold), `<Right>` (splitfold), `<Down>` (splitfold), `<Up>` (splitfold), `h` (wizardsplit), `l` (wizardsplit), `j` (wizardsplit), `k` (wizardsplit), `<Left>` (wizardsplit), `<Right>` (wizardsplit), `<Down>` (wizardsplit), `<Up>` (wizardsplit) | Split: the board's cursor: h l the part before or after in time, j k the agent below or above |
| `page.move` `<h|j|k|l>` | `h` (goalpage), `l` (goalpage), `j` (goalpage), `k` (goalpage) | the goal's page: h l the part before or after in time, j k the agent below or above (without a part: the goals) |
| `personas.move` `<1|-1>` | `j` (personaadd), `k` (personaadd), `<Down>` (personaadd), `<Up>` (personaadd), `j` (personas), `k` (personas) | Personas: the persona below (1) or above (-1) |
| `panel.row` `<1|-1>` | `j` (sessionspanel), `k` (sessionspanel), `<Down>` (sessionspanel), `<Up>` (sessionspanel), `j` (sessionspanelpr), `k` (sessionspanelpr), `<Down>` (sessionspanelpr), `<Up>` (sessionspanelpr) | the panel's popover: the persona below (1) or above (-1) |
| `personas.signal` `<1|-1>` | `j` (personasessions), `k` (personasessions) | Personas in sessions: the milestone below (1) or above (-1) |

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
| `view` `<sessions|attention|browse|inbox|issues|prs|watch|repos|insights|history|timeline|ledger|dashboard|mindmap|standup|goals|log>` |  | switch view |
| `view.sessions` | `gs` | sessions |
| `view.attention` `[filter]` | `gm`, `gi`, `gp` | attention: what wants you, with why, the thread beside it (a tab: foryou, reviews, mentions, mine, ...) |
| `view.browse` | `gb` | browse: the issues and PRs of an org or a repo, searched on GitHub, the thread beside them |
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
| `goal.doc` | `E` (goalagents), `E` (goalboard), `E` (goaldoc), `E` (goalevals), `E` (goalmap), `E` (goalpage), `E` (goalpersonas), `E` (goalplan), `E` (goalreviewers), `E` (goals), `E` (unassigned) | Goals: the goal's GOAL.md and its versions (again: the overview) |
| `goal.board` | `B` (goalagents), `B` (goalboard), `B` (goaldoc), `B` (goalevals), `B` (goalmap), `B` (goalpage), `B` (goalpersonas), `B` (goalplan), `B` (goalreviewers), `B` (goals), `B` (unassigned) | Goals: the goal as a board, its items by column (again: the overview) |
| `goal.unassigned` | `U` (goalagents), `U` (goalboard), `U` (goaldoc), `U` (goalevals), `U` (goalmap), `U` (goalpage), `U` (goalpersonas), `U` (goalplan), `U` (goalreviewers), `U` (goals), `U` (unassigned) | Goals › Unassigned: how heed put new work on goals, its asks, and goals it suggests (again: the overview) |
| `goal.reviewers` | `R` (goalagents), `R` (goalboard), `R` (goaldoc), `R` (goalevals), `R` (goalmap), `R` (goalpage), `R` (goalpersonas), `R` (goalplan), `R` (goalreviewers), `R` (goals), `R` (unassigned) | Goals: the goal's reviewers, their scores and objections, and its quality bars (again: the overview) |
| `goal.personas` | `P` (goalagents), `P` (goalboard), `P` (goaldoc), `P` (goalevals), `P` (goalmap), `P` (goalpage), `P` (goalpersonas), `P` (goalplan), `P` (goalreviewers), `P` (goals), `P` (unassigned) | Goals: who the goal needs, why now, how much of their work they have looked at (again: the overview) |
| `goal.evaluations` | `X` (goalagents), `X` (goalboard), `X` (goaldoc), `X` (goalevals), `X` (goalmap), `X` (goalpage), `X` (goalpersonas), `X` (goalplan), `X` (goalreviewers), `X` (goals), `X` (unassigned) | Goals: stranger walks of the goal, their friction logs and scores, by lens (again: the overview) |
| `goal.swarm` | `S` (goalagents), `S` (goalboard), `S` (goaldoc), `S` (goalevals), `S` (goalmap), `S` (goalpage), `S` (goalpersonas), `S` (goalplan), `S` (goalreviewers), `S` (goals), `S` (unassigned) | Goals: the goal's swarm: its plan by phase, the lead's questions, versions and steering (again: the overview) |
| `goal.agents` | `W` (goalagents), `W` (goalboard), `W` (goaldoc), `W` (goalevals), `W` (goalmap), `W` (goalpage), `W` (goalpersonas), `W` (goalplan), `W` (goalreviewers), `W` (goals), `W` (unassigned) | Goals: the swarm's agents: what each does and for how long, stuck or not, its notes and activity, and what needs you; once done, its summary (again: the overview) |
| `goal.map` | `V` (goalagents), `V` (goalboard), `V` (goaldoc), `V` (goalevals), `V` (goalmap), `V` (goalpage), `V` (goalpersonas), `V` (goalplan), `V` (goalreviewers), `V` (goals), `V` (unassigned) | Goals: the swarm as a map: phases as columns, tasks as cards by state, dependencies as edges (again: the overview) |
| `overlay.pr` |  | PR overlay for this session (toggle) |
| `overlay.item` | `go` | open the PR or issue under the cursor; in Sessions, the session's PR (toggle) |
| `overlay.diff` | `gd` | diff overlay: commits, staged, unstaged |
| `overlay.help` | `?`, `<D-/>`, `?` (VISUAL), `<D-/>` (VISUAL), `<D-/>` (INSERT), `<D-/>` (COMMAND) | keys & states |
| `overlay.close` | `<Esc>`, `<Esc>` (approvals), `<Esc>` (diff), `<Esc>` (issue), `<Esc>` (pr) | close overlay |
| `approvals.open` | `gy`, `gy` (approvals) | what agents ask permission for, from every session, oldest first (toggle) |
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
| `sessions.group` `[status|campaign|repo|none]` | `zG` (sessions), `zG` (sessionshelper), `zG` (sessionshelpers), `zG` (sessionsoffer), `zG` (sessionspanel), `zG` (sessionspanelchat), `zG` (sessionspanelpr), `zG` (sessionspromote) | group the sessions by status, campaign, repo or not at all (no argument: the next) |
| `sessions.sort` `[attention|touched|idle|started|size]` | `T` (sessions), `T` (sessionshelper), `T` (sessionshelpers), `T` (sessionsoffer), `T` (sessionspanel), `T` (sessionspanelchat), `T` (sessionspanelpr), `T` (sessionspromote) | sort the sessions: attention, you recent first, idle longest, started, size (no argument: next) |
| `sessions.rows` `[one|two]` | `zR` (sessions), `zR` (sessionshelper), `zR` (sessionshelpers), `zR` (sessionsoffer), `zR` (sessionspanel), `zR` (sessionspanelchat), `zR` (sessionspanelpr), `zR` (sessionspromote) | one line or two per session in the sidebar |
| `sessions.close.ready` | `X` (sessions), `X` (sessionshelpers), `X` (sessionsoffer), `X` (sessionspanel), `X` (sessionspanelchat), `X` (sessionspanelpr), `X` (sessionspromote) | close every session in Can close (its PRs merged or closed, nothing left open), after asking |
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
| `history.list` | `H` (audit), `H` (dashboard), `H` (history), `H` (ledger), `H` (mindmap), `H` (standup), `H` (telemetry) | Insights' History: the work that ended, by day, each with its story (again: the dashboard) |
| `history.timeline` |  | History with every event as its own line (again: folded), as history.events |
| `history.ledger` | `L` (audit), `L` (dashboard), `L` (history), `L` (ledger), `L` (mindmap), `L` (standup), `L` (telemetry) | Insights' ledger: a summary of each piece of work (again: back to the dashboard) |
| `history.dashboard` | `D` (audit), `D` (dashboard), `D` (history), `D` (ledger), `D` (mindmap), `D` (standup), `D` (telemetry) | Insights' dashboard: what shipped, agent time, your bests, goals; where Insights opens |
| `history.standup` | `U` (audit), `U` (dashboard), `U` (history), `U` (ledger), `U` (mindmap), `U` (standup), `U` (telemetry) | Insights' standup: your questions answered per org (again: back to the dashboard) |
| `history.telemetry` | `T` (audit), `T` (dashboard), `T` (history), `T` (ledger), `T` (mindmap), `T` (standup), `T` (telemetry) | Insights' OpenTelemetry: the agents' own spans, latency, waits and cost (again: back to the dashboard) |
| `history.audit` | `A` (audit), `A` (dashboard), `A` (history), `A` (ledger), `A` (mindmap), `A` (standup), `A` (telemetry) | Insights' Audit: what heed and your agents did outside this Mac, and why (again: back to the dashboard) |
| `session.trace` `[session]` | `t` (sessions), `t` (sessionshelper), `t` (sessionshelpers), `t` (sessionsoffer), `t` (sessionspanel), `t` (sessionspanelchat), `t` (sessionspanelpr), `t` (sessionspromote), `t` (trace), `<Esc>` (trace) | a session's trace from its agent's OpenTelemetry: its last turns, span by span (again: back) |
| `history.mindmap` | `M` (audit), `M` (dashboard), `M` (history), `M` (ledger), `M` (mindmap), `M` (standup), `M` (telemetry) | Insights' Mindmap: the work grouped into campaigns, per org (again: back to the dashboard) |
| `goal.wizard` `[goal]` |  | Goals: walk the goal through the new-goal wizard (plan, panel, done looks like, …); where it was left, it resumes |
| `goal.tldr` | `T` (goalagents), `T` (goalboard), `T` (goaldoc), `T` (goalevals), `T` (goalmap), `T` (goalpage), `T` (goalpersonas), `T` (goalplan), `T` (goalreviewers), `T` (goals), `T` (splitdefine), `T` (splitfold), `T` (tldr), `<Esc>` (tldr), `q` (tldr), `T` (unassigned), `T` (wizardcareful), `T` (wizardchat), `T` (wizarddone), `T` (wizardgo), `T` (wizardpanel), `T` (wizardplan), `T` (wizardsplit) | the goal's TL;DR: each step's summary, what is settled, what is still open (toggle) |
| `personas.open` |  | Settings › Personas: the people heed asks for a view, in one library |
| `personas.sessions` | `s` (personas), `s` (personasessions), `<Esc>` (personasessions) | Settings › Personas: the library, or when personas look at sessions |

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
| `approvals.next` | `j` (approvals), `<Down>` (approvals) | approvals: the next request |
| `approvals.prev` | `k` (approvals), `<Up>` (approvals) | approvals: the request before |
| `approvals.allow` | `y` (approvals) | approvals: allow the selected request; the next one is selected |
| `approvals.deny` `[reason]` | `n` (approvals) | approvals: deny the selected request, telling the agent why when given |
| `approvals.deny.reason` | `t` (approvals) | approvals: deny the selected request with a reason you type |
| `approvals.always` | `a` (approvals) | approvals: allow, and save the agent's own allow rule in this repo (Claude Code) |
| `approvals.allow.all` | `Y` (approvals) | approvals: allow every request heed can answer |
| `approvals.deny.all` | `N` (approvals) | approvals: deny every request heed can answer |
| `approvals.allow.read` | `r` (approvals) | approvals: allow every read-only request inside its worktree |
| `approvals.session` | `gS` (approvals) | approvals: go to the selected request's session |
| `select.toggle` | `<Space>` (VISUAL), `<Space>` (attention), `<Space>` (attentionhelper), `<Space>` (attentionother), `<Space>` (browse), `<Space>` (browsebulk), `<Space>` (prs), `<Space>` (swarmask), `<Space>` (watch), `<Space>` (watchhelper) | toggle row |
| `history.reopen` | `R` (dashboard), `R` (history), `<CR>` (history), `R` (ledger), `<CR>` (ledger) | reopen: resume, recreating the worktree if needed |
| `history.again` | `O` (history) | start a new session from this prompt |
| `history.outcome` `[outcome]` | `t` (history) | History: the next outcome filter, or one by name (all, merged, …) |
| `history.events` | `e` (history) | History: every event as its own line, or folded into its piece of work again |
| `timeline.kind` `[kind]` | `K` (history) | History: every kind, or one (sessions, worktrees, prs, questions, chats) |
| `timeline.repo` `[name]` | `r` (history) | History: every repo, or the next one |
| `timeline.where` `[local|host]` | `w` (history) | History: everywhere, this Mac, or a host |
| `timeline.gone` | `c` (history) | History: show or hide removed worktrees |
| `audit.grants` | `<Tab>` (audit) | Audit: the grants heed gave for good (Always rules, trust), or the actions again |
| `audit.revoke` | `d` (audit) | Audit: take back the grant under the cursor (asks first) |
| `audit.session` | `<CR>` (audit) | Audit: the session the action under the cursor came from |
| `audit.export` |  | Audit: write its record to a JSON lines file you pick |
| `telemetry.range` `[range]` | `r` (telemetry) | OpenTelemetry: the next range (15 m, 1 h, 6 h, 24 h, 7 d), or one named (30m) |
| `telemetry.agent` `[agent]` | `a` (telemetry) | OpenTelemetry: only the next agent, then all again (or the one named) |
| `telemetry.repo` `[repo]` | `p` (telemetry) | OpenTelemetry: only the next repo, then all again (or the one named) |
| `telemetry.model` `[model]` | `m` (telemetry) | OpenTelemetry: only the next model, then all again (or the one named) |
| `telemetry.kind` `[kind]` | `K` (telemetry) | OpenTelemetry: which spans the table lists: turns, tools, waits and model; all; one kind |
| `telemetry.live` | `l` (telemetry) | OpenTelemetry: stop or start redrawing as spans arrive |
| `telemetry.open` | `<CR>` (telemetry) | OpenTelemetry: the span's session's trace, on its turn |
| `telemetry.proxy.off` | `P` (telemetry) | OpenTelemetry: stop forwarding agents you set up yourself through heed ([telemetry] proxy = false) |
| `telemetry.banner.hide` | `x` (telemetry) | OpenTelemetry: put the forwarding banner away until heed starts again |
| `standup.run` | `S` (standup) | standup: write a report for this org now |
| `standup.copy` `[plain]` | `y` (standup) | standup: copy the answer to the question shown (all with none), as markdown |
| `standup.copy.all` `[plain]` | `Y` (standup) | standup: copy the whole report, as markdown |
| `standup.question` | `t` (standup) | standup: show one question's answers, the next, or all again |
| `standup.org.next` | `]o` (standup) | standup: the next org's reports (personal last) |
| `standup.org.prev` | `[o` (standup) | standup: the previous org's reports |
| `dashboard.range` `[days]` | `r` (dashboard) | dashboard: the next range (7 days, 4 weeks, 12 weeks), or one in days or weeks (2w) |
| `goal.new` `[title]` | `n` (goalpage), `n` (goals) | new goal: a title and what it is (on a session: from its prompt, and the session on it) |
| `goal.attach` `<goal>` |  | put the session or chat on a goal (no goal: the command line opens to pick one) |
| `goal.promote` | `gP`, `<Esc>` (sessionspromote) | make the session a goal: what it becomes, its merged PRs done, then its plan step (again or ⎋: close) |
| `goal.promote.go` | `<CR>` (sessionspromote), `<D-CR>` (sessionspromote) | Make it a goal: the goal made with the session on it as part 1, its plan step opens |
| `goal.promote.skip` | `s` (sessionspromote) | Make it a goal: stop waiting for the agent's handoff and make the goal from the session's prompt |
| `goal.promote.dismiss` | `x` (sessionspromote) | not now: the session's "growing into a goal" line goes away |
| `goal.detach` | `x` (goaldoc), `x` (goalpage), `x` (goals) | take the session or chat off its goal |
| `goal.archive` | `a` (goaldoc), `a` (goalpage), `a` (goals) | archive the goal (again: bring it back) |
| `goal.open` | `<CR>` (goaldoc), `<CR>` (goalevals), `<CR>` (goalpersonas), `<CR>` (goalplan), `<CR>` (goalreviewers), `<CR>` (goals), `<CR>` (unassigned) | Goals: what belongs to the goal; on a session or chat, go to it |
| `goal.focus` | `<Tab>` (goalagents), `<S-Tab>` (goalagents), `<Tab>` (goaldoc), `<S-Tab>` (goaldoc), `<Tab>` (goalevals), `<S-Tab>` (goalevals), `<Tab>` (goalpage), `<S-Tab>` (goalpage), `<Tab>` (goalpersonas), `<S-Tab>` (goalpersonas), `<Tab>` (goalplan), `<S-Tab>` (goalplan), `<Tab>` (goalreviewers), `<S-Tab>` (goalreviewers), `<Tab>` (goals), `<S-Tab>` (goals) | Goals: between the goals and what belongs to the goal |
| `goal.edit` | `e` (goaldoc), `e` (goalpage), `e` (goals) | edit the goal's GOAL.md in place; each save is a new version |
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
| `goal.sharpen` | `w` (goaldoc), `w` (goalpage), `w` (goals) | GOAL.md: ask a model to sharpen the goal; what it suggests waits for you |
| `goal.guide` |  | Goals: hide the goal's next-steps card (it comes back if a step it ticked off goes back), or show it again |
| `goal.ask.yes` | `y` (attention), `y` (attentionother), `y` (swarmask), `y` (unassigned) | yes: on the goal heed proposed (on a suggested goal: make it) |
| `goal.ask.no` | `n` (attention), `n` (attentionother), `n` (swarmask), `n` (unassigned) | no: not on that goal, and heed learns it (on a suggested goal: drop it) |
| `goal.ask.move` `<goal>` | `m` (attention), `m` (attentionhelper), `m` (attentionother), `m` (swarmask), `m` (unassigned) | on another goal instead, and heed learns it was not the one it proposed |
| `goal.ask.ignore` | `i` (attention), `i` (attentionother), `i` (unassigned) | leave things like this on no goal, and heed learns to (an ignore rule) |
| `goal.unassigned.how` | `g?` (unassigned) | Unassigned: show or hide how heed puts work on goals (shown on its own only while nothing waits for you) |
| `goal.attach.undo` | `u` (goalpage), `u` (goals), `u` (unassigned) | take heed's last attachment off again, and heed learns it (a never rule) |
| `goal.attach.find` |  | look for the session's goal now: rules, signals, the model when unsure |
| `goal.bar` `<lens> <bar|off|auto>` |  | pin a quality bar for the goal: a lens and 0–10, off to drop the lens, auto for the profile's |
| `goal.bars.accept` | `y` (goalreviewers) | Reviewers: these quality bars are right for the goal (recorded as yours; the first steps tick off on it) |
| `goal.mirror` | `M` (goalagents), `M` (goalboard), `M` (goaldoc), `M` (goalevals), `M` (goalmap), `M` (goalpage), `M` (goalpersonas), `M` (goalplan), `M` (goalreviewers), `M` (goals), `M` (unassigned) | mirror the goal to GitHub (its tracker checked first; heed keeps it up to date); again: stop |
| `goal.tracker` `[org/name|none]` |  | the repo the goal mirrors to on GitHub, checked read-only first (none: no tracker) |
| `goal.mirror.sync` |  | sync the goal's GitHub issues now and read them back |
| `goal.mirror.open` |  | open the goal's meta issue on GitHub (on a card: its sub-issue) |
| `goal.mirror.yes` | `Y` (goalagents), `Y` (goalboard), `Y` (goaldoc), `Y` (goalevals), `Y` (goalmap), `Y` (goalpage), `Y` (goalpersonas), `Y` (goalplan), `Y` (goalreviewers), `Y` (goals), `Y` (unassigned) | a colleague's change on GitHub: yes, the item follows it |
| `goal.mirror.no` | `K` (goalagents), `K` (goalboard), `K` (goaldoc), `K` (goalevals), `K` (goalmap), `K` (goalpage), `K` (goalpersonas), `K` (goalreviewers), `K` (goals), `K` (unassigned) | a colleague's change on GitHub: no, heed puts the sub-issue back |
| `goal.source.add` `[query]` |  | a GitHub query the goal's items come from, one item per PR or issue (prs org/repo, issues org/repo, label <name>, reviews, milestone <title> org/repo, or a search); none: the source dialog |
| `goal.source.remove` `[id]` |  | take a source off the goal (its items stay, marked) |
| `goal.source.edit` `<id> [query]` |  | change a source's query and rule (its items stay; none: the source dialog) |
| `goal.source.rule` `<id> <rule>` |  | what done means for a source's items: merged, closed, reviewed (by you) or green |
| `goal.source.accept` | `y` (goalpage), `y` (goals) | yes to the source heed proposes for the goal |
| `goal.source.dismiss` |  | no to the source heed proposes (not proposed again) |
| `goal.source.sync` |  | sync the goal's sources with GitHub now |
| `goal.reopen` |  | not done yet: undo heed marking the goal done (held until something new) |
| `swarm.new` `[title]` |  | new swarm: a new goal through the wizard (a goal with lanes is a swarm; Go starts it); same as n in Goals |
| `swarm.start` |  | swarm this goal: its wizard, where Split puts its parts on agents and Go starts them |
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
| `swarm.followup` | `F` (goalagents), `F` (goaldoc), `F` (goalmap), `F` (goalpage), `F` (goalplan), `F` (goals) | start a follow-up swarm on the goal: the last one's team and limits, its follow-ups for the lead (the form first) |
| `swarm.summary` |  | the swarm's end-of-build summary: written again from its record, and the lead asked to write its part |
| `swarm.stuck` `<estimate|errors|quiet|peer|you> <value>` |  | when the goal's swarm counts a worker as stuck: estimate (×), errors, quiet, peer and you (minutes) |
| `swarm.merge` `<off|auto|heed|repo>` |  | get it merged for the goal's swarm's PRs: off, auto, heed, or repo (each PR's repo says; the default). In merge order either way |
| `swarm.rule.delete` `[rule number]` |  | delete one of the goal's repeat rules: the controller stops answering with it |
| `review.recheck` `[reviewer]` | `r` (goaldoc), `r` (goalpage), `r` (goalreviewers), `r` (goals) | re-check: the reviewer under the cursor looks again now (elsewhere in Goals: every reviewer the goal needs) |
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
| `mindmap.accept` | `y` (mindmap) | Mindmap: keep the suggested placement as it is, or the decisions an agent proposed |
| `mindmap.decline` | `N` (mindmap) | Mindmap: drop the decisions an agent proposed on the node |
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
| `github.sync` | `r` (attention), `r` (attentionhelper), `r` (attentionother), `r` (pr), `r` (prs), `r` (swarmask), `r` (watch), `r` (watchhelper) | sync GitHub now |
| `items.start` | `s` (attention), `s` (attentionhelper), `s` (attentionother), `s` (issue), `s` (swarmask) | start one session from the picked items |
| `items.add` | `a` (attention), `a` (attentionhelper), `a` (attentionother), `a` (issue), `a` (swarmask) | add the picked items to the current session |
| `attention.done` | `x` (attention), `x` (attentionhelper), `x` (attentionother), `x` (swarmask) | done: mark the thread read on GitHub; it comes back when something new happens |
| `attention.snooze` `[duration]` | `Z` (attention), `Z` (attentionhelper), `Z` (attentionother), `Z` (swarmask) | snooze: out of the feed until later (3h, or 30m, 2d, tomorrow) |
| `attention.mute` | `M` (attention), `M` (attentionhelper), `M` (attentionother), `M` (swarmask) | mute the thread on GitHub (no more notifications about it); listed under Muted |
| `attention.reply` | `R` (attention), `R` (attentionhelper), `R` (attentionother), `R` (swarmask) | draft a reply with the model; you read it before anything is posted |
| `browse.open` | `<CR>` (browse), `<CR>` (browsebulk) | Browse: load the item under the cursor into the reader now |
| `browse.scope` | `<D-k>` (browse), `<D-k>` (browsebulk) | Browse: jump to an org or a repo (type to find it) |
| `browse.scope.next` | `]o` (browse), `]o` (browsebulk) | Browse: the next scope in the rail |
| `browse.scope.prev` | `[o` (browse), `[o` (browsebulk) | Browse: the previous scope in the rail |
| `browse.scope.toggle` | `za` (browse), `za` (browsebulk) | Browse: open or close the repos under the current org in the rail |
| `browse.query.next` | `]q` (browse), `]q` (browsebulk) | Browse: the next saved query |
| `browse.query.prev` | `[q` (browse), `[q` (browsebulk) | Browse: the previous saved query |
| `browse.query.save` | `S` (browse) | Browse: keep the query you are on in the rail |
| `browse.older` | `e` (browse), `e` (browsebulk) | Browse: show items older than the cap, or go back to it |
| `browse.refresh` | `r` (browse), `r` (browsebulk) | Browse: refresh the list |
| `browse.sort` | `T` (browse), `T` (browsebulk) | Browse: next sort (updated, created, comments, oldest) |
| `browse.filter.add` | `/` (browse), `/` (browsebulk) | Browse: add a filter: pick a field, type words, or paste a GitHub query |
| `browse.filter.remove` | `x` (browse) | Browse: take the last filter off the query |
| `browse.query.rename` | `N` (browse), `N` (browsebulk) | Browse: rename the saved query you are on, or change its glyph and tint |
| `browse.query.delete` | `D` (browse), `D` (browsebulk) | Browse: remove the saved query you are on from the rail |
| `browse.query.up` | `[Q` (browse), `[Q` (browsebulk) | Browse: move the saved query you are on one place up the rail |
| `browse.query.down` | `]Q` (browse), `]Q` (browsebulk) | Browse: move the saved query you are on one place down the rail |
| `browse.view.new` |  | Browse: make a view of the org you are in (a language, archived or not) and pin it |
| `browse.read` | `U` (browse), `U` (browsebulk) | Browse: heed reads the items under the cursor or picked (class, size, how agent-ready, a TL;DR), again if stale |
| `browse.fix` | `F` (browse), `F` (browsebulk) | Browse: work on the item with an agent: reproduce, fix, test, open a PR |
| `browse.implement` | `I` (browse), `I` (browsebulk) | Browse: work on the item with an agent: build it with tests, open a PR |
| `browse.chat` | `C` (browse), `C` (browsebulk) | Browse: chat about the item with an agent, no edits |
| `browse.review` | `R` (browse), `R` (browsebulk) | Browse: review the pull request with an agent; nothing is posted without you |
| `browse.tell` | `t` (browse), `t` (browsebulk) | Browse: tell an agent what to do with the item, in your own words |
| `browse.run.close` | `<Esc>` (browse), `<Esc>` (browsebulk) | Browse: close the agent run under the cursor and remove its temporary worktree (a branch it pushed stays); with items picked, clear the picks; on a pushed reader, go back to the list |
| `browse.run.keep` | `s` (browse) | Browse: keep the agent run as a session: its worktree moves under heed's usual naming and a session opens in it |
| `browse.run.steer` | `i` (browse), `i` (browsebulk) | Browse: steer the agent run, or ask it a follow-up |
| `browse.run.review.post` | `P` (browse), `P` (browsebulk) | Browse: post the review the agent drafted to the pull request (public: only on this key) |
| `browse.run.review.edit` | `E` (browse), `E` (browsebulk) | Browse: ask the agent to change the review it drafted before you post it |
| `browse.run.review.discard` | `X` (browse), `X` (browsebulk) | Browse: throw the drafted review away; nothing is posted |
| `browse.select.all` | `a` (browse), `a` (browsebulk) | Browse: pick every item in the view (again: none) |
| `browse.bulk.session` | `s` (browsebulk) | Browse, with items picked: one session for all of them, in every repo they are in, its prompt listing each issue with a Closes line |
| `browse.bulk.goal` | `G` (browsebulk) | Browse, with items picked: a goal from all of them, planned with you first |
| `browse.bulk.each` | `S` (browsebulk) | Browse, with items picked: one session per repo (asks first above 5) |
| `browse.bulk.label` | `1` (browsebulk) | Browse, with items picked: add labels to all on GitHub, after a confirm step |
| `browse.bulk.assign` | `A` (browsebulk) | Browse, with items picked: assign all to you on GitHub, after a confirm step |
| `browse.bulk.comment` | `c` (browsebulk) | Browse, with items picked: comment on all on GitHub, after a confirm step |
| `browse.bulk.close` | `x` (browsebulk) | Browse, with items picked: close all on GitHub as completed or not planned, after a confirm step |
| `browse.clone.go` |  | Browse: clone the repo, then start the agent run |
| `browse.clone.only` | `c` (browse) | Browse: clone the repo and stop there |
| `browse.clone.folder` | `d` (browse), `d` (browsebulk) | Browse: choose the folder the repo is cloned into |
| `attention.session` | `gS` (attention), `gS` (attentionhelper), `gS` (attentionother), `gS` (swarmask) | go to the item's session |
| `attention.filter` `[filter]` | `t` (attention), `t` (attentionhelper), `t` (attentionother), `t` (swarmask) | next Attention tab (Muted after Everything), or the one named |
| `attention.done.new` | `X` (attention), `X` (attentionother), `X` (swarmask) | done with everything in For you's New since |
| `attention.fold` | `za` (attention), `za` (attentionhelper), `za` (attentionother), `za` (swarmask) | For you's Mentioned before: list it, or fold it again |
| `attention.reader.down` | `<C-e>` (attention), `<C-e>` (attentionhelper), `<C-e>` (attentionother), `<C-e>` (swarmask) | scroll Attention's reader down half its height |
| `attention.reader.up` | `<C-y>` (attention), `<C-y>` (attentionhelper), `<C-y>` (attentionother), `<C-y>` (swarmask) | scroll Attention's reader up half its height |
| `attention.sort` | `T` (attention), `T` (attentionhelper), `T` (attentionother), `T` (swarmask) | Attention: recent first, or weight then recent |
| `attention.summarize` | `U` (attention), `U` (attentionhelper), `U` (attentionother), `U` (swarmask) | write the thread's catch-up summary again (↻): what is new since you last looked |
| `attention.coverage` |  | Coverage: what Attention has of each source against GitHub, and where it went |
| `helper.do` | `D` (attention), `D` (attentionhelper), `D` (attentionother), `D` (swarmask) | do heed's next step for the item (review it, draft a reply, get it green, merge, set up Autopilot, start work) |
| `helper.always` | `Y` (attention), `Y` (attentionother), `Y` (swarmask) | do heed's next step, and from now on always in this repo (turns its Autopilot capability on) |
| `helper.other` | `.` (attention), `.` (attentionhelper), `.` (attentionother), `.` (swarmask) | Other: a small menu of the item's other next steps and what else you can do with it |
| `helper.watch` | `gW` | Watch it: the helper on the session's PR in a split under its panes; with more than one, the list of them |
| `helper.menu.next` | `j` (attentionother), `<Down>` (attentionother), `j` (sessionshelpers), `<Down>` (sessionshelpers) | the next row of the open menu (Other, or the session's helpers) |
| `helper.menu.prev` | `k` (attentionother), `<Up>` (attentionother), `k` (sessionshelpers), `<Up>` (sessionshelpers) | the previous row of the open menu |
| `helper.menu.pick` | `<CR>` (attentionother), `<CR>` (sessionshelpers) | do the menu's row: propose that step, run that action, or watch that helper |
| `helper.menu.close` | `<Esc>` (attentionother), `<Esc>` (sessionshelpers) | close the menu |
| `helper.dismiss` | `x` (sessionshelpers) | take a finished helper off the session's line (all of them, outside the list) |
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
| `pilot.run` | `gv` | show the session's running get it green / get it merged run |
| `pilot.run.stop` | `zx` | stop the session's running get it green / get it merged run |
| `pilot.retry` | `zr` | one more round of get it green for a stalled PR (or the picked PRs) |
| `pilot.copilot` | `C` (pr), `A` (watch), `A` (watchhelper) | ask GitHub's Copilot coding agent to resolve the PR's conflicts and address its comments |
| `pilot.reviewers` | `zv` | ask the PR's configured reviewers ([pilot] reviewers) to review it |
| `pilot.reviewers.trust` `[login]` | `zT` (watch), `zT` (watchhelper) | trust a bot that reviews the PR's repo: add it to the repo's trusted_reviewers (no name: the first heed suggests) |
| `pilot.reviewers.dismiss` `[login]` | `zD` (watch), `zD` (watchhelper) | stop suggesting a bot that reviews the PR's repo for trusted_reviewers (no name: the first heed suggests) |
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
| `wizard.leave` | `<Esc>` (wizardcareful), `<Esc>` (wizarddone), `<Esc>` (wizardgo), `<Esc>` (wizardpanel), `<Esc>` (wizardplan), `<Esc>` (wizardsplit) | wizard: back to the goals; it keeps its place |
| `wizard.discard` | `D` (splitfold), `D` (wizardcareful), `D` (wizarddone), `D` (wizardgo), `D` (wizardpanel), `D` (wizardplan), `D` (wizardsplit) | wizard: discard this goal: deleted for good when nothing is attached to it, else archived (a in the Goals list brings it back); asks first |
| `wizard.next` | `<D-CR>` (splitfold), `<D-CR>` (wizardcareful), `<D-CR>` (wizarddone), `<D-CR>` (wizardpanel), `<D-CR>` (wizardplan), `<D-CR>` (wizardsplit) | wizard: on to the next step (Plan: good enough; Panel: worth it, take the fixes; Done looks like: looks right) |
| `wizard.step` `<step>` | `H` (splitfold), `L` (splitfold), `H` (wizardcareful), `L` (wizardcareful), `H` (wizarddone), `L` (wizarddone), `H` (wizardgo), `L` (wizardgo), `H` (wizardpanel), `L` (wizardpanel), `H` (wizardplan), `L` (wizardplan), `H` (wizardsplit), `L` (wizardsplit) | wizard: show a step already reached (prev, next, or a name) |
| `wizard.pick` `<n>` | `1` (wizarddone), `2` (wizarddone), `3` (wizarddone), `1` (wizardplan), `2` (wizardplan), `3` (wizardplan), `4` (wizardplan), `5` (wizardplan), `6` (wizardplan), `7` (wizardplan), `8` (wizardplan), `9` (wizardplan) | wizard: Plan answers with option n; Done looks like highlights replacement n |
| `wizard.answer` | `i` (wizardchat), `i` (wizardplan) | wizard: type an answer (Plan), or a message to the persona you talk to |
| `wizard.smaller` | `-` (wizardpanel) | wizard: Panel: make the plan smaller, and the panel reads it again |
| `wizard.talk` | `<Esc>` (wizardchat), `i` (wizardpanel) | wizard: Panel: talk to the persona under the cursor (again: close) |
| `wizard.drop` | `x` (wizardpanel) | wizard: Panel: don't do it: archive the goal with the reason |
| `wizard.invite` `[persona]` | `<Esc>` (wizardinvite), `+` (wizardpanel) | wizard: Panel: invite another persona (the picker; with a name, that one) |
| `wizard.invite.pick` | `<CR>` (wizardinvite) | wizard: invite the persona under the cursor in the picker |
| `wizard.use` | `<CR>` (wizarddone) | wizard: Done looks like: use the highlighted replacement for the criterion |
| `wizard.define` `[n]` | `d` (wizarddone) | wizard: Done looks like: an agent reads the repo and proposes a check for the criterion |
| `careful.pick` `<1|2|3>` | `1` (wizardcareful), `2` (wizardcareful), `3` (wizardcareful) | wizard: How careful: pick Quick (1), Standard (2) or Thorough (3) |
| `careful.details` | `Q` (wizardcareful) | wizard: How careful: the goal's reviewers, bars and lenses behind each level (the wizard keeps its place) |
| `go.pick` `<n>` | `1` (wizardgo), `2` (wizardgo), `3` (wizardgo) | wizard: Go: option n on the row under the cursor |
| `go.step` `<delta>` | `h` (wizardgo), `l` (wizardgo), `<Left>` (wizardgo), `<Right>` (wizardgo) | wizard: Go: the next (1) or previous (-1) option on the row |
| `go.start` | `<D-CR>` (wizardgo) | wizard: Go: start it: the split becomes the swarm's approved plan, its first parts start, the goal's page shows |
| `go.save` | `S` (wizardgo) | wizard: Go: save it, start later; the wizard waits at Go |
| `wizard.handoff.edit` | `e` (wizardplan) | wizard: Plan: edit the session's handoff, which is GOAL.md's Handoff section (the wizard waits) |
| `tldr.copy` | `y` (tldr) | TL;DR: copy it as markdown |
| `tldr.act` | `d` (tldr) | TL;DR: do the first open point's action |
| `split.fold` | `<CR>` (splitfold), `<Esc>` (splitfold), `<CR>` (wizardsplit) | Split: fold the part under the cursor out (again: in) |
| `split.agent` `[agent]` | `a` (splitfold), `a` (wizardsplit) | Split: the part on the next agent who should do it (with a name, that agent); it stays where you put it |
| `split.shift` `<1|-1>` | `J` (splitfold), `K` (splitfold), `J` (wizardsplit), `K` (wizardsplit) | Split: move the part to the agent's row below (1) or above (-1) |
| `split.split` | `s` (splitfold), `s` (wizardsplit) | Split: split the part in two (a cheap model call) |
| `split.waits` | `w` (splitfold), `w` (wizardsplit) | Split: what the part waits on: type part numbers (empty: nothing) |
| `split.size` | `Z` (splitfold), `Z` (wizardsplit) | Split: the part's size, round from XS to L; its estimate follows |
| `split.later` | `p` (splitfold), `p` (wizardsplit) | Split: put the part off (Later), or bring it back |
| `split.note` | `i` (splitfold), `i` (wizardsplit) | Split: tell the part's agent something before it starts |
| `split.define` | `d` (splitfold), `d` (wizardsplit) | Split: define the part with its agent: an ACP session that reads the repo and writes nothing |
| `split.balance` `[credits|speed|fewest]` | `b` (splitfold), `b` (wizardsplit) | Split: balance for the credits you have, speed, or the fewest agents (round) |
| `split.resplit` | `r` (splitfold), `r` (wizardsplit) | Split: split the plan again (a cheap model call); your changes go |
| `define.answer` | `i` (splitdefine) | defining a part: type an answer to its agent |
| `define.pick` `<n>` | `1` (splitdefine), `2` (splitdefine), `3` (splitdefine) | defining a part: answer the agent's question with option n |
| `define.use` | `<D-CR>` (splitdefine) | defining a part: use this definition: the part takes its done when, estimate and context |
| `define.later` | `p` (splitdefine) | defining a part: put it off; d on the part comes back to the conversation |
| `define.close` | `<Esc>` (splitdefine) | defining a part: close it; nothing changes |
| `page.fold` | `<CR>` (goalpage), `<Esc>` (goalpage) | the goal's page: fold the part out (again: in); without a part, open the goal |
| `page.steer` | `s` (goalpage) | the goal's page: steer the running part: its live helper or worker opens |
| `page.pick` `<n>` |  | the goal's page: answer your next step with option n |
| `page.answer` | `i` (goalpage) | the goal's page: type an answer to your next step |
| `personas.toggle` | `<Space>` (personas) | Personas: turn the persona under the cursor on or off |
| `personas.try` | `t` (personadefine), `t` (personas) | Personas: try the persona on a recent merged PR in its scope (a cheap model call); defining one: another PR |
| `personas.edit` | `e` (personas) | Personas: edit the persona's file in place (again, ⎋ or ⌘S: save it) |
| `personas.share` | `p` (personas) | Personas: copy the persona's file, to send to a teammate |
| `personas.join` `<panels|pr|plans>` |  | Personas: what the persona joins on its own, on or off |
| `personas.add` | `a` (personas) | Personas: add one: heed reads your repos and proposes the people they serve (a cheap model call) |
| `personas.pick` | `<Space>` (personaadd) | Add a persona: pick the proposal under the cursor (again: unpick) |
| `personas.read` | `r` (personaadd) | Add a persona: read the repos picked again and propose again |
| `personas.repo` `<repo>` |  | Add a persona: look at a repo, or not |
| `personas.describe` | `i` (personaadd) | Add a persona: describe one in your words; heed drafts it |
| `personas.overlap` `<sharpen|keep>` | `s` (personaadd), `b` (personaadd) | Add a persona: a proposal that overlaps one you have: sharpen that one, or keep both |
| `personas.drafted` | `<M-CR>` (personaadd) | Add a persona: add the picked as drafted, into the library |
| `personas.define` | `<D-CR>` (personaadd) | Add a persona: define the picked with an agent: an ACP session per persona that reads the repo and writes nothing |
| `personas.answer` | `i` (personadefine) | defining a persona: type an answer to its agent |
| `personas.option` `<n>` | `1` (personadefine), `2` (personadefine), `3` (personadefine) | defining a persona: answer with option n |
| `personas.next` | `n` (personadefine) | defining a persona: the next picked persona |
| `personas.save` | `<D-CR>` (personadefine) | defining a persona: save it into the library |
| `personas.close` | `<Esc>` (personaadd), `<Esc>` (personadefine) | Personas: close Add a persona, or the persona being defined (nothing saved) |
| `panel.ask` `[persona…]` | `gL` | ask the panel for a look at the session's work: yes to its offer, open its verdict, or ask now (a cheap model call); with names, only those personas |
| `panel.notnow` | `x` (sessionsoffer) | the panel's offer: not now (the next milestone offers again) |
| `panel.never` | `N` (sessionsoffer) | the panel's offer: never in this session (you can still ask) |
| `panel.open` | `<CR>` (sessionspanel), `<Space>` (sessionspanel), `<Space>` (sessionspanelpr) | the panel's verdict: read the persona under the cursor's full reasoning in place (again: fold it) |
| `panel.send` `[all]` | `s` (sessionspanel), `S` (sessionspanel) | the panel's verdict: send the full reasoning of the persona under the cursor to the agent, or of every persona with `all` (its inbox, else typed under the usual rules) |
| `panel.talk` | `i` (sessionspanel), `<Esc>` (sessionspanelchat) | the panel's verdict: talk to the persona under the cursor (again: close the chat) |
| `panel.say` | `i` (sessionspanelchat) | talking to a persona: type to it |
| `panel.dismiss` | `x` (sessionspanel) | the panel's verdict: dismiss it |
| `panel.close` | `<Esc>` (sessionspanel), `<Esc>` (sessionspanelpr) | close the panel's popover |
| `panel.pr` `<open|concern|hold>` | `<CR>` (sessionspanelpr), `s` (sessionspanelpr), `h` (sessionspanelpr) | a PR held for the panel: let it open, send the concern first, or hold the PR |
| `personas.signal.toggle` | `<Space>` (personasessions) | Personas in sessions: the milestone under the cursor on or off |
