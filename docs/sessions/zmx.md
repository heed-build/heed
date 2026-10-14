---
description: Keep agents running when Heed quits, restarts or updates, with zmx.
---

# Agents that outlive Heed

By default a pane's terminal belongs to Heed: quitting Heed stops the agents in it, and the next launch
[resumes](resume.md) them from their own history. With `persist = "zmx"`, every pane runs in a
[zmx](https://zmx.sh) session instead, and Heed attaches to it. Quitting, restarting or updating Heed leaves the
agents running, mid-turn if they were, and the next launch reattaches: same screen, same scrollback, nothing typed
again.

zmx is yours to install; Heed does not ship it. On this Mac:

```sh
brew install neurosnap/tap/zmx
```

(or any way [zmx.sh](https://zmx.sh) describes). Then:

```toml
[sessions]
persist = "zmx"    # none (the default) or zmx
```

Heed finds zmx on your PATH like `git` and `gh` (`heed tools` shows where). With `persist = "zmx"` and no zmx installed,
panes stay plain shells and Heed says how to install it.

The setting applies to panes opened from then on; panes already open keep going as they are until they close.

## What changes

| | `none` | `zmx` |
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
