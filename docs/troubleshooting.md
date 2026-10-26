---
description: Fixes for the problems people run into most.
---

# Troubleshooting

## gh is not signed in

The first-run screen and Attention say so. Run `gh auth login` in any terminal; Heed notices without a restart.

## git or gh is "not found"

Heed searches your login shell's PATH and the usual install locations. If it still picks the wrong one, or none, set
it: `[tools] git = "/opt/homebrew/bin/git"`. `heed tools` in a terminal shows what Heed finds and why. See
[Finding git and gh](configuration/tools.md).

## Some pull requests or issues are missing

Items in orgs your `gh` token is not authorized for (SAML single sign-on) are counted in the title bar ("· 49 hidden")
instead of shown. `gh auth refresh`, or authorizing the GitHub CLI for that org on GitHub, brings them in.

## An agent's state is wrong or missing

Check the agent is started by Heed (its pane's command line includes Heed's hooks; see [Hooks](agents/hooks.md)). States
it cannot report are guessed from its screen, drawn with a dotted ring; add patterns for your agent under
`[agents.<name>.patterns]` ([Reading the screen](agents/screen-reading.md)).

## No notification came

A session notifies only once it has needed you for `grace_seconds` (30), never during `[attention] quiet` hours, never
while Heed is in front showing it, and only when macOS lets Heed notify (System Settings › Notifications). Each
decision, and why nothing was posted, goes to the event log in `heed.sqlite`. See
[Notifications](outside-the-window/notifications.md).

## Something Heed ran failed or is slow

`:log` opens the [call log](reference/call-log.md): every command Heed ran and every GitHub call, with how long it
took and how it ended. `x` shows only the failed ones, `s` the slow ones.

## The ledger or Attention has no summaries

They come from Heed's [model calls](agents/model-calls.md), through an agent CLI you are logged in to. Settings ›
Agents shows which agents take part, and **Test** makes one call to see what goes wrong; `:log` lists every model call
as `llm`.

## The Start work panel closes right away, or tiles

A tiling window manager is managing it. Add a rule for the window titled `Heed Start Work`; see
[From anywhere](start-work/from-anywhere.md).

## Work went on the wrong goal, or on none

`U` in Goals opens [Unassigned](goals/attach.md): what heed decided lately and why. `u` undoes heed's last attachment,
and `:goal.attach` puts a session on the right goal; each correction becomes a line in `goals/attach.rules`, so it
learns. Work heed was unsure about waits in Attention as **which goal?**. To have it attach more or ask less, change
`attach_auto` and `attach_ask` under `[goals]`; `attach = false` turns finding goals off.

## A goal's reviewers never run

Attention says why. **reviewers wait**: the goal used its `reviewer_runs_per_day`. **reviewers blocked**: the work is
in a repo with no clone on this Mac. A reviewer at or over its bar stays quiet until something
changes, and with `auto_review = false` they run only when you press `r`. With no session on the goal open, a reviewer
runs headless, which only claude and codex can: set `[goals] reviewer_agent`. See [Reviewers](goals/reviewers.md).

## A mirrored goal is not on GitHub

Mirroring is off until you press `M` on the goal. A tracker repo is taken only if it exists, has issues on, is not
archived and you can triage there; the overview's **On GitHub** panel says which failed. A sync makes at most 20 writes,
and the rest follow on the next one. `:goal.mirror.sync` syncs now, and every write is in `:log` under the caller
`goals.mirror`. See [GitHub mirror](goals/github.md).

## heed goal says Heed is not reachable, or no goal

Exit code 3: Heed is not running, or the shell is on a host, where the control socket cannot be reached. Exit code 4:
the session is on no goal; `heed goal attach <goal>` puts it on one, or pass `--goal`. See
[Agents keep the goal](goals/cli.md).

## A key does nothing

The status bar says what Heed made of it ("gq is not bound"). Check `config.toml` for a binding that was refused (the
reason is in the status bar), and `?` for what every key does now.

## Closing the window stopped my agents

With the menu bar item off, closing the window quits Heed. Turn it on (`[ui] menu_bar = true`) and closing the window
keeps Heed and its agents running.

## Heed never offers an update

- A build from source never checks; only release builds do (`:update` says which you have).
- `[updates] check = false` stops the daily check; `:update` still looks.
- Releases before 0.6.0 cannot update themselves: install 0.6.0 once (the disk image, `brew upgrade heed` or the
  install script), and it updates itself from then on.

See [Updates](configuration/updates.md).
