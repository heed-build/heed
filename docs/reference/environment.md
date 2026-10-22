---
description: The environment variables Heed sets in its panes, and the ones it reads.
---

# Environment variables

## Set in every pane

| Variable | |
|---|---|
| `HEED_SESSION_ID` | The session the pane belongs to |
| `HEED_SOCKET` | The socket to report to |
| `HEED_PANE_ID` | The pane |
| `HEED_BIN` | The bundled `heed` helper |
| `HEED_PROMPT` | Your prompt, while an agent starts with one; the start line reads it and unsets it |
| `PATH` | The PATH Heed found (see [Finding git and gh](../configuration/tools.md)), with the helper first |

## Read by Heed

| Variable | |
|---|---|
| `XDG_CONFIG_HOME` | Where `heed/config.toml` lives, if set |
| `HEED_FIXTURE` | Open on made-up data, with no IO: `main`, `empty`, `pr-storm`, `fresh-repos`, `chats`, `resume`, `firstrun` |
| `HEED_OUTSIDE` | With a fixture, show the Dock badge and the menu bar item, and ask before quitting, as the live app does |
| `HEED_SNAPSHOT` | Render the window to this PNG and quit (`HEED_SNAPSHOT_KEYS`, `_SIZE`, `_DELAY`, `_SETTLE`) |
| `HEED_SHOTS` | Render every docs screenshot into this folder and quit (`HEED_SHOTS_ONLY`, `HEED_DOCS`) |
| `HEED_TUTOR_CHECK` | Play every tutor lesson with the real keys and report steps that do not tick off |

All but the first are for working on Heed itself: `mise run shots` uses `HEED_SHOTS` to regenerate every image in
these docs from the fake world, and `mise run tutor-check` sets `HEED_TUTOR_CHECK`.
