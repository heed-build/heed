import Foundation

public extension Fixtures {
    /// History's timeline in the fake world: the main fixture's sessions and history as two days of the event log
    /// would hold them. Every name, path and number is invented.
    static var events: [LoggedEvent] {
        let now = Clock.now
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let wt = "/Users/you/code/wt"
        func event(
            _ minutes: Double, _ kind: EventKind, session: String? = nil, repo: Repo? = nil, host: String? = nil,
            worktree: String? = nil, subject: String? = nil, text: String = "", guessed: Bool = false,
            payload: [String: String] = [:]
        ) -> LoggedEvent {
            LoggedEvent(
                at: ago(minutes), kind: kind, session: session, repo: repo?.slug, host: host, worktree: worktree,
                subject: subject, text: text, guessed: guessed, payload: payload
            )
        }
        func state(_ minutes: Double, _ session: String, _ state: AgentState, guessed: Bool = false) -> LoggedEvent {
            event(minutes, .state, session: session, guessed: guessed, payload: ["state": state.rawValue])
        }
        /// A session from start to end: its worktree made, worked in, its PR, and what became of it.
        func life(
            _ id: String, _ repo: Repo, branch: String, startedAgo: Double, endedAgo: Double?, outcome: String?,
            pr: Int? = nil, removed: Bool = true, saved: String? = nil, host: String? = nil
        ) -> [LoggedEvent] {
            let path = host == nil ? "\(wt)/\(repo.name)/\(branch)" : "/home/you/code/wt/\(branch)"
            var events = [
                event(startedAgo, .sessionStarted, session: id, repo: repo, host: host, worktree: path),
                event(
                    startedAgo - 0.1,
                    .worktreeCreated,
                    repo: repo,
                    host: host,
                    worktree: path,
                    subject: path,
                    text: branch
                ),
                state(startedAgo - 0.5, id, .working),
                state(startedAgo * 0.6 + (endedAgo ?? 0) * 0.4, id, .idle),
                state(startedAgo * 0.5 + (endedAgo ?? 0) * 0.5, id, .working),
                state(startedAgo * 0.2 + (endedAgo ?? 0) * 0.8, id, .done),
            ]
            if let pr {
                events.append(event(
                    startedAgo * 0.3 + (endedAgo ?? 0) * 0.7, .pullTracked, session: id, repo: repo, host: host,
                    subject: "\(repo.slug)#\(pr)"
                ))
            }
            guard let endedAgo, let outcome else { return events }
            if outcome == "merged", let pr {
                events.append(event(
                    endedAgo + 2,
                    .pullMerged,
                    session: id,
                    repo: repo,
                    subject: "\(repo.slug)#\(pr)",
                    text: "merged"
                ))
            }
            events.append(event(endedAgo, .sessionClosed, session: id, repo: repo, host: host, text: outcome))
            if removed {
                if let saved {
                    events.append(event(
                        endedAgo - 0.5, .worktreeArchived, repo: repo, host: host, subject: "heed/archive/\(branch)",
                        text: saved, payload: ["commit": "4e1f0a2", "unpushed": "2"]
                    ))
                }
                events.append(event(
                    endedAgo - 0.6,
                    .worktreeRemoved,
                    repo: repo,
                    host: host,
                    worktree: path,
                    subject: path,
                    text: branch
                ))
            }
            return events
        }
        var events: [LoggedEvent] = []
        // Today.
        events += life(
            "s1",
            docsBuilder,
            branch: "fix-anchors-redirects",
            startedAgo: 380,
            endedAgo: nil,
            outcome: nil,
            pr: 2841
        )
        events += life(
            "h-fix-toc-ordering",
            docsBuilder,
            branch: "fix-toc-ordering",
            startedAgo: 190,
            endedAgo: 60,
            outcome: "merged",
            pr: 2810
        )
        events += life(
            "h-fix-redirect-typos",
            docsContent,
            branch: "fix-redirect-typos",
            startedAgo: 221,
            endedAgo: 180,
            outcome: "merged",
            pr: 1912
        )
        events.append(event(95, .sessionParked, session: "s6", repo: docsBuilder))
        events.append(event(14, .questionAnswered, session: "s2", repo: docsBuilder))
        events.append(event(
            145,
            .sessionStarted,
            session: "h-chat-csv",
            text: "Compare two CSV exports",
            payload: ["agent": "claude", "chat": "scratch"]
        ))
        events.append(event(120, .sessionClosed, session: "h-chat-csv", text: "closed"))
        // Yesterday.
        events += life(
            "h-bump-spec-tests-0-17",
            editorconfig,
            branch: "bump-spec-tests-0-17",
            startedAgo: 26 * 60 + 65,
            endedAgo: 26 * 60,
            outcome: "merged",
            pr: 412
        )
        events += life(
            "h-flowchart-label-wrapping", mermaider, branch: "flowchart-label-wrapping", startedAgo: 28 * 60 + 26,
            endedAgo: 28 * 60, outcome: "abandoned",
            saved: "saved 2 unpushed commits and uncommitted changes as heed/archive/flowchart-label-wrapping"
        )
        events += life(
            "s7",
            docsBuilder,
            branch: "flake-hunt",
            startedAgo: 29 * 60,
            endedAgo: nil,
            outcome: nil,
            host: "devbox"
        )
        events += life(
            "h-docs-nav-spike-v1",
            docsBuilder,
            branch: "docs-nav-spike-v1",
            startedAgo: 30 * 60 + 220,
            endedAgo: 30 * 60,
            outcome: "closed",
            pr: 2790
        )
        return events.sorted { $0.at > $1.at }
    }
}
