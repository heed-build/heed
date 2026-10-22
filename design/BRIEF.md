# Starting prompt: Command Center (working title)

Paste this into a fresh Claude Code session in an empty repo. Keep `design/` next to it.

---

Build a native macOS app, a **command center for agentic coding**. It hosts coding agents and shells in terminals, manages repos and git worktrees, and tracks the GitHub issues and PRs around each task. It is heavily keyboard driven, with vim-style modes.

`design/screens/*.png` are the approved visual designs. `design/html/*.html` are the same boards as static HTML (open in a browser), and `design/source/` is the original canvas source. Match them. The designs are mockups: sample data is invented, and every board name below maps to a screen.

## Stack and constraints

- Swift, SwiftUI for the shell, AppKit where SwiftUI is not enough (terminal surfaces, key routing).
- Terminals: **libghostty** (GhosttyKit). Each pane is an AppKit view wrapped for SwiftUI. Verify how mature the embedding API is before committing, and report back.
- Not sandboxed (it spawns shells, git, and agents). Notarized, distributed outside the Mac App Store.
- Local helper CLI `cc` that agents call to talk to the app over a unix domain socket. Either a small Swift binary or a .NET single-file program. Propose one.
- Do not store agent transcripts. Agents own them. The app keeps only session records.
- Dark UI, mono type for data and keys, system font for chrome. See `design/screens/Main.png`.

## Core concepts

- **Session**: one task. A prompt, one or more worktrees (possibly across repos), terminals, an agent session id, tracked PRs, a state, and a pin flag.
- **Org and repo**: every repo belongs to an org (or a personal account). Orgs have an icon (GitHub avatar, cached) and a color. Repos inherit unless overridden. Org colors never use the state hues. Show repo chips with icon and color in every list (sessions, repos, inbox, issues, PRs, history). Board: `Colors`.
- **Agent state**, set by hooks, each with its own glyph shape (not only color):
  - working (spinner ring), idle (hollow circle), blocked (amber diamond, waiting on permission), asking (violet circle with ?, interviewing the user), done (green check), limited (dashed ring, rate limited), exited (hollow square, agent ended but shell lives).
  - States guessed from terminal output rather than reported by the agent get a small dotted ring, so the user trusts them less.

## Modes and keys (board: `Modes`, the `?` overlay)

Modes: NORMAL (keys drive the app), INSERT (every key goes to the focused pty; only the escape chord `⌃\`, configurable, is caught), VISUAL (multi-select, then act), COMMAND (`:` with completion: `:start`, `:pr 2841`, `:wt sweep`, `:agent codex`, `:track`), HINT (`f` shows letter badges over every pane, tab and session; `F` jumps and enters INSERT).

- `?` opens the keys-and-states overlay in every mode except INSERT. `⌘/` works everywhere. The overlay highlights the current mode.
- Move: `j k` sessions (counts work, e.g. `3j`; the list shows vim-style relative line numbers), `h l` focus pane, `gg G`, `/` filter.
- Sessions: `o` start work, `O` start from this session's prompt, `ga` next session needing you, `zz` park, `x` close session (keep worktree), `p` pin or unpin, `'1`..`'9` jump to pinned session N, `''` back to previous session, `gh` history.
- Panes and tabs: `⌃w v` split right, `⌃w s` split below, `⌃w z` zoom, `⌃w q` close, `gt gT` tabs, `gn` new tab, `i` enter INSERT.
- Views: `⌘1`..`⌘6` = Sessions, Inbox, Issues, PRs, Repos, History.
- Overlays: `gp` PR overlay for this session (toggle; `]p [p` cycle the session's PRs), `gd` diff overlay, `gS` jump from a PR to its session, `⌃o` back, `gB` open in browser, `gP` track a PR by URL, `gs` run cleanup sweep, `gi` toggle inspector.
- Reading: `↩` or `o` opens an inbox item, issue or PR in the in-app reader.
- Pins: max 9. Pinned sessions are exempt from cleanup, always restored on launch, and shown in a "Pinned" group at the top of the sidebar.

## Main window (board: `Main`)

Sessions sidebar (groups: Pinned, Needs you, Working, Parked), center area with tabs and splits of libghostty panes, right inspector (worktree, PRs with watch status, agent hook events), status bar with mode, pending keys and counts. The title bar has the view switcher and "N blocked / N asking" with `ga`.

A "tests" tab is NOT an auto-detected thing. Build per-repo **pinned tasks** (test, build, docs preview). Suggest them from `*.sln`, `package.json` scripts, Makefile. Run each in its own pane; the exit code sets a pass/fail glyph on the tab.

## Start work (board: `StartWork`)

A dialog (key `o`): prompt box, then guesses for repo (multiple repos allowed, with confidence % and a one-line reason each), worktree name (auto-named from the prompt), base branch, and agent. `⇥` moves fields, `⌃n ⌃p` cycle guesses. Options: autostart the agent with the prompt, plan first, open shell + test split. Show the exact command that will run. Autostart runs the agent inside a libghostty shell so the session survives the agent exiting.

## Repos and worktrees (board: `Repos`)

Table of all worktrees with state glyph, org-colored repo chip, branch, agent, PR, idle time and cleanup ETA. VISUAL mode selects rows for `d` remove, `p` pin, `y` copy path, `o` open. `a` add repo, `c` clone, `n` new worktree. Worktrees live under a configurable root, e.g. `~/code/wt/<repo>/<name>`.

Auto cleanup, version 1 has ONE rule: remove worktrees with no activity for N days (default 14). Activity = agent output, keystrokes, commits, PR events. Plus: never remove dirty or unpushed work (locked on), delete the local branch too, optional "ask before each sweep". Pinned sessions are never cleaned. Merged/closed-PR rules come later. A banner shows what the next sweep would do.

## Agents and settings (boards: `Agents`, `AgentsMore`, `AgentsMore2`, `FirstRun`)

Supported: claude, codex, cursor (cursor-agent), pi, opencode, and a custom command. Each has its own settings pane tailored to it (real fields, not a generic form), a command, prompt delivery (argument, stdin, paste, file, server API), profiles, per-repo routing, and a fallback order when one is rate limited. Icons: use the official assets and GitHub org avatars; the designs show placeholder tiles.

- State integration per agent (verify each against current docs; the table in `AgentsMore2` is from memory): claude via hooks in settings.json; codex via a `notify` program plus pty watching; cursor via project hooks plus pty; pi via an extension (never blocks, so hide the Blocked filter); opencode via a plugin or `opencode serve`.
- Custom command: name, icon, command with variables `{prompt} {worktree} {branch} {session}`, prompt delivery, and state detection by hooks, process only, or output patterns (regex to state, with a test box).
- First run: connect GitHub, scan for repos, detect agents on PATH, show a diff of what "install hooks" will change and keep backups, choose keys.

## Hook protocol

`cc` talks to a local unix socket. The app sets `CC_SESSION_ID` and `CC_SOCKET` in every pane. Commands: `cc state <working|idle|blocked|asking|done|limited> --reason "..."`, `cc notify`, `cc pr add <url>`, `cc title "..."`. Agent hooks call these. Capture the agent's own session id from its start hook the moment the session begins.

## Resume on launch (board: `Resume`)

Persist active sessions. On launch show a dialog (setting: Ask / Always / Never auto-continue) listing sessions that were active, with the exact command per row. Claude: `claude --resume <guid>`. Other agents' resume commands (`codex resume <id>`, `opencode --session <id>`, cursor, pi) must be verified. Sessions that were mid-turn get resume then an editable "Continue where you left off." once idle. Blocked or asking sessions resume only. Restore worktrees, tabs, splits, shell directories; running processes are not restored. If the agent no longer has the session, start fresh with the same prompt.

## GitHub: inbox, issues, PRs (boards: `Inbox`, `Issues`, `PRs`, `Reader`, `PROverlay`)

- Auth via `gh` or a token. Poll notifications, issues and PRs; work offline from cache with a clear banner (board: `Empty`).
- Inbox and Issues: VISUAL multi-select (`space`, `v`), then `s` starts ONE session from all selected items (prompt built from issue text, optional "Closes #..." lines), or `a` adds them to a running session. `m` marks read.
- PRs: auto-watch the user's open PRs across repos for review comments and CI checks. Track PRs for a session automatically (branch match, or reported by the agent via `cc pr add`), including across repos.
- Feedback pipeline per PR: New, Queued, Sent, Addressed, Resolved. Auto-feed mode per PR: Off, Ask (default), Auto when idle. Feedback is delivered to the running session as one prompt, only when the agent is idle, never while it is blocked or asking, and waits again if the user types in the pane. Preview and edit the prompt first (`e`). CI loop: after the agent pushes, watch the new run and report if the failure is gone. Stop after 3 rounds without a new approval. `w` pauses watching.
- Reader (`↩`/`o`): description, review comments with the diff they refer to, failing checks, linked session and issues. `space` queues a comment, `s` sends queued ones.

## Diff overlay (board: `Diff`)

`gd` over the session. Scope switch: All, Committed (vs base), Staged, Unstaged, or a single commit (`c`). Files grouped by repo (cross-repo sessions), staged vs not marked. Unified view, `t` for split. Syntax highlighting (tree-sitter), word-level highlights within changed lines, `n N` hunks, `]f [f` files, `a` ask the agent about this hunk, `y` copy path:line, `e` open in editor, `R` full file. Candidates for the viewer: CodeEditSourceEditor (CodeEdit), STTextView with SwiftTreeSitter/Neon. Diff rendering is custom: parse `git diff`, render in a lazy list or text view. Check licenses.

## History (board: `History`)

`⌘6` or `gh`. Searchable list of past sessions grouped by day, with outcome (merged, closed, abandoned, cleaned up), repo chip, agent, duration. Detail shows prompt, timeline, resume command. `R` reopens: resume the agent, recreate the worktree from its branch if it was cleaned up (or from `refs/heed/archive/<branch>`, where every removal saves unpushed and uncommitted work first), or start fresh if the agent dropped the session. `O` new session from the prompt, `p` pin. The app stores the prompt, session id, branch and timeline, and the ledger: a short summary of each piece of work (what it did, decisions, follow-ups) written by a cheap model from git, the PR, the timeline and the agent's last message, kept on this Mac in heed.sqlite. The agent owns transcripts; heed never copies them.

## Build order

1. Window shell: sidebar, tabs, splits, one libghostty pane. Prove the embedding and the focus model.
2. Mode engine and key routing (NORMAL/INSERT first), `?` overlay, relative line numbers, `f` hints.
3. Repos, worktrees, Start work, autostart agent in a shell.
4. `cc` socket, claude hooks, agent states in the UI, `ga`.
5. Persistence, resume on launch, pins, history.
6. GitHub: auth, inbox, issues, PR watch, org icons and colors.
7. PR overlay, reader, feedback queue and auto-feed.
8. Diff overlay.
9. Other agents' integrations, custom command, first run, empty and offline states, cleanup sweep.

## Before writing code

Report back on: libghostty embedding status and API, how you will route keys between app and terminal (this is the riskiest part), the `cc` implementation choice, and which per-agent facts in this document you could not verify. Then start with step 1.
