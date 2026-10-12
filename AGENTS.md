# Agents working on Heed

## Principles (from the owner; they decide design questions)

- **Domain driven.** Clean domain models in `HeedCore` (sessions, repos, worktrees, PRs, agents, config) power both
  the UI and the config file. Views render the domain; they never hold their own copy of it.
- **Cache everything, start fast.** The domain is persisted and loaded first, so the window draws the last known state
  immediately; fresh data replaces it as it arrives. Startup never waits on gh, git or the network.
- **Data access is async and projected.** gh, git, the agents' hooks and the filesystem are adapters that run off the
  main actor and project their results into domain values. Raw JSON or command output never reaches a view.
- **Differential UI updates.** Changes land as small domain diffs on `@Observable` models, so only what changed
  redraws. No whole-list replacement when one row changed; stable identities everywhere.
- **Never steal focus.** Heed never activates itself or raises a window on its own: not on launch from a hook, not on
  a state change, not when a PR event arrives. Attention is asked for (badge, `ga`, a notification), never taken.

- Read `docs/plan.md` first; the brief is `design/BRIEF.md`, the boards `design/screens/*.png`.
- `mise run test` and `mise run lint` before committing. Core logic goes in `HeedCore` with tests; the app layer
  stays thin.
- Never block the main actor: no `Process.waitUntilExit`, file or network IO on it.
- All libghostty calls live in `Sources/HeedTerminal`.
- Keys: add a command to `Commands.all`, bind it in `DefaultKeys`, handle it in `AppModel.perform`. Never handle a key
  anywhere else.
- Check UI against the design with `HEED_SNAPSHOT` (see README).
- GitHub only via `gh`.
