import HeedCore
import SwiftUI

/// Every screenshot in the docs, generated from the fake world by `mise run shots`. A shot's id is its path under
/// docs/images/shots; pages reference them as `../images/shots/<id>.png`.
@MainActor
enum Shots {
    static let all: [Shot] = landing + home + gettingStarted + concepts + sessions + chats + startWork + agents +
        pilot +
        hosts +
        github +
        worktrees
        + diff + history + log + keyboard + outside + configuration

    /// Types a sentence (spaces become <Space>).
    static func typed(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "<Space>")
    }

    static let firstRunReport = FirstRunReport(
        githubUser: "you",
        agents: [
            .init(name: "claude", path: "/Users/you/.local/bin/claude"),
            .init(name: "codex", path: "/opt/homebrew/bin/codex"),
            .init(name: "cursor", path: nil), .init(name: "pi", path: nil),
            .init(name: "opencode", path: "/opt/homebrew/bin/opencode"), .init(name: "gemini", path: nil),
        ],
        tools: ToolReport(
            shell: "/opt/homebrew/bin/fish", shellPath: ["/opt/homebrew/bin", "/usr/bin"],
            searchPath: ["/opt/homebrew/bin", "/usr/bin", "/bin"],
            tools: [
                ResolvedTool(
                    name: "git",
                    path: "/opt/homebrew/bin/git",
                    version: "git version 2.51.0",
                    source: .loginShell,
                    problem: nil
                ),
                ResolvedTool(
                    name: "gh",
                    path: "/opt/homebrew/bin/gh",
                    version: "gh version 2.96.0",
                    source: .loginShell,
                    problem: nil
                ),
            ]
        )
    )

    static let gettingStarted: [Shot] = [
        Shot(id: "getting-started/first-run", crop: .dialog, prepare: { $0.showFirstRun(report: firstRunReport) }),
        // The tour on its fourth step: the banner, the spotlight on what needs you, the card, the TUTOR pill.
        Shot(id: "getting-started/tutor", prepare: { $0.beginTutor(lesson: "tour", step: 3) }),
        // The title bar's reminder, until the tour is done.
        Shot(id: "getting-started/tutor-reminder", crop: .titleBar, prepare: { $0.tutorReminderInShots = true }),
        // Every terminal of a session exited: delete it, close it, or keep it.
        Shot(id: "sessions/all-closed", crop: .confirm, prepare: { model in
            model.panesEnded(Set(model.currentTabs.flatMap(\.tree.panes).map(\.id)))
        }),
        Shot(
            id: "getting-started/tutor-picker",
            crop: .dialog,
            prepare: { $0.perform(CommandInvocation(name: "tutor")) }
        ),
        Shot(
            id: "getting-started/tutor-nudge", keys: "q", crop: .tutorCard,
            prepare: { $0.beginTutor(lesson: "tour", step: 0) }
        ),
        Shot(
            id: "getting-started/tutor-done", keys: "i<S-Esc>", crop: .tutorCard,
            prepare: { $0.beginTutor(lesson: "tour", step: 0) }
        ),
        Shot(
            id: "getting-started/tutor-finish", crop: .tutorCard,
            prepare: { $0.beginTutor(lesson: "sessions", step: 4, startedAt: ShotRunner.instant - 161) }
        ),
        Shot(
            id: "getting-started/first-session-1-start",
            keys: "o" + typed("Fix broken anchors in the redirect pages"),
            crop: .dialog
        ),
        Shot(id: "getting-started/first-session-2-working", highlight: [.panes]),
        Shot(id: "getting-started/first-session-3-blocked", keys: "j", highlight: [.sidebar, .panes]),
        Shot(id: "getting-started/first-session-4-insert", keys: "ji", highlight: [.panes]),
        Shot(id: "getting-started/first-session-5-feedback", keys: "go", highlight: [.pipeline]),
        Shot(id: "getting-started/first-session-6-history", keys: "gh", highlight: [.historyList]),
    ]

    static let concepts: [Shot] = [
        Shot(id: "concepts/session", highlight: [.tabStrip, .panes, .inspector]),
        Shot(id: "concepts/states", size: CGSize(width: 1440, height: 640), crop: .sidebar),
        Shot(id: "concepts/worktrees", keys: "gr", crop: .worktreeTable),
        Shot(id: "concepts/mode-normal", crop: .statusBar, cropPadding: 0),
        Shot(id: "concepts/mode-insert", keys: "i", crop: .statusBar, cropPadding: 0),
        Shot(id: "concepts/mode-visual", keys: "gsv", crop: .statusBar, cropPadding: 0),
        Shot(id: "concepts/mode-command", keys: ":", crop: .statusBar, cropPadding: 0),
        Shot(id: "concepts/mode-hint", keys: "f", crop: .statusBar, cropPadding: 0),
    ]

    /// The landing page (docs/heed-landing.html), which draws its own window frames: no chrome here.
    static let landing: [Shot] = [
        Shot(id: "landing/main", chrome: false),
        Shot(id: "landing/states", chrome: false, keys: "2j"),
        Shot(id: "landing/start-work", chrome: false, keys: "o" + typed("Fix broken anchors in the redirect pages")),
        Shot(id: "landing/agents", subject: .settings(.agents), size: CGSize(width: 1100, height: 700)),
        Shot(id: "landing/keys", chrome: false, keys: "?"),
        Shot(id: "landing/prs", chrome: false, keys: "gp"),
        Shot(id: "landing/green", chrome: false, keys: "gw"),
        Shot(id: "landing/merged", chrome: false, keys: "gw/anchors<CR>"),
        Shot(id: "landing/worktrees", chrome: false, keys: "gr4jvj"),
        Shot(id: "landing/resume", chrome: false, prepare: { $0.showResumeForFixture() }),
        Shot(id: "landing/hosts", chrome: false, keys: "G"),
        Shot(id: "landing/diff", chrome: false, keys: "gd"),
        Shot(id: "landing/inbox", chrome: false, keys: "gm<Space>j<Space>"),
    ]

    /// The docs' home page.
    static let home: [Shot] = [
        Shot(id: "home/sessions"),
    ]

    static let sessions: [Shot] = [
        Shot(id: "sessions/anatomy", highlight: [.sidebar, .center, .inspector]),
        Shot(id: "sessions/sidebar", size: CGSize(width: 1440, height: 640), crop: .sidebar),
        Shot(id: "sessions/watching", size: CGSize(width: 1440, height: 1000), keys: "jjj", crop: .sidebar),
        Shot(id: "sessions/rail", size: CGSize(width: 1440, height: 640), keys: "zs", crop: .rail),
        Shot(id: "sessions/moving", size: CGSize(width: 1440, height: 640), keys: "2j", crop: .sidebar),
        Shot(id: "sessions/attention", size: CGSize(width: 1440, height: 640), keys: "ga", crop: .sidebar),
        Shot(id: "sessions/insert-before", crop: .panes),
        Shot(id: "sessions/insert-after", keys: "i", crop: .panes),
        Shot(id: "sessions/split", keys: "<C-w>v", highlight: [.panes]),
        Shot(id: "sessions/tab-strip", crop: .tabStrip, cropPadding: 6),
        Shot(id: "sessions/task-picker", keys: "!", crop: .picker, prepare: withDiscoveredTasks),
        Shot(id: "sessions/run-tab", keys: "4j", crop: .center),
        Shot(id: "sessions/run-reader", crop: .dialog, prepare: { $0.runReader = $0.runs.first { !$0.isRunning } }),
        Shot(id: "sessions/tab-strip-insert", keys: "i", crop: .tabStrip, cropPadding: 6),
        Shot(id: "sessions/zoom", keys: "<C-w>z", highlight: [.panes]),
        // Tall enough for the anchors session's subagents, and its usage line and agent events under them.
        Shot(id: "sessions/inspector", size: CGSize(width: 1440, height: 1140), crop: .inspector, cropPadding: 0),
        // bump-spec-tests: its PR's card with the get it green run working on it.
        Shot(id: "sessions/run-card", keys: "4j", crop: .inspector, cropPadding: 0),
        Shot(id: "sessions/links-picker", keys: "gB", crop: .picker),
        Shot(id: "sessions/close-confirm", keys: "x", crop: .confirm),
        Shot(id: "sessions/delete-confirm", keys: "dd", crop: .confirm),
        Shot(id: "sessions/handoff-confirm", keys: typed(":agent.switch codex") + "<CR>", crop: .confirm),
        Shot(id: "sessions/resume", crop: .dialog, prepare: { $0.showResumeForFixture() }),
        Shot(id: "sessions/away", keys: "gZ", crop: .dialog),
        Shot(id: "sessions/filter-typing", keys: "/docs", crop: .statusBar, cropPadding: 0),
        Shot(id: "sessions/filter-kept", size: CGSize(width: 1440, height: 640), keys: "/docs<CR>", crop: .sidebar),
    ]

    static let prompt = typed("Fix broken anchors in the redirect pages")

    /// The fake world's chats, added to `main`: in the sidebar's Chats group (one asking, in Needs you) and History.
    static func withChats(_ model: AppModel) {
        var changes: [DomainChange] = Fixtures.chats.flatMap { session, layout in
            [DomainChange.sessionUpserted(session), .layoutChanged(session: session.id, layout)]
        }
        changes.append(.sessionClosed(Fixtures.closedChat))
        model.commit(changes)
    }

    static let chatPrompt = typed("Which shell one-liner counts lines per file type in a folder?")

    static let chats: [Shot] = [
        Shot(id: "sessions/chats-sidebar", size: CGSize(width: 1440, height: 1240), crop: .sidebar, prepare: withChats),
        // The scratch chat that is asking: no repo chip, its folder in the inspector. Tall enough for every session.
        Shot(id: "sessions/chats-session", size: CGSize(width: 1440, height: 1240), keys: "4G", prepare: withChats),
        Shot(id: "sessions/chats-new", keys: ":chat<Space>" + chatPrompt + "<CR>", crop: .dialog),
        Shot(id: "sessions/chats-new-folder", keys: ":chat<Space>" + chatPrompt + "<CR><Esc>jjl<Space>", crop: .dialog),
        Shot(
            id: "sessions/chats-from-start-work",
            keys: "o" + chatPrompt + "<Esc>j" + String(repeating: "l", count: 7),
            crop: .dialog
        ),
        Shot(id: "sessions/chats-history", keys: "gh", prepare: withChats),
        // :promote on the asking scratch chat: its conversation goes to the new worktree's agent.
        Shot(id: "sessions/chats-promote", keys: "4G:promote<CR>", crop: .dialog, prepare: withChats),
        Shot(id: "sessions/chats-promote-codex", keys: "4G:promote<CR><Esc>jjjl", crop: .dialog, prepare: withChats),
        // The chat closed into History as promoted, naming the session it became.
        Shot(id: "sessions/chats-promoted", keys: "gh", prepare: { model in
            withChats(model)
            guard var chat = Fixtures.chats.first?.0 else { return }
            chat.record("promoted → feature/nightly-cron-job", at: ShotRunner.instant)
            chat.record("ended after 0h 22m", at: ShotRunner.instant)
            model.commit(.sessionClosed(HistoryEntry(session: chat, closedAt: ShotRunner.instant, outcome: .promoted)))
        }),
    ]

    static let startWork: [Shot] = [
        Shot(id: "start-work/dialog", keys: "o" + prompt, crop: .dialog),
        Shot(id: "start-work/repos", keys: "o" + prompt + "<Esc>j", crop: .dialog),
        Shot(id: "start-work/repo-search", keys: "o" + prompt + "<Esc>j/mer", crop: .dialog),
        Shot(id: "start-work/branch-name", keys: "o" + prompt + "<Esc>jj", crop: .dialog),
        Shot(id: "start-work/agent-options", keys: "o" + prompt + "<Esc>jjjj", crop: .dialog),
        Shot(id: "start-work/panel", subject: .panel, size: CGSize(width: 1100, height: 820), keys: "o" + prompt),
        Shot(id: "start-work/from-github-picked", keys: "gi<Space>j<Space>", highlight: [.list, .pickedPanel]),
        Shot(id: "start-work/from-github-dialog", keys: "gi<Space>j<Space>s", crop: .dialog),
        Shot(id: "start-work/again", keys: "ghO", crop: .dialog),
        Shot(
            id: "start-work/on-a-host", keys: "o" + typed("Fix the flaky link checker in docs-builder") + "<C-n>",
            crop: .dialog
        ),
    ]

    static let short = CGSize(width: 1440, height: 640)

    static let agents: [Shot] = [
        Shot(id: "agents/guessed", size: short, keys: "2j", crop: .sidebar),
    ]

    static let hosts: [Shot] = [
        // gH: the hosts, with @devbox's checks; @gpu wants a key, @ci is down.
        Shot(
            id: "hosts/picker",
            keys: "<C-n>",
            crop: .dialog,
            prepare: { $0.perform(CommandInvocation(name: "host.open")) }
        ),
        Shot(
            id: "hosts/picker-auth",
            keys: "<C-n><C-n>",
            crop: .dialog,
            prepare: { $0.perform(CommandInvocation(name: "host.open")) }
        ),
        Shot(id: "hosts/picker-offline", crop: .dialog, prepare: { $0.perform(CommandInvocation(name: "host.open")) }),
        // A host without zmx: the line that installs it there.
        Shot(
            id: "hosts/picker-no-zmx", keys: "<C-n><C-n><C-n>", crop: .dialog,
            prepare: { $0.perform(CommandInvocation(name: "host.open")) }
        ),
        // The tailnet's machines that are not hosts yet, with gpu-box (Tailscale SSH) picked.
        Shot(
            id: "hosts/picker-tailnet", keys: "<C-n><C-n><C-n><C-n><C-n>", crop: .dialog,
            prepare: { $0.perform(CommandInvocation(name: "host.open")) }
        ),
        // Where are your projects on @devbox: made-up folders, the ones holding repos picked.
        Shot(
            id: "hosts/roots", crop: .dialog,
            prepare: { $0.perform(CommandInvocation(name: "host.roots", arguments: ["devbox"])) }
        ),
        // Repos with a host column: a registered and a discovered worktree on @devbox.
        Shot(id: "hosts/repos", keys: "gr"),
        // @ narrows a view to one host.
        Shot(id: "hosts/filter", keys: "gr@dev<CR>", crop: .worktreeTable),
        // A session on @devbox: the pane strip, the sidebar rail and chip, the status bar's host segment.
        Shot(id: "hosts/session", keys: "G"),
    ]

    static let pilot: [Shot] = [
        // The Watch view: watched PRs by state, the selected PR's items and timeline, the pilot's activity.
        Shot(id: "watch/view", keys: "gw"),
        Shot(id: "watch/stalled", keys: "gw", crop: .list),
        Shot(id: "watch/visual", keys: "gwjjvj", crop: .list),
        Shot(id: "watch/paused", keys: "gwjjvjzp", crop: .list),
        Shot(id: "watch/detail", keys: "gw", crop: .pilotDetail),
        // The green PR's checklist, and the conflicting one's.
        Shot(id: "watch/green", keys: "gw/moved<CR>", crop: .pilotDetail),
        Shot(id: "watch/conflict", keys: "gw/spec<CR>", crop: .pilotDetail),
        // Get it merged: a repo's merge queue with its runs, and the queues above the activity.
        Shot(id: "watch/merge-queue", keys: "gw/moved<CR>gM", crop: .pilotDetail),
        Shot(id: "watch/queues", keys: "gw", crop: .pilotActivity),
        Shot(id: "watch/heed", keys: "gw/anchors<CR>", crop: .pilotDetail),
        Shot(id: "watch/inspector", crop: .inspector),
        // `z?`: what heed will do for the PR, and what holds it back.
        Shot(id: "watch/explain", keys: "gw/anchors<CR>z?", crop: .dialog),
        Shot(id: "watch/prs", keys: "gp", crop: .list),
    ]

    static let github: [Shot] = [
        Shot(id: "github/offline", keys: "gm", highlight: [.syncBanner], prepare: { model in
            var state = model.github
            state.status = .offline("gh: could not resolve host api.github.com")
            model.commit(.githubSynced(state))
        }),
        Shot(id: "github/inbox", keys: "gm", highlight: [.chips]),
        Shot(id: "github/inbox-rows", size: short, keys: "gm", crop: .list),
        Shot(id: "github/issues", keys: "gi", highlight: [.issueRepos, .chips]),
        Shot(id: "github/issue-rows", size: short, keys: "gi", crop: .list),
        Shot(id: "github/prs", keys: "gp"),
        Shot(id: "github/reader-pr", keys: "gpgo"),
        Shot(id: "github/reader-issue", size: CGSize(width: 1200, height: 420), keys: "gigo", crop: .reader),
        Shot(id: "github/feedback", keys: "go", prepare: withGreenInstructions),
        Shot(id: "github/delivery", keys: "go", crop: .delivery),
        Shot(id: "github/prompt", keys: "go", crop: .promptPreview, prepare: withGreenInstructions),
    ]

    /// A `green_instructions`, so the prompt preview shows where they go.
    private static let withGreenInstructions: @MainActor (AppModel) -> Void = { model in
        model.applyConfig(source: "[pilot]\ngreen_instructions = \"Resolve the threads you addressed.\"\n")
    }

    static let worktrees: [Shot] = [
        Shot(id: "worktrees/repos", keys: "gr", highlight: [.repoColumn, .worktreeTable, .rulesPanel]),
        Shot(id: "worktrees/repos-filtered", keys: "gr/fix<CR>", crop: .worktreeTable),
        Shot(id: "worktrees/repo-column", size: short, keys: "gr", crop: .repoColumn),
        Shot(id: "worktrees/import-worktree", keys: "Iw", crop: .picker),
        // Typing narrows by repo, branch or the path below its root, and marks what matched.
        Shot(id: "worktrees/import-worktree-filtered", keys: "Iwgantt", crop: .picker),
        Shot(id: "worktrees/import-path", keys: "Ip" + "code/wt/docs-builder/toc", crop: .picker),
        Shot(id: "worktrees/remove", keys: "gr4jvjd", crop: .confirm),
        Shot(id: "worktrees/rules", keys: "gr", crop: .rulesPanel),
        Shot(id: "worktrees/sweep", keys: "gr", crop: .sweepBanner, prepare: { model in
            model.applyConfig(source: "[cleanup]\nenabled = true\nidle_days = 3\n")
        }),
        Shot(id: "worktrees/setup", keys: "gr", crop: .setupBanner, prepare: withSetupProposals),
        Shot(id: "worktrees/setup-review", keys: "grS", crop: .confirm, prepare: withSetupProposals),
    ]

    /// The session under the cursor with tasks of every source, as a worktree with a mise config, a Makefile and a
    /// package.json offers them.
    private static let withDiscoveredTasks: @MainActor (AppModel) -> Void = { model in
        model.showTasks([
            TaskSpec(name: "tests", command: "dotnet test"),
            TaskSpec(name: "build", command: "mise run build", source: .mise, detail: "Build the docs-builder binary"),
            TaskSpec(name: "lint", command: "mise run lint", source: .mise, detail: "dotnet format, verify only"),
            TaskSpec(name: "clean", command: "make clean", source: .make, detail: "Remove build output"),
            TaskSpec(name: "release", command: "make release", source: .make, detail: "Publish a release build"),
            TaskSpec(name: "dev", command: "pnpm run dev", source: .packageJSON, detail: "vite --port 3000"),
            TaskSpec(name: "storybook", command: "pnpm run storybook", source: .packageJSON, detail: "storybook dev"),
        ])
    }

    /// Every repo of the fake world with a pnpm lockfile, so Repos proposes its setup.
    private static let withSetupProposals: @MainActor (AppModel) -> Void = { model in
        for record in model.repos {
            model.propose(SetupProposal(commands: ["pnpm install"], reasons: ["pnpm-lock.yaml"]), for: record)
        }
    }

    static let diff: [Shot] = [
        Shot(id: "diff/overlay", keys: "gd"),
        Shot(id: "diff/split", keys: "gdt"),
        // `a` on a line: the comment box under it, a note being typed.
        Shot(id: "diff/note", keys: "gdjja" + typed(noteText)),
        // Queued: the hunk's header counts it, and it joins the PR's feedback.
        Shot(id: "diff/note-queued", keys: "gdjja" + typed(noteText) + "<CR>"),
        Shot(id: "github/feedback-note", keys: "gdjja" + typed(noteText) + "<CR><Esc>go"),
    ]

    static let noteText = "Lowercase the slug once in the helper instead of at each call site."

    static let history: [Shot] = [
        Shot(id: "history/history", keys: "gh"),
        Shot(id: "history/detail", keys: "gh", crop: .historyDetail),
    ]

    /// `:log`, the call log, on the fake world's calls (`Fixtures.calls`).
    static let log: [Shot] = [
        Shot(id: "log/log", keys: ":log<CR>"),
        Shot(id: "log/failed", keys: ":log<CR>x"),
        Shot(id: "log/detail", keys: ":log<CR>x", crop: .logDetail),
        Shot(id: "log/llm", keys: ":log<CR>ttt"),
    ]

    static let keyboard: [Shot] = [
        Shot(id: "keyboard/leader", keys: "g", crop: .leaderHints),
        Shot(id: "keyboard/view-tabs", crop: .viewTabs, cropPadding: 8),
        Shot(id: "keyboard/hints-sessions", keys: "f"),
        Shot(id: "keyboard/hints-list", size: short, keys: "gif", crop: .list),
        Shot(id: "keyboard/command-line", keys: ":vie", crop: .commandLine),
        Shot(id: "keyboard/visual", size: short, keys: "grvjj", crop: .worktreeTable),
    ]

    static let configuration: [Shot] = [
        Shot(id: "configuration/problem", keys: "", crop: .statusBar, cropPadding: 0, prepare: { model in
            model.applyConfig(source: "[cleanup]\nidle_days = 0\n")
        }),
        Shot(id: "configuration/settings", subject: .settings(), size: CGSize(width: 900, height: 1380)),
        Shot(id: "configuration/orgs-repos", subject: .settings(.colors), size: CGSize(width: 1180, height: 1400)),
    ]

    static let outside: [Shot] = [
        Shot(id: "outside/menu-bar", subject: .menuBar, size: CGSize(width: 520, height: 34)),
        Shot(id: "outside/menu", subject: .menu, size: CGSize(width: 620, height: 380)),
        Shot(id: "outside/dock", subject: .dock, size: CGSize(width: 420, height: 130), crop: .picker, cropPadding: 30),
    ]
}
