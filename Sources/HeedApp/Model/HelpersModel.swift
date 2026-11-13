import Foundation
import HeedCore
import Observation

/// The helpers heed runs on your behalf (`HelperRun`, over ACP), and what the views keep about them: which one is
/// open in a split, zoomed, the steer box, the tile Autopilot › Now has under its cursor, and what each session was
/// told. The connections themselves are kept out of observation: only the runs redraw.
@MainActor
@Observable
final class HelpersModel {
    /// Every helper, newest first, until you close it out (closed ones stay for the session, folded in Now).
    var runs: [HelperRun] = []
    /// The helper open in a split: under Attention's reader, under the session's panes (Watch it), or under Now's
    /// tiles.
    var shown: String?
    /// The split takes the whole column.
    var zoomed = false
    /// Steering: what you are typing to the helper shown (`i`), or nil. While it is open, keys type into it.
    var steer: EditableText?
    /// Helpers whose split you closed in Attention (`⎋`): the item shows its proposal line only.
    var hidden: Set<String> = []
    /// The close-out shows the helper's whole diff (`d`).
    var showDiff = false
    /// That diff, from git, once asked for.
    var diff: [String: [FileDiff]] = [:]
    /// Now's live tiles: the one under the cursor, or nil when the cursor is in the PR list.
    var tile: Int?
    /// Which of an Attention item's steps `.` moved the proposal to (0: heed's own), by item id.
    var proposal: [String: Int] = [:]
    /// How many times `.` moved a proposal (what the tutor checks).
    var otherSteps = 0
    /// What each session was told about a helper, by session id (the band over its panes). Never typed in.
    var notices: [String: SessionNotice] = [:]
    /// Whether helpers can run, as last looked up (nil: not yet).
    var availability: ACPAgents.Availability?
    /// `X` once arms throwing a helper's work away; again within a few seconds does it.
    var throwAwayArmed: (id: String, at: Date)?

    @ObservationIgnored var clients: [String: ACPClient] = [:]
    @ObservationIgnored var sessionIDs: [String: String] = [:]
    /// Turns under way, by helper.
    @ObservationIgnored var turns: [String: Task<Void, Never>] = [:]
    /// Why a turn was cancelled, so its end is read right: paused, steered (with the words), capped, timed out.
    @ObservationIgnored var cancelling: [String: CancelReason] = [:]
    /// Where each started, for git's count of what it changed.
    @ObservationIgnored var bases: [String: String] = [:]
    @ObservationIgnored var records: [String: RepoRecord] = [:]
    /// Feedback items each get it green helper was sent, for mapping its replies to threads.
    @ObservationIgnored var items: [String: [FeedbackItem]] = [:]

    enum CancelReason: Equatable {
        case pause
        case steer(String)
        case stop(String)
    }

    /// The band on a session: what heed told it, and the helper it is about.
    struct SessionNotice: Equatable {
        var helperID: String
        var text: String
        var at: Date
        /// How its agent got it: through its channel, or not (the band only); nil while it is being sent.
        var outcome: DeliveryOutcome?
    }

    func run(_ id: String?) -> HelperRun? {
        guard let id else { return nil }
        return runs.first { $0.id == id }
    }

    func update(_ id: String, _ edit: (inout HelperRun) -> Void) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        edit(&runs[index])
    }

    /// The helper on a PR that is not closed out yet: live, or waiting for your close-out.
    func current(on ref: PullRef) -> HelperRun? {
        runs.first { $0.ref == ref && !isClosed($0) }
    }

    /// The helper working on a PR now.
    func live(on ref: PullRef) -> HelperRun? { runs.first { $0.ref == ref && $0.phase.isLive } }

    /// Helpers at work or waiting on you, newest first: Now's tiles.
    var active: [HelperRun] { runs.filter { !isClosed($0) } }

    private func isClosed(_ run: HelperRun) -> Bool {
        if case .closed = run.phase { return true }
        return false
    }
}
