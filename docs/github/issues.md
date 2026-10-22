---
description: Issues assigned to you or mentioning you, and every open issue in the repos you choose.
---

# Issues

`:issues` shows open issues (`gi` opens [Attention](attention.md) on its Issues filter): those assigned to you or mentioning you, everywhere, plus every open issue in the repos you
choose to watch.

![Issues: the repo column on the left, filter chips, issues tagged assigned or mentioned](../images/shots/github/issues.png)

## All issues, or only yours

For each repo, the Issues view shows either every open issue or only those involving you. An eye in the repo column
marks repos showing all of them.

- `w` on an issue flips its repo between the two (`w` does the same in [Repos](../worktrees/index.md)).
- Set it per org or per repo in `config.toml`; the most specific setting wins:

```toml
[issues]
default = "involved"        # only issues assigned to you or mentioning you

[orgs.nullean]
issues = "all"              # every open issue in this org's repos

[repos."nullean/noisy"]
issues = "involved"         # except this one
```

Settings (`⌘,`) sets the default and each org.

## Filters

| Chip (`t` cycles) | Shows |
|---|---|
| All | Everything shown |
| Assigned | Assigned to you |
| Mentioned | Mentioning you |
| Watched repos | Shown only because their repo shows all issues |

`⇥` and `⇧⇥` move through the repo column; clicking a repo works too. Issues take the same keys as the
[Inbox](inbox.md): `space`, `s`, `a`, `go`.

![Issue rows with their involvement and labels](../images/shots/github/issue-rows.png)
