---
description: "Hosts: machines Heed drives over ssh, and the repos and worktrees on them."
---

# Hosts

A host is a machine Heed reaches over ssh: a devbox, a GPU box, a build runner. Heed uses your own ssh: your
`~/.ssh/config`, keys, agent and jump hosts. It never reads a key, and it shares one connection per host, so its
calls are fast.

Today Heed finds the repos and worktrees on your hosts and shows them next to the ones on this Mac. Sessions on hosts,
with agents that survive a dropped connection, come next.

## Adding a host

`gH` opens the hosts: the ones Heed has, and the ones in `~/.ssh/config` it could add. `↩` on one from your ssh
config adds it to `config.toml`; `↩` on one Heed has checks it again. The checks say how it answers:

![The hosts, with @devbox's checks: connected, its platform, git, zmx and agents](../images/shots/hosts/picker.png)

| Check | Means |
|---|---|
| connected in 24 ms | It answers, through your ssh agent, without a prompt |
| ssh needs your key | Your key is locked or not loaded: `ssh-add`, then `↩` |
| host key not known yet | Connect once in a terminal to check and accept its key |
| host key changed | The key does not match `known_hosts`: blocked until you find out why |
| offline | It does not answer; what Heed saw of it last stays, marked stale |

![A host that wants your key](../images/shots/hosts/picker-auth.png)

A host in `config.toml`:

```toml
[hosts.devbox]
# ssh = "devbox"                 # what ssh connects to; the name by default (an alias from ~/.ssh/config)
repo_roots = ["~/code"]          # where repos are looked for on it, two levels deep
worktree_root = "~/code/wt"      # where Heed will put the worktrees it makes there
color = "teal"                   # teal, periwinkle, pink or sky
```

Amber and green are never host colours: they mean "needs you" and "done".

## Repos on hosts

On each refresh Heed checks every host and, for each one that answers, finds its repos and lists their worktrees
with their status. In [Repos](../worktrees/repos.md) they appear with their host:

![Repos with a host column: worktrees on @devbox next to the ones on this Mac](../images/shots/hosts/repos.png)

A worktree on a host is one of:

| State | |
|---|---|
| **registered** | Heed's to manage: it made it, or you registered it |
| **discovered** | Found by a scan and never touched. `↩` registers it |
| **stale** | Its host does not answer: shown as last seen |
| **missing** | Registered, but no longer on its host |

The cleanup sweep never touches a host's worktrees.

`@` narrows the view you are on to one host: it starts the filter with `@`, so `@dev` keeps what is on `@devbox`
(`:host.filter devbox` does the same).

![Repos narrowed to @devbox](../images/shots/hosts/filter.png)
