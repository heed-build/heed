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
        + diff + history + goals + log + keyboard + outside + configuration

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
        // A first launch with nothing yet: the sidebar's first steps, clickable.
        Shot(id: "getting-started/empty", size: CGSize(width: 1440, height: 760), crop: .sidebar, fixture: "empty"),
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
        Shot(id: "landing/prs", chrome: false, keys: ":prs<CR>"),
        Shot(id: "landing/green", chrome: false, keys: "gw"),
        Shot(id: "landing/merged", chrome: false, keys: "gw/anchors<CR>"),
        Shot(id: "landing/worktrees", chrome: false, keys: "gr4jvj"),
        Shot(id: "landing/resume", chrome: false, prepare: { $0.showResumeForFixture() }),
        Shot(id: "landing/hosts", chrome: false, keys: "G"),
        Shot(id: "landing/diff", chrome: false, keys: "gd"),
        // Attention on a pull request that asks for your review: its summary, the thread in three lines, the rule.
        Shot(id: "landing/attention", chrome: false, keys: "gm3j"),
        // The asking scratch chat, tall enough for the whole sidebar and its Chats group.
        Shot(
            id: "landing/chats", chrome: false, size: CGSize(width: 1440, height: 1240), keys: "4G",
            prepare: withChats
        ),
        Shot(id: "landing/history", chrome: false, keys: "ghL"),
        // A goal's overview: its numbers, its items by stage, what is on it, its reviewers and where it waits on you.
        Shot(id: "landing/goals", chrome: false, keys: "gGj"),
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
        Shot(id: "start-work/repo-search", keys: "o" + prompt + "<Esc>j/mar", crop: .dialog),
        Shot(id: "start-work/branch-name", keys: "o" + prompt + "<Esc>jj", crop: .dialog),
        Shot(id: "start-work/agent-options", keys: "o" + prompt + "<Esc>jjjj", crop: .dialog),
        Shot(id: "start-work/panel", subject: .panel, size: CGSize(width: 1100, height: 820), keys: "o" + prompt),
        Shot(id: "start-work/from-github-picked", keys: ":issues<CR><Space>j<Space>", highlight: [.list, .pickedPanel]),
        Shot(id: "start-work/from-github-dialog", keys: ":issues<CR><Space>j<Space>s", crop: .dialog),
        Shot(id: "start-work/again", keys: "ghO", crop: .dialog),
        Shot(
            id: "start-work/on-a-host", keys: "o" + typed("Fix the flaky link checker in docs-toolkit") + "<C-n>",
            crop: .dialog
        ),
    ]

    static let short = CGSize(width: 1440, height: 640)

    static let agents: [Shot] = [
        Shot(id: "agents/guessed", size: short, keys: "2j", crop: .sidebar),
        // Settings › Agents: claude's part in heed's model calls, after a Test.
        Shot(
            id: "agents/model-calls", subject: .settings(.agents), size: CGSize(width: 1000, height: 820),
            prepare: { model in
                model.llmTests["claude"] = LLMTest(answer: "Hello!", model: "claude-haiku", seconds: 2.9, cost: 0.00026)
            }
        ),
        // Settings › Agents › Local decisions: screen snapshots on, with the fake world's invented counts.
        Shot(id: "agents/local-decisions", subject: .settings(.agents), size: CGSize(width: 1000, height: 1900)),
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
        Shot(id: "watch/prs", keys: ":prs<CR>", crop: .list),
        // Merging ahead of time: a PR ready to merge with merging off, merge now's confirmation, and a repo whose
        // merge settings cannot work.
        Shot(id: "watch/ready", keys: "gw/backpressure<CR>", crop: .pilotDetail),
        Shot(id: "watch/merge-now", keys: "gw/backpressure<CR>zM", crop: .confirm),
        Shot(id: "watch/misconfigured", keys: "gw/arrowheads<CR>", crop: .pilotDetail),
    ]

    static let github: [Shot] = [
        Shot(id: "github/offline", keys: ":inbox<CR>", highlight: [.syncBanner], prepare: { model in
            var state = model.github
            state.status = .offline("gh: could not resolve host api.github.com")
            model.commit(.githubSynced(state))
        }),
        Shot(id: "github/attention", keys: "gm", highlight: [.attentionFilters]),
        Shot(id: "github/attention-detail", keys: "gm/2845<CR>", crop: .attentionDetail),
        Shot(id: "github/attention-muted", keys: "gm" + String(repeating: "t", count: 7)),
        Shot(id: "github/attention-reply", keys: "gm/2845<CR>R", crop: .confirm),
        Shot(id: "github/inbox", keys: ":inbox<CR>", highlight: [.chips]),
        Shot(id: "github/inbox-rows", size: short, keys: ":inbox<CR>", crop: .list),
        Shot(id: "github/issues", keys: ":issues<CR>", highlight: [.issueRepos, .chips]),
        Shot(id: "github/issue-rows", size: short, keys: ":issues<CR>", crop: .list),
        Shot(id: "github/prs", keys: ":prs<CR>"),
        Shot(id: "github/reader-pr", keys: ":prs<CR>go"),
        Shot(id: "github/reader-issue", size: CGSize(width: 1200, height: 420), keys: ":issues<CR>go", crop: .reader),
        Shot(id: "github/feedback", keys: "go", prepare: withGreenInstructions),
        Shot(id: "github/delivery", keys: "go", crop: .delivery),
        Shot(id: "github/prompt", keys: "go", crop: .promptPreview, prepare: withGreenInstructions),
        // The setup wizard on the fake world's invented history: the Repos column's status, then each step.
        Shot(id: "github/repo-setup-repos", size: short, keys: "gr", crop: .repoColumn),
        Shot(id: "github/repo-setup-1-sampling", keys: "gr", crop: .dialog, prepare: { model in
            model.showRepoSetupSampling(Fixtures.main.repos[0].repo)
        }),
        Shot(id: "github/repo-setup-1-sample", keys: "grM", crop: .dialog),
        Shot(id: "github/repo-setup-2-propose", size: tall, keys: "grM<CR>", crop: .dialog),
        Shot(id: "github/repo-setup-3-validate", keys: "grM<CR><CR>", crop: .dialog),
        Shot(id: "github/repo-setup-4-write", keys: "grM<CR><CR><CR>", crop: .dialog),
    ]

    /// Tall enough for the wizard's whole proposal.
    private static let tall = CGSize(width: 1440, height: 1500)

    /// A `green_instructions`, so the prompt preview shows where they go.
    private static let withGreenInstructions: @MainActor (AppModel) -> Void = { model in
        model.applyConfig(source: "[pilot]\ngreen_instructions = \"Resolve the threads you addressed.\"\n")
    }

    static let worktrees: [Shot] = [
        Shot(id: "worktrees/repos", keys: "gr", highlight: [.repoColumn, .worktreeTable, .rulesPanel]),
        Shot(id: "worktrees/repos-filtered", keys: "gr/fix<CR>", crop: .worktreeTable),
        // No repos under the roots yet: where to look, and the next step.
        Shot(id: "worktrees/repos-empty", size: CGSize(width: 1440, height: 760), keys: "gr", fixture: "empty"),
        Shot(id: "worktrees/repo-column", size: short, keys: "gr", crop: .repoColumn),
        Shot(id: "worktrees/import-worktree", keys: "Iw", crop: .picker),
        // Typing narrows by repo, branch or the path below its root, and marks what matched.
        Shot(id: "worktrees/import-worktree-filtered", keys: "Iwgantt", crop: .picker),
        Shot(id: "worktrees/import-path", keys: "Ip" + "code/wt/docs-toolkit/toc", crop: .picker),
        Shot(id: "worktrees/remove", keys: "gr4jvjd", crop: .confirm),
        Shot(id: "worktrees/rules", keys: "gr", crop: .rulesPanel),
        Shot(id: "worktrees/sweep", keys: "gr", crop: .sweepBanner, prepare: { model in
            model.applyConfig(source: "[cleanup]\nenabled = true\nidle_days = 3\n")
        }),
        // A chat closed 40 days ago: its scratch folder is in the sweep too.
        Shot(id: "worktrees/sweep-chats", keys: "gr", crop: .sweepBanner, prepare: withOldChat),
        Shot(id: "worktrees/sweep-chats-confirm", keys: "grgC", crop: .confirm, prepare: withOldChat),
        // Work saved 120 days ago, past keep_archive_days: the sweep drops it, and says so first.
        Shot(id: "worktrees/sweep-archives", keys: "grgC", crop: .confirm, prepare: withOldArchive),
        Shot(id: "worktrees/setup", keys: "gr", crop: .setupBanner, prepare: withSetupProposals),
        Shot(id: "worktrees/setup-review", keys: "grS", crop: .confirm, prepare: withSetupProposals),
    ]

    /// Cleanup on, and a chat closed 40 days ago whose scratch folder is still there.
    private static let withOldChat: @MainActor (AppModel) -> Void = { model in
        model.applyConfig(source: "[cleanup]\nenabled = true\nidle_days = 3\nask_before_sweep = true\n")
        var entry = Fixtures.closedChat
        entry.closedAt = Clock.now.addingTimeInterval(-40 * 86400)
        entry.session.workspace = .chat(ChatFolder(
            .scratch, path: "/Users/you/Library/Application Support/Heed/chats/2026-09-03-rows-differ-exports"
        ))
        model.commit(.sessionClosed(entry))
    }

    /// Cleanup on (asking first), and work saved from a removed worktree 120 days ago.
    private static let withOldArchive: @MainActor (AppModel) -> Void = { model in
        model.applyConfig(source: "[cleanup]\nenabled = true\nidle_days = 3\nask_before_sweep = true\n")
        let repo = Repo(org: "acme", name: "docs-toolkit")
        model.commit(.archivesListed(repo: repo, location: .local, [ArchiveRef(
            repo: repo, branch: "toc-experiment", commit: "4e1f0a2",
            archivedAt: Clock.now.addingTimeInterval(-120 * 86400), unpushed: 2
        )]))
    }

    /// The session under the cursor with tasks of every source, as a worktree with a mise config, a Makefile and a
    /// package.json offers them.
    private static let withDiscoveredTasks: @MainActor (AppModel) -> Void = { model in
        model.showTasks([
            TaskSpec(name: "tests", command: "dotnet test"),
            TaskSpec(name: "build", command: "mise run build", source: .mise, detail: "Build the docs-toolkit binary"),
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
        // Lines selected, as a drag over them or `v` selects them: the footer's actions say they act on the lines.
        Shot(id: "diff/select", keys: "gdjjvjj"),
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
        Shot(id: "history/timeline", keys: "ghT"),
        Shot(id: "history/dashboard", keys: "ghD"),
        // Twelve weeks: r steps the range on from four weeks.
        Shot(id: "history/dashboard-weeks", keys: "ghDr"),
        Shot(id: "history/ledger", keys: "ghL"),
        // The abandoned spike: its follow-up, the agent time an estimate.
        Shot(id: "history/ledger-detail", keys: "ghLjjj"),
        Shot(id: "history/timeline-worktrees", keys: "ghTtt"),
        Shot(id: "history/timeline-detail", keys: "ghTtt/flowchart<CR>", crop: .timelineDetail),
    ]

    /// Goals (`gG`), on the fake world's goals (`GoalFixtures`).
    static let goals: [Shot] = [
        Shot(id: "goals/goals", keys: "gG"),
        // The goal with three versions: what is on it, its PRs and where its work was left.
        Shot(id: "goals/overview", keys: "gGj<Tab>", crop: .goalsOverview, cropPadding: 0),
        Shot(id: "goals/doc", keys: "gGjE"),
        // New goal from the session under the cursor: its title and prompt filled in.
        Shot(id: "goals/new", crop: .goalForm, cropPadding: 24, prepare: { model in
            model.perform(CommandInvocation(name: "goal.new", target: .session("s5")))
            model.goals.form?.statement = "Every editor rule passes the 0.17 spec tests, and the suite runs on each PR."
        }),
        // The goal's items by stage, filled by evidence; its board; the changes to GOAL.md the work suggests.
        Shot(id: "goals/matrix", keys: "gGj", crop: .goalMatrix, cropPadding: 8),
        Shot(id: "goals/board", keys: "gGjB"),
        Shot(id: "goals/proposals", keys: "gGjE", crop: .goalProposals, cropPadding: 8),
        Shot(id: "goals/session-chip", keys: "", crop: .sidebar, cropPadding: 0),
        Shot(id: "goals/inspector", keys: "", crop: .inspectorGoal, cropPadding: 8),
        // Unassigned: what heed decided about new work lately, its ask, and a goal it suggests.
        Shot(id: "goals/unassigned", keys: "gGU"),
        // The cursor on the suggested goal, its keys showing.
        Shot(id: "goals/suggestion", keys: "gGUj", crop: .goalsUnassigned, cropPadding: 0),
        // heed's ask in Attention, answered with one key.
        Shot(id: "goals/attach-ask", keys: "gm/z-order<CR>", crop: .attentionDetail),
        // Reviewers (R): the implementation reviewer under the cursor, its objections and why its score is what it is.
        Shot(id: "goals/reviewers", keys: "gGjR<Tab>j"),
        Shot(id: "goals/reviewer-detail", keys: "gGjR<Tab>j<Tab>", crop: .goalReviewerDetail, cropPadding: 8),
        Shot(id: "goals/how-happy", keys: "gGj", crop: .goalHappy, cropPadding: 8),
        // The goal mirrored to GitHub: its tracker, meta issue, last sync and a colleague's change waiting.
        Shot(id: "goals/mirror", keys: "gGj", crop: .goalMirror, cropPadding: 8),
        Shot(id: "goals/quality-bars", keys: "gGjR", crop: .goalBars, cropPadding: 8),
        Shot(id: "goals/spawn", keys: "gGjR", crop: .goalSpawn, cropPadding: 8, prepare: { model in
            model.goals.spawn.kind = .security
            model.goals.spawn.policy = .nightly
        }),
        // Personas (P): who the goal needs, gaps first; the first gap under the cursor, its evidence and its file.
        Shot(id: "goals/personas", keys: "gGjP<Tab>"),
        Shot(id: "goals/persona-table", keys: "gGjP<Tab>", crop: .goalPersonaList, cropPadding: 8),
        Shot(id: "goals/persona-file", keys: "gGjP<Tab>", crop: .goalPersonaFile, cropPadding: 8),
        // Evaluations (X): the DX evaluator's two walks, its friction log, and the lens picker.
        Shot(id: "goals/evaluations", keys: "gGjX<Tab>"),
        Shot(id: "goals/walk", keys: "gGjX", crop: .goalEvaluator, cropPadding: 8),
        Shot(id: "goals/friction", keys: "gGjX<Tab>", crop: .goalFriction, cropPadding: 8),
        Shot(id: "goals/lenses", keys: "gGjX", crop: .goalLenses, cropPadding: 8),
        // Swarms (S): the diagrams goal's lead drafted v2 and asks two things; the anchors goal's plan is approved.
        Shot(id: "goals/swarm-new", crop: .swarmForm, cropPadding: 24, prepare: { model in
            model.perform(CommandInvocation(name: "swarm.new"))
            model.goals.swarmForm?.title = "Diagram export to SVG"
            model.goals.swarmForm?.statement = "Every diagram type exports to SVG that matches the canvas, with "
                + "fonts embedded."
            model.goals.swarmForm?.repos = ["globex/markgraph"]
            model.goals.swarmForm?.lead = GoalItem.Owner(agent: "claude", model: "opus")
            model.goals.swarmForm?.workers = [
                SwarmSettings.Worker(agent: "claude", count: 2), SwarmSettings.Worker(agent: "codex"),
            ]
            model.goals.swarmForm?.limits = SwarmSettings.Limits(agents: 3, hours: 3, dollars: 30)
        }),
        Shot(id: "goals/swarm-plan", keys: "gGS"),
        Shot(id: "goals/swarm-questions", keys: "gGS", crop: .swarmQuestions, cropPadding: 8),
        Shot(id: "goals/swarm-approved", keys: "gGjS"),
        Shot(id: "goals/swarm-diff", keys: "gGjS<Tab>j", crop: .swarmVersions, cropPadding: 8),
        Shot(id: "goals/swarm-edit", keys: "gGSje", crop: .swarmEditor, cropPadding: 8),
        Shot(id: "goals/swarm-goal-page", keys: "gG", crop: .goalSwarm, cropPadding: 8),
        // The anchors swarm running: 1.2 merged and done, 1.1's PR green, two workers stacked on it, one asking.
        Shot(id: "goals/swarm-running", keys: "gGjS", prepare: { $0.loadRunningSwarmFixture(.running) }),
        Shot(id: "goals/swarm-stacked", keys: "gGjS", crop: .swarmTask, cropPadding: 8, prepare: {
            $0.loadRunningSwarmFixture(.running)
        }),
        Shot(id: "goals/swarm-goal-running", keys: "gGj", crop: .goalSwarm, cropPadding: 8, prepare: {
            $0.loadRunningSwarmFixture(.running)
        }),
        // The same swarm at its 4 h limit: paused, the plan pane says so, and Needs you asks for more.
        Shot(id: "goals/swarm-limit", keys: "gGjS", crop: .swarmLimit, cropPadding: 8, prepare: {
            $0.loadRunningSwarmFixture(.pausedAtLimit)
        }),
        Shot(id: "goals/swarm-limit-ask", keys: "gm/limit<CR>", crop: .attentionDetail, prepare: {
            $0.loadRunningSwarmFixture(.pausedAtLimit)
        }),
        // Landing: every task has its PR; the merge order on the right, the two PRs stacked on #412 held after it.
        Shot(id: "goals/swarm-landing", keys: "gGjS", prepare: { $0.loadRunningSwarmFixture(.landing) }),
        Shot(id: "goals/swarm-order", keys: "gGjS", crop: .swarmOrder, cropPadding: 8, prepare: {
            $0.loadRunningSwarmFixture(.landing)
        }),
        Shot(id: "goals/swarm-held", keys: "gGjS", crop: .swarmHeld, cropPadding: 8, prepare: {
            $0.loadRunningSwarmFixture(.landing)
        }),
        // m: the outline itself in merge order.
        Shot(id: "goals/swarm-merge-order", keys: "gGjSm", crop: .swarmOutline, cropPadding: 8, prepare: {
            $0.loadRunningSwarmFixture(.landing)
        }),
        // The repo's merge queue takes the swarm's PRs in its order, the held ones held.
        Shot(
            id: "goals/swarm-merge-queue",
            keys: typed(":merge.queue docs-toolkit") + "<CR>",
            crop: .pilotDetail,
            prepare: { $0.loadRunningSwarmFixture(.landing) }
        ),
        // Done: every task merged, the stacked PRs moved to main first; the goal page says the goal stays open.
        Shot(id: "goals/swarm-done", keys: "gGjS", prepare: { $0.loadRunningSwarmFixture(.done) }),
        Shot(id: "goals/swarm-goal-done", keys: "gGj", crop: .goalSwarm, cropPadding: 8, prepare: {
            $0.loadRunningSwarmFixture(.done)
        }),
        // Steering: the running anchors swarm's questions in Needs you (one with the controller's suggestion), its
        // steering log with the controller's answer you overruled, and one task's agent-to-agent log.
        Shot(id: "goals/swarm-needs-you", keys: "gm/asks:<CR>", prepare: { $0.loadSteeringFixture() }),
        Shot(id: "goals/swarm-ask", keys: "gm/cached timings<CR>", crop: .swarmAsk, cropPadding: 8, prepare: {
            $0.loadSteeringFixture()
        }),
        Shot(id: "goals/swarm-steering", keys: "gGjS<Tab><Tab>jjjjj", crop: .swarmSteering, cropPadding: 8, prepare: {
            $0.loadSteeringFixture()
        }),
        Shot(id: "goals/swarm-agent-log", keys: "gGjSjj", crop: .swarmAgentLog, cropPadding: 8, prepare: {
            $0.loadSteeringFixture()
        }),
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
        Shot(id: "keyboard/hints-list", size: short, keys: ":issues<CR>f", crop: .list),
        Shot(id: "keyboard/command-line", keys: ":vie", crop: .commandLine),
        Shot(id: "keyboard/visual", size: short, keys: "grvjj", crop: .worktreeTable),
    ]

    static let configuration: [Shot] = [
        Shot(id: "configuration/problem", keys: "", crop: .statusBar, cropPadding: 0, prepare: { model in
            model.applyConfig(source: "[cleanup]\nidle_days = 0\n")
        }),
        // Tall enough for the whole General page, down to the call log's retention and the tools.
        Shot(id: "configuration/settings", subject: .settings(), size: CGSize(width: 900, height: 2280)),
        // Orgs & repos at the Settings window's default width, a shot per tab, and at its minimum width on the longest
        // tab: tall enough for the whole page (the window scrolls it), and nothing may be clipped at the side.
        Shot(
            id: "configuration/orgs-repos", subject: .settings(.colors), size: CGSize(width: 1000, height: 960),
            prepare: { $0.settingsScope = .repo(Repo(org: "acme", name: "docs-toolkit")) }
        ),
    ] + OverrideTab.allCases.dropFirst().map { tab in
        Shot(
            id: "configuration/orgs-repos-\(tab.rawValue)", subject: .settings(.colors),
            size: CGSize(width: 1000, height: 960),
            prepare: { model in
                model.settingsScope = .repo(Repo(org: "acme", name: "docs-toolkit"))
                model.orgRepoTab = tab
            }
        )
    } + [
        // Only overridden: the list and each tab keep what is overridden, and the tabs with nothing are dimmed.
        Shot(
            id: "configuration/orgs-repos-only-overridden", subject: .settings(.colors),
            size: CGSize(width: 1000, height: 960),
            prepare: { model in
                model.settingsScope = .repo(Repo(org: "acme", name: "docs-toolkit"))
                model.orgRepoTab = .merged
                model.orgRepoOnlyOverridden = true
            }
        ),
        Shot(
            id: "configuration/orgs-repos-min", subject: .settings(.colors), size: CGSize(width: 780, height: 1100),
            prepare: { model in
                model.settingsScope = .repo(Fixtures.longNamedRepo)
                model.orgRepoTab = .merged
            }
        ),
        Shot(id: "configuration/settings-hosts", subject: .settings(.hosts), size: CGSize(width: 1000, height: 820)),
        // Settings › Inference & decisions as a first launch finds it: nothing chosen, the one-click setup on top.
        Shot(
            id: "configuration/inference-not-configured", subject: .settings(.inference),
            size: CGSize(width: 1100, height: 1060)
        ),
        // The same once set up: claude for model calls, the on-device model for decisions, both tested.
        Shot(
            id: "configuration/inference-configured", subject: .settings(.inference),
            size: CGSize(width: 1100, height: 1000),
            prepare: { model in
                model.applyConfig(source: "[llm]\nagent = \"claude\"\n[decisions]\ndecider = \"local\"\n")
                model.llmTests["claude"] = LLMTest(
                    answer: "Hello there!", model: "claude-haiku", seconds: 2.4, cost: 0.00031
                )
                model.decisionTest = DecisionTest(answer: "done (confidence 90%)", seconds: 0.6)
            }
        ),
        // The title bar's reminder while model calls and decisions are not set up.
        Shot(
            id: "configuration/inference-reminder", crop: .titleBar,
            prepare: { $0.inferenceReminderInShots = true }
        ),
        // Hunch in each of its states: chosen with no model, downloading, ready with a trained head, learning.
        Shot(
            id: "configuration/hunch-no-model", subject: .settings(.inference), size: CGSize(width: 1100, height: 2000),
            prepare: { HunchShots.prepare($0, .noModel) }
        ),
        Shot(
            id: "configuration/hunch-downloading", subject: .settings(.inference),
            size: CGSize(width: 1100, height: 2000), prepare: { HunchShots.prepare($0, .downloading) }
        ),
        Shot(
            id: "configuration/hunch-ready", subject: .settings(.inference), size: CGSize(width: 1100, height: 2000),
            prepare: { HunchShots.prepare($0, .ready) }
        ),
        Shot(
            id: "configuration/hunch-learning", subject: .settings(.inference), size: CGSize(width: 1100, height: 2000),
            prepare: { HunchShots.prepare($0, .learning) }
        ),
        // The title bar's reminder while Hunch is chosen and its model is downloading.
        Shot(
            id: "configuration/hunch-reminder", crop: .titleBar,
            prepare: { model in
                HunchShots.prepare(model, .downloading)
                model.inferenceReminderInShots = true
            }
        ),
        Shot(
            id: "configuration/attention-rules", subject: .settings(.attention), size: CGSize(
                width: 1180,
                height: 1480
            ),
            prepare: { model in
                model.attention.ruleDraftSeed = Fixtures.attentionRules.map {
                    $0.hasPrefix("ci ") ? "ci ignore" : $0
                } + ["mention team:? lower", "# the rest", "assigend boost 1"]
                model.attention.ruleFormSeed = AttentionRuleForm(
                    clauses: [.reason(.review), .repo("acme/guides")], weight: .lower, notify: false
                )
            }
        ),
        // The editor at work: a repo typed without its org is caught before the rule can be added.
        Shot(
            id: "configuration/attention-rule-editor", subject: .settings(.attention),
            size: CGSize(width: 1180, height: 1120),
            prepare: { model in
                model.attention.ruleDraftSeed = ["mention user:me boost 3", "author bot:dependabot ignore"]
                model.attention.ruleFormSeed = AttentionRuleForm(
                    clauses: [.reason(.ci), .repo("guides"), .branch("main|release/*")], weight: .boost2, notify: true
                )
            }
        ),
    ]

    static let outside: [Shot] = [
        Shot(id: "outside/menu-bar", subject: .menuBar, size: CGSize(width: 520, height: 34)),
        Shot(id: "outside/menu", subject: .menu, size: CGSize(width: 620, height: 380)),
        Shot(id: "outside/dock", subject: .dock, size: CGSize(width: 420, height: 130), crop: .picker, cropPadding: 30),
    ]
}
