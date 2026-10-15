---
description: Keep agents running when Heed quits, restarts or updates, with zmx.
---

# Agents that outlive Heed

Install [zmx](https://zmx.sh) and every pane runs in a zmx session that Heed attaches to. Quitting, restarting or
updating Heed leaves the agents running, mid-turn if they were, and the next launch reattaches: same screen, same
scrollback, nothing typed again. Without zmx, a pane's terminal belongs to Heed: quitting stops its agent, and the
next launch [resumes](resume.md) it from its own history.

zmx is yours to install; Heed does not ship it. On this Mac:

```sh
brew install neurosnap/tap/zmx
```

(or any way [zmx.sh](https://zmx.sh) describes). Heed picks it up on its own:

```toml
[sessions]
persist = "auto"   # the default: zmx when it is installed and works; zmx to insist, none to turn it off

[tools]
zmx = ""           # empty: found like git and gh (Homebrew, ~/.local/bin, your PATH); or a path
```

**Settings › General › Tools** shows zmx's check, next to git and gh: where it found zmx, its version, and whether it
works the way Heed uses it (`zmx version`, then listing Heed's own sessions). It also says whether panes run in zmx
because of it. With `auto`, a zmx that is missing or fails its check leaves panes as plain shells. With `zmx`, Heed
uses it whenever it is there, and says how to install it when it is not.

The setting applies to panes opened from then on; panes already open keep going as they are until they close.

## What changes

| | without zmx (`none`) | with zmx |
|---|---|---|
| Quit Heed with agents working | Asks first; the agents stop | Quits; the agents keep going |
| Next launch | Resume dialog: each agent restarts from its history | Panes reattach to the running agents; only ones that are gone (after a reboot) resume |
| `exit` in a pane | The pane closes | The same |
| Close or delete a session, sweep a worktree | Its terminals end | Its zmx sessions end too, so nothing is left running |

`:agents.stop` ends every agent and shell in every pane at once, when you want them all gone (Heed asks first).
Sessions stay; their panes come back as shells.

## Details

- Heed keeps its sessions apart from any you run yourself: they live in
  `~/Library/Application Support/Heed/zmx` and are named `heed-<pane>`. `ZMX_DIR` set to that folder lets you
  `zmx list` or `zmx attach heed-<pane>` them from another terminal.
- zmx's own detach key (`⌃\`) is off in Heed's sessions: `⌃\` is Heed's way out of INSERT.
- Keys, the mouse and terminal modes pass through untouched, and a reattached pane is told the modes its program had
  on (keyboard protocol, mouse, bracketed paste).
- zmx is a separate project by Eric Bower ([zmx.sh](https://zmx.sh)). Heed only calls the zmx you installed.
