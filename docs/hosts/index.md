---
description: "Hosts: machines Heed drives over ssh, and the repos and worktrees on them."
---

# Hosts

A host is a machine Heed reaches over ssh: a devbox, a GPU box, a build runner. Heed uses your own ssh: your
`~/.ssh/config`, keys, agent and jump hosts. It never reads a key, and it shares one connection per host, so its
calls are fast.

Heed finds the repos and worktrees on your hosts and shows them next to the ones on this Mac, and runs sessions there:
the agent runs on the host, in a [zmx](../sessions/zmx.md) session when the host has zmx, so a dropped connection, a
closed lid or a restarted Heed never stops it.

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

## Sessions on a host

`↩` on a registered worktree on a host makes it a session there. The first time, Heed puts what its hooks need on the
host, all inside `~/.heed` and without root:

- `~/.heed/bin/heed-hook`, a few lines of POSIX sh that agents' hooks call;
- the hook settings and plugins the agents are started with (the same ones Heed uses on this Mac).

For the agent to outlive the link, the host needs [zmx](https://zmx.sh), which you install there yourself. Heed copies
no programs to your hosts. The host's checks (`gH`) say whether it has zmx, and if not, the line that installs it for
that host's system and architecture:

![A host without zmx: the line that installs it there](../images/shots/hosts/picker-no-zmx.png)

Heed looks for zmx on the host's PATH and in `~/.local/bin`, `~/bin`, `~/.nix-profile/bin`, `/usr/local/bin` and
`/opt/homebrew/bin` (a non-interactive ssh often has no `~/.local/bin` on its PATH). Without zmx, a session there is a
plain login shell over ssh, marked **not persistent**: it ends when the link drops.

![A session on @devbox: the pane strip, the rail and chip in the sidebar, and the host in the status bar](../images/shots/hosts/session.png)

A remote session shows where it runs without your reading anything: an `@host` chip and a rail in the host's colour
in the sidebar, a tinted strip over its panes with the link's state and latency, and the host in the title bar and
status bar. Local sessions stay unmarked.

What runs where:

| | |
|---|---|
| The agent, git, its worktree | On the host. Your Mac never clones the repo |
| The terminal you see | Here: ssh to the host, attached to the pane's zmx session there |
| Agent state (working, asking, blocked) | The agent's hooks write it to `~/.heed/events.log` on the host; Heed reads that over the shared ssh connection, and catches up on anything it missed while away |
| PRs | Here, through `gh`, matched by repo and branch as for local sessions |

When the link drops, the pane says so and reconnects every few seconds. zmx kept the session, so the screen and
scrollback come back as they were. (Without zmx the pane says the session ended with the link, and closes.) `exit` in the pane, closing it, or closing the session ends the zmx session on the
host. Cursor's hooks are not set up on hosts yet; its state is read from the screen there.
