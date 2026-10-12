# Agents working on Heed

- Read `docs/plan.md` first; the brief is `design/BRIEF.md`, the boards `design/screens/*.png`.
- `mise run test` and `mise run lint` before committing. Core logic goes in `HeedCore` with tests; the app layer
  stays thin.
- Never block the main actor: no `Process.waitUntilExit`, file or network IO on it.
- All libghostty calls live in `Sources/HeedTerminal`.
- Keys: add a command to `Commands.all`, bind it in `DefaultKeys`, handle it in `AppModel.perform`. Never handle a key
  anywhere else.
- Check UI against the design with `HEED_SNAPSHOT` (see README).
- GitHub only via `gh`.
