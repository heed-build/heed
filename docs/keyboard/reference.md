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
| `session.agent` | `<CR>` (sessions) | INSERT into the session's agent pane (the focused pane when it has none) |
| `session.open` `<words>` |  | go to the session matching these words |
| `pin.jump` `<1-9>` | `'1`, `'2`, `'3`, `'4`, `'5`, `'6`, `'7`, `'8`, `'9` | jump to pinned session |
| `work.start` | `o` | start work |
| `work.start.panel` |  | start work in the floating panel, as the global shortcut does |
| `resume` |  | pick up where you left off: the sessions to resume, as on launch |
| `summary` | `gZ` | while you were away: what still waits on you, and what merged, ran, finished and closed |
| `work.again` | `O` | start work from this session's prompt |
| `chat.new` `[prompt]` | `gc` | start a chat: an agent in a scratch folder or one you pick, no repo or worktree |
| `chat.promote` |  | turn this chat into work: pick a repo, heed makes a worktree and hands the agent the chat |
| `agent.switch` `[agent]` | `gA` | hand the session to another agent: stop its agent, start that one on a handoff prompt |
| `view.history` | `gh` | history |
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
| `view` `<sessions|attention|inbox|issues|prs|watch|repos|history|timeline|ledger|dashboard|goals|log>` |  | switch view |
| `view.sessions` | `gs` | sessions |
| `view.attention` `[filter]` | `gm`, `gi`, `gp` | attention: everything that wants you, one feed, with why (a filter: tagged, reviews, mine, ...) |
| `view.inbox` |  | inbox |
| `view.issues` |  | issues |
| `view.prs` |  | pull requests |
| `view.watch` | `gw` | watch: the PRs your sessions track, what heed does for each and has done |
| `view.repos` | `gr` | repos & worktrees |
| `view.log` |  | the call log: every command and GitHub call heed made, how long it took, how it ended |
| `view.timeline` |  | History's timeline: sessions, worktrees, PRs and questions, by day |
| `view.dashboard` |  | History's dashboard: what the work amounted to over a range |
| `view.ledger` |  | History's ledger: a summary of each piece of work, kept after its worktree |
| `view.goals` | `gG` | goals: long-running work, what belongs to each goal, and its GOAL.md |
| `goal.doc` | `E` (goalboard), `E` (goaldoc), `E` (goalevals), `E` (goalpersonas), `E` (goalplan), `E` (goalreviewers), `E` (goals), `E` (unassigned) | Goals: the goal's GOAL.md and its versions (again: the overview) |
| `goal.board` | `B` (goalboard), `B` (goaldoc), `B` (goalevals), `B` (goalpersonas), `B` (goalplan), `B` (goalreviewers), `B` (goals), `B` (unassigned) | Goals: the goal as a board, its items by column (again: the overview) |
| `goal.unassigned` | `U` (goalboard), `U` (goaldoc), `U` (goalevals), `U` (goalpersonas), `U` (goalplan), `U` (goalreviewers), `U` (goals), `U` (unassigned) | Goals › Unassigned: how heed put new work on goals, its asks, and goals it suggests (again: the overview) |
| `goal.reviewers` | `R` (goalboard), `R` (goaldoc), `R` (goalevals), `R` (goalpersonas), `R` (goalplan), `R` (goalreviewers), `R` (goals), `R` (unassigned) | Goals: the goal's reviewers, their scores and objections, and its quality bars (again: the overview) |
| `goal.personas` | `P` (goalboard), `P` (goaldoc), `P` (goalevals), `P` (goalpersonas), `P` (goalplan), `P` (goalreviewers), `P` (goals), `P` (unassigned) | Goals: who the goal needs, why now, how much of their work they have looked at (again: the overview) |
| `goal.evaluations` | `X` (goalboard), `X` (goaldoc), `X` (goalevals), `X` (goalpersonas), `X` (goalplan), `X` (goalreviewers), `X` (goals), `X` (unassigned) | Goals: stranger walks of the goal, their friction logs and scores, by lens (again: the overview) |
| `goal.swarm` | `S` (goalboard), `S` (goaldoc), `S` (goalevals), `S` (goalpersonas), `S` (goalplan), `S` (goalreviewers), `S` (goals), `S` (unassigned) | Goals: the goal's swarm: its plan by phase, the lead's questions, versions and steering (again: the overview) |
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
| `host.roots` `[host]` |  | choose where heed looks for repos on a host |
| `agents.stop` |  | stop every agent and shell in every pane (with [sessions] persist = "zmx") |
| `tutor.back` |  | the tutor's previous step, the world as it was then |
| `tutor.skip` |  | skip the tutor's step |
| `tutor.exit` | `<D-.>`, `<D-.>` (INSERT) | leave the tutor; your sessions come back as they were |
| `update.check` |  | look for a new version of heed now (also :update) |
| `tools.detect` |  | find git and gh again (login shell PATH, usual places, [tools]) |
| `app.quit` |  | quit Heed |
| `settings.open` `[section] [tab]` | `<D-,>` | open Settings, on a section (general, agents, inference, colors, cleanup, pilot, attention, keys, hosts); orgs takes a tab (general, green, merged, reviews, instructions) |
| `inference.setup` |  | set up heed's model calls and decisions (Settings › Inference & decisions) |
| `inference.hide` `[always]` |  | hide the title bar's model call setup reminder until the next launch (always: for good) |
| `hunch.download` `[checkpoint]` |  | download (or resume) Hunch's model, english by default; says its size and license first |
| `hunch.cancel` `[checkpoint]` |  | stop Hunch's model download; hunch.download resumes it |
| `hunch.delete` `[checkpoint]` |  | delete Hunch's downloaded model and the head trained on it |
| `hunch.retrain` |  | train Hunch on your corrections now, in the background |
| `hunch.reset` |  | put Hunch back on its checkpoint's own head (the training set stays) |
| `app.activate` |  | bring Heed's window to the front, as the global shortcut does |
| `welcome` |  | show the getting-started checks again |
| `history.timeline` | `T` (dashboard), `T` (history), `T` (ledger), `T` (timeline) | History as a timeline: what happened, by day (again: back to the list) |
| `history.ledger` | `L` (dashboard), `L` (history), `L` (ledger), `L` (timeline) | History's ledger: a summary of each piece of work (again: back to the list) |
| `history.dashboard` | `D` (dashboard), `D` (history), `D` (ledger) | History's dashboard: sessions, agent time, PRs, by day, agent and repo |

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
| `select.toggle` | `<Space>` (VISUAL), `<Space>` (attention), `<Space>` (inbox), `<Space>` (issues), `<Space>` (prs), `<Space>` (watch) | toggle row |
| `history.reopen` | `R` (dashboard), `<CR>` (dashboard), `R` (history), `<CR>` (history), `R` (ledger), `<CR>` (ledger), `R` (timeline), `<CR>` (timeline) | reopen: resume, recreating the worktree if needed |
| `history.again` | `O` (history) | start a new session from this prompt |
| `history.outcome` | `t` (history) | cycle the outcome filter |
| `timeline.kind` `[kind]` | `t` (timeline) | timeline: every kind, or one (sessions, worktrees, prs, questions, chats) |
| `timeline.repo` `[name]` | `r` (timeline) | timeline: every repo, or the next one |
| `timeline.where` `[local|host]` | `w` (timeline) | timeline: everywhere, this Mac, or a host |
| `timeline.gone` | `D` (timeline) | timeline: show or hide removed worktrees |
| `dashboard.range` `[days]` | `r` (dashboard) | dashboard: the next range (7 days, 4 weeks, 12 weeks), or one in days or weeks (2w) |
| `goal.new` `[title]` | `n` (goals) | new goal: a title and what it is (on a session: from its prompt, and the session on it) |
| `goal.attach` `<goal>` |  | put the session or chat on a goal (no goal: the command line opens to pick one) |
| `goal.detach` | `x` (goaldoc), `x` (goals) | take the session or chat off its goal |
| `goal.archive` | `a` (goaldoc), `a` (goals) | archive the goal (again: bring it back) |
| `goal.open` | `<CR>` (goaldoc), `<CR>` (goalevals), `<CR>` (goalpersonas), `<CR>` (goalplan), `<CR>` (goalreviewers), `<CR>` (goals), `<CR>` (unassigned) | Goals: what belongs to the goal; on a session or chat, go to it |
| `goal.focus` | `<Tab>` (goaldoc), `<S-Tab>` (goaldoc), `<Tab>` (goalevals), `<S-Tab>` (goalevals), `<Tab>` (goalpersonas), `<S-Tab>` (goalpersonas), `<Tab>` (goalplan), `<S-Tab>` (goalplan), `<Tab>` (goalreviewers), `<S-Tab>` (goalreviewers), `<Tab>` (goals), `<S-Tab>` (goals) | Goals: between the goals and what belongs to the goal |
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
| `goal.ask.yes` | `y` (attention), `y` (unassigned) | yes: on the goal heed proposed (on a suggested goal: make it) |
| `goal.ask.no` | `n` (attention), `n` (unassigned) | no: not on that goal, and heed learns it (on a suggested goal: drop it) |
| `goal.ask.move` `<goal>` | `m` (attention), `m` (unassigned) | on another goal instead, and heed learns it was not the one it proposed |
| `goal.ask.ignore` | `i` (attention), `i` (unassigned) | leave things like this on no goal, and heed learns to (an ignore rule) |
| `goal.attach.undo` | `u` (goals), `u` (unassigned) | take heed's last attachment off again, and heed learns it (a never rule) |
| `goal.attach.find` |  | look for the session's goal now: rules, signals, the model when unsure |
| `goal.bar` `<lens> <bar|off|auto>` |  | pin a quality bar for the goal: a lens and 0–10, off to drop the lens, auto for the profile's |
| `goal.mirror` | `M` (goalboard), `M` (goaldoc), `M` (goalevals), `M` (goalpersonas), `M` (goalplan), `M` (goalreviewers), `M` (goals), `M` (unassigned) | mirror the goal to GitHub (its tracker checked first; heed keeps it up to date); again: stop |
| `goal.tracker` `[org/name|none]` |  | the repo the goal mirrors to on GitHub, checked read-only first (none: no tracker) |
| `goal.mirror.sync` |  | sync the goal's GitHub issues now and read them back |
| `goal.mirror.open` |  | open the goal's meta issue on GitHub (on a card: its sub-issue) |
| `goal.mirror.yes` | `Y` (goalboard), `Y` (goaldoc), `Y` (goalevals), `Y` (goalpersonas), `Y` (goalplan), `Y` (goalreviewers), `Y` (goals), `Y` (unassigned) | a colleague's change on GitHub: yes, the item follows it |
| `goal.mirror.no` | `K` (goalboard), `K` (goaldoc), `K` (goalevals), `K` (goalpersonas), `K` (goalreviewers), `K` (goals), `K` (unassigned) | a colleague's change on GitHub: no, heed puts the sub-issue back |
| `goal.reopen` |  | not done yet: undo heed marking the goal done (held until something new) |
| `swarm.new` `[title]` |  | new swarm: a goal, where it works, its lead and team, its limits; the lead drafts a plan for you to approve |
| `swarm.start` |  | swarm this goal: a lead drafts a plan for its work (the form first) |
| `swarm.stop` |  | stop the goal's swarm: nothing more starts, its plan and steering stay readable |
| `swarm.pause` |  | pause the goal's swarm (again: resume): nothing more starts, workers at work finish their turn |
| `swarm.approve` | `A` (goalplan) | approve the swarm's plan (or the change waiting for you): its tasks become items |
| `swarm.accept` | `y` (goalplan) | yes to the plan change waiting for you: it becomes the approved plan |
| `swarm.task.pause` | `p` (goalplan) | pause the swarm task under the cursor (again: resume): its worker stops, its worktree stays |
| `swarm.task.swap` `<agent[:model]>` | `t` (goalplan) | hand the swarm task under the cursor to another agent; a working worker hands over its worktree |
| `swarm.task.open` | `s` (goalplan) | the swarm task under the cursor's worker: its tab |
| `swarm.reject` `[why]` | `n` (goalplan) | no to the plan change waiting for you; the lead hears why |
| `swarm.task.edit` | `e` (goalplan) | edit the plan's task under the cursor: a new plan version |
| `swarm.task.add` `[title]` | `a` (goalplan) | add a task after the one under the cursor, in its phase: a new plan version |
| `swarm.task.move` `<1|-1>` | `J` (goalplan), `K` (goalplan) | move the plan's task down (1) or up (-1); past its phase, into the next |
| `swarm.task.drop` | `x` (goalplan) | drop the plan's task under the cursor; nothing waits for it any more |
| `swarm.replan` `[feedback]` | `r` (goalplan) | ask the swarm's lead to re-plan, with your feedback |
| `swarm.answer` `[answer]` | `i` (goalplan) | answer the lead's first open question (or the one clicked) |
| `swarm.answer.option` `<n>` | `1` (goalplan), `2` (goalplan), `3` (goalplan), `4` (goalplan), `5` (goalplan), `6` (goalplan), `7` (goalplan), `8` (goalplan), `9` (goalplan) | answer the lead's first open question with its option n (1 is the first) |
| `swarm.diff` | `d` (goalplan) | the plan version under the cursor's whole diff against the one before (again: short) |
| `swarm.restore` `[version]` | `u` (goalplan) | make a plan version current again, as a new version |
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
| `ledger.edit` `[text]` | `E` (ledger) | edit the ledger entry's summary (no text: the command line opens with it) |
| `log.kind` `[all|kind]` | `t` (log) | call log: all, or one kind (shell, github, llm, decide) |
| `log.failed` | `x` (log) | call log: only calls that failed, or all |
| `log.slow` | `s` (log) | call log: only slow calls (5 s or more), or all |
| `log.writes` | `w` (log) | call log: only GitHub writes, or all |
| `log.caller` | `c` (log) | call log: only the caller of the call under the cursor, or every caller |
| `log.agent` | `a` (log) | call log: only the agent of the call under the cursor, or every agent |
| `log.copy` | `y` (log) | copy the command of the call under the cursor |
| `github.sync` | `r` (attention), `r` (inbox), `r` (issues), `r` (pr), `r` (prs), `r` (watch) | sync GitHub now |
| `items.start` | `s` (attention), `s` (inbox), `s` (issue), `s` (issues) | start one session from the picked items |
| `items.add` | `a` (attention), `a` (inbox), `a` (issue), `a` (issues) | add the picked items to the current session |
| `items.read` | `x` (inbox) | mark read |
| `items.filter` | `t` (inbox), `t` (issues) | cycle the filter chips |
| `attention.done` | `x` (attention) | done: mark the thread read on GitHub; it comes back when something new happens |
| `attention.snooze` `[duration]` | `Z` (attention) | snooze: out of the feed until later (3h, or 30m, 2d, tomorrow) |
| `attention.mute` | `M` (attention) | mute the thread on GitHub (no more notifications about it); listed under Muted |
| `attention.reply` | `R` (attention) | draft a reply with the model; you read it before anything is posted |
| `attention.session` | `gS` (attention) | go to the item's session |
| `attention.filter` `[filter]` | `t` (attention) | next Attention filter, or the one named |
| `attention.sort` | `T` (attention) | Attention: recent first, or weight then recent |
| `issues.repo.next` | `<Tab>` (issues) | next repo in the Issues repo column |
| `issues.repo.prev` | `<S-Tab>` (issues) | previous repo in the Issues repo column |
| `issues.repo` `[name]` |  | show one repo's issues (no name: every repo) |
| `issues.visibility` | `w` (issues), `w` (repos) | flip the repo under the cursor between all issues and only yours |
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
| `pilot.copilot` | `C` (pr), `C` (watch) | ask GitHub's Copilot coding agent to resolve the PR's conflicts and address its comments |
| `pilot.reviewers` | `zv` | ask the PR's configured reviewers ([pilot] reviewers) to review it |
| `pilot.merge` | `zm` | get it merged for the PR (or the picked PRs): off or auto |
| `pilot.merge.now` | `zM` | merge the PR now; past unmet required reviews or checks with --admin when you are an admin (merge_now, force_merge) |
| `pilot.merge.setup` |  | set up get it merged for the PR's repo |
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
| `diff.commit` `[sha|all]` | `c` (diff) | show one commit (cycles; a sha shows that one, all the whole branch) |
| `diff.split` | `t` (diff) | unified / split |
| `diff.ask` | `a` (diff), `<CR>` (diff) | queue feedback on this hunk (or the selected lines) |
| `diff.ask.now` | `A` (diff) | ask the agent about this hunk (or the selected lines) now |
| `diff.copy` | `y` (diff) | copy path:line (path:first-last for selected lines) |
| `diff.edit` | `e` (diff) | open the file in the editor |
| `repo.add` `<path>` |  | add a repo outside the scanned roots (kept in repo_paths) |
| `repo.scan` | `r` (repos) | refresh: rescan the repo roots |
| `worktree.new` | `o` (repos) | start work in the repo under the cursor |
| `setup.review` | `S` (repos) | the setup heed detected for the repo's new worktrees: approve, edit or never |
| `setup.approve` |  | approve the detected setup for the repo's new worktrees |
| `setup.never` |  | no setup for the repo's new worktrees, and no more proposals |
| `setup.edit` |  | edit the repo's setup commands (Settings, Orgs & repos) |
| `repo.setup` `[repo]` | `M` (repos) | set up get it merged and get it green for the repo: sample its history, propose, validate, write config |
| `select.remove` | `d` (VISUAL), `dd` (repos) | remove the selected worktrees, or the one under the cursor (asks first) |
| `select.pin` | `m` (VISUAL) | pin selected |
| `select.copy` | `y` (VISUAL) | copy paths |
| `select.open` | `o` (VISUAL), `<CR>` (repos) | open the worktree's session, importing it when it has none |
