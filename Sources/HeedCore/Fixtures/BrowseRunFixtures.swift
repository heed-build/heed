import Foundation

public extension Fixtures.Browse {
    /// A scripted agent for the fake world: what an agent run on an item reports, in the order it would, with no IO.
    /// The fiction is one bug in an anchor map; the numbers follow the item.
    enum FakeAgent {
        public static let suffix = "4f9c2e"

        /// What a run's worktree is called in the fake world.
        public static func worktree(for item: BrowseItem) -> (name: String, branch: String, path: String) {
            let name = BrowseWorktree.name(item.kind, number: item.number, suffix: suffix)
            return (
                name, BrowseWorktree.branch(named: name),
                BrowseWorktree.path(root: "~/code/wt", repo: item.repo, name: name)
            )
        }

        public static func run(
            _ item: BrowseItem, verb: BrowseVerb, phase: BrowseRun.Phase = .working, mode: BrowseRun.Mode = .full,
            playing steps: Int? = nil, now: Date = Clock.now
        ) -> BrowseRun {
            let place = worktree(for: item)
            var run = BrowseRun(
                item: item, verb: verb, mode: mode, agent: "claude", adapter: "claude via ACP", name: place.name,
                branch: place.branch, worktree: place.path, phase: phase, startedAt: now, cap: 0.5
            )
            run.said(BrowseRun.youSaid(verb, item), at: now)
            let all = updates(verb, item: item)
            for update in all.prefix(steps ?? all.count) {
                run.apply(update, at: now)
            }
            if verb == .review, steps == nil, let message = lastMessage(verb, item) { run.drafted(from: message) }
            return run
        }

        static func lastMessage(_ verb: BrowseVerb, _: BrowseItem) -> String? {
            guard verb == .review else { return nil }
            return """
            The change does what it says. One snapshot moved for a real reason, and nothing else changed.
            heed-did: read the diff against the spec-test fixtures
            heed-did: ran the suite, 212 pass
            heed-comment fixtures/anchor-fold.json:18: This snapshot changed meaningfully: the renamed anchor-fold case \
            is the only one that should differ. Worth a line in the changelog.
            heed-verdict: comment
            """
        }

        public static func updates(_ verb: BrowseVerb, item: BrowseItem) -> [ACPUpdate] {
            let number = item.number
            let thread = item.kind == .pull ? "pr" : "issue"
            func call(
                _ id: String, _ title: String, _ kind: ACPToolKind, command: String? = nil, paths: [String]? = nil,
                output: String? = nil, diff: (String, String, String)? = nil
            ) -> [ACPUpdate] {
                var content: [ACPToolContent] = []
                if let output { content.append(.text(output)) }
                if let diff { content.append(.diff(path: diff.0, oldText: diff.1, newText: diff.2)) }
                return [
                    .toolCall(ACPToolCall(
                        id: id,
                        title: title,
                        kind: kind,
                        status: .inProgress,
                        paths: paths,
                        command: command
                    )),
                    .toolCallUpdate(ACPToolCall(id: id, status: .completed, content: content.isEmpty ? nil : content)),
                ]
            }
            let view = call(
                "t1", "gh \(thread) view \(number) --comments", .execute,
                command: "gh \(thread) view \(number) --repo \(item.repo.slug) --comments"
            )
            switch verb {
            case .chat:
                return view + [
                    .agentMessage(
                        "Reading the anchor map: anchors are keyed by the old path before the redirect resolves, "
                    ),
                ] + call("t2", "Read src/Redirects/AnchorMap.cs", .read, paths: ["src/Redirects/AnchorMap.cs"])
                    +
                    [
                        .agentMessage(
                            "so a moved page loses its fragments. I would key them by the resolved path. Draft reply: “Found it: anchors are keyed before redirects resolve.”"
                        ),
                    ]
            case .review:
                return call(
                    "t1",
                    "gh pr diff \(number)",
                    .execute,
                    command: "gh pr diff \(number) --repo \(item.repo.slug)"
                )
                    + call("t2", "Read fixtures/anchor-fold.json", .read, paths: ["fixtures/anchor-fold.json"])
                    + call("t3", "dotnet test", .execute, command: "dotnet test", output: "(212)")
                    + [.agentMessage(lastMessage(.review, item) ?? "")]
            case .fix, .implement:
                var all = view
                all += [.agentMessage("Reproduced: moving guide/setup.md drops #fragments. New test fails.")]
                all += call(
                    "t2", "Edit src/Redirects/AnchorMap.cs", .edit, paths: ["src/Redirects/AnchorMap.cs"],
                    diff: (
                        "src/Redirects/AnchorMap.cs",
                        "    var key = old.Path;\n",
                        "    var key = Resolve(old.Path);\n    Carry(fragments, key);\n"
                    )
                )
                all += call("t3", "dotnet test", .execute, command: "dotnet test", output: "(212, 1 new)")
                all += call(
                    "t4", "gh issue comment \(number)", .execute,
                    command: "gh issue comment \(number) --body \"Found it: anchors are keyed before redirects resolve.\""
                )
                all += call(
                    "t5", "gh pr create", .execute,
                    command: "gh pr create --title \"Keep anchors when a page moves\" --body \"Closes #\(number)\"",
                    output: "https://github.com/\(item.repo.slug)/pull/\(number + 30)"
                )
                all += call(
                    "t6", "gh issue edit \(number)", .execute, command: "gh issue edit \(number) --add-label has-pr"
                )
                return all
            }
        }
    }
}
