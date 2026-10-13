---
description: Install Heed on macOS with one line, or build it from source.
---

# Installation

Heed is a macOS app for Apple Silicon (macOS 15 or later).

```sh
curl -fsSL https://heed.build/install.sh | sh
```

That downloads the latest release, checks its sha256, and puts `Heed.app` in `/Applications` (or `~/Applications` when
`/Applications` is not writable). Run it again to update. `HEED_VERSION=0.1.0` installs a given version and
`HEED_APP_DIR` another folder.

The app is not notarized yet. Installed this way it opens normally; a `Heed-arm64.zip` downloaded with a browser from
the [releases](https://github.com/heed-build/heed/releases) is flagged by macOS, and needs
`xattr -dr com.apple.quarantine /Applications/Heed.app` before it opens.

You also need the [GitHub CLI](https://cli.github.com), signed in (`gh auth login`): Heed talks to GitHub only through
`gh`.

## From source

- Xcode, selected with `xcode-select`, with its licence accepted and the Metal toolchain installed.
- [mise](https://mise.jdx.dev), which brings in the rest (Zig for libghostty, swiftformat, swiftlint).

```sh
git clone https://github.com/heed-build/heed.git
cd heed
mise install
mise run doctor     # reports anything missing
mise run ghostty    # builds libghostty (GhosttyKit) from the pinned Ghostty commit
mise run bundle     # release build: build/Heed.app
```

Move `build/Heed.app` to `/Applications` and open it.
