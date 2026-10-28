import Foundation

/// Domains to start the UI in without any IO: one per design board. `HEED_FIXTURE=<name>` opens the app on one with
/// every adapter switched off.
public enum Fixtures {
    /// `resume` is `main` opening on the resume dialog (the app handles that name).
    public static let names = ["main", "empty", "resume", "pr-storm", "fresh-repos", "chats"]

    /// What the fixtures' config would say about issues: docs-toolkit and the globex org show all of them.
    public static let issueRules = IssueRules(orgs: ["globex": .all], repos: ["acme/docs-toolkit": .all])

    /// Org and repo overrides for Settings › Orgs & repos. Only markgraph's shows elsewhere: it asks for GitHub's
    /// auto-merge, which that repo does not allow, so its PR reads "Merging misconfigured".
    public static let pilotRules: PilotRules = {
        var org = PilotOverrides(reviewers: ["copilot"])
        org.quietMinutes = 10
        var repo = PilotOverrides()
        repo.quietMinutes = 15
        repo.gateChecks = ["build", "integration"]
        repo.holdLabels = ["do-not-merge"]
        let misconfigured = PilotOverrides(merge: .auto)
        return PilotRules(
            orgs: ["acme": org], repos: ["acme/docs-toolkit": repo, "globex/markgraph": misconfigured]
        )
    }()

    /// A repo only config.toml names (not cloned), with a name too long for Settings › Orgs & repos' list.
    public static let longNamedRepo = Repo(org: "acme", name: "handbook-translations-release-notes-archive")

    /// `[repos."org/name"]` tables the fake world's config.toml has beyond the overrides above.
    public static let repoConfigs: [String: HeedConfig.RepoConfig] = [
        longNamedRepo.slug: HeedConfig.RepoConfig(color: nil, issues: nil, tasks: []),
    ]

    /// Goal trackers: acme's goals mirror to acme/planning, docs-toolkit's to a tracker of its own.
    public static let goalMirror: GoalMirrorSettings = {
        var mirror = GoalMirrorSettings()
        mirror.trackers = ["acme": "acme/planning", "acme/docs-toolkit": "acme/docs-planning"]
        return mirror
    }()

    /// What the issue links of the fake world fetched: their titles and states.
    public static let issueInfo: [IssueRef: IssueInfo] = [
        IssueRef(repo: docsWebsite, number: 88): IssueInfo(
            title: "Old links to moved pages 404", closed: false,
            body: "Pages moved in the reorg are linked from outside; their old URLs now 404.", labels: ["bug"],
            author: "reader", updatedAt: Clock.now.addingTimeInterval(-86400)
        ),
        IssueRef(repo: docsToolkit, number: 2830): IssueInfo(title: "Anchors lost when a page is moved", closed: false),
    ]

    /// Hosts: @devbox answers, @gpu wants your key, @ci is down.
    public static let hosts: [String: HostConfig] = [
        "devbox": HostConfig(name: "devbox", color: "teal"),
        "gpu": HostConfig(name: "gpu", worktreeRoot: "~/runs", color: "periwinkle"),
        "ci": HostConfig(name: "ci", ssh: "ci@10.0.4.9", worktreeRoot: "~/builds", color: "pink"),
        "lab": HostConfig(name: "lab", color: "sky"),
    ]

    public static let hostStatuses: [String: HostStatus] = [
        "devbox": .connected(HostInfo(
            latency: .milliseconds(24), platform: "Linux x86_64", git: "2.46.0", zmx: "0.8.1",
            agents: ["claude", "codex"], checkedAt: Clock.now, home: "/home/you",
            zmxPath: "/home/you/.local/bin/zmx", os: "ubuntu", link: .direct
        )),
        // Answers, but zmx is not installed there yet: heed says how.
        "lab": .connected(HostInfo(
            latency: .milliseconds(41), platform: "Linux aarch64", git: "2.43.0", zmx: nil, agents: ["claude"],
            checkedAt: Clock.now, home: "/home/you", os: "debian", link: .relay("fra")
        )),
        "gpu": .needsAuth("martijn@gpu: Permission denied (publickey)."),
        "ci": .offline(
            reason: "ssh: connect to host 10.0.4.9 port 22: Operation timed out",
            lastSeen: Clock.now.addingTimeInterval(-3 * 86400)
        ),
    ]

    /// A made-up tailnet: @devbox and @lab are hosts already (over it), gpu-box and build-mini are not added yet.
    public static let tailnet = Tailnet(
        state: .running, name: "example-tailnet.ts.net",
        machines: [
            TailnetMachine(
                name: "build-mini", hostName: "Build Mini", dnsName: "build-mini.example-tailnet.ts.net",
                addresses: ["100.64.0.12"], os: "macOS", online: false,
                lastSeen: Clock.now.addingTimeInterval(-2 * 86400)
            ),
            TailnetMachine(
                name: "devbox", dnsName: "devbox.example-tailnet.ts.net", addresses: ["100.64.0.7"], link: .direct,
                hostKeys: ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleDevboxHostKeyNotARealOne000000000"]
            ),
            TailnetMachine(
                name: "gpu-box", dnsName: "gpu-box.example-tailnet.ts.net", addresses: ["100.64.0.9"],
                hostKeys: ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleGpuBoxHostKeyNotARealOne000000000"]
            ),
            TailnetMachine(
                name: "lab", dnsName: "lab.example-tailnet.ts.net", addresses: ["100.64.0.4"], link: .relay("fra")
            ),
        ]
    )

    static let remoteRepos = [
        RepoRecord(
            repo: docsToolkit,
            path: "/home/you/code/docs-toolkit",
            defaultBranch: "main",
            location: .host("devbox")
        ),
    ]

    /// On @devbox: one registered worktree, one a scan found.
    static let remoteWorktrees = [
        Worktree(
            repo: docsToolkit, path: "/home/you/code/wt/flake-hunt", branch: "flake-hunt", head: "4e1c2aa",
            isMain: false, status: WorktreeStatus(ahead: 0, behind: 4, upstream: "origin/flake-hunt"),
            location: .host("devbox")
        ),
        Worktree(
            repo: docsToolkit, path: "/home/you/code/wt/old-spike", branch: "old-spike", head: "9b0d113",
            isMain: false, status: WorktreeStatus(changedFiles: 2, upstream: nil), location: .host("devbox")
        ),
    ]

    public static func named(_ name: String) -> Domain? {
        switch name {
        case "main": main
        case "empty": .empty
        case "pr-storm": prStorm
        case "fresh-repos": freshRepos
        case "chats": withChats
        default: nil
        }
    }

    static let docsToolkit = Repo(org: "acme", name: "docs-toolkit")
    static let docsWebsite = Repo(org: "acme", name: "docs-website")
    static let markgraph = Repo(org: "globex", name: "markgraph")
    static let editorRules = Repo(org: "initech", name: "editor-rules")
    static let ingest = Repo(org: "umbrella", name: "ingest")

    /// design/screens/Main.png.
    public static let main: Domain = {
        let root = "/Users/you/code"
        let repos = [docsToolkit, docsWebsite, markgraph, editorRules, ingest].map {
            RepoRecord(repo: $0, path: "\(root)/\($0.name)", defaultBranch: "main")
        }
        var sessions = [
            Session(
                id: "s1", title: "Fix broken anchors in redirects",
                prompt: "Fix broken anchors in redirects.yml. Every redirect target must resolve to a real heading."
                    + "\n\nFixes acme/docs-website#88",
                repos: [docsToolkit, docsWebsite], branch: "fix-anchors-redirects", agent: "claude",
                agentSessionID: "7f3a9c1e-52b4-4e0d-9a61-0c8d3e1f2b77",
                state: ObservedState(.working), activity: "running tests · 14m", trackedPRs: [
                    PullRef(repo: docsToolkit, number: 2841),
                    PullRef(repo: docsWebsite, number: 1920),
                    PullRef(repo: docsToolkit, number: 2836),
                ], pinned: true
            ),
            Session(
                id: "s2", title: "Cross-link validator for assemblies", repos: [docsToolkit],
                branch: "cross-link-validator", agent: "claude", agentSessionID: "2c81d6aa-9e17-4b3f-8d05-6a4e7b9c0d12",
                state: ObservedState(.blocked, reason: "Bash(dotnet publish)"),
                activity: "wants to run dotnet publish", trackedPRs: [PullRef(repo: docsToolkit, number: 2838)],
                pinned: true
            ),
            Session(
                id: "s3", title: "Backpressure in ingest stage", repos: [ingest], branch: "ingest-backpressure",
                agent: "codex", agentSessionID: "91be40d2-7a35-4c68-b2f9-13e5a8d07c46", state: ObservedState(
                    .asking,
                    source: .guessed
                ), activity: "3 questions waiting", trackedPRs: [PullRef(repo: ingest, number: 31)]
            ),
            Session(
                id: "s4", title: "Sequence diagram arrowheads", repos: [markgraph], branch: "sequence-arrowheads",
                agent: "claude", agentSessionID: "e0457f3b-18c2-4d9a-a6b1-5f2d9c8e3a04", state: ObservedState(.working),
                activity: "editing · 3m", trackedPRs: [PullRef(repo: markgraph, number: 418)]
            ),
            Session(
                id: "s5", title: "Bump spec tests to 0.17", repos: [editorRules], branch: "bump-spec-tests",
                agent: "claude", state: ObservedState(.done), activity: "done · PR approved", trackedPRs: [PullRef(
                    repo: editorRules,
                    number: 412
                )], lastActivity: Clock.now.addingTimeInterval(-50 * 60)
            ),
            Session(
                id: "s6", title: "Docs nav spike", repos: [docsToolkit], branch: "docs-nav-spike", agent: "opencode",
                agentSessionID: "b36c9d71-04fa-42e8-8a3d-7e1c5b2f9d60",
                state: ObservedState(.idle), activity: "idle 2h", trackedPRs: [PullRef(repo: docsToolkit, number: 2852)]
            ),
            // On @devbox: its agent runs there, in zmx, and outlives the link.
            {
                var session = Session(
                    id: "s7", title: "Nightly flake hunt", repos: [docsToolkit], branch: "flake-hunt", agent: "claude",
                    state: ObservedState(.idle), activity: "idle 20m"
                )
                session.host = "devbox"
                session.worktreePaths = ["/home/you/code/wt/flake-hunt"]
                return session
            }(),
        ]
        // What the first session's agent used, as its hooks reported it (the inspector's agent line).
        sessions[0].usage = AgentUsage(
            model: "model-a", tokens: TokenCounts(input: 1840, output: 4120, cacheRead: 9870, cacheWrite: 610),
            costUSD: 0.42, contextTokens: 76000, contextWindow: 200_000
        )
        var worktrees: [Worktree] = []
        var layouts: [String: SessionLayout] = [:]
        for session in sessions {
            if let host = session.host {
                // Its worktree is on the host (remoteWorktrees); its pane runs there.
                let pane = PaneSpec(
                    id: "\(session.id)-agent", role: .agent, title: session.agent,
                    directory: session.worktreePaths.first ?? "~", location: .host(host)
                )
                layouts[session.id] = SessionLayout(tabs: [PaneTab(title: "agent", tree: .leaf(pane))])
                continue
            }
            for repo in session.repos {
                var status = WorktreeStatus(upstream: "origin/\(session.branch)")
                // Work not shared yet, for the rows' pending chips: s1 has files to commit, s6 a commit and files.
                switch (session.id, repo) {
                case ("s1", docsToolkit): status.changedFiles = 2
                case ("s6", _): (status.ahead, status.changedFiles, status.untrackedFiles) = (1, 3, 1)
                default: break
                }
                worktrees.append(Worktree(
                    repo: repo, path: "\(root)/wt/\(repo.name)/\(session.branch)", branch: session.branch,
                    head: "0000000", isMain: false, status: status
                ))
            }
            layouts[session.id] = SessionLayout(tabs: tabs(for: session, root: root))
        }
        // s5's PR has a get it green run working in the background, in a tab next to its agent tab.
        if var layout = layouts["s5"] {
            layout.tabs.append(PaneTab(id: "s5-helper-tab", title: "get it green", tree: .leaf(PaneSpec(
                id: "s5-helper", role: .helper, title: "get it green",
                directory: "\(root)/wt/editor-rules/bump-spec-tests"
            ))))
            layouts["s5"] = layout
        }
        // Worktrees made outside Heed, with no session yet: what `I` in Sessions imports.
        worktrees += [
            Worktree(
                repo: docsToolkit, path: "\(root)/wt/docs-toolkit/toc-ordering", branch: "toc-ordering",
                head: "0000000", isMain: false, status: WorktreeStatus(upstream: "origin/toc-ordering")
            ),
            Worktree(
                repo: markgraph, path: "\(root)/wt/markgraph/gantt-labels", branch: "gantt-labels", head: "0000000",
                isMain: false, status: WorktreeStatus(upstream: nil)
            ),
            Worktree(repo: ingest, path: "\(root)/ingest", branch: "main", head: "0000000", isMain: true),
        ]
        let detail = pullDetail
        var pipeline = PullFeedback(ref: detail.ref)
        pipeline.merge(detail)
        if let index = pipeline.items.firstIndex(where: { $0.id == "T1" }) { pipeline.items[index].status = .queued }
        if let index = pipeline.items
            .firstIndex(where: { $0.id == "check:lint" }) { pipeline.items[index].status = .queued }
        var resolved = FeedbackItem(
            id: "T0",
            kind: .review(location: "RedirectFile.cs:41", author: "reviewer"),
            text: "Use the shared slug helper.",
            status: .resolved
        )
        resolved.resolvedAt = Clock.now
        pipeline.items.append(resolved)
        var (pilots, log) = pilotStates
        // editor-rules#412 conflicts, and Copilot was asked to resolve it.
        if let conflicting = otherDetails.first(where: { $0.mergeable == "CONFLICTING" }) {
            var copilot = PullFeedback(ref: conflicting.ref)
            copilot.merge(conflicting)
            CopilotAsk.asked(&copilot, items: ["conflict"], at: Clock.now.addingTimeInterval(-12 * 60))
            copilot.reviewersRequested = ["@copilot"]
            pilots[conflicting.ref.description] = copilot
            log.insert(PilotEvent(
                at: Clock.now.addingTimeInterval(-12 * 60), ref: conflicting.ref, kind: .copilot,
                text: "asked Copilot to merge in main and resolve the conflicts"
            ), at: 0)
            log.append(PilotEvent(
                at: Clock.now.addingTimeInterval(-3 * 3600), ref: conflicting.ref, kind: .review,
                text: "asked @copilot to review"
            ))
            log.sort { $0.at > $1.at }
        }
        // While you were away: #2836 merged this morning, markgraph#415 last night.
        log += [
            PilotEvent(
                at: Clock.now.addingTimeInterval(-109 * 60), ref: PullRef(repo: docsToolkit, number: 2836),
                kind: .merged, text: "merged into main"
            ),
            PilotEvent(
                at: Clock.now.addingTimeInterval(-879 * 60), ref: PullRef(repo: markgraph, number: 415),
                kind: .merged, text: "Fix label clipping"
            ),
        ]
        log.sort { $0.at > $1.at }
        // heed merges #2841 (held: lint failed), docs-website#1920 has auto-merge on.
        pipeline.merge = .heed
        pipeline.mergeSet = true
        return Domain(
            repos: repos + remoteRepos, worktrees: worktrees + remoteWorktrees, sessions: sessions, layouts: layouts,
            history: history, github: github,
            pullDetails: Dictionary(([detail] + otherDetails).map { ($0.ref.description, $0) }) { first, _ in first },
            feedback: pilots.merging([detail.ref.description: pipeline]) { _, main in main }, pilotLog: log,
            mergeRuns: mergeRuns, registeredWorktrees: [remoteWorktrees[0].id], runs: runs
        )
    }()

    /// The pilot's other states: #2852 paused, ingest#31 not watched (set by hand), markgraph#418 stuck after three
    /// rounds, and a morning of activity.
    static let pilotStates: ([String: PullFeedback], [PilotEvent]) = {
        let now = Clock.now
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let nav = PullRef(repo: docsToolkit, number: 2852)
        let ingestPR = PullRef(repo: ingest, number: 31)
        let arrows = PullRef(repo: markgraph, number: 418)
        let anchors = PullRef(repo: docsToolkit, number: 2841)
        let redirects = PullRef(repo: docsWebsite, number: 1920)
        var paused = PullFeedback(ref: nav)
        paused.pausedUntil = now.addingTimeInterval(42 * 60)
        var unwatched = PullFeedback(ref: ingestPR, watching: false)
        unwatched.watchSet = true
        var merging = PullFeedback(ref: redirects)
        merging.merge = .auto
        merging.mergeSet = true
        var stuck = PullFeedback(ref: arrows, items: [FeedbackItem(
            id: "A1", kind: .review(location: "Arrow.cs:57", author: "reviewer"),
            text: "Arrowheads still detach below 50% zoom.", status: .new
        )])
        stuck.rounds = 3
        let log = [
            PilotEvent(at: ago(6), ref: anchors, kind: .waiting, text: "2 queued, held: the agent is working"),
            PilotEvent(at: ago(9), ref: anchors, kind: .items, text: "2 review threads and check lint arrived"),
            PilotEvent(at: ago(18), ref: nav, kind: .pause, text: "paused for 1h (by you)"),
            PilotEvent(
                at: ago(24),
                ref: arrows,
                kind: .stuck,
                text: "3 rounds without a new approval: stopped sending"
            ),
            PilotEvent(at: ago(31), ref: arrows, kind: .sent, text: "sent 1 item to claude (round 3)"),
            PilotEvent(
                at: ago(40), ref: redirects, kind: .autoMerge,
                text: "auto-merge on: squash; GitHub merges once its requirements are met"
            ),
            PilotEvent(at: ago(44), ref: redirects, kind: .resolved, text: "check link-check resolved"),
            PilotEvent(at: ago(52), ref: redirects, kind: .addressed, text: "the agent pushed: 1 item addressed"),
            PilotEvent(at: ago(70), ref: redirects, kind: .sent, text: "sent 1 item to claude (round 1)"),
            PilotEvent(at: ago(95), ref: ingestPR, kind: .watch, text: "stopped watching (by you)"),
            PilotEvent(at: ago(100), ref: redirects, kind: .merge, text: "merge: auto (by you)"),
        ]
        return (
            [
                nav.description: paused, ingestPR.description: unwatched, arrows.description: stuck,
                redirects.description: merging,
            ],
            log
        )
    }()

    /// The merge queues' runs: docs-website turned green and got auto-merge, docs-toolkit holds #2841 on lint.
    /// Get it green runs: one working on s5's PR, and s1's history (pushed, nothing to change, timed out).
    static let runs: [PilotRun] = {
        let now = Clock.now
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func run(
            _ id: String, _ ref: PullRef, _ session: String, agent: String, model: String?, started: Double,
            minutes: Double?, items: Int, outcome: PilotRun.Outcome?, usage: AgentUsage? = nil, screen: String? = nil
        ) -> PilotRun {
            let branch = ref.number == 412 ? "bump-spec-tests" : "fix-anchors-redirects"
            var run = PilotRun(
                id: id, ref: ref, sessionID: session, goal: .green, agent: agent, model: model, startedAt: ago(started),
                items: items, prBranch: branch, branch: Runs.branch(.green, prBranch: branch),
                worktree: "~/code/wt/heed/\(ref.repo.name)/get-it-green-\(branch)", startSHA: nil
            )
            if let minutes {
                run.endedAt = ago(started - minutes)
                run.outcome = outcome
                run.screen = screen
            }
            run.usage = usage
            return run
        }
        let anchors = PullRef(repo: docsToolkit, number: 2841)
        return [
            run(
                "r4",
                PullRef(repo: editorRules, number: 412),
                "s5",
                agent: "codex",
                model: "gpt-5-codex",
                started: 3,
                minutes: nil,
                items: 2,
                outcome: nil
            ),
            run(
                "r3",
                anchors,
                "s1",
                agent: "codex",
                model: "gpt-5-codex",
                started: 40,
                minutes: 6,
                items: 3,
                outcome: .pushed(2),
                usage: AgentUsage(tokens: TokenCounts(input: 21400, output: 3800, cacheRead: 64000), costUSD: 0.18),
                screen: """
                ✓ Fixed the anchor slugs in redirects.yml (2 files)
                ✓ lint passes locally
                $ git push origin HEAD:fix-anchors-redirects
                To github.com:acme/docs-toolkit.git
                   4f2a1c9..b81e0d3  HEAD -> fix-anchors-redirects
                Done: pushed 2 commits.
                """
            ),
            run(
                "r2",
                anchors,
                "s1",
                agent: "claude",
                model: "haiku",
                started: 95,
                minutes: 3,
                items: 1,
                outcome: .noChanges,
                screen: "The review thread asks a question; nothing to change in the code."
            ),
            run(
                "r1",
                anchors,
                "s1",
                agent: "codex",
                model: nil,
                started: 180,
                minutes: 30,
                items: 4,
                outcome: .timedOut
            ),
        ]
    }()

    static let mergeRuns: [String: [MergeRun]] = {
        let now = Clock.now
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let anchors = PullRef(repo: docsToolkit, number: 2841)
        let redirects = PullRef(repo: docsWebsite, number: 1920)
        return [
            docsToolkit.slug: [
                MergeRun(repo: docsToolkit.slug, at: ago(20), why: "schedule", lines: [
                    .init(ref: anchors, action: "held", detail: "Green: checks pass: lint failed"),
                ]),
                MergeRun(repo: docsToolkit.slug, at: ago(80), why: "merge turned on", lines: [
                    .init(ref: anchors, action: "brought up to date", detail: "merged main in"),
                ]),
            ],
            docsWebsite.slug: [
                MergeRun(repo: docsWebsite.slug, at: ago(40), why: "#1920 turned green", lines: [
                    .init(
                        ref: redirects, action: "auto-merge on",
                        detail: "squash; GitHub merges once its requirements are met"
                    ),
                ]),
                MergeRun(repo: docsWebsite.slug, at: ago(100), why: "merge turned on", lines: [
                    .init(ref: redirects, action: "held", detail: "Checks pass: link-check failed"),
                ]),
            ],
        ]
    }()

    /// The tutor's PR storm: every review comment and failing check on #2841 is new, and it is the PR updated last,
    /// while the session that owns it is busy working.
    /// Subagents running in `main`'s sessions, by session id: the anchors session has two out exploring.
    public static var subagents: [String: [LiveSubagent]] {
        let now = Clock.now
        return ["s1": [
            LiveSubagent(id: "agent-a1", type: "Explore", startedAt: now.addingTimeInterval(-6 * 60)),
            LiveSubagent(id: "agent-b2", type: "general-purpose", startedAt: now.addingTimeInterval(-2 * 60)),
        ]]
    }

    public static let prStorm: Domain = {
        var domain = main
        for key in domain.feedback.keys {
            for index in domain.feedback[key]!.items.indices
                where domain.feedback[key]!.items[index].status != .resolved
            {
                domain.feedback[key]!.items[index].status = .new
            }
        }
        if let index = domain.github.pulls.firstIndex(where: { $0.ref == pullDetail.ref }) {
            var pull = domain.github.pulls.remove(at: index)
            pull.updatedAt = Clock.now
            domain.github.pulls.insert(pull, at: 0)
        }
        return domain
    }()

    /// `main` with chats: two in scratch folders (one asking, so it is in Needs you), one in a folder you picked, one
    /// on @lab; and one closed in History.
    public static let withChats: Domain = {
        var domain = main
        for (session, layout) in chats {
            domain.sessions.append(session)
            domain.layouts[session.id] = layout
        }
        domain.history.insert(closedChat, at: 1)
        return domain
    }()

    /// The fake world's chats, each with its one agent pane in its folder.
    public static let chats: [(Session, SessionLayout)] = {
        let now = Clock.now
        let scratch = "/Users/you/Library/Application Support/Heed/chats"
        func chat(
            _ id: String, _ title: String, prompt: String, agent: String, _ state: ObservedState, activity: String,
            _ folder: ChatFolder, host: String? = nil, minutesAgo: Double, agentSessionID: String? = nil
        ) -> (Session, SessionLayout) {
            var session = Session(
                id: id, title: title, prompt: prompt, repos: [], branch: "", agent: agent,
                agentSessionID: agentSessionID, state: state,
                activity: activity, lastActivity: now.addingTimeInterval(-minutesAgo * 60), workspace: .chat(folder)
            )
            session.host = host
            session.record(
                "started chat · \(agent) · \(folder.kind == .scratch ? "scratch folder" : "in \(folder.path)")",
                at: now.addingTimeInterval(-(minutesAgo + 20) * 60)
            )
            let pane = PaneSpec(
                id: "\(id)-agent", role: .agent, title: agent, directory: folder.path,
                command: ShellCommand(words: [.raw(agent)]), location: host.map(Location.host) ?? .local
            )
            return (session, SessionLayout(tabs: [PaneTab(id: "\(id)-t1", title: "agent", tree: .leaf(pane))]))
        }
        return [
            chat(
                "c1", "Cron line for weekdays at nine", prompt: "What cron line runs a job at nine on weekdays?",
                agent: "claude", ObservedState(.asking, reason: "which timezone?"),
                activity: "asking · which timezone?",
                ChatFolder(.scratch, path: "\(scratch)/2026-10-21-cron-line-runs-job"), minutesAgo: 2,
                agentSessionID: "5d0e7a41-9c3b-4f62-8e17-2b6c9a0f4d38"
            ),
            chat(
                "c2", "Explain git rebase --onto", prompt: "Explain git rebase --onto with a small example.",
                agent: "codex", ObservedState(.done), activity: "done",
                ChatFolder(.scratch, path: "\(scratch)/2026-10-21-explain-git-rebase-onto"), minutesAgo: 12
            ),
            chat(
                "c3", "Sort receipts by month", prompt: "Sort the PDFs in this folder into one folder per month.",
                agent: "claude", ObservedState(.working), activity: "working · moving files",
                ChatFolder(.folder, path: "/Users/you/Documents/receipts"), minutesAgo: 1
            ),
            chat(
                "c4", "Read the nightly build log", prompt: "Why did last night's build stop halfway?",
                agent: "claude", ObservedState(.idle), activity: "idle 40m",
                ChatFolder(.scratch, path: "~/.heed/chats/2026-10-21-last-night-build-stop"), host: "lab",
                minutesAgo: 40
            ),
        ]
    }()

    /// A chat closed this morning, as History lists it.
    public static let closedChat: HistoryEntry = {
        let closed = Clock.now.addingTimeInterval(-2 * 3600)
        var session = Session(
            id: "h-chat-csv", title: "Compare two CSV exports", prompt: "Which rows differ between these two exports?",
            repos: [], branch: "", agent: "claude", state: ObservedState(.done), lastActivity: closed,
            createdAt: closed.addingTimeInterval(-25 * 60),
            workspace: .chat(ChatFolder(
                .scratch, path: "/Users/you/Library/Application Support/Heed/chats/2026-10-21-rows-differ-exports"
            ))
        )
        session.record("started chat · claude · scratch folder", at: closed.addingTimeInterval(-25 * 60))
        session.record("ended after 0h 25m", at: closed)
        return HistoryEntry(session: session, closedAt: closed, outcome: .closed)
    }()

    /// The tutor's fresh repos: every repo and worktree, no sessions or history yet.
    public static let freshRepos: Domain = {
        var domain = main
        domain.sessions = []
        domain.layouts = [:]
        domain.history = []
        domain.feedback = [:]
        return domain
    }()

    /// design/screens/Diff.png.
    public static let diffCommits = [
        CommitSummary(sha: "4f2a1c0", subject: "Validate anchors against headings"),
        CommitSummary(sha: "a91e3d0", subject: "Fix lint in redirects.md"),
        CommitSummary(sha: "0be7d20", subject: "Add moved-page redirect fixtures"),
    ]

    public static let diff: [FileDiff] = {
        let text = """
        diff --git a/src/Acme.Markdown/Redirects/RedirectFile.cs b/src/Acme.Markdown/Redirects/RedirectFile.cs
        --- a/src/Acme.Markdown/Redirects/RedirectFile.cs
        +++ b/src/Acme.Markdown/Redirects/RedirectFile.cs
        @@ -76,9 +76,11 @@ public sealed class RedirectFile
             public bool TryResolve(string page, string fragment)
             {
        -        var anchors = _anchors.GetValueOrDefault(page);
        +        var anchors = _anchors.GetValueOrDefault(page, EmptyAnchors);
        +        var slug = Slugify(fragment);
                 // headings are lowercased by the slugifier
        -        if (!anchors.Contains(fragment))
        +        if (!anchors.Contains(slug, StringComparer.Ordinal))
                     return false;
        +        _resolved[page] = new Resolved(page, slug);
                 return true;
             }
        @@ -131,6 +133,8 @@ public sealed class RedirectFile
             private static IReadOnlySet<string> EmptyAnchors
        +        = new HashSet<string>(StringComparer.Ordinal);
         }
        diff --git a/tests/Redirects/AnchorTests.cs b/tests/Redirects/AnchorTests.cs
        new file mode 100644
        --- /dev/null
        +++ b/tests/Redirects/AnchorTests.cs
        @@ -0,0 +1,3 @@
        +public class AnchorTests
        +{
        +}
        diff --git a/docs/redirects.md b/docs/redirects.md
        --- a/docs/redirects.md
        +++ b/docs/redirects.md
        @@ -40,2 +40,3 @@
         Redirects keep anchors.
        -A very long line that the linter rejects because it goes on and on.
        +A shorter line.
        +Another line.

        """
        return DiffParser.parse(text, repo: docsToolkit, staged: ["src/Acme.Markdown/Redirects/RedirectFile.cs"])
    }()

    /// design/screens/Reader.png.
    static let pullDetail: PullDetail = {
        var detail = PullDetail(
            ref: PullRef(repo: docsToolkit, number: 2841), title: "Fix broken anchors in redirects",
            body: "Validates redirect targets against real headings, so moved pages no longer lose their anchors.\nCloses #2830. Companion change in docs-website #1920.",
            author: "you", baseBranch: "main", headBranch: "fix-anchors-redirects", additions: 82, deletions: 4,
            commitCount: 3, headSHA: "a91e3d0",
            reviews: [PullDetail.Review(
                author: "reviewer", state: "CHANGES_REQUESTED", submittedAt: Clock.now.addingTimeInterval(-686 * 60)
            )],
            threads: [
                ReviewThread(
                    id: "T1", isResolved: false, path: "src/Redirects/RedirectFile.cs", line: 88, author: "reviewer",
                    body: "Anchor lookup is case sensitive. Heading slugs are lowercased, so this misses valid targets.",
                    diff: [
                        "     var slug = Slugify(heading);",
                        "-    var exists = anchors.Contains(target);",
                        "+    var exists = anchors.Contains(target, StringComparer.Ordinal);",
                    ],
                    replies: 0, url: nil
                ),
                ReviewThread(
                    id: "T2", isResolved: false, path: "tests/Redirects/AnchorTests.cs", line: 12, author: "reviewer",
                    body: "Please cover the moved-page case.", diff: [], replies: 0, url: nil
                ),
            ],
            failingChecks: [PullDetail.FailingCheck(
                name: "lint",
                summary: "docs/redirects.md:41 line too long",
                url: nil
            )],
            checks: CheckSummary(passed: 3, failed: 1, pending: 1, failedNames: ["lint"]),
            closes: [PullRef(repo: docsToolkit, number: 2830)], fetchedAt: Clock.now
        )
        detail.state = "OPEN"
        detail.isDraft = false
        detail.mergeable = "MERGEABLE"
        detail.mergeState = "BLOCKED"
        detail.reviewDecision = "CHANGES_REQUESTED"
        detail.requiredChecks = ["build", "lint"]
        detail.repoAllowsAutoMerge = true
        detail.repoMergeMethods = ["squash"]
        // The companion change links here (yours, tracked); someone's docs PR mentions it (suggested, not tracked).
        detail.references = [
            PullDetail.Reference(
                ref: PullRef(repo: docsWebsite, number: 1920), title: "Redirects for moved pages", author: "you",
                state: "OPEN", createdAt: Clock.now.addingTimeInterval(-3 * 3600)
            ),
            PullDetail.Reference(
                ref: PullRef(repo: docsWebsite, number: 1934), title: "Document anchor redirects",
                author: "docs-writer", state: "OPEN", createdAt: Clock.now.addingTimeInterval(-50 * 60)
            ),
        ]
        detail.autoMergeEnabled = false
        return detail
    }()

    /// The other PRs' details, one per green verdict: docs-website#1920 green, editor-rules#412 conflicting.
    static let otherDetails: [PullDetail] = {
        func detail(
            _ repo: Repo, _ number: Int, _ title: String, _ branch: String, mergeable: String, state: String,
            checks: CheckSummary, review: String?
        ) -> PullDetail {
            var detail = PullDetail(
                ref: PullRef(repo: repo, number: number), title: title, body: "", author: "you", baseBranch: "main",
                headBranch: branch, additions: 20, deletions: 3, commitCount: 1, headSHA: "b\(number)",
                reviews: review.map { [PullDetail.Review(author: "reviewer", state: $0)] } ?? [], threads: [],
                failingChecks: [], checks: checks, closes: [], fetchedAt: Clock.now
            )
            detail.state = "OPEN"
            detail.isDraft = false
            detail.mergeable = mergeable
            detail.mergeState = state
            detail.reviewDecision = review
            detail.requiredChecks = ["build"]
            detail.repoAllowsAutoMerge = true
            detail.repoMergeMethods = ["squash", "merge"]
            // The green one is waiting on GitHub's auto-merge (the fixture never merges).
            detail.autoMergeEnabled = state == "CLEAN"
            detail.autoMergeMethod = state == "CLEAN" ? "squash" : nil
            return detail
        }
        return [
            detail(
                docsWebsite,
                1920,
                "Redirects for moved pages",
                "fix-anchors-redirects",
                mergeable: "MERGEABLE",
                state: "CLEAN",
                checks: CheckSummary(passed: 4),
                review: nil
            ),
            detail(
                editorRules,
                412,
                "Bump spec tests to 0.17",
                "bump-spec-tests",
                mergeable: "CONFLICTING",
                state: "DIRTY",
                checks: CheckSummary(passed: 3),
                review: "APPROVED"
            ),
            // Ready to merge while get it merged is off: green, no review required, quiet for hours.
            {
                var ready = detail(
                    ingest, 31, "Backpressure for the ingest stage", "ingest-backpressure", mergeable: "MERGEABLE",
                    state: "CLEAN", checks: CheckSummary(passed: 2), review: nil
                )
                ready.autoMergeEnabled = false
                ready.autoMergeMethod = nil
                ready.labels = []
                ready.headCommittedAt = Clock.now.addingTimeInterval(-3 * 3600)
                ready.viewerPermission = "WRITE"
                return ready
            }(),
            // markgraph sets merge = "auto", but the repo does not allow GitHub's auto-merge: misconfigured.
            {
                var arrows = detail(
                    markgraph, 418, "Arrowheads at small zoom", "sequence-arrowheads", mergeable: "MERGEABLE",
                    state: "BLOCKED", checks: CheckSummary(passed: 5), review: "REVIEW_REQUIRED"
                )
                arrows.threads = [ReviewThread(
                    id: "A1", isResolved: false, path: "Arrow.cs", line: 57, author: "reviewer",
                    body: "Arrowheads still detach below 50% zoom.", diff: [], replies: 0, url: nil
                )]
                arrows.repoAllowsAutoMerge = false
                arrows.autoMergeEnabled = false
                arrows.autoMergeMethod = nil
                arrows.viewerPermission = "WRITE"
                return arrows
            }(),
        ]
    }()

    /// design/screens/Inbox.png and PRs.png.
    static let github: GitHubState = {
        let now = Clock.now
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func pull(
            _ repo: Repo, _ number: Int, _ title: String, _ branch: String, _ checks: CheckSummary,
            _ review: ReviewDecision?, threads: Int = 0
        ) -> PullRequest {
            PullRequest(
                ref: PullRef(repo: repo, number: number), title: title, url: PullRef(repo: repo, number: number).url,
                state: .open, isDraft: false, headBranch: branch, review: review, checks: checks,
                unresolvedThreads: threads, updatedAt: ago(Double(number % 60))
            )
        }
        let inbox = [
            InboxItem(
                id: "n1",
                kind: .pr,
                repo: docsToolkit,
                number: 2845,
                title: "Add link validation to assembler",
                reason: "review_requested",
                unread: true,
                updatedAt: ago(4),
                url: nil
            ),
            InboxItem(
                id: "n2",
                kind: .ci,
                repo: docsToolkit,
                number: nil,
                title: "lint failed on #2841",
                reason: "ci_activity",
                unread: true,
                updatedAt: ago(9),
                url: nil
            ),
            InboxItem(
                id: "n3",
                kind: .pr,
                repo: docsWebsite,
                number: 1920,
                title: "2 new review comments",
                reason: "comment",
                unread: true,
                updatedAt: ago(12),
                url: nil
            ),
            InboxItem(
                id: "n4",
                kind: .issue,
                repo: docsToolkit,
                number: 2830,
                title: "Anchors lost when a page is moved",
                reason: "assign",
                unread: true,
                updatedAt: ago(60),
                url: nil
            ),
            InboxItem(
                id: "n5",
                kind: .issue,
                repo: docsToolkit,
                number: 2833,
                title: "Redirect loop on /reference",
                reason: "mention",
                unread: true,
                updatedAt: ago(120),
                url: nil
            ),
            InboxItem(
                id: "n6",
                kind: .pr,
                repo: markgraph,
                number: 187,
                title: "Arrowhead markers on sequence diagrams",
                reason: "review_requested",
                unread: true,
                updatedAt: ago(180),
                url: nil
            ),
            InboxItem(
                id: "n7",
                kind: .issue,
                repo: ingest,
                number: 94,
                title: "Backpressure drops events under burst",
                reason: "assign",
                unread: true,
                updatedAt: ago(300),
                url: nil
            ),
        ]
        let issues = [
            Issue(
                repo: docsToolkit,
                number: 2830,
                title: "Anchors lost when a page is moved",
                url: "",
                body: "Moving a page drops its heading anchors from redirects.",
                labels: ["bug"],
                author: "reviewer",
                updatedAt: ago(60),
                assigned: true
            ),
            Issue(
                repo: docsToolkit,
                number: 2833,
                title: "Redirect loop on /reference",
                url: "",
                body: "/reference redirects to itself after the nav change.",
                labels: ["bug", "redirects"],
                author: "reviewer",
                updatedAt: ago(120),
                mentioned: true
            ),
            Issue(
                repo: ingest,
                number: 94,
                title: "Backpressure drops events under burst",
                url: "",
                body: "Under burst load the stage drops events instead of slowing producers.",
                labels: [],
                author: nil,
                updatedAt: ago(300),
                assigned: true
            ),
            // Shown because docs-toolkit shows all issues, not because it involves you.
            Issue(
                repo: docsToolkit,
                number: 2851,
                title: "Support nested includes in snippets",
                url: "",
                body: "Snippets cannot include other snippets yet.",
                labels: ["enhancement"],
                author: "contributor",
                updatedAt: ago(400)
            ),
            Issue(
                repo: markgraph,
                number: 12,
                title: "Arrow heads render detached at small zoom",
                url: "",
                body: "",
                labels: ["bug"],
                author: "someone",
                updatedAt: ago(900)
            ),
        ]
        let pulls = [
            pull(
                docsToolkit,
                2841,
                "Fix broken anchors in redirects",
                "fix-anchors-redirects",
                CheckSummary(passed: 3, failed: 1, pending: 1, failedNames: ["lint"]),
                .changesRequested,
                threads: 2
            ),
            pull(docsWebsite, 1920, "Redirects for moved pages", "fix-anchors-redirects", CheckSummary(passed: 4), nil),
            // Merged earlier on the same branch: done, its checks as they finished.
            {
                var merged = pull(
                    docsToolkit, 2836, "Redirect checker: first pass", "fix-anchors-redirects",
                    CheckSummary(passed: 4), .approved
                )
                merged.state = .merged
                return merged
            }(),
            pull(
                docsToolkit,
                2838,
                "Cross-link validator for assembler",
                "cross-link-validator",
                // A big matrix, so the check bar shows what it does past 12 checks.
                CheckSummary(passed: 38, pending: 4, skipped: 3),
                nil
            ),
            pull(editorRules, 412, "Bump spec tests to 0.17", "bump-spec-tests", CheckSummary(passed: 3), .approved),
            pull(ingest, 31, "Backpressure for the ingest stage", "ingest-backpressure", CheckSummary(passed: 2), nil),
            pull(
                markgraph, 418, "Arrowheads at small zoom", "sequence-arrowheads", CheckSummary(passed: 5), nil,
                threads: 1
            ),
            pull(docsToolkit, 2852, "Docs nav spike", "docs-nav-spike", CheckSummary(passed: 1, pending: 2), nil),
        ]
        return GitHubState(viewer: "you", inbox: inbox, issues: issues, pulls: pulls, syncedAt: ago(0.3), status: .ok)
    }()

    /// design/screens/History.png: closed sessions over the last week.
    static let history: [HistoryEntry] = {
        let now = Clock.now
        func entry(
            _ title: String, _ repo: Repo, _ agent: String, hoursAgo: Double, minutes: Double, _ outcome: Outcome,
            pr: Int? = nil, tokens: Int = 0, cost: Double? = nil
        ) -> HistoryEntry {
            let closed = now.addingTimeInterval(-hoursAgo * 3600)
            let started = closed.addingTimeInterval(-minutes * 60)
            var session = Session(
                id: "h-\(StartWork.name(for: title))", title: title,
                prompt: "\(title). Keep the change small and add a test.",
                repos: [repo], branch: StartWork.name(for: title), agent: agent,
                agentSessionID: "b36c9d71-04fa-42e8-8a3d-7e1c5b2f9d60", state: ObservedState(.done),
                trackedPRs: pr.map { [PullRef(repo: repo, number: $0)] } ?? [], lastActivity: closed, createdAt: started
            )
            session.record("started · \(agent) · 2 panes", at: started)
            if let pr { session.record("opened PR #\(pr)", at: started.addingTimeInterval(minutes * 30)) }
            session.record("ended after \(Int(minutes / 60))h \(Int(minutes) % 60)m", at: closed)
            // What its agent reported it used: claude reports a cost, opencode none.
            if tokens > 0 {
                session.usage = AgentUsage(
                    model: agent == "claude" ? "model-a" : "model-o",
                    tokens: TokenCounts(input: tokens * 3 / 10, output: tokens / 10, cacheRead: tokens * 6 / 10),
                    costUSD: cost
                )
            }
            return HistoryEntry(session: session, closedAt: closed, outcome: outcome)
        }
        return [
            entry(
                "Fix toc ordering", docsToolkit, "claude", hoursAgo: 1, minutes: 130, .merged, pr: 2810,
                tokens: 129_100, cost: 0.61
            ),
            entry(
                "Fix redirect typos", docsWebsite, "claude", hoursAgo: 3, minutes: 41, .merged, pr: 1912,
                tokens: 38000, cost: 0.17
            ),
            entry(
                "Bump spec tests to 0.17", editorRules, "claude", hoursAgo: 26, minutes: 65, .merged, pr: 412,
                tokens: 52000, cost: 0.24
            ),
            entry(
                "Flowchart label wrapping", markgraph, "opencode", hoursAgo: 28, minutes: 26, .abandoned, tokens: 21000
            ),
            entry(
                "Docs nav spike v1", docsToolkit, "opencode", hoursAgo: 30, minutes: 220, .closed, pr: 2790,
                tokens: 64000
            ),
            entry("Snippet include performance", docsToolkit, "claude", hoursAgo: 120, minutes: 175, .merged, pr: 2781),
            entry("Parser fuzzing harness", markgraph, "claude", hoursAgo: 130, minutes: 90, .cleanedUp),
        ]
    }()

    private static func tabs(for session: Session, root: String) -> [PaneTab] {
        let directory = "\(root)/wt/\(session.repos[0].name)/\(session.branch)"
        let agent = PaneSpec(
            id: "\(session.id)-agent", role: .agent, title: session.agent, directory: directory,
            command: ShellCommand(words: [.raw(session.agent)])
        )
        let shell = PaneSpec(
            id: "\(session.id)-shell", role: .shell, title: "zsh \(session.branch)", directory: directory
        )
        var main = PaneTab(id: "\(session.id)-t1", title: "agent", tree: .leaf(agent))
        main.split(.horizontal, with: shell)
        main.focused = agent.id
        let tests = PaneSpec(
            id: "\(session.id)-tests", role: .task, title: "tests", directory: directory,
            command: ShellCommand(line: "dotnet watch test")
        )
        return [
            main,
            PaneTab(id: "\(session.id)-t2", title: "shell", tree: .leaf(PaneSpec(
                id: "\(session.id)-zsh", role: .shell, title: "zsh", directory: directory
            ))),
            PaneTab(id: "\(session.id)-t3", title: "tests", tree: .leaf(tests)),
        ]
    }

    /// Settings › Agents › Local decisions in the fake world: invented counts of screen snapshots kept.
    public static func screenCounts(now: Date, calendar: Calendar = .current) -> ScreenSnapshotCounts {
        let labelled: [(String, AgentState, Int)] = [
            ("claude", .asking, 17), ("claude", .blocked, 38), ("claude", .done, 64), ("claude", .idle, 41),
            ("claude", .working, 112), ("codex", .blocked, 12), ("codex", .done, 22), ("codex", .idle, 20),
            ("codex", .working, 46), ("opencode", .asking, 3), ("opencode", .done, 5), ("opencode", .working, 9),
        ]
        let perDay = [31, 48, 0, 0, 57, 62, 19]
        return ScreenSnapshotCounts(
            labelled: labelled.map { ScreenSnapshotCounts.Labelled(agent: $0, state: $1, count: $2) },
            unlabelled: 27, total: labelled.map(\.2).reduce(0, +) + 27,
            days: zip(ScreenSnapshotCounts.lastWeek(now: now, calendar: calendar), perDay)
                .map { ScreenSnapshotCounts.Day(day: $0, count: $1) },
            bytes: 1_240_000
        )
    }
}
