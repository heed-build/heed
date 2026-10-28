# Plan

The brief is `design/BRIEF.md`; the boards in `design/screens` are the visual reference. This file records what was
decided on top of the brief, and the build order. Keep it true to `Sources/`.

## Decisions

- **Name**: Heed (working name). App `Heed.app`, CLI `heed`, env `HEED_SESSION_ID`, `HEED_SOCKET`, `HEED_PANE_ID`.
  The brief's `cc` collides with the system C compiler.
- **Stack**: Swift 6, SwiftPM, mise. SwiftUI for chrome, AppKit for terminals and key routing. No Rust.
- **Terminal**: libghostty (GhosttyKit) built from a pinned upstream commit (`GHOSTTY_COMMIT` in `mise.toml`).
  `ghostty.h` is Ghostty's internal embedding API with no stability promise: all of it stays in `HeedTerminal`.
  Building needs Xcode + the Metal toolchain; this project sets `DEVELOPER_DIR` itself and never touches
  `xcode-select`. Fallback if the source build fails: the prebuilt `Lakr233/libghostty-spm`.
- **Never block the UI**: the main actor only holds finished state. git, gh and agent processes run off it with
  timeouts; Ghostty renders on its own threads; output polling for guessed states runs off-main.
- **Domain and cache**: `Domain` is one value (repos, worktrees, sessions, layouts); every edit is a `DomainChange`
  applied on the main actor per property and persisted by `DomainStore` off it, coalesced, to
  `~/Library/Application Support/Heed/domain.json` (versioned; a mismatch starts fresh). Append-only data (history,
  session timelines, the event log, the ledger) is in SQLite, `heed.sqlite` beside it (`EventLog`, system SQLite
  through a thin wrapper, with migrations), and does not depend on the domain's version. The call log (`log.sqlite`)
  and Attention's items (`attention.sqlite`) have files of their own, so pruning them never touches history. Hooks
  that fire while the app is closed append to `hooks.spool`, read on launch. `HEED_FIXTURE=<name>` starts on a
  fixture with no IO.
- **GitHub**: only through `gh` (`gh api graphql`, `gh pr`, `gh issue`, `gh api notifications`). No tokens.
- **Config**: `~/.config/heed/config.toml` is the source of truth, hot-reloaded, last good config kept on errors.
  The Settings window edits it (comment-preserving), except key bindings, which are edited in the file only.
  Uniform shape: every binding names a command, every command can be typed after `:`, and `?` is drawn from the
  same table. Every agent is an `[agents.<name>]` with the same fields; the custom command is just another entry.
- **Agents** (formats verified against source/docs on 2026-10-12): hooks are passed per run, never by editing the
  user's config. claude `--settings` + `--session-id`; codex `-c hooks.<Event>=[...]` with
  `--dangerously-bypass-hook-trust` (trusts exactly those hooks for that run); cursor a `.cursor/hooks.json` written
  into the worktree and excluded via `info/exclude` (its CLI fires only `sessionStart` and `stop` reliably); pi
  `-e heed-pi.js` + `--session-id`; opencode 1.x a plugin through `OPENCODE_CONFIG_CONTENT`, prompt via `--prompt`;
  gemini `--session-id`, `-i`, `--resume` and screen reading (per-run hooks unverified). States an agent cannot
  report are read from its screen (`ScreenGuess`, dotted ring).
- **Resume**: claude `--resume <id>` (its session file under `~/.claude/projects/<cwd, / and . as ->/` tells whether
  it still exists), codex `resume <id>`, cursor `--resume <id>`, pi and opencode `--session <id>`; gemini starts fresh
  until verified. Resumed agent panes start at launch even off screen.
- **heed's own model calls**: no API key. `LLMRunner` calls the agent CLIs you are logged in to, headless, on their
  cheapest model, taking turns, with daily caps and a backoff; `Summarizer` and `Decider` sit on it. A decision is
  never acted on where it cannot be undone. Every call, model call and decision is a row in the call log.
- **Signing and deploy**: ad-hoc signed, rsync to the MacBook's SMB share after every build (`HEED_DEPLOY_DIR` in `mise.local.toml`).

## Build order

1. Window shell, tabs, splits, libghostty panes; focus model; deploy. *(done; INSERT typing needs a hands-on check)*
2. Mode engine and key routing, `?` overlay, relative numbers, `f` hints. *(done for NORMAL/INSERT/COMMAND/HINT)*
3. Repos, worktrees, Start work, autostart the agent in a shell. *(done: domain store + fixtures, git adapter, Repos view,
   Start work; config file still to come, defaults live in `WorkSettings`)*
4. The `heed` socket, claude hooks, live agent states, `ga`. *(done: HookServer, `heed hook claude <event>`,
   `--settings` + `--session-id` per launch, event log in the inspector; needs a hands-on check)*
5. Persistence, resume on launch, pins, history. *(done: resume dialog per `resumeOnLaunch`, continue prompt once idle,
   history with outcomes and timelines, `R` reopen recreating cleaned-up worktrees, `/` filters)*
6. GitHub: inbox, issues, PR watch, org icons and colors. *(done except org icons: gh sync every 60s into the cached
   domain, Inbox/Issues/PRs views, start one session from picked items, mark read, PRs tracked by branch; SAML-hidden
   items counted, offline keeps the cache. Org avatars need a non-gh download, so letter tiles stay for now)*
7. PR overlay, reader, feedback queue, auto-feed. *(done: `go` overlay and `o` reader, pipeline New → Queued → Sent →
   Addressed → Resolved, Off/Ask/Auto when idle, delivery only to an idle agent you are not typing to, 3-round stop,
   CI loop reports checks that pass again; editing the prompt before sending is still to do)*
8. Diff overlay. *(done: `gd`, scopes All/Committed/Staged/Unstaged/commit (`⇥`, `c`), files grouped by repo with staged
   marks, unified/split (`t`), word-level highlights, `n N` `]f [f`, `a` asks the agent, `y`, `e`. Syntax highlighting is
   a small built-in highlighter; tree-sitter per language is a follow-up)*
9. Other agents, custom command, first run, empty and offline states, cleanup sweep, config file and Settings.
   *(done: config.toml with live reload and Settings, all agent integrations, custom agents with screen patterns,
   cleanup sweep, first-run screen)*
10. The store. *(done: `heed.sqlite` for history, timelines and the event log (#94, #96); hooks spool while the app is
    closed; every command and GitHub call names its caller (#97) and lands in the call log, `log.sqlite`, kept per
    `[log]` (#100, #106); `:log` shows it live with filters and today's model usage (#104))*
11. heed's own model calls. *(done: `LLMRunner` over the logged-in agent CLIs, `[llm]` and `llm`/`llm_model` per
    agent (#108); Settings › Agents › Model calls with a Test (#111); `Decider`, `Summarizer`, `summary_instructions`
    (#112))*
12. Notifications that wait. *(done: `grace_seconds` and one reminder (#105), PRs and helper tabs in Needs you notify
    (#107), quiet hours from `[attention] quiet` (#109), each decision in the event log (#110))*
13. Chats. *(done: a session in a folder with no repo or branch (#95); `:chat`, the chat chip and a Chats group (#98),
    `gc` (#103); `:promote` turns one into work, outcome "promoted" (#99); the sweep removes closed chats' scratch
    folders after 30 days (#101))*
14. Removal that loses nothing. *(done: removing a worktree saves `refs/heed/archive/<branch>` and `<branch>-wip`
    first, Reopen in History brings them back, `[cleanup] keep_archive_days` (#114); the sweep sees the refs (#120);
    a host's worktree is removed on that host (#115), and reopening a host session recreates it there (#116))*
15. History beyond the list. *(done: the timeline, `T` (#117); the agent's last message with each turn's end (#118);
    the ledger, `L`, `[summary]` when and include, `S` and `E` (#123); `[pilot] summary_sign_off` (#124); the
    dashboard, `D` and `r` (#125))*
16. Attention. *(done: one item per thread with every reason, kept 30 days (#121); team attribution, needing gh's
    `read:org` (#119); `[attention] rules`, first match wins (#122); the feed, `gm`, with `gi` and `gp` opening it
    filtered and Inbox, Issues and PRs left out of the tab bar but reachable with `:` (#127); the rules editor in
    Settings › Attention with a preview (#128); Attention notifications, the Decider's suggested weights and what you
    do kept as labels (#129))*
17. Docs that render themselves. *(done: History's detail says what heed keeps (#133); a title bar that shows a PR
    number or host whole or not at all (#134); deterministic shots from invented fixture orgs (#135), the sweep on the
    pinned clock and text independent of render order (#147); `LLMRunner` takes its queue place when a call is made
    (#146))*
18. Outside heed and on this Mac. *(done: the control socket, `control.sock`, with `heed start`, `send`, `show`,
    `sessions` and `watch` (#137); Local decisions: an opt-in, local-only recorder of what a pane showed at each
    reported state, `[local] record_screens` (#138); Start work's smart guesses from Apple's on-device model, and its
    outcomes kept to learn from, `[start_work] smart_guesses` (#139))*
19. The pilot, seen and set up. *(done: merge mode on every PR, **Ready to merge**, `zM` merge now and force merge with
    `--admin`, `merge_now` and `force_merge`, and merging misconfigured named ahead of time (#141); the repo setup
    wizard, `M` in Repos, proposing get it merged and get it green from a repo's last 30 merged PRs and its CI (#142))*
20. The mouse. *(done: `↩` types into the agent, Start work with clicks and Start and Cancel buttons (#140); a menu bar
    with every command under File, Session, View, PR, Go, Window and Help (#143); Settings for config-only keys, tutor
    steps and empty states with a next step (#144); key hints are buttons (#145); the diff overlay with clicks and
    drag-select (#148); tabs drag and dividers resize (#149); the resume dialog starts all ticked (#150) and takes the
    mouse (#151))*
21. Goals. *(done: goals with a `GOAL.md` and its versions, sessions and chats on them, `gG`, agents told to read it
    (#152); items, evidence, stages, the board and edits to `GOAL.md` from the work, records applying themselves and
    scope changes waiting (#153); new work finding its goal from signals and a cheap model, asks in Attention,
    Unassigned, suggested goals and `attach.rules` learnt from corrections (#154); profiles and quality bars per goal,
    reviewers within a daily budget, scores with their basis, done on its own (#155); UX and DX stranger walks in a
    fresh clone with a friction log (#156); `heed goal` over the control socket and the `heed-goal` skill through
    `--plugin-dir`, `item spawn` (#157); personas (#158); the GitHub mirror, a meta issue and a sub-issue per item in
    a tracker repo, colleagues' changes coming back as asks (#159))*
22. Swarms: a goal in swarm mode. *(S1, describe, plan, approve: swarm runs on a goal with plan versions and an
    append-only steering log in `goals.sqlite`, a lead session that drafts with `heed goal plan propose` and asks with
    `heed goal ask`, the plan pane (`S`) with edits, versions, diffs, restore and approval, `PLAN.md` next to `GOAL.md`.
    Nothing runs yet: workers (S2), merge order (S3), steering and the controller (S4), watching (S5) come next)*

## Open questions

- **Leaving INSERT with Esc.** Today only `<C-\>` (configurable) leaves INSERT; Esc belongs to the terminal (claude's
  interrupt, Esc Esc rewind, vim). Options weighed: Esc twice, Esc with `<C-\>` sending a real Esc, hold Esc. Parked
  by the owner on 2026-10-12, to revisit.
