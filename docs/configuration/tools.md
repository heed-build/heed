---
description: How Heed finds git and gh, and how to point it at others.
---

# Finding git and gh

An app opened from the Finder gets a minimal PATH, without Homebrew, mise or nix on it. So Heed finds `git` and `gh`
itself, and runs every command (and every pane) with what it found. It searches, in order:

1. `path` under `[tools]`.
2. Your login shell's PATH: fish, zsh, bash and nu are each asked in their own way.
3. The usual places: Homebrew, MacPorts, mise, asdf, nix, `~/.local/bin`, cargo, bun, volta.
4. The PATH Heed was started with.

Each candidate must answer `--version`. `/usr/bin/git` is skipped when the Command Line Tools are not installed, rather
than popping up their installer.

```toml
[tools]
git = ""     # empty detects; a path ("/opt/homebrew/bin/git") or a name to look up
gh = ""
path = []    # directories searched first, for git, gh and agent commands
```

A configured value that does not work is reported, and detection carries on. The first-run screen and Settings show
what was found and where from; `:tools.detect` looks again.

## From a terminal

`heed tools` prints the same report. `env -i HOME=$HOME heed tools` shows what an app opened from the Finder would find.
