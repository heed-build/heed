import Foundation
import HeedCore

/// What else in Needs you notifies besides sessions' own agents: PRs that need you and helper tabs that are asking or
/// blocked. Read whole each time the list is rebuilt; `Notices` keeps what changed. `seen`: the domain was just loaded,
/// so what needs you was already there and is not news, as sessions loaded from the cache are not.
extension AppModel {
    func noteOtherNeeds(seen: Bool = false) {
        guard !isFixture else { return }
        let settings = config.notifications
        var pulls: [Notices.Entry] = []
        var helpers: [Notices.Entry] = []
        if settings.enabled {
            for session in sessions {
                for ref in session.trackedPRs {
                    if let entry = Notices.pull(ref, status: pilotStatus(for: ref), of: session) { pulls.append(entry) }
                }
            }
        }
        for live in liveRuns.values.sorted(by: { $0.paneID < $1.paneID }) {
            guard let state = runStates[live.paneID], settings.wants(state),
                  let session = sessions.first(where: { $0.id == live.sessionID }) else { continue }
            let agent = runs.first { $0.id == live.runID }?.agent ?? session.agent
            if let entry = Notices.helper(pane: live.paneID, state: state, agent: agent, ref: live.ref, of: session) {
                helpers.append(entry)
            }
        }
        Notifier.shared.sync(.pull, pulls, settings: settings, seen: seen)
        Notifier.shared.sync(.helper, helpers, settings: settings, seen: seen)
    }
}
