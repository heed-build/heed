---
description: Build and install Heed on macOS.
---

# Installation

Heed is a macOS app (macOS 15 or later). There is no download yet: build it from source.

## What you need

- Xcode, selected with `xcode-select`, with its licence accepted and the Metal toolchain installed.
- [mise](https://mise.jdx.dev), which brings in the rest (Zig for libghostty, swiftformat, swiftlint).
- The [GitHub CLI](https://cli.github.com), signed in (`gh auth login`). Heed talks to GitHub only through `gh`.

## Build

```sh
git clone https://github.com/nullean/heed.git
cd heed
mise install
mise run doctor     # reports anything missing
mise run ghostty    # builds libghostty (GhosttyKit) from the pinned Ghostty commit
mise run bundle     # release build: build/Heed.app
```

Move `build/Heed.app` to `/Applications` and open it.
