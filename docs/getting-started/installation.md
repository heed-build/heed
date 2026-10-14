---
description: Install Heed on macOS with one line, or build it from source.
---

# Installation

Heed is a macOS app for Apple Silicon (macOS 15 or later).

```sh
brew install --cask heed-build/tap/heed
```

or, without Homebrew:

```sh
curl -fsSL https://heed.build/install.sh | sh
```

Homebrew also puts the `heed` command on your `PATH` and updates with `brew upgrade`; `brew uninstall --zap heed`
removes its settings and caches too. The install script downloads the latest release, checks its sha256, and puts
`Heed.app` in `/Applications` (or `~/Applications` when `/Applications` is not writable). Run it again to update.
`HEED_VERSION=0.1.0` installs a given version and `HEED_APP_DIR` another folder.

Or download [`Heed-arm64.dmg`](https://github.com/heed-build/heed/releases/latest/download/Heed-arm64.dmg), open
it, and drag Heed onto Applications. Releases are signed with a Developer ID and notarized by Apple, the disk image
too, so it opens without a warning. `Heed-arm64.zip` on the [releases](https://github.com/heed-build/heed/releases)
is the same app, for scripts and Homebrew.

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
