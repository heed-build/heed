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

## Layout

| Path | What |
| --- | --- |
| `Sources/HeedCore` | No UI: key notation, keymaps, the mode engine, commands, sessions, pane trees, the hook protocol |
| `Sources/HeedApp` | SwiftUI shell, AppKit key routing (`Keys/KeyRouter.swift`), terminal hosting (`Terminal/`) |
| `Sources/HeedTerminal` | The libghostty wrapper; the only code that touches `ghostty.h` (built when GhosttyKit exists) |
| `Sources/heed` | The CLI agent hooks call: `heed state blocked --reason "..."` over a unix socket |
| `design/` | The approved boards (`screens/*.png`) and the original brief (`BRIEF.md`) |
| `docs/plan.md` | The plan, decisions and build order |

## Deploying to the MacBook

`mise run build` copies `build/Heed.app` to `$HEED_DEPLOY_DIR` (set in `mise.local.toml`, not committed). Skipped,
never failed, when the share is not mounted.
