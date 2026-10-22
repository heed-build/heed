---
description: Where Heed finds repos, the order it lists them in, and their colours.
---

# Repos

Heed scans `repo_roots` (two levels deep) for git repositories, and lists every worktree added to them.

```toml
[worktrees]
repo_roots = ["~/Projects", "~/code"]
repo_paths = []          # repos outside the roots, added when you import one of their worktrees by path
```

![The repo column: repos with the most worktrees first](../images/shots/worktrees/repo-column.png)

- **Order.** Repos with the most worktrees come first, then by name; the worktree table groups rows in the same
  order, and Start work ranks those repos higher too.
- **Colours.** Every org has a colour, and its repos inherit it. Set them in Settings (`⌘,`) or in `config.toml`:

```toml
[orgs.acme]
color = "teal"      # teal, pink, lime, orange, periwinkle, sky

[repos."acme/docs-toolkit"]
color = "orange"
```

Org avatars are fetched once and cached; repos without a GitHub remote get a letter tile.
