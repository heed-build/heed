import Foundation
import HeedCore

/// Screen snapshots (`[local] record_screens`, off by default): the cleaned tail of an agent's pane at each state its
/// hooks report, now and then while it works, and (unlabelled) at states read from the screen. Kept in heed.sqlite on
/// this Mac for a local decision model to learn from; never in the call log, never sent anywhere. Fixtures keep none.
extension AppModel {
    /// After a session's state changed from `previous`: a snapshot when the change is worth one. A reported change is
    /// read a moment later (`ScreenSnapshot.settle`), as the agent may draw what it reported after its hook fired, and
    /// only if the session is still in that state.
    func recordScreen(of session: Session, from previous: ObservedState) {
        guard config.local.recordScreens, !isFixture, eventLog != nil,
              let source = ScreenSnapshot.source(from: previous, to: session.state)
        else { return }
        let now = Date()
        switch source {
        case .reported: screenSampler.reported(session: session.id, state: session.state.state, at: now)
        case .guessed: guard screenSampler.takeGuessed(session: session.id, now: now) else { return }
        case .sampled: return
        }
        let id = session.id, state = session.state
        Task { @MainActor [weak self] in
            if source == .reported { try? await Task.sleep(for: ScreenSnapshot.settle) }
            guard let self, let current = sessions.first(where: { $0.id == id }), current.state == state else { return }
            keepScreen(of: current, previous: previous.state, source: source)
        }
    }

    /// From screen reading, once a second: a sample of a session its hooks say is working, at most one every
    /// `ScreenSampler.workingEvery`.
    func sampleWorkingScreens(now: Date) {
        guard config.local.recordScreens, !isFixture, eventLog != nil else { return }
        for session in sessions where session.state.state == .working && session.state.source == .reported {
            guard screenSampler.sampleWorking(session: session.id, now: now) else { continue }
            keepScreen(of: session, previous: nil, source: .sampled)
        }
    }

    /// Reads the session's agent pane now and keeps it, cleaned off the main actor.
    private func keepScreen(of session: Session, previous: AgentState?, source: ScreenSnapshot.Source) {
        guard let log = eventLog, let layout = layouts[session.id], let (_, paneID) = agentPane(in: layout),
              let screen = TerminalSurfaces.shared.visibleText(paneID: paneID)
        else { return }
        let keepDays = config.local.keepDays
        let (id, agent, state, remote) = (session.id, session.agent, session.state.state, session.host != nil)
        Task.detached(priority: .utility) {
            let text = ScreenText.clean(screen, lines: ScreenSnapshot.lines)
            guard !text.isEmpty else { return }
            let snapshot = ScreenSnapshot(
                at: Date(), session: id, agent: agent, state: state, previous: previous, source: source,
                remote: remote, text: text
            )
            await log.record(snapshot, keepDays: keepDays)
        }
    }

    /// At launch: what is past `keep_days` goes, recording on or off.
    func pruneScreenSnapshots() {
        guard let log = eventLog, !isFixture else { return }
        let keepDays = config.local.keepDays
        Task.detached(priority: .utility) { await log.pruneScreens(now: Date(), keepDays: keepDays) }
    }

    /// Settings › Agents › Local decisions: reads the counts. Fixtures keep their invented ones.
    func refreshScreenCounts() async {
        guard !isFixture, let log = eventLog else { return }
        screenCounts = try? await log.screenCounts()
    }

    /// Settings' Delete all, after it was confirmed.
    func deleteScreenSnapshots() async {
        if isFixture {
            screenCounts = .empty(now: Clock.now)
            return
        }
        guard let log = eventLog else { return }
        await log.deleteScreens()
        await refreshScreenCounts()
    }
}
