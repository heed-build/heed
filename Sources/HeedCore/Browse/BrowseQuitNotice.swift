import Foundation

/// What quitting says about Browse's agent runs: they stop with the app, and what they leave is kept.
public enum BrowseQuitNotice {
    /// The lines for the quit confirmation: which runs are live, and that unpushed work stays in its worktree. Empty
    /// when no run is live (a closed or failed one is not running anything).
    public static func lines(for runs: [BrowseRun]) -> [String] {
        let live = runs.filter(\.isLive)
        guard !live.isEmpty else { return [] }
        let count = live.count
        var lines = ["\(count) Browse agent run\(count == 1 ? " is" : "s are") live and will stop"]
        lines += live.prefix(5).map { "\($0.verb.title) \($0.repo.slug)#\($0.number) · \($0.phase.text)" }
        if count > 5 { lines.append("and \(count - 5) more") }
        lines.append("Unpushed work is kept in its worktree")
        return lines
    }
}
