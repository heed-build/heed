import Foundation

/// A helper's life as events: what each does to its phase, its end and its close-out, and what the app does next.
/// Every change of phase goes through `apply`, so a late event (a turn's end after you closed it out, a close-out
/// still being worked out when you took it over) cannot bring a finished helper back or move its end.
public extension HelperRun {
    /// Why heed cancelled a helper's turn, so its end is read right.
    enum Cancel: Equatable, Sendable {
        /// You paused it.
        case pause
        /// You told it something: its words start the next turn.
        case steer(String)
        /// heed stopped it: its cap, its `run_timeout`, thrown away, taken over.
        case stop(String)
    }

    enum Event: Equatable, Sendable {
        /// Its agent started; a note says what started where.
        case ready(note: String?)
        /// A prompt turn starts: a new close-out comes with its end.
        case turnStarted
        /// Its turn ended, why it was cancelled if it was, and whether its agent is still there.
        case turnEnded(ACPStopReason, cancel: Cancel?, connected: Bool)
        /// heed stopped a paused helper: there is no turn to cancel.
        case stopped(String)
        /// It could not start: its worktree, its setup or its agent.
        case couldNotStart(String)
        /// Its turn failed.
        case turnFailed(String)
        /// Its agent went away.
        case agentExited(String)
        /// What it did, once its turn ended: its close-out and, when git says so, its files. `keep` keeps a
        /// close-out it already has (the fake world's).
        case closeOut(HelperCloseOut, files: [HelperFile]?, keep: Bool)
        /// You closed it out: pushed, posted, thrown away or taken over.
        case closed(String)
        /// A part's helper's worker ended with it; `summary` is its close-out when it has none.
        case partEnded(summary: HelperCloseOut?)
    }

    /// What the app does after an event.
    enum Effect: Equatable, Sendable {
        /// Work out its close-out (`finishTurn`).
        case finishTurn
        /// Start the next turn on your words.
        case steer(String)
        /// Its PR's history says it failed.
        case recordFailure(String)
    }

    /// Takes one event in. Nil when it no longer applies, and nothing changed: a turn's start needs one that has not
    /// failed or been closed out; a turn's end, a failure or a stop needs a live one; a close-out needs one waiting
    /// for it; closing it out needs one not closed out already.
    mutating func apply(_ event: Event, at time: Date) -> [Effect]? {
        switch event {
        case let .ready(note):
            guard phase.isLive else { return nil }
            phase = .working
            if let note { append(.note(note), at: time) }
            return []
        case .turnStarted:
            guard !isOver else { return nil }
            phase = .working
            closeOut = nil
            return []
        case let .turnEnded(stop, cancel, connected):
            guard phase.isLive else { return nil }
            switch cancel {
            case .pause:
                phase = .paused
                append(.note("paused"), at: time)
                return []
            case let .steer(text):
                guard connected else {
                    phase = .paused
                    return []
                }
                return [.steer(text)]
            case let .stop(why):
                phase = .stopped(why)
                return [.finishTurn]
            case nil:
                withdrawPermission()
                phase = .done(stop)
                return [.finishTurn]
            }
        case let .stopped(why):
            guard phase.isLive else { return nil }
            phase = .stopped(why)
            return [.finishTurn]
        case let .couldNotStart(why):
            guard phase.isLive else { return nil }
            phase = .failed(why)
            endedAt = time
            append(.note(why), at: time)
            return [.recordFailure(why)]
        case let .turnFailed(why):
            guard phase.isLive else { return nil }
            phase = .failed(why)
            append(.note(why), at: time)
            return [.recordFailure(why)]
        case let .agentExited(why):
            guard phase.isLive else { return nil }
            withdrawPermission()
            phase = .failed(why)
            append(.note(why), at: time)
            return [.recordFailure(why)]
        case let .closeOut(closeOut, files, keep):
            guard phase.awaitsCloseOut else { return nil }
            self.closeOut = keep ? self.closeOut ?? closeOut : closeOut
            if let files { self.files = files }
            endedAt = time
            return []
        case let .closed(how):
            // A failed helper is closed out too (thrown away); a closed one stays as it was closed.
            if case .closed = phase { return nil }
            phase = .closed(how)
            endedAt = endedAt ?? time
            return []
        case let .partEnded(summary):
            endedAt = endedAt ?? time
            if closeOut == nil, let summary { closeOut = summary }
            return []
        }
    }

    /// Failed or closed out: nothing more happens to it.
    internal var isOver: Bool {
        switch phase {
        case .failed, .closed: true
        default: false
        }
    }
}
