---
description: How heed hands an agent what it sends it (feedback, notes, the continue prompt, heed send), and when it types.
---

# How Heed talks to agents

Heed sends agents things on your behalf: a PR's feedback with `run_in = "session"`, a session's notes on its diff, the
continue prompt after a resume, items added from GitHub (`a`), loose ends from the inspector, `heed send`, a swarm's
messages and answers, and a nudge to a swarm's lead. Each one goes the best way the agent offers:

| Agent | How | When |
|---|---|---|
| claude | Its cross-session inbox | Whenever it runs: Claude holds it until it can read it |
| codex | `codex queue`, when `codex_queue` is on | Whenever it runs: codex keeps it in the thread's queue |
| any other, or either of those without its channel | Typed into its pane, Return pressed | Only while it is idle or done, and you have not typed there in the last 20 seconds |

Where each went is on the session's activity ("sent 2 notes to claude, through Claude's inbox"), in the status line,
in the Autopilot log for a PR's rounds, and in a swarm's rows. A message typed as always says nothing more.

The one thing heed still types whatever the agent is: **Allow** on a permission notification presses Return on the
prompt. No channel can answer a prompt, by design.

## Claude's inbox

Claude Code (2.1.224 and later) gives every running session an inbox, a Unix socket only your user can reach, and
exports its path to hooks as `CLAUDE_CODE_MESSAGING_SOCKET`. Heed's hook passes the path to the app when the session
starts, with each prompt and when a turn ends, so heed learns it again after a restart. Heed's panes start with the
variable empty, so an inbox inherited from wherever Heed was opened is never taken for the pane's own.

A message there arrives as a message from another session, starting "From heed, the app your user runs this session
in:". Claude Code tells the agent such a message can never approve a permission prompt or stand in for you, and never
to change its permissions, `CLAUDE.md` or settings because of one; a command in it (`/compact`) is plain text. While
the agent works it reads the message between tool calls; when idle, it starts a turn with it. So a message through the
inbox does not wait for the agent to be idle, nor for you to stop typing in its pane (nothing is typed under your
fingers). A delivery that waits for you to leave the session alone (auto-fed feedback, five minutes after your last
keystroke) still waits.

What Claude Code does with it depends on the session:

- **Delivered**: the default for a session that asks for permissions, and with `crossSessionInbound = "accept"`.
- **Held for your approval**: a session that bypasses permission prompts, or `crossSessionInbound = "hold"`. Claude
  shows the message in the session for you to approve or deny; heed records it as queued ("held for your approval in
  the session"), and records it again if it is denied or expires there.
- **Refused**: `crossSessionInbound = "refuse"`. Heed types it instead, under the typing rules above, and stops
  using that session's inbox.

Heed learns which from Claude Code itself: each message names a reply socket beside the session's own
(`heed-<pid>.sock`), where Claude Code says when it held or refused one. No answer means it was delivered. Nothing
answering at the inbox (the agent exited) also falls back to typing.

Heed never changes `crossSessionInbound` and never presents the session's own token: to Claude Code, heed is another
process on your machine, and the session's own rules for one apply. To turn the inbox off and have everything typed as
before:

```toml
[sessions]
claude_inbox = false
```

A Claude session on a [host](../hosts/index.md) is always typed to: its inbox is on that machine.

## Codex

Codex sessions on codex's shared app-server daemon (where codex 0.163's TUI runs unless started with `--no-daemon`) take messages with `codex queue --thread
<id> --message <text>`, which adds it to the thread's queue: codex runs it when the thread takes its next turn, as it
does a prompt you queue while it works. Heed knows the thread from codex's `SessionStart` hook. This is off by
default:

```toml
[sessions]
codex_queue = true
```

It is off because `codex queue` says only that the message was stored, not that a running TUI picked it up: a thread
not loaded on the daemon (a codex started with `--no-daemon`, or interrupted mid-turn) can keep it until you start a
turn yourself. Heed records it as "queued in codex's queue". When `codex queue` fails, heed types it instead, under
the typing rules.

## Everything else

opencode, cursor, pi and gemini are typed to. opencode's TUI runs a local HTTP server on a port of its choosing, and
heed does not learn that port for the session it started yet; the others offer nothing a running session reads.

## For heed's own features

A part of heed that wants to tell a session something calls `notify(session:text:)` on the app model: the session's
channel, else typed under the typing rules, recorded on the session either way. It says where the message ended up
(`DeliveryOutcome`): delivered, queued, typed (and why its channel was not used), waiting, or failed. Nothing
retries a message that waits.

[Helpers](helpers.md) tell a session about the work they do on its PR this way, with typing ruled out
(`mayType: false`): the note goes through the agent's channel or not at all, and the helper line at the foot of the
session's panes shows it in every case.
