import Foundation
@testable import HeedCore
import Testing

/// VISUAL's worktree keys act on worktrees, in Repos only.
struct VisualSelectGuardTests {
    private static let commands = ["select.remove", "select.open", "select.pin", "select.copy"]

    @Test func reposKeepsEveryCommand() {
        for command in Self.commands {
            #expect(VisualSelectGuard.decide(command: command, view: "repos") == .run, "\(command)")
        }
    }

    @Test func noOtherListEverRunsAWorktreeCommand() {
        for view in ["browse", "attention", "prs", "watch", "sessions", "goals", "history"] {
            for command in Self.commands {
                #expect(VisualSelectGuard.decide(command: command, view: view) != .run, "\(command) in \(view)")
            }
        }
    }

    @Test func browseOpensItsPicksOnGitHubAndSaysThePinAndRemoveDoNothing() {
        #expect(VisualSelectGuard.decide(command: "select.open", view: "browse") == .openOnGitHub)
        for command in ["select.remove", "select.pin"] {
            guard case let .say(text) = VisualSelectGuard.decide(command: command, view: "browse") else {
                Issue.record("no message for \(command)")
                continue
            }
            #expect(text.contains("does nothing in Browse"))
        }
    }

    @Test func otherListsSayWhereTheCommandWorks() {
        #expect(VisualSelectGuard
            .decide(command: "select.remove", view: "attention") == .say("select.remove works in Repos"))
    }

    @Test func theStatusLineCountsThePicksOfTheListYouAreIn() {
        #expect(
            VisualSelectGuard.hint(view: "browse", selected: 3, open: "o", copy: "y")
                == "3 selected · space toggle · o open on GitHub · y copy link · ⎋ cancel"
        )
        #expect(VisualSelectGuard.hint(view: "attention", selected: 2, open: nil, copy: nil)?
            .hasPrefix("2 selected") == true)
        #expect(VisualSelectGuard.hint(view: "repos", selected: 2, open: nil, copy: nil) == nil)
    }
}
