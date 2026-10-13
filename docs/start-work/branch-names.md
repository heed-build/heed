---
description: How Start work names the branch and worktree, and how to change the prefixes.
---

# Branch names

The worktree field fills itself from your prompt: a prefix picked by the first word, then the words that matter.
"Fix broken anchors in the redirect pages" becomes `fix/broken-anchors-redirect-pages`. The worktree folder uses `-`
for `/`.

![The worktree field: fix/broken-anchors-redirect-pages, and where the worktree will go](../images/shots/start-work/branch-name.png)

Type in the field to name it yourself; it stops following the prompt once you do.

## Prefixes

The first word picks the prefix; anything else gets `default_prefix` (`feature`; `""` for none).

```toml
[worktrees]
default_prefix = "feature"

[worktrees.prefixes]
fix = ["fix", "bug", "broken", "crash", "repair", "resolve"]
bump = ["bump", "upgrade", "update"]
chore = ["chore", "cleanup", "tidy", "remove", "rename"]
refactor = ["refactor", "restructure", "simplify"]
docs = ["docs", "doc", "document", "readme"]
test = ["test", "tests", "cover"]
perf = ["perf", "speed", "optimize", "faster"]
feature = ["add", "implement", "support", "create", "introduce", "build", "feature"]
```

Worktrees go under `root` (`~/code/wt` by default) as `<root>/<repo>/<name>`.
