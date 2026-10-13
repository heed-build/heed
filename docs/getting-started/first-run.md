---
description: What Heed looks for the first time it opens, and where its configuration lives.
---

# The first run

The first time it opens, Heed shows what it found:

- **GitHub**: whether `gh` is signed in. Signing in from any terminal is picked up without a restart.
- **Tools**: where `git` and `gh` are, found through your login shell's PATH (fish, zsh, bash and nu) and the usual
  install locations.
- **Repos**: the repositories under `~/Projects` and `~/code`.
- **Agents**: which of claude, codex, cursor, pi, opencode and gemini are installed.

Nothing in your own agent configuration changes: Heed passes its hooks to each agent per run.

## Configuration

Everything lives in `~/.config/heed/config.toml`, written with comments the first time Heed opens. Settings (`⌘,`)
edits the same file; key bindings live only in the file.
