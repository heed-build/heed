# Docs outline

The plan for heed.build: feature-first, one folder per feature area, screenshot-heavy. To be agreed before
pages are written. Every screenshot listed here is produced by a script from a fake world (see the end).

Legend: **[full]** whole window · **[full+hl a, b]** whole window, regions a and b highlighted, the rest dimmed ·
**[crop x]** just component x · **[seq]** a short sequence (before, after).

## Hierarchy

```
index.md                                 Home: what Heed is, one full shot, links into each area
getting-started/
  index.md                               The path: install → first run → tutor → first session
  installation.md                        Build from source (mise, Xcode, gh)
  first-run.md                           [crop first-run screen] what it finds, what it won't change
  tutor.md                               [full+hl tutor card, banner]
  first-session.md                       Walkthrough: start work → agent works → it asks → you answer →
                                         PR → review feedback → merged → history. [seq] one shot per beat
concepts/
  index.md                               The four ideas the rest builds on
  sessions.md                            A session: agent + terminals + worktree(s) + PRs. [full+hl sidebar row, panes, inspector]
  agent-states.md                        working, blocked, asking, done, limited, idle; reported vs guessed
                                         (dotted ring). [crop state glyphs] [crop sidebar groups]
  worktrees.md                           One worktree per task, branch naming, cross-repo sessions
  modes.md                               NORMAL, INSERT, VISUAL, COMMAND, HINT. [crop status bar per mode]
sessions/
  index.md                               Anatomy of the Sessions view. [full+hl sidebar, center, inspector, status bar]
  sidebar.md                             Groups (pinned, needs you, working, parked), relative numbers, collapse
                                         to the rail (zs). [crop sidebar] [crop rail]
  moving-around.md                       j k gg G, counts, ga next attention, '' back, '1–'9 pins. [crop sidebar, cursor]
  typing-into-agents.md                  i, ⇧⎋ / ⌃\, click to type; the white border. [seq crop pane normal → insert]
  panes-and-tabs.md                      ⌃w v/s/h/j/k/l/z/q, gt gT gn, task tabs. [full+hl split] [crop tab strip]
  inspector.md                           Worktree status, PRs, agent events; zi. [crop inspector]
  pin-park-close-delete.md               p, zz, x, dd and what each keeps. [crop confirm dialog for x] [crop dd dialog]
  resume.md                              Resume on launch, the continue prompt. [crop resume dialog]
  filtering.md                           / in Sessions. [crop status bar typing] [crop sidebar filtered + pill]
start-work/
  index.md                               The dialog, field by field. [full+hl dialog] [crop dialog]
  repos.md                               Guesses and why, the 'other repo…' typeahead. [crop repo field] [crop typeahead]
  branch-names.md                        Prefixes from the first word, config. [crop worktree field]
  agent-and-options.md                   Agent row, plan first, shell split, autostart, the command preview. [crop options + preview]
  from-anywhere.md                       ⌃⌥Space floating panel; OmniWM and yabai rules. [crop panel over another app]
  from-github.md                         s from Inbox / Issues, a from them into a running session. [full+hl picked rows]
  again.md                               O: start again from a session's or history entry's prompt
agents/
  index.md                               Supported agents and how each reports its state (table)
  hooks.md                               What Heed passes per run (settings, -c, -e, plugin, cursor's project file)
  screen-reading.md                      States read from the screen; [agents.x.patterns]. [crop guessed glyph]
  custom-agents.md                       [agents.mytool]: command, prompt delivery, plan, resume, profiles
github/
  index.md                               Through gh only; sync, offline, SAML-hidden items. [crop sync banner]
  inbox.md                               Chips (Unread, All, PRs, Issues, Review requested, Assigned, CI runs),
                                         mark read, start from items. [full+hl chips] [crop row kinds]
  issues.md                              Repo column, chips, all-issues vs only-yours per org/repo, w / I.
                                         [full+hl repo column, eye] [crop involvement tags]
  pull-requests.md                       Checks, review state, threads; go to read. [full] [crop checks bar]
  reading.md                             The reader for PRs and issues (go, ↩). [full+hl reader] [crop issue reader]
  review-feedback.md                     The pipeline New → Queued → Sent → Addressed → Resolved; auto-feed off /
                                         ask / auto; when delivery waits; the round limit. [full+hl pipeline,
                                         delivery panel] [crop prompt preview]
  tracking-prs.md                        Tracked PRs per session, gU by URL, ]p [p
worktrees/
  index.md                               The Repos view. [full+hl repo column, table]
  repos.md                               Scan roots, repo_paths, ordering by worktree count, colors per org
  importing.md                           Iw: worktrees Heed doesn't manage; Ip: any path. [crop import picker]
                                         [crop path import with preview]
  removing.md                            dd, VISUAL d, what is kept and why. [crop remove dialog with Kept]
  cleanup.md                             Rules, the sweep, gC. [crop rules panel] [crop sweep banner]
diff/
  index.md                               The diff overlay: scopes, files, hunks. [full+hl file list, hunk]
  reviewing.md                           Split view, word highlights, ask the agent about a hunk, open in editor.
                                         [crop split] [crop word-level highlight]
history/
  index.md                               Outcomes, search, timelines. [full+hl outcome chips, timeline]
  reopening.md                           R reopen (recreates the worktree), O start again. [crop reopen detail]
keyboard/
  index.md                               How keys work: modes, sequences, counts, the g panel. [crop leader hints]
  views.md                               gs gm gi gp gr gh; the title bar. [crop title bar with key caps]
  hints.md                               f and F, everywhere. [full+hl hint labels] [crop labels on rows]
  command-line.md                        :, completion, aliases. [crop command line with completions]
  visual.md                              Selecting rows and acting on them. [crop selected rows]
  mac-shortcuts.md                       ⌘W ⌘Q ⌘H ⌘M ⌘, and why they always win
  customizing.md                         [keys.<mode>] and [keys.<view>], unbinding, the clash rule
  reference.md                           Every command and its default keys, generated from Commands.swift
outside-the-window/
  index.md                               Heed when it isn't in front
  menu-bar.md                            The owl, its count and menu. [crop menu bar item] [crop open menu]
  dock.md                                The badge. [crop dock icon with badge]
  global-shortcuts.md                    ⌃⌥Space, ⌃⌥H; closing the window keeps agents running
configuration/
  index.md                               config.toml, live reload, problems in the status bar. [crop status bar problem]
  settings.md                            The Settings window, section by section. [crop each section]
  reference.md                           Every key, generated from the commented default config
  tools.md                               Finding git and gh; [tools]; heed tools
reference/
  cli.md                                 The heed helper: state, notify, hook, task-exit, tools
  files.md                               Where things live: config, cache, socket, hooks files
  environment.md                         HEED_* variables (incl. the snapshot/shot hooks)
troubleshooting.md                       gh signed out, tools not found, SAML, hooks timing out, tiling WMs
```

About 70 pages, around 110 screenshots, two thirds of them crops.

## The fake world and scripted screenshots

Every screenshot comes from one command, `mise run shots`, which renders them all from a fake world. Nothing in
them is hand-taken, so a UI change is one command away from fresh docs.

- **A docs world.** A fixture made for the docs (`Fixtures.docs`), richer than the main one: sessions in every state
  (including guessed, limited, parked and pinned), a cross-repo session, PRs with failing and running checks and
  queued feedback, inbox items of every kind, assigned and watched issues, unmanaged worktrees to import, history
  entries with every outcome, and a diff.
- **A fixed clock.** The world is built at a fixed instant, so "14m", "synced 19 seconds ago" and dates never move.
- **Fake terminals.** In shot mode a pane draws a scripted transcript from the world (an agent mid-task, a test run)
  instead of starting a shell. Today's screenshots show a real shell, with a user name, host name and login date in
  them; shots must not.
- **Shots as data.** A manifest (`Shots.swift`, type-checked) lists each shot: id and output path, world, window size,
  keys to type, settle time, and how to frame it: full window, crop to a named region, highlight named regions.
- **Named regions.** Views mark their parts (`.shotRegion(.sidebar)`, `.inspector`, `.statusBar`, `.repoColumn`,
  `.dialog`, …). The renderer reads their frames, so crops and highlights follow the layout rather than pixel
  coordinates, and survive UI changes.
- **One process.** The app runs every shot in turn (a fresh model per shot), offscreen at a fixed size, so tiling
  window managers never touch it, then quits. Output goes to `docs/images/shots/<area>/<id>.png`, at 2x.
- **Outside the window.** Menu bar, Dock and the floating panel are drawn from the same views into an image, so they
  are scripted too, not screen captures.

Highlight style: the highlighted regions keep full brightness with a 2pt amber outline; everything else is dimmed to
40%. Crops get 16pt of padding and the window's rounded-corner shadow.
