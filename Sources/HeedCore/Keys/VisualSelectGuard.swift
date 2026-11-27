import Foundation

/// VISUAL's `d`, `o`, `m` and `y` (`select.remove`, `select.open`, `select.pin`, `select.copy`) were written for Repos'
/// worktree rows, but VISUAL is also entered in Browse, Attention, PRs and Watch, where the same keys read the Repos
/// cursor. What each does where it is pressed.
public enum VisualSelectGuard {
    public enum Decision: Equatable, Sendable {
        /// Repos: the command as it always was.
        case run
        /// Browse's `o`: the picked items open on GitHub.
        case openOnGitHub
        /// Say this, and do nothing else.
        case say(String)
    }

    /// `view` is the `AppView` raw value ("repos", "browse", ...).
    public static func decide(command: String, view: String) -> Decision {
        guard view != "repos" else { return .run }
        let word = switch command {
        case "select.remove": "d"
        case "select.open": "o"
        case "select.pin": "m"
        case "select.copy": "y"
        default: command
        }
        if view == "browse" {
            switch command {
            case "select.open": return .openOnGitHub
            case "select.remove", "select.pin": return .say("\(word) does nothing in Browse: it works on worktrees, in Repos")
            default: break
            }
        }
        return .say("\(command) works in Repos")
    }

    /// The status line while VISUAL is on in a list that is not Repos.
    public static func hint(view: String, selected: Int, open: String?, copy: String?) -> String? {
        switch view {
        case "browse":
            var parts = ["\(selected) selected", "space toggle"]
            if let open { parts.append("\(open) open on GitHub") }
            if let copy { parts.append("\(copy) copy link") }
            return (parts + ["⎋ cancel"]).joined(separator: " · ")
        case "attention":
            return "\(selected) selected · space toggle · ⎋ cancel"
        default:
            return nil
        }
    }
}
