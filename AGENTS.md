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
- **The UI starts from a domain value, with no IO.** The window is a function of a domain snapshot plus the input
  state (mode, overlay, cursor). Fixtures are plain domain values (`main`, `blocked`, `offline`, `empty`, `first-run`,
  one per design board), so the app can open in any of them for snapshots, previews and tests with every adapter
  (gh, git, sockets, terminals) switched off: `HEED_FIXTURE=offline HEED_SNAPSHOT=out.png`.
- **Never steal focus.** Heed never activates itself or raises a window on its own: not on launch from a hook, not on
  a state change, not when a PR event arrives. Attention is asked for (badge, `ga`, a notification), never taken.

- Read `PLAN.md` first; the brief is `design/BRIEF.md`, the boards `design/screens/*.png`.
- `mise run live` (`HEED_LIVE=1`) runs the live checks in `Tests/HeedCoreTests/Live`: helpers, approvals, the goal wizard and
  OpenTelemetry against real Claude Code on haiku, in throwaway repos. They call a model, so `mise run test` and CI skip
  them; turn what they capture into a scrubbed fixture under `Fixtures/live` when the agents change.
- `mise run bench` (`HEED_BENCH=1`) runs `Tests/HeedCoreTests/Bench`: timings, in an optimized build, one at a time. A test in
  the suite never asserts a duration (the suite runs in parallel on loaded machines); it checks what a cost comes from
  (reads, sizes, counts) and the timing goes to a bench.
- `mise run test` and `mise run lint` before committing. Core logic goes in `HeedCore` with tests; the app layer
  stays thin.
- Text other people wrote (PR and issue text, comments, checks) is `ExternalText`, and what leaves heed for an agent
  is a `Prompt` (`Sources/HeedCore/Domain/Prompt.swift`). `mise run text-check` (CI runs it) fails when either is
  interpolated into a plain String; run it after changing a prompt.
- Never block the main actor: no `Process.waitUntilExit`, file or network IO on it.
- All libghostty calls live in `Sources/HeedTerminal`.
- Keys: add a command to `Commands.all`, bind it in `DefaultKeys`, handle it in `AppModel.perform`. Never handle a key
  anywhere else.
- Check UI against the design with `HEED_SNAPSHOT` (see README).
- GitHub only via `gh`.

## Measuring the app

- `Perf` (`Sources/HeedCore/Store/Perf.swift`) puts os_signpost intervals on the hot paths, subsystem `build.heed.app`,
  category `perf`: `commit`, `rebuildList`, `readScreens`, `attentionEntries`, `audit.refilter`, `domain.flush`,
  `telemetry.costs`, and startup up to the cached domain (`start.toCache`, inside it `start.callLog`,
  `start.detectTools`, `start.llm`, `start.telemetry`, `start.loadDomain`, `start.openLog`, `start.adopt`,
  `start.livePanes`, `start.replace`). Add one with `let perf = Perf.begin("name")` and `defer { perf.end() }`; while
  nothing records, it costs one `isEnabled` check.
- To record them: Instruments' Logging template (or Time Profiler or SwiftUI with the os_signpost instrument added),
  filtered to subsystem `build.heed.app`; or, beside the CPU samples,
  `xcrun xctrace record --template 'Time Profiler' --instrument os_signpost --attach Heed --time-limit 60s
  --output heed.trace` and `open heed.trace`. The intervals show under os_signpost, category perf, with each one's
  count and durations.
- `mise run bench` builds only the test product (HeedCore and its tests) with `-O`, not the app and MLX.
