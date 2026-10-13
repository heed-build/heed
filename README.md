# Heed

A native macOS command center for agentic coding. It hosts coding agents and shells in libghostty terminals,
manages repos and git worktrees, and tracks the GitHub issues and PRs around each task. Keyboard first, with
vim-style modes. Heed keeps a record of each session; the agents own their transcripts.

```sh
mise install        # zig (libghostty), swiftformat, swiftlint
mise run doctor     # what is missing: Xcode licence, Metal toolchain, zig, gh
mise run ghostty    # build Vendor/GhosttyKit.xcframework from the pinned Ghostty commit
mise run dev        # build, assemble build/Heed.app, copy it to HEED_DEPLOY_DIR, launch
mise run test       # Swift Testing (HeedCore)
mise run lint       # swiftformat + swiftlint
```

Without GhosttyKit the app builds with placeholder panes, so everything but the terminal can be worked on.

Headless checks: `HEED_SNAPSHOT=out.png build/Heed.app/Contents/MacOS/Heed` renders the window to a PNG and quits;
`HEED_SNAPSHOT_KEYS="2j<C-w>s?"` types keys first (vim notation).

## Documentation

`docs/` is a [docs-builder](https://github.com/elastic/docs-builder) site published to heed.build by
`.github/workflows/docs.yml`; `docs/heed-landing.html` is a standalone page copied over the generated home page.
`mise run docs` builds it the same way and serves it on :4000 (`docs-builder serve` would skip the landing page).

## Outside the window

- `⌃⌥H` (`[keys] global_activate`) brings Heed to the front from any app, reopening the window if it was closed.
- The menu bar owl (`[ui] menu_bar`, on by default) shows how many sessions need you; its menu lists them (choosing
  one opens Heed on it), plus Start work, Open Heed, Settings and Quit. With it on, closing the window keeps Heed
  and its agents running.
- The Dock icon (`[ui] dock_state`, on by default) gets a badge in the state's colour (blocked, else asking) with the
  count.

The brand pack (icon, logo, menu bar template, social preview, org avatars) lives in `design/brand/`.

## Start work from anywhere

`⌃⌥Space` (`[keys] global_start_work` in config.toml; `""` turns it off) opens Start work in a floating panel over
whatever app is in front. It takes the keyboard without bringing Heed forward; `⎋ ⎋` or a click elsewhere closes it,
`⌘↩` starts the session. The panel's window title is always `Heed Start Work` (bundle id `net.nullean.heed`), so a
tiling window manager can leave it alone:

```toml
# OmniWM: ~/.config/omniwm/settings.toml (id is any UUID)
[[appRules]]
bundleId = "net.nullean.heed"
id = "75CF2DF1-FF34-4187-9CC9-01DD190EFC51"
layout = "float"
titleRegex = "^Heed Start Work$"
```

```sh
# yabai
yabai -m rule --add app="^Heed$" title="^Heed Start Work$" manage=off
```

## Layout

| Path | What |
| --- | --- |
| `Sources/HeedCore` | No UI: key notation, keymaps, the mode engine, commands, sessions, pane trees, the hook protocol |
| `Sources/HeedApp` | SwiftUI shell, AppKit key routing (`Keys/KeyRouter.swift`), terminal hosting (`Terminal/`) |
| `Sources/HeedTerminal` | The libghostty wrapper; the only code that touches `ghostty.h` (built when GhosttyKit exists) |
| `Sources/heed` | The CLI agent hooks call: `heed state blocked --reason "..."` over a unix socket |
| `design/` | The approved boards (`screens/*.png`) and the original brief (`BRIEF.md`) |
| `PLAN.md` | The plan, decisions and build order |

## Contributing and releasing

`main` only changes through pull requests, and CI must pass: lint, the tests, a release build and the tutor check on
macOS, and the docs build. Branch names label pull requests for the release notes: `feature/…`, `fix/…`, `docs/…`.

[release-drafter](https://github.com/release-drafter/release-drafter) keeps a draft release up to date as pull requests
merge, and works out the next version from their labels (`major`, `minor` or `enhancement`, otherwise a patch). To
release, run the **release** workflow (`gh workflow run release`, optionally `-f version=0.2.0`): it builds `main`,
signs it with the Developer ID (hardened runtime, `scripts/sign.sh`), has Apple notarize it and staples the ticket,
attaches `Heed-arm64.zip` and its sha256 to the draft, checks both are there, and only then publishes the draft, which
tags the commit it built. A rejected notarization stops it before anything is attached. `-f dry_run=true` does all
but the release, from any branch, and keeps the notarized zip on the run. `install.sh` installs from the latest
release. The signing and notarization secrets come from `scripts/release-secrets.sh`.

## Deploying to the MacBook

`mise run build` copies `build/Heed.app` to `$HEED_DEPLOY_DIR` (set in `mise.local.toml`, not committed). Skipped,
never failed, when the share is not mounted.
