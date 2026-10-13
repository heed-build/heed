---
description: Removing worktrees nobody has touched for a while, automatically.
---

# Cleanup

Cleanup removes worktrees nobody has touched for a while. It is off until you turn it on.

```toml
[cleanup]
enabled = false
idle_days = 14
delete_branch = true        # the local branch; the remote is left alone
ask_before_sweep = false
```

A worktree is idle when nothing happened in it for `idle_days`: no agent output, keystrokes, hook events, commits or
pull request updates. The same safety rules as [removing](removing.md) apply: dirty, unpushed and pinned work is never
removed.

![The cleanup rules in Repos](../images/shots/worktrees/rules.png)

With cleanup on, Repos shows what the next sweep would do. Sweeps run hourly unless `ask_before_sweep` is set; `gC` runs
one now, after a confirmation that lists every worktree it would remove.

![The sweep banner: what would be removed, what is kept](../images/shots/worktrees/sweep.png)
