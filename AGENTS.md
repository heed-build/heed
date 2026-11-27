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
- `HEED_LIVE=1 mise run live-browse` is the live smoke suite for Browse (`LiveGitHubContractTests`, `LiveBrowseE2ETests`): the real
  HeedCore reads against real GitHub with your `gh`, then an end-to-end run (trust, worktrees, Chat, Fix and Review through
  the real ACP adapter on haiku under the hardened policy, bulk writes, the resume line) on one throwaway repository,
  `Mpdreamz/heed-smoke`. It finds what fakes cannot: a field that needs another token scope, a flag gh lacks, a policy that
  refuses a legitimate command. It needs HEED_LIVE=1 and sets HEED_LIVE_BROWSE=1 itself, so `mise run live` and
  `mise run test` skip it. Writes go through `SmokeGH.write`, which refuses every repository but `LiveSmoke.slug` (tested in
  `LiveSmokeGuardTests`, which runs everywhere); models are haiku only, with a spend and tool-call cap per run and a wall-clock
  cap. Whatever a run makes there is closed or deleted when it ends, and the next run sweeps what a crashed one left
  (`heed-live-smoke` labels and `heed-live-*`, `heed/browse/*` branches older than an hour). The report is written to
  `$HEED_LIVE_REPORT` or `~/Projects/heed-plans/browse/audit/live-smoke-<date>.md`. `LiveRunDriver.swift` runs a Browse run the
  way `AppModel+BrowseRun.swift` does (same HeedCore pieces, same order): change it with the app's glue.
- `mise run bench` (`HEED_BENCH=1`) runs `Tests/HeedCoreTests/Bench`: timings, in an optimized build, one at a time. A test in
  the suite never asserts a duration (the suite runs in parallel on loaded machines); it checks what a cost comes from
  (reads, sizes, counts) and the timing goes to a bench.
- `mise run test` builds only HeedCore and its tests (no app, MLX, Sparkle or Ghostty), so it is the fast loop; `-- --filter Name`
  runs some tests and `-- --skip-build` reuses the build. It does not compile the app: run `mise run check` after
  touching `Sources/HeedApp`. `mise run test` and `mise run lint` before committing. Core logic goes in `HeedCore` with tests; the app layer
  stays thin.
- CI builds are incremental: `scripts/pin-mtimes.sh` (run by the setup action) stamps each tracked file from its content,
  because Swift Build rebuilds an input whose modification time changed and a fresh checkout changes all of them. Main
  saves `.build` (the newest two per job are kept, `scripts/prune-caches.sh`) and pull requests restore it.
- Several agents build at once on one machine, and a `swift build` spawns a compiler per core, so the heavy commands (`mise run
  test`, `check`, `build`, `bundle`, `bench`, `live`, `ghostty`) run through `scripts/slot.sh`: two machine-wide build slots, the rest
  wait their turn and say who is building. `HEED_BUILD_SLOTS=N` changes the count (0 turns it off; CI does not need it).
  `scripts/prune-worktree-builds.sh` lists the worktrees whose `.build` has been idle (3 to 4 GB each; Swift Build ties its
  state to the absolute path, so one cannot be moved or shared) and deletes them only with `--delete`.
- Text other people wrote (PR and issue text, comments, checks) is `ExternalText`, and what leaves heed for an agent
  is a `Prompt` (`Sources/HeedCore/Domain/Prompt.swift`). `mise run text-check` fails when either is
  interpolated into a plain String; run it after changing a prompt. CI reads the warnings of its own builds (the test
  build and the release build), so nothing is compiled twice; locally it builds in `.build/text-check`.
- Never block the main actor: no `Process.waitUntilExit`, file or network IO on it.
- All libghostty calls live in `Sources/HeedTerminal`.
- Keys: add a command to `Commands.all`, bind it in `DefaultKeys`, handle it in `AppModel.perform`. Never handle a key
  anywhere else.
- Check UI against the design with `HEED_SNAPSHOT` (see README).
- GitHub only via `gh`.

## Measuring the app

- `Perf` (`Sources/HeedCore/Store/Perf.swift`) puts os_signpost intervals on the hot paths, subsystem `build.heed.app`,
  category `perf`: `commit`, `rebuildList`, `readScreens`, `attentionEntries`, `audit.refilter`, `domain.flush`,
  `telemetry.costs`, and startup: up to the cached domain drawn (`start.toCache`, inside it `start.callLog`,
  `start.loadDomain`, `start.openLog`, `start.adopt`, `start.replace`), and up to the panes' terminals made
  (`start.toPanes`, inside it also `start.detectTools`, `start.llm`, `start.telemetry`, `start.livePanes`). Add one with `let perf = Perf.begin("name")` and `defer { perf.end() }`; while
  nothing records, it costs one `isEnabled` check.
- To record them: Instruments' Logging template (or Time Profiler or SwiftUI with the os_signpost instrument added),
  filtered to subsystem `build.heed.app`; or, beside the CPU samples,
  `xcrun xctrace record --template 'Time Profiler' --instrument os_signpost --attach Heed --time-limit 60s
  --output heed.trace` and `open heed.trace`. The intervals show under os_signpost, category perf, with each one's
  count and durations.
- `mise run bench` builds only the test product (HeedCore and its tests) with `-O`, not the app and MLX.
