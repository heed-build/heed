import Foundation

/// The one line at the foot of a session's panes while helpers work on its PRs, however many there are:
/// `▶ 3 helpers on this session's PRs · #412 needs your OK · #2841 step 3 of 5 · #1920 paused`. What needs you
/// comes first, then what works, then what waits; a finished run stays on it (`✓ #2841 pushed a3f9c1d · pull before
/// your next change`) until you have seen it: you looked at the session after it finished, or dismissed it.
public struct SessionHelperLine: Hashable, Sendable {
    /// Where a run stands, in the line's order.
    public enum Standing: Int, Hashable, Sendable, Comparable {
        /// It asks permission, or its close-out waits for your OK (done, stopped or failed).
        case needsYou
        case working
        /// Paused: it goes on when you let it.
        case waiting
        /// Closed out: pushed, posted, taken over or thrown away.
        case finished

        public static func < (lhs: Standing, rhs: Standing) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// One run on the line.
    public struct Entry: Hashable, Sendable, Identifiable {
        /// The helper's id.
        public var id: String
        public var number: Int
        public var kind: HelperKind
        public var standing: Standing
        /// `step 3 of 5`, `needs your OK`, `paused`, `pushed a3f9c1d · pull before your next change`.
        public var status: String
        /// `A helper is getting #2841 green`.
        public var headline: String

        /// `#2841 step 3 of 5`, `✓ #2841 pushed a3f9c1d · pull before your next change`.
        public var text: String { (standing == .finished ? "✓ " : "") + "#\(number) \(status)" }
    }

    /// A piece of the line as drawn, with the standing it is coloured by (nil: the line's lead).
    public struct Part: Hashable, Sendable {
        public var text: String
        public var standing: Standing?
    }

    /// The runs, in the line's order.
    public var entries: [Entry]

    /// The line's pieces: with one run, that run (`▶ A helper is getting #2841 green`, `step 3 of 5`); with more,
    /// how many and each run's short state.
    public var parts: [Part] {
        if entries.count == 1, let only = entries.first {
            if only.standing == .finished { return [Part(text: only.text, standing: .finished)] }
            return [Part(text: "▶ " + only.headline, standing: nil), Part(text: only.status, standing: only.standing)]
        }
        let lead = (entries.allSatisfy { $0.standing == .finished } ? "✓ " : "▶ ")
            + "\(entries.count) helpers on this session's PRs"
        return [Part(text: lead, standing: nil)] + entries.map { Part(text: $0.text, standing: $0.standing) }
    }

    /// The whole line, as one string.
    public var text: String { parts.map(\.text).joined(separator: " · ") }

    /// One of its runs waits on you: the line turns amber.
    public var needsYou: Bool { entries.contains { $0.standing == .needsYou } }

    /// Finished runs still on the line.
    public var finished: [Entry] { entries.filter { $0.standing == .finished } }

    /// What changes when a run moves a step, changes standing or finishes: the line is highlighted briefly then.
    public var signature: [String] { entries.map { "\($0.id)|\($0.standing.rawValue)|\($0.status)" } }

    /// The line for a session: the helpers on the PRs it tracks (or started from it), live, waiting for their
    /// close-out, or finished and not seen yet. Nil when there are none. `runs` newest first, as heed keeps them;
    /// within a standing they keep that order. `leftAt`: when you last left the session; `dismissed`: finished
    /// runs you dismissed.
    public static func of(
        _ runs: [HelperRun], tracked: [PullRef], sessionID: String, leftAt: Date?, dismissed: Set<String>
    ) -> SessionHelperLine? {
        let entries = runs.enumerated()
            .filter { _, run in run.sessionID == sessionID || tracked.contains(run.ref) }
            .compactMap { index, run -> (Int, Entry)? in
                let entry = entry(run)
                if entry.standing == .finished,
                   seen(endedAt: run.endedAt, leftAt: leftAt, dismissed: dismissed.contains(run.id))
                {
                    return nil
                }
                return (index, entry)
            }
            .sorted { $0.1.standing == $1.1.standing ? $0.0 < $1.0 : $0.1.standing < $1.1.standing }
            .map(\.1)
        return entries.isEmpty ? nil : SessionHelperLine(entries: entries)
    }

    /// A finished run is seen once you dismissed it, or left the session after it finished (you were on it after
    /// it finished, so you saw the line). A run with no end time is never seen.
    public static func seen(endedAt: Date?, leftAt: Date?, dismissed: Bool) -> Bool {
        if dismissed { return true }
        guard let endedAt, let leftAt else { return false }
        return leftAt > endedAt
    }

    /// Where one run stands, and its short state.
    public static func entry(_ run: HelperRun) -> Entry {
        let (standing, status): (Standing, String) = switch run.phase {
        case .asking: (.needsYou, "needs your OK")
        case .starting: (.working, "starting")
        case .working:
            if run.permission != nil {
                (.needsYou, "needs your OK")
            } else {
                (.working, run.planProgress.map { "step \($0.step) of \($0.of)" } ?? "working")
            }
        case .paused: (.waiting, "paused")
        case .done: (.needsYou, run.kind == .review ? "drafted its review · needs your OK" : "done · needs your OK")
        case .stopped: (.needsYou, "stopped · needs your OK")
        case let .failed(why): (.needsYou, "failed: \(why)")
        case let .closed(how): (.finished, finishedStatus(run, how: how))
        }
        let headline = "A helper is " + run.headline.prefix(1).lowercased() + run.headline.dropFirst()
        return Entry(
            id: run.id, number: run.ref.number, kind: run.kind, standing: standing, status: status, headline: headline
        )
    }

    private static func finishedStatus(_ run: HelperRun, how: String) -> String {
        if let sha = run.closeOut?.pushedSHA { return "pushed \(sha.prefix(7)) · pull before your next change" }
        if how == "taken over" { return "taken over · \(run.branch) is yours" }
        return how
    }
}
