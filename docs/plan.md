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
  `~/Library/Application Support/Heed/domain.json` (versioned; a mismatch starts fresh). JSON until history needs
  querying, then SQLite. `HEED_FIXTURE=<name>` starts on a fixture with no IO.
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
7. PR overlay, reader, feedback queue, auto-feed. *(done: `gp` overlay and `o` reader, pipeline New → Queued → Sent →
   Addressed → Resolved, Off/Ask/Auto when idle, delivery only to an idle agent you are not typing to, 3-round stop,
   CI loop reports checks that pass again; editing the prompt before sending is still to do)*
8. Diff overlay. *(done: `gd`, scopes All/Committed/Staged/Unstaged/commit (`⇥`, `c`), files grouped by repo with staged
   marks, unified/split (`t`), word-level highlights, `n N` `]f [f`, `a` asks the agent, `y`, `e`. Syntax highlighting is
   a small built-in highlighter; tree-sitter per language is a follow-up)*
9. Other agents, custom command, first run, empty and offline states, cleanup sweep, config file and Settings.
   *(done except the first-run screen: config.toml with live reload and Settings, all agent integrations, custom agents
   with screen patterns, cleanup sweep)*

## Open questions

- **Leaving INSERT with Esc.** Today only `<C-\>` (configurable) leaves INSERT; Esc belongs to the terminal (claude's
  interrupt, Esc Esc rewind, vim). Options weighed: Esc twice, Esc with `<C-\>` sending a real Esc, hold Esc. Parked
  by the owner on 2026-10-12, to revisit.
