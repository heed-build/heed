import Foundation
import HeedCore

/// Hunch reading agent panes (`HunchScreen`): the last lines of a swarm worker's pane, and of sessions whose agent
/// cannot report every state, as working, waiting for input, stuck or done. Only while Hunch is the decider with a
/// model downloaded; otherwise heed's own guess (`ScreenGuess`) is all there is. A pane is read at most once a minute
/// and only when its screen changed; the read runs off the main actor (Hunch's runtime is an actor of its own) and
/// its answer lands in `screenReadings` when it comes.
extension AppModel {
    /// Whether Hunch reads panes now.
    var hunchReadsScreens: Bool {
        HunchScreen.reads(decider: config.decisions.decider, modelReady: hunch.status.modelReady)
            && hunch.directory != nil
    }

    /// Hunch's newest reading of a pane, while Hunch reads panes.
    func hunchReading(pane: String) -> HunchScreen.Reading? {
        hunchReadsScreens ? screenReadings[pane] : nil
    }

    /// Asks Hunch to read `pane`, which shows `text`, when it is due (`HunchScreen.Throttle`) or `now` says so. Never
    /// waits for the answer. True when a read started.
    @discardableResult
    func readWithHunch(pane: String, text: String, subject: String, now: Date, force: Bool = false) -> Bool {
        guard !isFixture, hunchReadsScreens, let directory = hunch.directory,
              !screenReadsInFlight.contains(pane)
        else { return false }
        if force { screenThrottle.forget(pane: pane) }
        guard screenThrottle.due(pane: pane, text: text, now: now) else { return false }
        screenReadsInFlight.insert(pane)
        let (runtime, head, name) = (hunch.runtime, hunch.head, hunch.modelName)
        Task { [weak self] in
            let reading = await Task.detached(priority: .utility) { () -> HunchScreen.Reading? in
                let state = HunchScreen.state(ofScreen: text)
                guard !state.isEmpty else { return nil }
                let decider = HunchDecider(caller: "screen.read", model: name) { state, questions in
                    try await runtime.answer(directory: directory, head: head, state: state, questions: questions)
                }
                let answers = try? await decider.decide(
                    subject: subject, state: state, questions: [HunchScreen.questionID: HunchScreen.question]
                )
                return answers?[HunchScreen.questionID].flatMap { HunchScreen.Reading($0, at: Date()) }
            }.value
            guard let self else { return }
            screenReadsInFlight.remove(pane)
            // A read that failed (or saw a blank pane) says nothing: the old reading goes with it.
            if screenReadings[pane] != reading { screenReadings[pane] = reading }
        }
        return true
    }

    /// Each live swarm worker whose hooks say working: its pane to Hunch, when due.
    func readWorkerPanesWithHunch(now: Date) {
        guard hunchReadsScreens else { return }
        for live in liveWorkers.values where runStates[live.paneID] == .working {
            guard let text = TerminalSurfaces.shared.visibleText(paneID: live.paneID) else { continue }
            readWithHunch(pane: live.paneID, text: text, subject: "task:\(live.task)", now: now)
        }
    }

    /// A pane that closed: its reading and its throttle go.
    func forgetHunchReading(pane: String) {
        screenThrottle.forget(pane: pane)
        if screenReadings[pane] != nil { screenReadings[pane] = nil }
    }

    /// `hunch.screen`: Hunch reads the pane under the cursor now (the agents pane's worker, else the session's agent),
    /// whether or not its screen changed.
    func readScreenWithHunchNow() {
        guard hunchReadsScreens else {
            return say(
                config.decisions.decider == .hunch ? "Hunch has no model yet (:hunch.download)"
                    : "Hunch reads screens only as the decider ([decisions] decider = \"hunch\")"
            )
        }
        let target = paneUnderCursor()
        guard let target, let text = TerminalSurfaces.shared.visibleText(paneID: target.pane) else {
            return say("no agent pane here for Hunch to read")
        }
        guard readWithHunch(pane: target.pane, text: text, subject: target.subject, now: Clock.now, force: true) else {
            return say("Hunch is reading that pane already")
        }
        say("Hunch is reading the pane's last \(HunchScreen.lines) lines")
    }

    /// The agent pane under the cursor, and what its decisions are about: the agents pane's live worker, else the
    /// selected session's agent.
    private func paneUnderCursor() -> (pane: String, subject: String)? {
        if view == .goals, goals.pane == .agents, let task = goals.selectedTask {
            return liveWorker(on: task.id).map { ($0.paneID, "task:\(task.id)") }
        }
        guard let session = currentSession, let layout = layouts[session.id], let (_, pane) = agentPane(in: layout)
        else { return nil }
        return (pane, session.id)
    }

    /// The newest reading of any pane, for Settings › Inference & decisions.
    var latestScreenReading: HunchScreen.Reading? {
        screenReadings.values.max { $0.at < $1.at }
    }

    // MARK: The fake world

    /// The running swarm and its workers' activity, with Hunch as the decider and its model downloaded, and Hunch's
    /// readings of the live workers' panes laid in (`SwarmFixtures.screenReadings`). Nothing is read.
    func loadHunchScreenFixture() {
        guard isFixture else { return }
        applyConfig(source: "[decisions]\ndecider = \"hunch\"\n")
        hunch.show(downloads: ["english": .ready], usage: HunchDiskUsage())
        loadRunningSwarmFixture(.running)
        workerActivity = SwarmFixtures.activity(now: Clock.now)
        for (task, reading) in SwarmFixtures.screenReadings(now: Clock.now) {
            if let live = liveWorker(on: task) { screenReadings[live.paneID] = reading }
        }
    }
}
