import Foundation

/// What the event log records of a batch of domain changes. Every edit takes the domain path (hooks, screen guesses,
/// git, gh, the UI), so this one projection sees everything, and nothing has to remember to log.
public enum DomainEvents {
    /// The writes for `changes` applied to `before`, in order. `now` dates what the change itself does not date.
    public static func writes(before: Domain, changes: [DomainChange], now: Date) -> [EventLogWrite] {
        var domain = before
        return apply(changes, to: &domain, now: now)
    }

    /// Applies `changes` to `domain` and says what the log records of them: one pass, for the store.
    public static func apply(_ changes: [DomainChange], to domain: inout Domain, now: Date) -> [EventLogWrite] {
        var writes: [EventLogWrite] = []
        let reopened = Set(changes.compactMap { change -> String? in
            if case let .historyRemoved(id) = change { return id }
            return nil
        })
        for change in changes {
            let previous = domain
            domain.apply(change)
            var events: [LoggedEvent] = []
            switch change {
            case let .sessionUpserted(session):
                let old = previous.session(session.id)
                events = sessionEvents(old, session, reopened: reopened.contains(session.id), now: now)
            case let .sessionClosed(entry):
                // A refined outcome of an entry already closed is not a second close.
                if previous.session(entry.id) != nil || !previous.history.contains(where: { $0.id == entry.id }) {
                    events.append(LoggedEvent(
                        at: entry.closedAt, kind: .sessionClosed, about: entry.session, text: entry.outcome.rawValue
                    ))
                }
                writes.append(.closed(entry))
            case let .historyRemoved(id):
                writes.append(.reopened(id))
            case let .historyUpdated(entry):
                // The entry replaces its row; its new timeline lines (the sweep's note) are notes like any other.
                let known = Set(previous.history.first { $0.id == entry.id }?.session.timeline ?? [])
                events = entry.session.timeline.filter { !known.contains($0) }.map {
                    LoggedEvent(at: $0.at, kind: .note, about: entry.session, text: $0.text)
                }
                writes.append(.closed(entry))
            case let .worktreesListed(repo, listed):
                events = worktreeEvents(repo, before: previous.worktrees, listed: listed, now: now)
            case let .pullDetailFetched(detail):
                let was = previous.pullDetails[detail.ref.description]
                if detail.state == "MERGED", was.map({ $0.state != "MERGED" }) == true {
                    events.append(merged(detail.ref, at: detail.fetchedAt, in: previous))
                }
            case let .githubSynced(state):
                let open = Set(previous.github.pulls.filter { $0.state == .open }.map(\.ref))
                for pull in state.pulls where pull.state == .merged && open.contains(pull.ref) {
                    events.append(merged(pull.ref, at: now, in: previous))
                }
            default:
                break
            }
            if !events.isEmpty { writes.append(.events(events)) }
        }
        return writes
    }

    private static func merged(_ ref: PullRef, at: Date, in domain: Domain) -> LoggedEvent {
        if let session = domain.sessions.first(where: { $0.trackedPRs.contains(ref) }) {
            return LoggedEvent(at: at, kind: .pullMerged, about: session, subject: ref.description, text: "merged")
        }
        return LoggedEvent(at: at, kind: .pullMerged, repo: ref.repo.slug, subject: ref.description, text: "merged")
    }

    static func sessionEvents(_ old: Session?, _ new: Session, reopened: Bool, now: Date) -> [LoggedEvent] {
        var events: [LoggedEvent] = []
        guard let old else {
            // A chat says so, and where it runs: it has no repo or worktree to tell it by.
            let chat = new.chat.map { ["chat": $0.kind.rawValue, "folder": $0.path] } ?? [:]
            events.append(LoggedEvent(
                at: reopened ? now : new.createdAt, kind: reopened ? .sessionReopened : .sessionStarted, about: new,
                text: new.title, payload: ["agent": new.agent].merging(chat) { first, _ in first }
            ))
            events += new.timeline.map { LoggedEvent(at: $0.at, kind: .note, about: new, text: $0.text) }
            return events
        }
        if old.state.state != new.state.state || old.state.source != new.state.source {
            let state = new.state
            events.append(LoggedEvent(
                at: new.lastActivity, kind: .state, about: new, text: new.activity, guessed: state.source == .guessed,
                payload: ["state": state.state.rawValue, "from": old.state.state.rawValue]
                    .merging(state.reason.map { ["reason": $0] } ?? [:]) { first, _ in first }
            ))
            if state.state == .asking, old.state.state != .asking {
                events.append(LoggedEvent(
                    at: new.lastActivity, kind: .questionAsked, about: new, text: state.reason ?? "",
                    guessed: state.source == .guessed
                ))
            } else if old.state.state == .asking, state.state != .asking, state.state != .exited {
                events.append(LoggedEvent(at: new.lastActivity, kind: .questionAnswered, about: new))
            }
        }
        if old.parked != new.parked {
            events.append(LoggedEvent(at: now, kind: new.parked ? .sessionParked : .sessionUnparked, about: new))
        }
        for pull in new.trackedPRs where !old.trackedPRs.contains(pull) {
            events.append(LoggedEvent(at: now, kind: .pullTracked, about: new, subject: pull.description))
        }
        // Timeline lines are appended (the oldest drop off past the cap): the new ones are those the old one lacks.
        let known = Set(old.timeline)
        events += new.timeline.filter { !known.contains($0) }.map {
            LoggedEvent(at: $0.at, kind: .note, about: new, text: $0.text)
        }
        return events
    }

    /// Worktrees that appeared or went in a repo's listing. Only on machines it was listed on before: the first
    /// listing (a new repo, a new host, an empty cache) is what exists, not what was created.
    static func worktreeEvents(_ repo: Repo, before: [Worktree], listed: [Worktree], now: Date) -> [LoggedEvent] {
        let places = Set(listed.map(\.location))
        let known = before.filter { $0.repo == repo && places.contains($0.location) }
        let listedBefore = Set(known.map(\.location))
        let old = Set(known.map(\.id))
        let new = Set(listed.map(\.id))
        func event(_ worktree: Worktree, _ kind: EventKind) -> LoggedEvent {
            LoggedEvent(
                at: now, kind: kind, repo: repo.slug, host: worktree.location.hostName, worktree: worktree.path,
                subject: worktree.path, text: worktree.branch ?? ""
            )
        }
        let created = listed.filter { !old.contains($0.id) && listedBefore.contains($0.location) && !$0.isMain }
        let removed = known.filter { !new.contains($0.id) && !$0.isMain }
        return created.map { event($0, .worktreeCreated) } + removed.map { event($0, .worktreeRemoved) }
    }
}
