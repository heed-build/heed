---
description: "heed goal: the goal a session is on, from its shell. Agents keep their goal with it, told how by heed's heed-goal skill."
---

# Agents keep the goal

The goal a session is on is not only Heed's to keep. From the session's own shell, `heed goal` reads the goal and
writes to it: an agent records the decisions it takes and the questions it hits, adds the work it finds, checks a
criterion when it has the evidence, and proposes a change to the goal instead of quietly doing more. Every change goes
through the same rules as the Goals view, so an agent can do no more from the shell than heed would do on its own.

```sh
heed goal show                                   # GOAL.md, the items and their stages, the quality bars
heed goal decision add "Cache keys hash the lockfile"
heed goal item add "Measure cold builds" --parent cache-the-toolchain --by-subagent explorer
heed goal criterion check 2 --evidence "CI run 81: 48s cold"
heed goal propose not-the-goal "Remote execution"
```

## Which goal

The goal is the one the calling session is on: `heed goal` reads `HEED_SESSION_ID`, which every Heed pane sets.
`--goal <id>` (or the goal's title) works on another one. A session on no goal gets exit code 4 and the words to fix
it: `heed goal attach <goal>` puts it on one, `heed goal list` shows them.

## Records apply, scope waits

What only records what happened applies at once, as a new `GOAL.md` version or a new item, attributed to the session
(or to the subagent named with `--by-subagent`), and undoable in Heed like any change heed makes on its own:

| Command | |
|---|---|
| `attach [<goal>]` | Put this session on a goal; with no goal, say which one it is on |
| `item add <title> [--parent <id>] [--by-subagent <name>]` | New work on the goal; `--parent` splits an item, `--by-subagent` names who does the part |
| `item done <id> [--evidence <text>]` | The item's card to Done, with what shows it |
| `item move <id> <column>` | The card to `explore`, `planned`, `working`, `verify` or `done` |
| `decision add <text>` | A decision, into **Decisions** |
| `question add <text>` | A question, as a card in To explore |
| `question answer <id or question> <text>` | The answer becomes a decision and the question closes: the card to Done, an open question out of `GOAL.md` |
| `criterion check <n or text> --evidence <text>` | A **Done when** criterion met. The evidence is required: without it, it would change the goal's scope |
| `link pr <url, org/repo#n or #n> [--item <id>]` | A PR on the goal, and on an item; `#n` is in the session's repo |

What changes the goal itself waits for you: `propose <section> <text>` makes a proposal, listed under the goal's
`GOAL.md` and in Attention like the ones the work suggests ([What the work suggests](items.md#what-the-work-suggests)).
The section is `goal`, `not-the-goal`, `done-when` or `question` (an open question in `GOAL.md`). Whether an edit
applies or waits is decided by what it does, never by the command: `propose decision …` records, since a decision only
records.

## Work and reviews

| Command | |
|---|---|
| `item spawn <id> [--agent <name>] [--background]` | Start work on the item: a session, as Start work would make it, on the goal and the item and told about the goal; or, with `--background`, a background run |
| `review request <kind>` | The goal's reviewer of that kind (`implementation`, `security`, `docs-reader`, …) looks again, within the day's reviewer budget |
| `list` | Every goal: id, status, criteria met, items, score, title; `*` marks the session's |
| `show` | `GOAL.md`, the items with their stages and columns, the quality bars and scores, what waits for you |

A spawned session works in a new worktree of the asking session's repos (or of the newest session on the goal) and
starts off screen. A background run is the agent without a pane (`claude -p`, `codex exec`) in a worktree of its own on
`heed/spawn/<goal>/<item>`, kept when it ends so the work can be opened, pushed or thrown away; it may edit files there,
and its shell is limited to `heed goal` and reading git. How it ended is evidence on the item.

Spawning is capped per goal: `spawn_concurrent` going at once (2) and `spawn_per_day` a day (6). Past either, the spawn
waits for you as one Attention item per goal: `y` starts what waits, `n` drops it, `↩` opens the goal's board. The
command says so with exit code 5.

```toml
[goals]
spawn_concurrent = 2
spawn_per_day = 6
```

## For agents and scripts

Every command takes `--json` and then prints one JSON object, also when it fails: `outcome` (`applied`, `proposed`,
`moot`, `added`, `moved`, `attached`, `linked`, `started`, `held`, `read`, `refused`), `exit`, `message`, and what it
is about (`goal`, `item`, `edit`, `version`, `session`, and `goals` for `list`, `view` for `show`).

| Exit | |
|---|---|
| 0 | Done, or proposed |
| 1 | Refused: no such goal, item, column or reviewer; nothing changed |
| 2 | Wrong usage; the usage is printed |
| 3 | Heed is not running, or not reachable from here |
| 4 | No goal: the session is on none and no `--goal` was given |
| 5 | Held for you in Attention (a spawn past the cap, a review past the budget) |

`heed goal --help` prints all of it. The command talks to Heed over the [control socket](../reference/cli.md#the-control-socket)
(method `goal`); it never opens the goals database itself. A background run has no session, so heed sets `HEED_GOAL`
for it, which `heed goal` uses when there is no session and no `--goal`.

`heed goal` runs on this Mac. A session on a host can read its goal's pointer, but its shell cannot reach Heed's
control socket, so the commands are not available there yet.

## The heed-goal skill

Agents learn all this from heed. When a session or chat on a goal starts or resumes (and `tell_agents` is on):

- **claude** loads heed's plugin for that session only, with `--plugin-dir`. The plugin is a folder heed writes in
  `~/Library/Application Support/Heed/plugin/`, rewritten when heed updates; nothing is installed, and nothing is
  written into your repos or `~/.claude`. Its one skill, `heed-goal`, tells the agent to read the goal first with
  `heed goal show`, keep to **Not the goal**, record decisions and questions, add the work it finds and split it for
  subagents (registering their parts with `--by-subagent`), check criteria only with evidence, propose scope changes
  instead of doing them, spawn only separate work, and finish with a short summary.
- **codex** takes no plugin per session (its plugins are installed), so it gets the goal's pointer and the same
  guidance, from the same source, in its developer instructions.
- Other agents get neither; `heed goal` still works from their panes.

```text
~/Library/Application Support/Heed/plugin/
├── .claude-plugin/
│   └── plugin.json          name "heed", heed's version
└── skills/
    └── heed-goal/
        └── SKILL.md
```

A claude session on a host does not have the plugin, and gets the pointer as before.
