import Foundation

// The entries, page by page. Labels and details are the ones Settings shows today; settings only config.toml had
// so far get theirs from its comments. `since` is the first release whose config read the key (from git history).

extension SettingsCatalog {
    /// A global setting: `key` is its whole path. The example defaults to the key with its default value.
    static func global(
        _ key: String, _ page: SettingsPage, _ section: String, tab: SettingsTab? = nil, _ label: String,
        _ detail: String, level: SettingLevel = .basic, impact: SettingImpact = .none, since: String,
        example: String? = nil, table: Bool = false, _ read: @escaping @Sendable (HeedConfig) -> SettingValue?
    ) -> SettingsEntry {
        let path = key.split(separator: ".").map(String.init)
        return SettingsEntry(
            id: key, page: page, section: section, tab: tab, label: label, detail: detail, scope: .global, key: path,
            isTable: table, level: level, impact: impact, since: since,
            example: example ?? "\(TOMLValue.key(path.last ?? key)) = \(read(.default)?.toml.literal ?? "\"\"")",
            read: { config, _ in read(config) }
        )
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    // MARK: Global settings

    static let globalEntries: [SettingsEntry] = general + notifications + updates + modelCalls + decisions
        + worktrees + goals + history + github + pilot + helpers + attention + tools + keys

    static let general: [SettingsEntry] = [
        global(
            "sessions.default_agent", .general, "Sessions", "Default agent",
            "The agent Start work picks when nothing else does.", since: "0.1.0"
        ) { .text($0.work.defaultAgent) },
        global(
            "sessions.resume_on_launch", .general, "Sessions", "Resume on launch",
            "Ask lists the sessions that were open; Always resumes them; Never starts empty.", since: "0.1.0"
        ) { .text($0.work.resumeOnLaunch.rawValue) },
        global(
            "sessions.continue_prompt", .general, "Sessions", "Continue prompt",
            "Typed into a resumed session that was mid-turn, once idle. Empty turns it off.", since: "0.1.0"
        ) { .text($0.work.continuePrompt) },
        global(
            "sessions.shell_split", .general, "Sessions", "Shell split",
            "New sessions open a shell beside the agent; off is one pane.", since: "0.1.0"
        ) { .bool($0.work.shellSplit) },
        global(
            "sessions.name_sessions", .general, "Sessions", "Name sessions",
            "Heed names each session from what it is doing, after its first turn and when it opens a PR; a title "
                + "you give it stays.", since: "0.38.0"
        ) { .bool($0.work.nameSessions) },
        global(
            "sessions.claude_inbox", .general, "Sessions", "Send to Claude through its inbox",
            "What heed sends a Claude session (feedback, notes, the continue prompt) goes to its cross-session inbox "
                + "instead of being typed: it waits there while the agent works and can never approve a prompt. "
                + "Without one, typed as before.", since: "0.42.0"
        ) { .bool($0.work.channels.claudeInbox) },
        global(
            "sessions.codex_queue", .general, "Sessions", "Send to codex with codex queue",
            "The same for codex sessions, through codex's shared app-server. Experimental: off by default.",
            since: "0.42.0"
        ) { .bool($0.work.channels.codexQueue) },
        global(
            "sessions.persist", .general, "Sessions", "Persistent panes",
            "Panes run in zmx, so agents keep running when heed quits, restarts or updates, and come back as they "
                + "were. Auto uses zmx when it is installed and passes its check (Tools).",
            impact: .high, since: "0.4.0"
        ) { .text($0.work.persist.rawValue) },
        global(
            "ui.menu_bar", .general, "Outside the window", "Menu bar item",
            "How many sessions need you, those sessions, Start work and Open Heed. With it on, closing the window "
                + "keeps Heed running.",
            impact: .medium, since: "0.1.0"
        ) { .bool($0.showMenuBarItem) },
        global(
            "ui.dock_state", .general, "Outside the window", "Dock state",
            "A badge on the Dock icon in the state's colour when sessions need you.", since: "0.1.0"
        ) { .bool($0.showDockState) },
    ]

    static let notifications: [SettingsEntry] = [
        global(
            "notifications.enabled", .notifications, "Sessions", "Notifications",
            "A notification when a session starts needing you, unless Heed is in front on it. macOS asks the first "
                + "time.",
            impact: .high, since: "0.10.0"
        ) { .bool($0.notifications.enabled) },
        global(
            "notifications.asking", .notifications, "Sessions", "Asking",
            "When a session asks a question or has a plan to approve.", since: "0.10.0"
        ) { .bool($0.notifications.asking) },
        global(
            "notifications.blocked", .notifications, "Sessions", "Blocked",
            "When a session waits on a permission prompt.", since: "0.10.0"
        ) { .bool($0.notifications.blocked) },
        global(
            "notifications.grace_seconds", .notifications, "Sessions", "Grace",
            "How long a session must keep needing you before it notifies, so a prompt that clears itself stays "
                + "quiet. 0 notifies at once.",
            level: .advanced, since: "0.11.4"
        ) { .integer($0.notifications.graceSeconds) },
        global(
            "notifications.reminder_minutes", .notifications, "Sessions", "Reminder",
            "One more notification if it still needs you this long after the first, then none until it comes back.",
            since: "0.11.4"
        ) { .integer($0.notifications.reminderMinutes) },
        global(
            "approvals.wait_seconds", .notifications, "Approvals", "Wait for heed",
            "How long a Claude Code or Codex permission request waits for your answer in heed (gy) before the agent "
                + "asks in its own pane. 0: agents always ask in their pane.",
            since: "0.42.0"
        ) { .integer($0.approvals.waitSeconds) },
        global(
            "notifications.attention", .notifications, "Attention", "Notify",
            "Attention items a rule says to notify about (notify, or boost 3); several from one sync come as one.",
            since: "0.12.0"
        ) { .bool($0.notifications.attention) },
        global(
            "attention.quiet", .notifications, "Quiet hours", "Quiet hours",
            "No notifications from start to end, like 22:00-07:00; empty for none. What needed you meanwhile shows "
                + "in Needs you and on the Dock, not as a notification when they end.",
            impact: .low, since: "0.11.4", example: "quiet = \"22:00-07:00\""
        ) { .text($0.attention.quiet?.description ?? "") },
        global(
            "nudges.whats_new", .notifications, "Nudges", "What's new",
            "After an update, once: what is new since the version you last opened, with the new settings. "
                + ":whatsnew.show opens it any time.",
            since: "0.37.0"
        ) { .bool($0.nudges.whatsNew) },
        global(
            "nudges.gaps", .notifications, "Nudges", "Settings worth a look",
            "How often heed may point at the settings that add the most and are still at their default. Only while "
                + "heed is in front and idle in NORMAL mode, never over a dialog.",
            since: "0.37.0", example: "gaps = \"weekly\""
        ) { .text($0.nudges.gaps.rawValue) },
    ]

    static let updates: [SettingsEntry] = [
        global(
            "updates.check", .updates, "Updates", "Check for updates",
            "Once a day, on GitHub, heed's releases. Only what heed's key signed and Apple notarized installs. "
                + ":update checks now either way.",
            since: "0.6.0"
        ) { .bool($0.updates.check) },
        global(
            "updates.install", .updates, "Updates", "Install",
            "Ask shows what is new and installs when you say so; Auto downloads in the background and installs on "
                + "quit.",
            impact: .low, since: "0.6.0"
        ) { .text($0.updates.install.rawValue) },
    ]

    static let modelCalls: [SettingsEntry] = [
        global(
            "llm.enabled", .modelCalls, "Model calls", "Model calls",
            "heed's own short calls (summaries, decisions), through the agent CLIs you are logged in to. Off: heed "
                + "makes no model calls at all, whatever each agent says.",
            since: "0.11.4"
        ) { .bool($0.llm.enabled) },
        global(
            "llm.agent", .modelCalls, "Model calls", "Agent",
            "Taking turns: every agent you are logged in to, round-robin. One agent: that one alone. Each with a "
                + "cheap model. Unset: not set up yet, and the title bar reminds you.",
            impact: .high, since: "0.21.0", example: "agent = \"auto\""
        ) { $0.llm.agent.map(SettingValue.text) },
        global(
            "llm.timeout_seconds", .modelCalls, "Limits", "Timeout",
            "A call still running after this long is stopped.", level: .advanced, since: "0.11.4"
        ) { .integer($0.llm.timeoutSeconds) },
        global(
            "llm.concurrency", .modelCalls, "Limits", "At once",
            "Calls running at the same time; more wait, the ones you asked for first.", level: .advanced,
            since: "0.11.4"
        ) { .integer($0.llm.concurrency) },
        global(
            "llm.backoff_minutes", .modelCalls, "Limits", "Back off",
            "An agent whose call failed is skipped for this long; one rate limited, until its limit resets.",
            level: .advanced, since: "0.11.4"
        ) { .integer($0.llm.backoffMinutes) },
        global(
            "llm.daily_calls", .modelCalls, "Limits", "Daily calls",
            "Per agent per day: background calls stop until tomorrow at this many. 0: no cap.", since: "0.11.4"
        ) { .integer($0.llm.dailyCalls) },
        global(
            "llm.daily_dollars", .modelCalls, "Limits", "Daily dollars",
            "Per agent per day, counted where a cost is known (reported, or estimated from [usage.prices]). 0: no "
                + "cap.",
            since: "0.11.4"
        ) { .number($0.llm.dailyDollars) },
        global(
            "llm.setup_reminder", .modelCalls, "Reminder", "Remind me on launch",
            "While model calls or decisions are not set up, or their last test failed, the title bar says so until "
                + "you set them up or hide it (:inference.hide; always: for good).",
            since: "0.21.0"
        ) { .bool($0.llm.setupReminder) },
        global(
            "usage.show_cost", .modelCalls, "Usage", "Show cost",
            "The inspector shows each session's model and tokens, and a cost marked ≈: what the agent reported, "
                + "else an estimate from your prices. Off leaves the cost out.",
            since: "0.10.0"
        ) { .bool($0.usage.showCost) },
        global(
            "usage.prices", .modelCalls, "Usage", "Prices",
            "USD per million tokens by model name prefix, \"input / output\" or with cache read and write. None are "
                + "built in: with none set only reported costs show.",
            level: .advanced, since: "0.10.0", example: "\"model-a\" = \"3 / 15\"", table: true
        ) { config in
            .table(config.usage.prices.byPrefix.mapValues { price in
                [price.input, price.output, price.cacheRead, price.cacheWrite].map(number).joined(separator: " / ")
            })
        },
    ]

    static let decisions: [SettingsEntry] = [
        global(
            "decisions.decider", .decisions, "Decisions", "Decider",
            "On-device: Apple's model, free, on this Mac only. Hunch: a Laya checkpoint on this Mac that learns from "
                + "your corrections. Model call: through Model calls. Off: what asks goes without. Unset: a model "
                + "call, and the title bar reminds you to choose.",
            impact: .medium, since: "0.21.0", example: "decider = \"local\""
        ) { $0.decisions.decider.map { .text($0.rawValue) } },
        global(
            "goals.attach", .decisions, "Finding new work's goal", "Find new work's goal",
            "When a session or chat starts, gets its first prompt, tracks a PR or gets a ledger entry, heed looks for "
                + "its goal: it attaches when sure, asks in Attention when unsure, else leaves it in Unassigned.",
            since: "0.18.0"
        ) { .bool($0.goals.attach.enabled) },
        global(
            "goals.attach_auto", .decisions, "Finding new work's goal", "Attach on its own at",
            "At this confidence or more heed attaches, with undo (u).", level: .advanced, since: "0.18.0"
        ) { .number($0.goals.attach.auto) },
        global(
            "goals.attach_ask", .decisions, "Finding new work's goal", "Ask from",
            "From here up to the line above, heed asks with one key (y n m i); below, it leaves the work.",
            level: .advanced, since: "0.18.0"
        ) { .number($0.goals.attach.ask) },
        global(
            "goals.attach_model", .decisions, "Finding new work's goal", "Ask the model when unsure",
            "A cheap model call when the signals are between the two lines or two goals are close. Off: signals "
                + "alone.",
            level: .advanced, since: "0.18.0"
        ) { .bool($0.goals.attach.model) },
        global(
            "hunch.checkpoint", .decisions, "Hunch", "Model",
            "The Laya checkpoint Hunch runs, downloaded from its origin at a pinned revision, every file checked by "
                + "sha256. Unset: english.",
            since: "0.23.0", example: "checkpoint = \"english\""
        ) { $0.hunch.checkpoint.map(SettingValue.text) },
        global(
            "hunch.learn", .decisions, "Hunch", "Learn from my corrections",
            "Your Attention actions, your answers to goal attach proposals, and labelled screen snapshots become "
                + "examples Hunch trains its head on, in the background. Unset: on once a model is downloaded.",
            since: "0.23.0", example: "learn = true"
        ) { $0.hunch.learn.map(SettingValue.bool) },
        global(
            "local.record_screens", .decisions, "Local decisions", "Record screens",
            "At each state a hook reports, the cleaned last lines of the agent's pane, and one now and then while it "
                + "works, for a local model to learn from. On this Mac only. Off by default.",
            since: "0.13.0"
        ) { .bool($0.local.recordScreens) },
        global(
            "local.keep_days", .decisions, "Local decisions", "Keep",
            "Older snapshots go, and the oldest past 64 MB of text.", level: .advanced, since: "0.13.0"
        ) { .integer($0.local.keepDays) },
    ]

    static let worktrees: [SettingsEntry] = [
        global(
            "worktrees.root", .worktrees, "Worktrees", "Worktree root",
            "New worktrees go to <root>/<repo>/<name>.", since: "0.1.0"
        ) { .text($0.work.worktreeRoot) },
        global(
            "worktrees.repo_roots", .worktrees, "Worktrees", "Repo roots",
            "Comma separated; scanned two levels deep.", since: "0.1.0"
        ) { .list($0.work.repoRoots) },
        global(
            "worktrees.repo_paths", .worktrees, "Worktrees", "Repo paths",
            "Repos outside the roots, added when you import one of their worktrees by path (I in Sessions, "
                + ":import <path>).",
            level: .advanced, since: "0.1.0", example: "repo_paths = [\"~/elsewhere/tool\"]"
        ) { .list($0.work.repoPaths) },
        global(
            "worktrees.offer_trust", .worktrees, "Worktrees", "Offer to trust repos for agents",
            "Once per repo, before its first agent: Claude Code's folder trust, and mise's for [env].",
            since: "0.10.0"
        ) { .bool($0.work.offerTrust) },
        global(
            "worktrees.after_add", .worktrees, "Worktrees", "After adding a repo",
            "What Add or clone does once a repo is added or cloned: Repo setup (get it merged and get it green), "
                + "Start work in it, or nothing more. The dialog's \"then\" starts on this.",
            since: "0.40.0"
        ) { .text($0.work.afterAdd.rawValue) },
        global(
            "worktrees.default_prefix", .worktrees, "Branch names", "Default prefix",
            "Branches get a prefix picked by the prompt's first word (\"Fix broken anchors\" → fix/broken-anchors), "
                + "else this. Empty: no prefix.",
            level: .advanced, since: "0.1.0"
        ) { .text($0.work.prefixes.defaultPrefix) },
        global(
            "worktrees.prefixes", .worktrees, "Branch names", "Prefixes",
            "Each prefix and the first words that pick it.", level: .advanced, since: "0.1.0",
            example: "fix = [\"fix\", \"bug\"]", table: true
        ) { .table($0.work.prefixes.prefixes.mapValues { $0.joined(separator: ", ") }) },
        global(
            "start_work.smart_guesses", .worktrees, "Start work", "Smart guesses",
            "The on-device model suggests the repo, the branch name and its prefix as you type; your own picks "
                + "always win. On this Mac only.",
            since: "0.13.0"
        ) { .bool($0.startWork.smartGuesses) },
        global(
            "cleanup.enabled", .worktrees, "Cleanup", "Remove idle worktrees",
            "No agent output, keystrokes, commits or PR events for idle days. Dirty or unpushed work is never "
                + "removed.",
            impact: .low, since: "0.1.0"
        ) { .bool($0.cleanup.enabled) },
        global(
            "cleanup.idle_days", .worktrees, "Cleanup", "Idle for",
            "Days without activity before cleanup removes a worktree.", since: "0.1.0"
        ) { .integer($0.cleanup.idleDays) },
        global(
            "cleanup.delete_branch", .worktrees, "Cleanup", "Delete the local branch too",
            "The remote branch is left alone.", since: "0.1.0"
        ) { .bool($0.cleanup.deleteBranch) },
        global(
            "cleanup.ask_before_sweep", .worktrees, "Cleanup", "Ask before cleaning up",
            "Cleanup lists what it would remove and waits for you: it runs only when you press Clean up worktrees.",
            since: "0.1.0"
        ) { .bool($0.cleanup.askBeforeSweep) },
        global(
            "cleanup.keep_archive_days", .worktrees, "Saved work", "Keep saved work",
            "Removing a worktree saves its commits and changes as heed/archive/<branch> first; R in History brings "
                + "it back. Cleanup drops older ones (0: keep them).",
            since: "0.12.0"
        ) { .integer($0.cleanup.keepArchiveDays) },
    ]

    static let goals: [SettingsEntry] = [
        global(
            "goals.tell_agents", .goals, "Agents", "Tell agents their goal",
            "Sessions and chats on a goal start and resume told which goal, to read its GOAL.md first and to keep to "
                + "its Not the goal list (claude, codex).",
            since: "0.17.0"
        ) { .bool($0.goals.tellAgents) },
        global(
            "goals.auto_review", .goals, "Reviewers", "Reviewers run on their own",
            "When a goal's work changes (a PR opened, updated or merged, a new GOAL.md version) and nightly, for the "
                + "lenses the goal requires; quiet once at their bar until something new. Off: only when you press "
                + "re-check.",
            since: "0.18.0"
        ) { .bool($0.goals.autoReview) },
        global(
            "goals.reviewer_runs_per_day", .goals, "Reviewers", "Reviewer runs per day",
            "Per goal. Past it, heed asks in Attention; a re-check you press is never held back.",
            level: .advanced, since: "0.18.0"
        ) { .integer($0.goals.reviewerRunsPerDay) },
        global(
            "goals.reviewer_agent", .goals, "Reviewers", "Reviewer agent",
            "The agent reviewers run as. Empty: the agent of the goal's session the run's tab opens in.",
            level: .advanced, since: "0.18.0", example: "reviewer_agent = \"claude\""
        ) { .text($0.goals.reviewerAgent) },
        global(
            "goals.bars", .goals, "Reviewers", "Bars",
            "The lenses each kind of goal requires and the bar (0-10) each must reach before heed calls the goal "
                + "done. A row here replaces the built-in one.",
            level: .advanced, since: "0.18.0", example: "spike = \"plan 5, code 6\"", table: true
        ) { config in
            .table(config.goals.bars.rows.mapValues { row in
                row.keys.sorted().map { "\($0.rawValue) \(number(row[$0] ?? 0))" }.joined(separator: ", ")
            })
        },
        global(
            "goals.reviewers", .goals, "Reviewers", "Reviewer models",
            "The model each reviewer kind runs on: \"best\" (the agent's default) or \"cheap\" (its cheap model).",
            level: .advanced, since: "0.18.0", example: "security = \"cheap\"", table: true
        ) { config in
            .table(Dictionary(uniqueKeysWithValues: config.goals.reviewerTiers
                    .map { ($0.key.rawValue, $0.value.rawValue) }))
        },
        global(
            "goals.spawn_concurrent", .goals, "Items", "Spawned at once",
            "Sessions (or background runs) an agent may start on a goal's items at once. Past it, heed asks in "
                + "Attention.",
            level: .advanced, since: "0.19.0"
        ) { .integer($0.goals.spawnConcurrent) },
        global(
            "goals.spawn_per_day", .goals, "Items", "Spawned per day",
            "And per day. Past it, heed asks in Attention (y starts them, n drops them).", level: .advanced,
            since: "0.19.0"
        ) { .integer($0.goals.spawnPerDay) },
        global(
            "goals.tracker", .goals, "GitHub mirror", "Tracker on GitHub",
            "Where a new goal mirrors to, as org/name: a meta issue and a sub-issue per item, in any repo you can "
                + "triage. Orgs and repos set their own in Orgs & repos.",
            impact: .medium, since: "0.19.0", example: "tracker = \"acme/goals\""
        ) { .text($0.goals.mirror.tracker) },
        global(
            "goals.mirror", .goals, "GitHub mirror", "Mirror new goals",
            "New goals mirror from the start; off, M on a goal turns it on. Mirroring publishes: heed then writes "
                + "there on its own, and colleagues' changes come back as asks.",
            since: "0.19.0"
        ) { .bool($0.goals.mirror.on) },
        global(
            "goals.mirror_label", .goals, "GitHub mirror", "Label for heed's issues",
            "Put on the issues heed makes; empty: none.", since: "0.19.0", example: "mirror_label = \"heed\""
        ) { .text($0.goals.mirror.label) },
    ]

    static let history: [SettingsEntry] = [
        global(
            "summary.when", .history, "Ledger", "Write a summary when",
            "A cheap model writes a short summary of each piece of work: when a PR opens or merges, a worktree is "
                + "removed, the work is idle, or a chat closes.",
            since: "0.12.0"
        ) { config in .list(LedgerTrigger.configurable.filter(config.ledger.when.contains).map(\.rawValue)) },
        global(
            "summary.idle_hours", .history, "Ledger", "Idle for",
            "Hours without activity before an idle summary.", level: .advanced, since: "0.12.0"
        ) { .integer($0.ledger.idleHours) },
        global(
            "summary.include", .history, "Ledger", "Include",
            "Files come from git; the rest is what the model writes.", since: "0.12.0"
        ) { config in .list(LedgerPart.allCases.filter(config.ledger.include.contains).map(\.rawValue)) },
        global(
            "summary.away_hours", .history, "While you were away", "Open after away",
            "What still waits on you, what merged and how runs ended opens on its own when you come back after this "
                + "many hours away (0: never on its own); gZ opens it any time.",
            since: "0.10.0"
        ) { .integer($0.summaryAwayHours) },
        global(
            "mindmap.enabled", .history, "Mindmap", "Mindmap",
            "Group finished work into Insights' Mindmap: one per GitHub org, and one for your personal work, never "
                + "mixed.",
            since: "0.36.0"
        ) { .bool($0.mindmap.enabled) },
        global(
            "mindmap.shadow", .history, "Mindmap", "Shadow",
            "Every placement waits for you (y keeps it, m moves it); off, sure placements stand on their own.",
            since: "0.36.0"
        ) { .bool($0.mindmap.shadow) },
        global(
            "memory.brief", .history, "Memory", "Brief sessions",
            "What a session is told at launch from its org's Mindmap: decisions that still stand, what was dropped, "
                + "what is open. node_and_goal: sessions from a Mindmap node or on a goal; off: none.",
            since: "0.36.0"
        ) { .text($0.memory.brief.rawValue) },
        global(
            "standup.enabled", .history, "Standup", "Standup reports",
            "A report on the days you choose, one per Mindmap, each of your questions answered by a cheap model from "
                + "that Mindmap's work since the last report.",
            impact: .low, since: "0.36.0"
        ) { .bool($0.standup.enabled) },
        global(
            "standup.days", .history, "Standup", "Days", "The days a report is written.", since: "0.36.0"
        ) { config in .list(config.standup.days.compactMap { StandupSettings.dayNames.indices.contains($0 - 1)
                ? StandupSettings.dayNames[$0 - 1] : nil
        }) },
        global(
            "standup.at", .history, "Standup", "At", "The time of day, 24-hour.", since: "0.36.0"
        ) { .text(String(format: "%02d:%02d", $0.standup.at / 60, $0.standup.at % 60)) },
        global(
            "standup.range_days", .history, "Standup", "Covers",
            "Days of work a report covers. Unset: since the last report.", level: .advanced, since: "0.36.0",
            example: "range_days = 1"
        ) { $0.standup.rangeDays.map(SettingValue.integer) },
        global(
            "standup.questions", .history, "Standup", "Questions",
            "What each report answers. Orgs ask their own under Orgs & repos.", since: "0.36.0"
        ) { .list($0.standup.questions) },
        global(
            "standup.personal_questions", .history, "Standup", "Personal questions",
            "What your personal work's report answers instead.", since: "0.36.0",
            example: "personal_questions = [\"What did I learn?\"]"
        ) { $0.standup.questionsByInstance[MindmapInstance.personal].map(SettingValue.list) },
        global(
            "log.shell_days", .history, "Call log", "Commands",
            "Every command heed runs (git, zmx, a check on a host), kept this many days.", level: .advanced,
            since: "0.11.4"
        ) { .integer($0.log.shellDays) },
        global(
            "log.github_read_days", .history, "Call log", "GitHub reads",
            "Syncs and the PRs' details: many a day, seldom needed long.", level: .advanced, since: "0.11.4"
        ) { .integer($0.log.githubReadDays) },
        global(
            "log.github_write_days", .history, "Call log", "GitHub writes",
            "Merges, comments, review requests: what heed changed on GitHub.", level: .advanced, since: "0.11.4"
        ) { .integer($0.log.githubWriteDays) },
        global(
            "log.llm_days", .history, "Call log", "Model runs",
            "Summaries and other cheap-model runs, with their tokens and cost.", level: .advanced, since: "0.11.4"
        ) { .integer($0.log.llmDays) },
        global(
            "log.decide_days", .history, "Call log", "Decisions",
            "What heed decided, and how sure it was.", level: .advanced, since: "0.11.4"
        ) { .integer($0.log.decideDays) },
        global(
            "log.max_rows", .history, "Call log", "At most",
            "Rows of each kind, newest kept, whatever their age.", level: .advanced, since: "0.11.4"
        ) { .integer($0.log.maxRows) },
        global(
            "telemetry.enabled", .history, "OpenTelemetry", "Receive the agents' telemetry",
            "Listen on 127.0.0.1 for the agents' own OpenTelemetry (Insights › OpenTelemetry, :trace), and start "
                + "claude and codex with their exporters pointed there. What heed keeps stays on this Mac.",
            since: "0.42.0"
        ) { .bool($0.telemetry.enabled) },
        global(
            "telemetry.proxy", .history, "OpenTelemetry", "Forward through heed",
            "An agent you already send telemetry from is pointed at heed too, and heed forwards every export "
                + "unchanged to your collector, with your headers, which it never keeps. Off: heed leaves it alone.",
            since: "0.42.0"
        ) { .bool($0.telemetry.proxy) },
        global(
            "telemetry.port", .history, "OpenTelemetry", "Port",
            "OTLP/HTTP on 127.0.0.1. A port another collector holds leaves the receiver off.", level: .advanced,
            since: "0.42.0"
        ) { .integer($0.telemetry.port) },
        global(
            "telemetry.days", .history, "OpenTelemetry", "Keep", "Days of spans, prompts and usage kept.",
            level: .advanced, since: "0.42.0"
        ) { .integer($0.telemetry.days) },
        global(
            "telemetry.max_rows", .history, "OpenTelemetry", "At most", "Spans kept, newest first, whatever their age.",
            level: .advanced, since: "0.42.0"
        ) { .integer($0.telemetry.maxRows) },
        global(
            "telemetry.tool_details", .history, "OpenTelemetry", "Tool details",
            "Ask Claude Code for each tool's command or file, so a span says what ran.", level: .advanced,
            since: "0.42.0"
        ) { .bool($0.telemetry.toolDetails) },
        global(
            "telemetry.prompts", .history, "OpenTelemetry", "Prompts",
            "Ask the agents to include your prompts' text, so a turn reads by what you asked.", level: .advanced,
            since: "0.42.0"
        ) { .bool($0.telemetry.prompts) },
    ]

    static let helpers: [SettingsEntry] = [
        global(
            "helpers.agent", .pilot, "Helpers", tab: .green, "Helper agent",
            "Which agent helpers run over ACP: claude, codex, opencode or gemini. Empty: your default agent when heed "
                + "knows an ACP way to it, else claude.",
            since: "0.42.0", example: "agent = \"claude\""
        ) { $0.helpers.agent.map(SettingValue.text) },
        global(
            "helpers.command", .pilot, "Helpers", tab: .green, "Adapter command",
            "The ACP adapter's command line, instead of the one heed knows (claude-agent-acp, codex-acp, opencode acp, "
                + "gemini --acp).",
            level: .advanced, since: "0.42.0", example: "command = \"npx -y @agentclientprotocol/claude-agent-acp\""
        ) { $0.helpers.command.map(SettingValue.text) },
        global(
            "helpers.spend_cap", .pilot, "Helpers", tab: .green, "Spend cap",
            "Dollars one helper may spend before heed stops it, from what its agent reports. 0: no cap.",
            since: "0.42.0"
        ) { .number($0.helpers.spendCap) },
    ]

    static let github: [SettingsEntry] = [
        global(
            "github.poll_seconds", .github, "GitHub", "GitHub poll",
            "Seconds between gh syncs of the view on screen; the others refresh five times less often.",
            level: .advanced, since: "0.1.0"
        ) { .integer($0.githubPollSeconds) },
    ]

    static let attention: [SettingsEntry] = [
        global(
            "attention.rules", .attention, "Rules", "Rules",
            "What matters in Attention, one rule a line, first match wins: what to match, then boost 1-3, lower, "
                + "ignore, pin or notify.",
            since: "0.12.0", example: "rules = [\"author bot:dependabot ignore\"]"
        ) { .list($0.attention.rules) },
        global(
            "attention.summaries", .attention, "Summaries", "Catch-up summaries",
            "What is new in a thread since you last looked, written by heed's model calls. Ahead: every thread in "
                + "New, newest first, within the daily cap, and the rest when you open them; Open: only when you "
                + "open one; Off: none.",
            since: "0.39.0"
        ) { .text($0.attention.summaries.rawValue) },
    ]

    static let tools: [SettingsEntry] = [
        global(
            "tools.git", .tools, "Tools", "git", "Empty detects it. A path, or a name looked up on the search path.",
            level: .advanced, since: "0.1.0", example: "git = \"/opt/homebrew/bin/git\""
        ) { .text($0.tools.git) },
        global(
            "tools.gh", .tools, "Tools", "gh", "Empty detects it.", level: .advanced, since: "0.1.0",
            example: "gh = \"/opt/homebrew/bin/gh\""
        ) { .text($0.tools.gh) },
        global(
            "tools.zmx", .tools, "Tools", "zmx",
            "For persistent panes. Empty detects it (Homebrew, ~/.local/bin, the search path).", level: .advanced,
            since: "0.9.0", example: "zmx = \"~/.local/bin/zmx\""
        ) { .text($0.tools.zmx) },
        global(
            "tools.tailscale", .tools, "Tools", "tailscale",
            "For hosts on your tailnet. Empty detects it (the search path, then the Tailscale app).",
            level: .advanced, since: "0.11.0", example: "tailscale = \"/usr/local/bin/tailscale\""
        ) { .text($0.tools.tailscale) },
        global(
            "tools.path", .tools, "Tools", "Search path",
            "Directories searched first, for git, gh and agent commands alike.", level: .advanced, since: "0.1.0",
            example: "path = [\"~/.local/bin\"]"
        ) { .list($0.tools.path) },
    ]

    static let keys: [SettingsEntry] = [
        global(
            "keys.insert_escape", .keys, "Modes", "Leave INSERT",
            "It is also the terminal's quit signal, so pick something else if you need that.", level: .advanced,
            since: "0.1.0"
        ) { .text($0.insertEscape) },
        global(
            "keys.global_start_work", .keys, "Global shortcuts", "Start work",
            "Opens Start work in a floating panel over any app (window title \"Heed Start Work\"). Empty turns it off.",
            impact: .medium, since: "0.1.0"
        ) { .text($0.globalStartWork) },
        global(
            "keys.global_activate", .keys, "Global shortcuts", "Bring Heed forward",
            "Brings Heed to the front from any app. Empty turns it off.", since: "0.1.0"
        ) { .text($0.globalActivate) },
        // Bindings are edited in config.toml only; the entry is there so search and the counts know them.
        SettingsEntry(
            id: "keys.bindings", page: .keys, section: "Bindings", tab: nil, label: "Key bindings",
            detail: "Per mode ([keys.normal], [keys.visual], ...) or per view ([keys.repos], [keys.attention], ...), in "
                + "vim notation, each naming a command. \"\" unbinds. Edited in config.toml.",
            scope: .global, key: ["keys"], isTable: true, level: .advanced, impact: .none, since: "0.1.0",
            example: "normal = { \"<C-j>\" = \"row.next\" }",
            read: { config, _ in
                var pairs: [String: String] = [:]
                for (mode, bindings) in config.keys {
                    for (notation, command) in bindings {
                        pairs["\(mode.rawValue).\(notation)"] = command
                    }
                }
                for (view, bindings) in config.scopedKeys {
                    for (notation, command) in bindings {
                        pairs["\(view).\(notation)"] = command
                    }
                }
                return .table(pairs)
            }
        ),
    ]

    // MARK: Pilot

    /// `[pilot]`'s keys: the defaults every PR starts from. Tab and section as Orgs & repos has them.
    static let pilot: [SettingsEntry] = {
        func entry(
            _ key: String, _ label: String, _ detail: String, level: SettingLevel = .basic,
            impact: SettingImpact = .none, since: String, tab: SettingsTab? = nil, section: String? = nil,
            example: String? = nil, _ read: @escaping @Sendable (PilotSettings) -> SettingValue?
        ) -> SettingsEntry {
            let groupTitle = Overrides.groups.first { $0.keys.contains(key) }?.title
            let overrideTab = Overrides.groups.first { $0.keys.contains(key) }?.tab
            return global(
                "pilot.\(key)", .pilot, section ?? groupTitle ?? "Get it green",
                tab: tab ?? overrideTab.map(SettingsTab.init).map { $0 == .general ? .green : $0 }, label, detail,
                level: level, impact: impact, since: since, example: example
            ) { read($0.pilot.defaults) }
        }
        return [
            entry(
                "watch", "Watch PRs",
                "Follow their review threads and failing checks. Read-only, so on; w turns it off for one PR.",
                since: "0.2.0"
            ) { .bool($0.watch) },
            entry(
                "green", "Get it green",
                "Off shows what a PR collects; Ask waits for you to queue it; Auto sends it once the agent is idle.",
                impact: .medium, since: "0.2.0"
            ) { .text($0.green.configName) },
            entry(
                "max_rounds", "Stop after", "Prompts sent without a new approval.", level: .advanced, since: "0.2.0"
            ) { .integer($0.maxRounds) },
            entry(
                "run_in", "Runs in",
                "Helper: an agent heed starts over ACP in its own worktree, drawn and steered in heed; it pushes and "
                    + "replies only once you approve. Background: an agent in its own tab, worktree and branch "
                    + "(heed/get-it-green/…), all removed when it is done. Session: the session's own agent, once it is "
                    + "idle and you have not typed in it for five minutes.",
                since: "0.9.6"
            ) { .text($0.runIn.configName) },
            entry(
                "agent", "Run agent",
                "Which agent background runs use; the session's when unset. Spend tokens of an agent you do not use "
                    + "for real work.",
                since: "0.9.0", example: "agent = \"codex\""
            ) { $0.agent.map(SettingValue.text) },
            entry(
                "model", "Run model",
                "Its model; the agent's default when unset. Custom… takes any id the agent knows.", since: "0.9.0",
                example: "model = \"sonnet\""
            ) { $0.model.map(SettingValue.text) },
            entry(
                "effort", "Run effort",
                "Its reasoning effort, for agents that take one; the agent's default when unset.",
                since: "0.32.0", example: "effort = \"high\""
            ) { $0.effort.map(SettingValue.text) },
            entry(
                "run_timeout", "Run timeout", "A run still working after this long is stopped.", level: .advanced,
                since: "0.9.0", tab: .green, section: "Get it green"
            ) { .text(PilotDuration.text($0.runTimeout)) },
            entry(
                "pause", "Pause for", "What zp pauses a PR for: 30m, 1h, 4h, 1d, or forever.", level: .advanced,
                since: "0.2.0", tab: .green, section: "Get it green"
            ) { .text($0.pause.map(PilotDuration.text) ?? "forever") },
            entry(
                "merge_agent", "Conflict agent",
                "Merge conflicts with the base are usually simple: background runs for them can use a cheaper agent. "
                    + "The run agent when unset.",
                level: .advanced, since: "0.9.6", example: "merge_agent = \"codex\""
            ) { $0.mergeAgent.map(SettingValue.text) },
            entry(
                "merge_model", "Conflict model",
                "Its model; the run model's when unset (with a conflict agent of its own, that agent's defaults).",
                level: .advanced, since: "0.9.6", example: "merge_model = \"haiku\""
            ) { $0.mergeModel.map(SettingValue.text) },
            entry(
                "merge_effort", "Conflict effort", "Its effort; the run effort when unset.", level: .advanced,
                since: "0.32.0", example: "merge_effort = \"low\""
            ) { $0.mergeEffort.map(SettingValue.text) },
            entry(
                "merge", "Get it merged",
                "Auto turns on GitHub's auto-merge once nothing fails; heed merges itself once its rules hold. zm "
                    + "cycles one PR.",
                impact: .low, since: "0.2.0"
            ) { .text($0.merge.configName) },
            entry(
                "merge_method", "Merge method", "How PRs are merged; default: the first the repo allows.",
                level: .advanced, since: "0.2.0", example: "merge_method = \"squash\""
            ) { $0.mergeMethod.map(SettingValue.text) },
            entry(
                "update_branches", "Update branches", "Bring queued PRs that fell behind their base up to date.",
                level: .advanced, since: "0.2.0"
            ) { .bool($0.updateBranches) },
            entry(
                "merge_schedule", "Merge queue runs", "How often each repo's queue runs; manual: only when you run it.",
                level: .advanced, since: "0.2.0", tab: .merged, section: "Get it merged",
                example: "merge_schedule = \"1h\""
            ) { .text($0.mergeSchedule.map(PilotDuration.text) ?? "manual") },
            entry(
                "quiet_minutes", "Quiet for", "heed merges: no new commit or review for this many minutes first.",
                level: .advanced, since: "0.2.0"
            ) { .integer($0.quietMinutes) },
            entry(
                "gate_checks", "Gate checks", "heed merges: checks that must have passed, required by GitHub or not.",
                level: .advanced, since: "0.2.0", example: "gate_checks = [\"build\"]"
            ) { .list($0.gateChecks) },
            entry(
                "hold_labels", "Hold labels", "heed merges: a PR with one of these labels waits.", level: .advanced,
                since: "0.2.0"
            ) { .list($0.holdLabels) },
            entry(
                "merge_now", "Merge now",
                "zM, or merge now on a PR that is ready: ask shows the PR, the method and anything not met first; "
                    + "auto merges at once.",
                since: "0.14.0"
            ) { .text($0.mergeNow.rawValue) },
            entry(
                "force_merge", "Force merge",
                "Merging now past required reviews or checks with --admin, offered only where you are an admin: off, "
                    + "ask (lists what is bypassed), auto.",
                since: "0.14.0"
            ) { .text($0.forceMerge.rawValue) },
            entry(
                "reviewers", "Reviewers",
                "Asked to review each PR once it is open and ready: logins, org/team, or copilot. Comma separated.",
                since: "0.2.0", example: "reviewers = [\"copilot\"]"
            ) { .list($0.reviewers) },
            entry(
                "trusted_reviewers", "Trusted AI reviewers",
                "heed merges: their review on the last push counts, as an approval does. Comma separated logins.",
                level: .advanced, since: "0.2.0", example: "trusted_reviewers = [\"copilot-pull-request-reviewer\"]"
            ) { .list($0.trustedReviewers) },
            entry(
                "self_review", "Self-review",
                "heed merges: a command that reads the diff on stdin and answers APPROVE (e.g. claude -p). Empty: none.",
                level: .advanced, since: "0.2.0", example: "self_review = \"claude -p\""
            ) { $0.selfReview.map(SettingValue.text) },
            entry(
                "copilot_comments", "Copilot: comments",
                "Ask it to address new review comments too; with both on, one comment asks for both. C asks now.",
                since: "0.2.0"
            ) { .bool($0.copilotComments) },
            entry(
                "copilot_conflicts", "Copilot: conflicts",
                "Ask GitHub's Copilot coding agent on the PR to resolve merge conflicts, sparing your agent's tokens. "
                    + "Where Copilot can work in the repo.",
                since: "0.2.0"
            ) { .bool($0.copilotConflicts) },
            entry(
                "green_instructions", "Get it green instructions", "After the feedback items each run gets.",
                since: "0.9.5", example: "green_instructions = \"Resolve the review threads your changes addressed.\""
            ) { .text($0.greenInstructions) },
            entry(
                "review_instructions", "Self-review instructions", "Added to what heed merge's self-review looks for.",
                since: "0.9.5", example: "review_instructions = \"Flag any change to the public API.\""
            ) { .text($0.reviewInstructions) },
            entry(
                "start_instructions", "Start work instructions", "After the issue text Start work begins from.",
                since: "0.9.5", example: "start_instructions = \"Open a draft PR early.\""
            ) { .text($0.startInstructions) },
            entry(
                "summary_instructions", "Summary instructions",
                "Added to what heed asks its model calls for when it summarizes work.", since: "0.11.4",
                example: "summary_instructions = \"Name the issue it closes.\""
            ) { .text($0.summaryInstructions) },
            entry(
                "summary_sign_off", "Sign off with a summary",
                "Ask claude and codex to end their final message with a heed-summary: line; it becomes the ledger's "
                    + "summary (History, L). Per org and repo too, in Orgs & repos.",
                since: "0.12.0"
            ) { .bool($0.summarySignOff) },
        ]
    }()

    // MARK: Agents

    /// `[agents.<name>]`: each agent's own settings, built-in or custom.
    static let agentEntries: [SettingsEntry] = {
        func entry(
            _ key: String, _ label: String, _ detail: String, tab: SettingsTab = .sessions,
            level: SettingLevel = .basic, since: String, example: String, table: Bool = false,
            _ read: @escaping @Sendable (AgentProfile, LLMSettings) -> SettingValue?
        ) -> SettingsEntry {
            SettingsEntry(
                id: "agent.\(key)", page: .agents, section: tab.title, tab: tab, label: label, detail: detail,
                scope: .agent, key: [key], isTable: table, level: level, impact: .none, since: since,
                example: example,
                read: { config, target in
                    guard case let .agent(name) = target, let agent = config.work.agent(name) else { return nil }
                    return read(agent, config.llm)
                }
            )
        }
        return [
            entry(
                "command", "Command", "What runs the agent: a name on the search path, or a path.", since: "0.1.0",
                example: "command = \"claude\""
            ) { agent, _ in .text(agent.command) },
            entry(
                "prompt", "Prompt delivery", "How Start work hands the prompt over: argument, stdin, paste or file.",
                level: .advanced, since: "0.1.0", example: "prompt = \"argument\""
            ) { agent, _ in .text(agent.prompt.rawValue) },
            entry(
                "model", "Model",
                "What its sessions start on when nothing else picks one (Start work, a swarm, a handoff); the agent's "
                    + "own default when unset.",
                since: "0.32.0", example: "model = \"opus\""
            ) { agent, _ in agent.model.map(SettingValue.text) },
            entry(
                "effort", "Effort", "Its reasoning effort; the agent's own default when unset.", since: "0.32.0",
                example: "effort = \"high\""
            ) { agent, _ in agent.effort.map(SettingValue.text) },
            entry(
                "plan", "Plan first", "Arguments added when Start work's “Plan first” is on.", level: .advanced,
                since: "0.1.0", example: "plan = \"--permission-mode plan\""
            ) { agent, _ in agent.planArguments.map(SettingValue.text) },
            entry(
                "resume", "Resume",
                "{id} is the agent's own session id. Empty: sessions start fresh after a restart.", level: .advanced,
                since: "0.1.0", example: "resume = \"--resume {id}\""
            ) { agent, _ in agent.resumeArguments.map(SettingValue.text) },
            entry(
                "model_flag", "Model flag", "How the agent takes a model on its command line.", level: .advanced,
                since: "0.9.0", example: "model_flag = \"--model\""
            ) { agent, _ in agent.modelFlag.map(SettingValue.text) },
            entry(
                "effort_flag", "Effort flag",
                "How it takes a reasoning effort: \"--effort\", or with {level}: \"-c model_reasoning_effort={level}\".",
                level: .advanced, since: "0.32.0", example: "effort_flag = \"--effort\""
            ) { agent, _ in agent.effortFlag.map(SettingValue.text) },
            entry(
                "profiles", "Profiles", "Named command lines Start work offers for this agent.", level: .advanced,
                since: "0.1.0", example: "fast = \"claude --model haiku\"", table: true
            ) { agent, _ in .table(agent.profiles) },
            entry(
                "patterns", "Screen patterns",
                "For agents without hooks: a regex per state (blocked, asking, working, ...) read from the screen.",
                level: .advanced, since: "0.1.0", example: "blocked = \"Allow this\\\\?\"", table: true
            ) { agent, _ in .table(agent.patterns) },
            entry(
                "llm", "Use for model calls",
                "heed's own short calls (summaries, decisions) take turns over the agents you are logged in to, each "
                    + "with a cheap model. Off leaves this one out.",
                tab: .modelCalls, since: "0.11.4", example: "llm = false"
            ) { agent, llm in llm.agents[agent.name]?.enabled.map(SettingValue.bool) },
            entry(
                "llm_model", "Model calls model",
                "The model its calls use; empty: a cheap one heed detects (haiku for claude).", tab: .modelCalls,
                since: "0.11.4", example: "llm_model = \"haiku\""
            ) { agent, llm in llm.agents[agent.name]?.model.map(SettingValue.text) },
        ]
    }()

    // MARK: Orgs and repos

    /// `[orgs.<org>]` and `[repos."o/r"]`: what Orgs & repos overrides (`Overrides.keys`), plus the two keys it
    /// does not list (a repo's tasks, an org's standup questions).
    static let overrideEntries: [SettingsEntry] = {
        let advanced: Set = [
            "max_rounds", "quiet_minutes", "gate_checks", "hold_labels", "update_branches", "merge_method",
            "merge_agent", "merge_model", "merge_effort", "self_review", "trusted_reviewers", "admin_merge", "setup",
        ]
        let since: [String: String] = [
            "color": "0.1.0", "setup": "0.10.0", "goals_tracker": "0.19.0",
            "goals_mirror": "0.19.0", "agent": "0.9.0", "model": "0.9.0", "effort": "0.32.0", "merge_agent": "0.9.6",
            "merge_model": "0.9.6", "merge_effort": "0.32.0", "run_in": "0.9.6", "merge_now": "0.14.0",
            "force_merge": "0.14.0", "green_instructions": "0.9.5", "review_instructions": "0.9.5",
            "start_instructions": "0.9.5", "summary_instructions": "0.11.4", "summary_sign_off": "0.12.0",
        ]
        let examples: [String: String] = [
            "color": "color = \"teal\"", "setup": "setup = [\"pnpm install\"]",
            "goals_tracker": "goals_tracker = \"acme/goals\"", "agent": "agent = \"codex\"",
            "model": "model = \"sonnet\"", "effort": "effort = \"high\"", "merge_agent": "merge_agent = \"codex\"",
            "merge_model": "merge_model = \"haiku\"", "merge_effort": "merge_effort = \"low\"",
            "merge_method": "merge_method = \"squash\"", "reviewers": "reviewers = [\"copilot\"]",
            "trusted_reviewers": "trusted_reviewers = [\"copilot-pull-request-reviewer\"]",
            "gate_checks": "gate_checks = [\"build\"]", "self_review": "self_review = \"claude -p\"",
            "green_instructions": "green_instructions = \"Resolve the threads your changes addressed.\"",
            "review_instructions": "review_instructions = \"Flag any change to the public API.\"",
            "start_instructions": "start_instructions = \"Open a draft PR early.\"",
            "summary_instructions": "summary_instructions = \"Name the issue it closes.\"",
            "admin_merge": "admin_merge = true",
        ]
        var entries = Overrides.keys.map { key -> SettingsEntry in
            let group = Overrides.groups.first { $0.keys.contains(key.id) }
            let fallback = key.fallback(.default).toml.literal
            return SettingsEntry(
                id: "override.\(key.id)", page: .orgsAndRepos, section: group?.title ?? "General",
                tab: SettingsTab(Overrides.tab(of: key.id)), label: key.label, detail: key.detail,
                scope: key.repoOnly ? .repo : .orgAndRepo, key: [key.id], isTable: false,
                level: advanced.contains(key.id) ? .advanced : .basic, impact: .none,
                since: since[key.id] ?? "0.2.0", example: examples[key.id] ?? "\(key.id) = \(fallback)",
                read: { config, target in
                    target.overrideScope.flatMap { Overrides.value(key, at: $0, in: config) }.map(SettingValue.init)
                }
            )
        }
        entries.append(SettingsEntry(
            id: "repo.tasks", page: .orgsAndRepos, section: "Tasks", tab: .general, label: "Tasks",
            detail: "Pinned tasks, each run in its own pane; new sessions open them as tabs.", scope: .repo,
            key: ["tasks"], isTable: true, level: .advanced, impact: .none, since: "0.1.0",
            example: "test = \"swift test\"",
            read: { config, target in
                guard case let .repo(slug) = target else { return nil }
                let tasks = config.repos[slug]?.tasks ?? []
                return .table(Dictionary(tasks, uniquingKeysWith: { _, last in last }))
            }
        ))
        entries.append(SettingsEntry(
            id: "org.standup_questions", page: .orgsAndRepos, section: "Standup", tab: .general,
            label: "Standup questions", detail: "What this org's standup report answers, instead of the shared ones.",
            scope: .org, key: ["standup_questions"], isTable: false, level: .basic, impact: .none, since: "0.36.0",
            example: "standup_questions = [\"What shipped?\"]",
            read: { config, target in
                guard case let .org(org) = target else { return nil }
                return config.standup.questionsByInstance[MindmapInstance.name(org)].map(SettingValue.list)
            }
        ))
        return entries
    }()

    // MARK: Hosts

    /// `[hosts.<name>]`: machines heed drives over ssh.
    static let hostEntries: [SettingsEntry] = {
        func entry(
            _ key: String, _ label: String, _ detail: String, level: SettingLevel = .basic, since: String,
            example: String, _ read: @escaping @Sendable (HostConfig) -> SettingValue?
        ) -> SettingsEntry {
            SettingsEntry(
                id: "host.\(key)", page: .hosts, section: "Host", tab: nil, label: label, detail: detail,
                scope: .host, key: [key], isTable: false, level: level, impact: .none, since: since,
                example: example,
                read: { config, target in
                    guard case let .host(name) = target, let host = config.hosts[name] else { return nil }
                    return read(host)
                }
            )
        }
        return [
            entry(
                "ssh", "ssh", "An alias from ~/.ssh/config, or user@address; the name by default.", since: "0.4.0",
                example: "ssh = \"devbox\""
            ) { .text($0.ssh) },
            entry(
                "tailscale", "Tailscale machine", "The machine on your tailnet, when its name differs.",
                since: "0.11.0", example: "tailscale = \"devbox\""
            ) { $0.tailscale.map(SettingValue.text) },
            entry(
                "transport", "Transport", "ssh or tailscale; unset prefers the tailnet.", since: "0.11.0",
                example: "transport = \"ssh\""
            ) { $0.transport.map { .text($0.rawValue) } },
            entry(
                "user", "User", "Who to log in as over the tailnet, without an ssh alias.", since: "0.11.0",
                example: "user = \"you\""
            ) { $0.user.map(SettingValue.text) },
            entry(
                "repo_roots", "Repo roots", "Where its repos are, two levels deep.", since: "0.4.0",
                example: "repo_roots = [\"~/code\"]"
            ) { .list($0.repoRoots) },
            entry(
                "worktree_root", "Worktree root", "Where its worktrees go.", since: "0.4.0",
                example: "worktree_root = \"~/code/wt\""
            ) { .text($0.worktreeRoot) },
            entry(
                "color", "Color", "teal, periwinkle, pink or sky; unset: picked from the name.", since: "0.4.0",
                example: "color = \"teal\""
            ) { $0.color.map(SettingValue.text) },
        ]
    }()
}
