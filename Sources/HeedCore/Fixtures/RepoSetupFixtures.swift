import Foundation

/// The setup wizard's sample in the fake world: invented PRs, reviewers and CI runs, the same for every run, so
/// snapshots, the tutor and previews never reach GitHub.
public enum RepoSetupFixtures {
    public static func sample(for repo: Repo, runs: [PilotRun] = [], now: Date = Clock.now) -> RepoSetupSample {
        let settings = RepoMergeSettings(
            defaultBranch: "main", repoMethods: ["squash", "rebase"], autoMergeAllowed: false,
            deleteBranchOnMerge: true, viewerPermission: "ADMIN", requiredChecks: ["build", "lint"],
            requiredApprovals: 1, strictChecks: true, copilotReview: true, hasCodeowners: true
        )
        let people = ["ana-k", "bo-lind", "chen-w", "dara"]
        let reviewer = "copilot-pull-request-reviewer"
        var pulls: [SampledPull] = []
        for index in 0 ..< 30 {
            let merged = now.addingTimeInterval(-Double(index) * 5 * 3600 - 1800)
            let head = String(format: "%07x", 0xA1B2C3 + index * 977)
            let committed = merged.addingTimeInterval(-Double(12 + index % 7 * 5) * 60)
            let author = index % 10 == 9 ? "deps-bot[bot]" : people[index % people.count]
            var reviews: [PullDetail.Review] = []
            var bots: Set<String> = []
            if index % 3 != 2 {
                bots.insert(reviewer)
                reviews.append(.init(
                    author: reviewer, state: "COMMENTED", submittedAt: committed.addingTimeInterval(120), commit: head
                ))
            }
            // Most are approved on their head commit; a few only before their last push, one never.
            let approver = people[(index + 1) % people.count]
            if index % 11 == 4 {
                reviews.append(.init(
                    author: approver, state: "APPROVED", submittedAt: committed.addingTimeInterval(-600), commit: "0ld"
                ))
            } else if index != 17 {
                reviews.append(.init(
                    author: approver, state: "APPROVED",
                    submittedAt: merged.addingTimeInterval(-Double(4 + index % 5 * 3) * 60),
                    commit: head
                ))
            }
            var passed = ["build", "lint"]
            if index != 6 { passed.append("docs") }
            if index % 8 != 3 { passed.append("preview") }
            pulls.append(SampledPull(
                number: 2840 - index * 3, title: titles[index % titles.count], author: author,
                authorIsBot: author.hasSuffix("[bot]"), mergedBy: people[(index + 2) % people.count],
                createdAt: merged.addingTimeInterval(-Double(1 + index % 4) * 86400), mergedAt: merged,
                labels: index % 5 == 0 ? ["docs"] : [],
                removedBeforeMerge: index == 3 || index == 12 ? ["wip"] : index == 8 || index == 21 ? ["needs-design"] :
                    [],
                parents: 1, commits: 1 + index % 4, reviews: reviews, botReviewers: bots, headSHA: head,
                headCommittedAt: committed, passedChecks: passed
            ))
        }
        let failures: [CIHistory.Failure] =
            Array(
                repeating: CIHistory.Failure(workflow: "CI", job: "lint", step: "swiftformat --lint", kind: .lint),
                count: 5
            )
            + Array(
                repeating: CIHistory.Failure(workflow: "CI", job: "test", step: "swift test", kind: .test),
                count: 3
            )
            + [CIHistory.Failure(workflow: "Docs", job: "docs", kind: .infra)]
        let tasks = [
            TaskSpec(name: "lint", command: "mise run lint", source: .mise),
            TaskSpec(name: "fmt", command: "mise run fmt", source: .mise),
            TaskSpec(name: "test", command: "mise run test", source: .mise),
        ]
        return RepoSetupSample(
            repo: repo, settings: settings, pulls: pulls,
            ci: CIHistory(
                runs: 100, flaky: [CIHistory.Flaky(workflow: "Tests", retried: 4, runs: 61)], failures: failures
            ),
            runs: runs.filter { $0.ref.repo == repo }, tasks: tasks, calls: 27, cost: 18
        )
    }

    static let titles = [
        "Fix broken anchors in redirects", "Bump the spec tests", "Render tables with merged cells",
        "Faster link checker", "Drop the old theme switcher", "Add a print stylesheet", "Tidy the sidebar order",
    ]
}
