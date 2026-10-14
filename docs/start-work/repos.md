---
description: How Start work guesses the repo, and how to pick any repo instead.
---

# Choosing repos

As you type, Heed ranks your repos and selects the best guess, only that one: each selected repo gets a worktree, so a
second is always yours to add. Each guess shows how sure it is, and the line under the
chips says why:

- **The prompt names it**: the strongest signal (`… in docs-builder`). Whole names only, and not inside a link or
  an `org/repo#12` reference: those point at an issue, not at where the work happens.
- **Words in common** with the repo's name.
- **Recent sessions** ran there.
- **Worktrees already**: repos you work in most rank higher.

![The repo field: guesses with their confidence, and why the first was picked](../images/shots/start-work/repos.png)

Move to the repo field (`⎋` then `j`) and use `h` `l` to move between chips and `space` to add or remove one. More than
one repo makes a cross-repo session: a worktree in each, on the same branch. `⌃n` `⌃p` cycle which one is primary.

Repos on your [hosts](../hosts/index.md) are guessed the same way and their chips say `@host`: picking one starts
the work there.

## Any other repo

When none of the guesses is right, the last chip, **other repo…**, opens a search over every repo (or press `/` on the
repo field). Type to narrow, `⌃n` `⌃p` to move, `↩` to add it. It then keeps a chip of its own.

![Searching every repo: mer typed, mermaider matched](../images/shots/start-work/repo-search.png)
