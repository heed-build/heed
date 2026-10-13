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
| `PATH` | The PATH Heed found (see [Finding git and gh](../configuration/tools.md)), with the helper first |

## Read by Heed

| Variable | |
|---|---|
| `XDG_CONFIG_HOME` | Where `heed/config.toml` lives, if set |
| `HEED_FIXTURE` | Open on made-up data, with no IO: `main`, `empty`, `resume`, `firstrun` |
| `HEED_SNAPSHOT` | Render the window to this PNG and quit (`HEED_SNAPSHOT_KEYS`, `_SIZE`, `_DELAY`, `_SETTLE`) |
| `HEED_SHOTS` | Render every docs screenshot into this folder and quit (`HEED_SHOTS_ONLY`, `HEED_DOCS`) |

The last three are for working on Heed itself: `mise run shots` uses `HEED_SHOTS` to regenerate every image in these
docs from the fake world.
