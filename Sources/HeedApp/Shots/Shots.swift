import HeedCore
import SwiftUI

/// Every screenshot in the docs, generated from the fake world by `mise run shots`. A shot's id is its path under
/// docs/images/shots; pages reference them as `../images/shots/<id>.png`.
@MainActor
enum Shots {
    static let all: [Shot] = landing + home + gettingStarted + concepts + sessions + startWork + agents + github +
        worktrees
        + diff + history + keyboard + outside + configuration

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
        Shot(id: "landing/worktrees", chrome: false, keys: "gr4jvj"),
        Shot(id: "landing/resume", chrome: false, prepare: { $0.showResumeForFixture() }),
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
        Shot(id: "sessions/rail", size: CGSize(width: 1440, height: 640), keys: "zs", crop: .rail),
        Shot(id: "sessions/moving", size: CGSize(width: 1440, height: 640), keys: "2j", crop: .sidebar),
        Shot(id: "sessions/attention", size: CGSize(width: 1440, height: 640), keys: "ga", crop: .sidebar),
        Shot(id: "sessions/insert-before", crop: .panes),
        Shot(id: "sessions/insert-after", keys: "i", crop: .panes),
        Shot(id: "sessions/split", keys: "<C-w>v", highlight: [.panes]),
        Shot(id: "sessions/tab-strip", crop: .tabStrip, cropPadding: 6),
        Shot(id: "sessions/zoom", keys: "<C-w>z", highlight: [.panes]),
        Shot(id: "sessions/inspector", crop: .inspector, cropPadding: 0),
        Shot(id: "sessions/close-confirm", keys: "x", crop: .confirm),
        Shot(id: "sessions/delete-confirm", keys: "dd", crop: .confirm),
        Shot(id: "sessions/resume", crop: .dialog, prepare: { $0.showResumeForFixture() }),
        Shot(id: "sessions/filter-typing", keys: "/docs", crop: .statusBar, cropPadding: 0),
        Shot(id: "sessions/filter-kept", size: CGSize(width: 1440, height: 640), keys: "/docs<CR>", crop: .sidebar),
    ]

    static let prompt = typed("Fix broken anchors in the redirect pages")

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
    ]

    static let short = CGSize(width: 1440, height: 640)

    static let agents: [Shot] = [
        Shot(id: "agents/guessed", size: short, keys: "2j", crop: .sidebar),
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
        Shot(id: "github/feedback", keys: "go"),
        Shot(id: "github/delivery", keys: "go", crop: .delivery),
        Shot(id: "github/prompt", keys: "go", crop: .promptPreview),
    ]

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
    ]

    static let diff: [Shot] = [
        Shot(id: "diff/overlay", keys: "gd"),
        Shot(id: "diff/split", keys: "gdt"),
    ]

    static let history: [Shot] = [
        Shot(id: "history/history", keys: "gh"),
        Shot(id: "history/detail", keys: "gh", crop: .historyDetail),
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
        Shot(id: "configuration/settings", subject: .settings(), size: CGSize(width: 900, height: 640)),
    ]

    static let outside: [Shot] = [
        Shot(id: "outside/menu-bar", subject: .menuBar, size: CGSize(width: 520, height: 34)),
        Shot(id: "outside/menu", subject: .menu, size: CGSize(width: 620, height: 380)),
        Shot(id: "outside/dock", subject: .dock, size: CGSize(width: 420, height: 130), crop: .picker, cropPadding: 30),
    ]
}
