import Foundation

/// The anchors swarm landing, and landed: every task has its PR; the merge order is 1.1, 1.2, 2.1, 2.2; the two PRs
/// stacked on 1.1's are held until it merges, then move to main. Invented, as every fixture is.
extension SwarmFixtures {
    static func landed(_ variant: Running, now: Date) -> RunningWorld {
        let base = now.timeIntervalSince1970.rounded(.down)
        func ago(_ hours: Double) -> Date { Date(timeIntervalSince1970: base - hours * 3600) }
        let goal = anchors
        let done = variant == .done
        var swarm = approved(ago).swarm
        let toolkit = Repo(org: "acme", name: "docs-toolkit")
        func branch(_ slug: String) -> String { SwarmWork.branch(goal: goal, slug: slug) }
        func worker(
            _ slug: String, _ owner: GoalItem.Owner, stackedOn: String? = nil, started: Double, ended: Double,
            cost: Double
        ) -> SwarmWorker {
            // Once done, the stacked ones went to main when 1.1 merged.
            let stacked = done ? nil : stackedOn
            return SwarmWorker(
                id: "fixture-\(slug)", task: "\(goal)/\(slug)", owner: owner, host: "s2", repo: toolkit.slug,
                branch: branch(slug), base: stacked.map(branch) ?? "main", stackedOn: stacked.map { "\(goal)/\($0)" },
                worktree: "/Users/you/code/wt/heed/docs-toolkit/swarm-\(goal)-\(slug)", startedAt: ago(started),
                endedAt: ago(ended), outcome: .turnOver, costUSD: cost
            )
        }
        let claude = GoalItem.Owner(agent: "claude")
        swarm.status = done ? .done : .landing
        swarm.runningAt = ago(3.2)
        swarm.endedAt = done ? ago(0.1) : nil
        swarm.workers = [
            worker("heading-ids", claude, started: 3.2, ended: 2.6, cost: 2.4),
            worker("assembly-redirects", GoalItem.Owner(agent: "codex"), started: 3.2, ended: 2.2, cost: 1.9),
            worker(
                "validator-speed", GoalItem.Owner(agent: "claude", model: "opus"), stackedOn: "heading-ids",
                started: 2.4, ended: 1.1, cost: 4.2
            ),
            worker("sample-site", claude, stackedOn: "heading-ids", started: 2.0, ended: 1.3, cost: 2.1),
        ]
        let id = swarm.id
        func row(
            _ hours: Double, _ kind: SwarmSteer.Kind, _ text: String, reason: String? = nil, task: String? = nil
        ) -> SwarmSteer {
            SwarmSteer(
                swarm: id, goal: goal, at: ago(hours), actor: .heed, kind: kind, text: text, reason: reason,
                ref: task.map { "task:\(goal)/\($0)" }
            )
        }
        let stacked = "stacked on 1.1's PR"
        var steering = [
            row(3.2, .start, "Running: workers start on plan v3"),
            row(3.2, .work, "1.1 Anchor ids from heading text: claude from main", task: "heading-ids"),
            row(3.2, .work, "1.2 Redirects for moved assemblies: codex from main", task: "assembly-redirects"),
            row(
                2.4,
                .work,
                "2.2 Validator speed on a 10k-page site: claude · opus \(stacked)",
                task: "validator-speed"
            ),
            row(2.0, .work, "2.1 Sample site with moved pages: claude \(stacked)", task: "sample-site"),
            row(1.1, .land, "Landing: every task has its PR"),
        ]
        if done {
            let why = "its branch is rebased there by a get it green run"
            let from = branch("heading-ids")
            steering += [
                row(
                    0.9,
                    .retarget,
                    "#416 now goes against main: #412 merged (was \(from))",
                    reason: why,
                    task: "sample-site"
                ),
                row(
                    0.9,
                    .retarget,
                    "#415 now goes against main: #412 merged (was \(from))",
                    reason: why,
                    task: "validator-speed"
                ),
                row(
                    0.1, .land, "Done: every task merged, in merge order",
                    reason: "the swarm ends; the goal stays open until its own done rule holds"
                ),
            ]
        }
        func entry(
            _ slug: String, _ kind: GoalEvidence.Kind, _ text: String, source: String, ref: String? = nil,
            hours: Double
        ) -> GoalEvidence {
            GoalEvidence(
                goal: goal, item: "\(goal)/\(slug)", kind: kind, state: .done, at: ago(hours), source: source,
                text: text, ref: ref
            )
        }
        let tasks: [(slug: String, number: Int, title: String, check: String, opened: Double, merged: Double)] = [
            (
                "heading-ids",
                412,
                "Anchor ids from heading text",
                "two headings with the same text get distinct ids",
                2.6,
                0.95
            ),
            (
                "assembly-redirects",
                409,
                "Redirects for moved assemblies",
                "a moved assembly keeps its inbound anchors",
                2.2,
                1.0
            ),
            (
                "sample-site",
                416,
                "Sample site with moved pages",
                "the sample site builds with no broken anchor",
                1.3,
                0.3
            ),
            (
                "validator-speed",
                415,
                "Validator speed on a 10k-page site",
                "the validator checks 10k pages in under a minute",
                1.1,
                0.2
            ),
        ]
        var evidence: [GoalEvidence] = []
        var pulls: [PullRequest] = []
        var details: [PullDetail] = []
        for task in tasks {
            let ref = PullRef(repo: toolkit, number: task.number)
            let merged = done || task.number == 409
            evidence.append(entry(
                task.slug, .pr, "#\(task.number) \(merged ? "merged" : "open")", source: "#\(task.number)",
                ref: ref.description, hours: task.opened
            ))
            evidence.append(entry(
                task.slug, .criterion, task.check, source: "swarm worker on \(task.slug)", hours: task.opened
            ))
            if merged {
                evidence.append(entry(
                    task.slug, .merged, "#\(task.number) merged", source: "#\(task.number)", ref: ref.description,
                    hours: task.merged
                ))
            }
            // 2.1's checks still run; the rest pass.
            let running = !done && task.number == 416
            let checks = running ? CheckSummary(passed: 4, pending: 2) : CheckSummary(passed: 6)
            pulls.append(PullRequest(
                ref: ref, title: task.title, url: "https://github.com/\(toolkit.slug)/pull/\(task.number)",
                state: merged ? .merged : .open, isDraft: false, headBranch: branch(task.slug), review: nil,
                checks: checks, unresolvedThreads: 0, updatedAt: ago(merged ? task.merged : 0.5)
            ))
            guard !merged else { continue }
            let stacked = task.slug == "sample-site" || task.slug == "validator-speed"
            var detail = PullDetail(
                ref: ref, title: task.title, body: "", author: "you",
                baseBranch: stacked ? branch("heading-ids") : "main", headBranch: branch(task.slug), additions: 40,
                deletions: 6, commitCount: 2, headSHA: "c\(task.number)", reviews: [], threads: [],
                failingChecks: [], checks: checks, closes: [], fetchedAt: now
            )
            detail.state = "OPEN"
            detail.isDraft = false
            detail.mergeable = "MERGEABLE"
            detail.mergeState = running ? "BLOCKED" : "CLEAN"
            detail.requiredChecks = ["build"]
            detail.repoAllowsAutoMerge = true
            detail.repoMergeMethods = ["squash", "merge"]
            detail.autoMergeEnabled = false
            if running { detail.checks = CheckSummary(passed: 4, pending: 2, pendingNames: ["build", "test"]) }
            details.append(detail)
        }
        return RunningWorld(swarm: swarm, steering: steering, evidence: evidence, pulls: pulls, details: details)
    }
}
