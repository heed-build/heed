import Foundation
import HeedCore
import Observation

/// The agent runs on Browse's items (`BrowseRun`): the ones live or waiting for you, the line you are typing into, and
/// the connections behind them, which are kept out of observation so only the runs redraw. A closed run is gone from
/// here: its worktree is removed and its feed with it.
@MainActor @Observable
final class BrowseRunsModel {
    var runs: [BrowseRun] = []
    /// What you are typing into the panel: your words to the agent, the clone folder, or the review's text. Keys type
    /// into it while it is open.
    var input: Input?

    struct Input: Equatable {
        enum Kind: Equatable { case steer, folder, review }
        var kind: Kind
        var run: String
        var box: EditableText
    }

    @ObservationIgnored var clients: [String: ACPClient] = [:]
    @ObservationIgnored var sessionIDs: [String: String] = [:]
    @ObservationIgnored var turns: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var cancelling: [String: BrowseRun.Cancel] = [:]
    @ObservationIgnored var records: [String: RepoRecord] = [:]
    @ObservationIgnored var defaultBranches: [String: String] = [:]
    /// The commit each run's worktree began at: what its push guard measures from.
    @ObservationIgnored var startCommits: [String: String] = [:]
    /// The fake world's scripts under way, so closing a run stops its script.
    @ObservationIgnored var scripts: [String: Task<Void, Never>] = [:]

    func run(_ id: String?) -> BrowseRun? {
        guard let id else { return nil }
        return runs.first { $0.id == id }
    }

    /// The run on an item that is not over: what the reader shows below the thread.
    func current(for itemID: String) -> BrowseRun? { BrowseRuns.current(for: itemID, in: runs) }

    func update(_ id: String, _ edit: (inout BrowseRun) -> Void) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        edit(&runs[index])
    }

    /// One event of a run's life: what the app does next, or nil when it no longer applies (or there is no such run).
    func apply(_ id: String, _ event: BrowseRun.Event, at time: Date) -> [BrowseRun.Effect]? {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return nil }
        var run = runs[index]
        guard let effects = run.apply(event, at: time) else { return nil }
        runs[index] = run
        return effects
    }

    func remove(_ id: String) {
        runs.removeAll { $0.id == id }
        clients[id] = nil
        sessionIDs[id] = nil
        turns[id]?.cancel()
        turns[id] = nil
        cancelling[id] = nil
        records[id] = nil
        defaultBranches[id] = nil
        startCommits[id] = nil
        scripts[id]?.cancel()
        scripts[id] = nil
        if input?.run == id { input = nil }
    }

    /// Branches of runs that are using their worktree, for the startup sweep.
    var liveBranches: Set<String> { Set(runs.map(\.branch)) }
}
