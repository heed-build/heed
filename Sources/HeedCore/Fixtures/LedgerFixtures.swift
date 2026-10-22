import Foundation

public extension Fixtures {
    /// History's ledger in the fake world: entries for the main fixture's sessions and history, as a cheap model would
    /// have written them. Every name, number and sentence is invented.
    static var ledger: [LedgerEntry] {
        let now = Clock.now
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        // What the agents reported, as the fake world's sessions hold it: the same numbers the dashboard sums.
        let world = Fixtures.main.sessions + Fixtures.main.history.map(\.session)
        func usage(_ id: String) -> AgentUsage? { world.first { $0.id == id }?.usage }
        let builder = docsBuilder.slug
        let entries = [
            LedgerEntry(
                id: "s1", title: "Fix broken anchors in redirects", repos: [builder, docsContent.slug],
                branch: "fix-anchors-redirects", agent: "claude", startedAt: ago(6.3), outcome: "PR open",
                pulls: [PullRef(repo: docsBuilder, number: 2841)],
                diff: DiffStat(files: 9, added: 212, removed: 38),
                files: [
                    "src/Redirects/RedirectMap.cs", "src/Redirects/AnchorCheck.cs", "tests/RedirectTests.cs",
                    "src/Redirects/RedirectFile.cs", "src/Build/BuildContext.cs", "docs/redirects.md",
                    "tests/Fixtures/redirects.yml", "src/Redirects/AnchorIndex.cs", "CHANGELOG.md",
                ],
                agentTime: 3 * 3600 + 12 * 60,
                summary: "Redirect targets are now checked against the headings they point at; a failing test names "
                    + "the redirect and the missing anchor. The redirect map is generated at build time. Two review "
                    + "rounds, both addressed; waiting on the last approval.",
                decisions: [
                    "Generate the redirect map at build time, not checked in",
                    "Check anchors in a pass of their own so errors batch",
                ],
                followUps: ["Moved-page redirects in docs-content (#1920)"],
                source: .model, trigger: "PR opened", summarizedAt: ago(4.1)
            ),
            LedgerEntry(
                id: "h-fix-toc-ordering", title: "Fix toc ordering", repos: [builder], branch: "fix-toc-ordering",
                agent: "claude", startedAt: ago(3.2), endedAt: ago(1), outcome: "merged",
                pulls: [PullRef(repo: docsBuilder, number: 2810)], diff: DiffStat(files: 3, added: 46, removed: 12),
                files: ["src/Navigation/TocBuilder.cs", "tests/TocTests.cs", "docs/navigation.md"], agentTime: 104 * 60,

                summary: "Table of contents entries keep the order of the folder's index file instead of sorting by "
                    + "title. Merged after one review.",
                decisions: ["Fall back to title order when a folder has no index"],
                source: .model, trigger: "PR merged", summarizedAt: ago(1)
            ),
            LedgerEntry(
                id: "h-bump-spec-tests-0-17", title: "Bump spec tests to 0.17", repos: [editorconfig.slug],
                branch: "bump-spec-tests-0-17", agent: "claude", startedAt: ago(27.1), endedAt: ago(26),
                outcome: "merged", pulls: [PullRef(repo: editorconfig, number: 412)],
                diff: DiffStat(files: 4, added: 30, removed: 30), agentTime: 41 * 60,
                summary: "Spec tests moved to 0.17; two cases were renamed upstream and are renamed here too.",
                source: .model, trigger: "PR merged", summarizedAt: ago(26)
            ),
            LedgerEntry(
                id: "h-flowchart-label-wrapping", title: "Flowchart label wrapping", repos: [mermaider.slug],
                branch: "flowchart-label-wrapping", agent: "opencode", startedAt: ago(28.4), endedAt: ago(28),
                outcome: "abandoned", diff: DiffStat(files: 2, added: 88, removed: 5),
                files: ["src/layout/labels.ts", "src/layout/labels.test.ts"], agentTime: 19 * 60,
                agentTimeEstimated: true,
                summary: "Tried wrapping long flowchart labels at word boundaries in the layout pass. Wrapping before "
                    + "measuring broke edge routing; left unfinished, the work saved before the worktree was removed.",
                followUps: ["Measure labels after wrapping, not before"],
                source: .model, trigger: "worktree removed", summarizedAt: ago(28)
            ),
            LedgerEntry(
                id: "h-docs-nav-spike-v1", title: "Docs nav spike v1", repos: [builder], branch: "docs-nav-spike-v1",
                agent: "opencode", startedAt: ago(33.7), endedAt: ago(30), outcome: "closed",
                pulls: [PullRef(repo: docsBuilder, number: 2790)], agentTime: 2 * 3600 + 5 * 60,
                agentTimeEstimated: true,
                summary: "A flat navigation model for the docs tree. Slower than the tree on large sites; the PR was "
                    + "closed. Sibling ordering needs a stable key either way.",
                decisions: ["Keep the tree model"],
                source: .edited, trigger: "on demand", summarizedAt: ago(29)
            ),
        ]
        return entries.map { entry in
            var entry = entry
            entry.usage = usage(entry.id)
            return entry
        }
    }
}
