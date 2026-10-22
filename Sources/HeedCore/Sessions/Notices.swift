import Foundation

/// What becomes a macOS notification when something starts needing you, and when. A session that enters asking or
/// blocked waits out a grace (`[notifications] grace_seconds`), so a prompt that clears itself never shows; once the
/// grace is over it joins a short batch (`window`), so a burst of agents stopping at once comes as one summary. One
/// reminder follows if it still needs you `reminder_minutes` later, then nothing until it leaves and comes back.
///
/// The app notes changes as they happen and drains when `next` comes: the timing is all here, against the `now` it is
/// given, so tests drive it with a fake clock. Entries are keyed by id and carry their own timing, so another input
/// (attention items, coalesced per sync) can note its own without sharing the sessions' grace.
public struct Notices: Equatable, Sendable {
    /// What in Needs you an entry is: one queue, several sources.
    public enum Kind: String, Equatable, Sendable {
        /// A session's agent is asking or blocked.
        case session
        /// A helper tab of a session (a get it green or get it merged run in its own tab) is asking or blocked.
        case helper
        /// A PR of a session needs you (`PilotStatus.stuck`): feedback to send and nowhere to send it.
        case pull
    }

    /// Something that started needing you.
    public struct Entry: Equatable, Sendable {
        public var id: String
        public var title: String
        public var agent: String
        /// For a PR, `.asking`: what it waits on is you.
        public var state: AgentState
        public var reason: String?
        public var kind: Kind
        /// The session Open brings Heed forward on.
        public var session: String
        /// The second notification for the same wait: it still needs you.
        public var reminder: Bool

        public init(
            id: String, title: String, agent: String, state: AgentState, reason: String? = nil, kind: Kind = .session,
            session: String? = nil, reminder: Bool = false
        ) {
            self.id = id
            self.title = title
            self.agent = agent
            self.state = state
            self.reason = reason
            self.kind = kind
            self.session = session ?? id
            self.reminder = reminder
        }

        /// What it waits on, in words: `blocked`, `asking`, `needs you` (a PR).
        public var label: String { kind == .pull ? "needs you" : state.rawValue }

        /// The notification's text under the title: `Blocked: Bash(rm -rf build)`, `Still asking: asked a question`.
        public var body: String {
            let name = reminder ? "Still \(label)" : label.prefix(1).uppercased() + label.dropFirst()
            return reason.map { "\(name): \($0)" } ?? name
        }
    }

    /// How long an entry waits before it notifies, and before it reminds.
    public struct Timing: Equatable, Sendable {
        /// After entering: nothing is shown before this, so what resolves itself stays quiet. 0: at once.
        public var grace: TimeInterval
        /// After the notification: one more if it still needs you. nil: none.
        public var reminder: TimeInterval?

        public init(grace: TimeInterval, reminder: TimeInterval?) {
            self.grace = max(0, grace)
            self.reminder = reminder.flatMap { $0 > 0 ? $0 : nil }
        }

        public init(_ settings: NotificationSettings) {
            self.init(
                grace: TimeInterval(settings.graceSeconds), reminder: TimeInterval(settings.reminderMinutes * 60)
            )
        }
    }

    public enum Notice: Equatable, Sendable {
        case one(Entry)
        /// Several at once, blocked first: one notification naming them all.
        case summary([Entry])

        public var title: String {
            switch self {
            case let .one(entry): entry.title
            case let .summary(entries):
                entries.allSatisfy(\.reminder)
                    ? "\(entries.count) sessions still need you" : "\(entries.count) sessions need you"
            }
        }

        public var body: String {
            switch self {
            case let .one(entry): entry.body
            case let .summary(entries): entries.map { "\($0.title) · \($0.label)" }.joined(separator: "\n")
            }
        }

        /// The session Open brings Heed forward on: the one, or the first (most urgent) of a summary.
        public var session: String? {
            switch self {
            case let .one(entry): entry.session
            case let .summary(entries): entries.first?.session
            }
        }
    }

    /// Where an entry is in its wait.
    public enum Stage: Equatable, Sendable {
        /// Entered; notifies at this time if it still needs you.
        case grace(until: Date)
        /// Notified (or seen on screen); reminds at this time, or never.
        case notified(remind: Date?)
        /// Reminded: nothing more until it leaves and enters again.
        case done
    }

    struct Waiting: Equatable, Sendable {
        var entry: Entry
        var timing: Timing
        var stage: Stage

        /// When this entry next has something to say.
        var ready: Date? {
            switch stage {
            case let .grace(until): until
            case let .notified(remind): remind
            case .done: nil
            }
        }
    }

    /// How long the batch stays open after the first entry is ready: long enough to collect a burst, short enough to
    /// matter.
    public static let window: TimeInterval = 3

    /// What needs you, in the order it started to.
    private(set) var waiting: [Waiting] = []

    public init() {}

    /// The entries still in their grace: what the next drains may show for the first time.
    public var pending: [Entry] {
        waiting.filter { if case .grace = $0.stage { true } else { false } }.map(\.entry)
    }

    /// Where one entry is in its wait; nil when it does not need you.
    public func stage(of id: String) -> Stage? { waiting.first { $0.entry.id == id }?.stage }

    /// When the next drain is due: the batch window after the first entry is ready. nil: nothing to say.
    public var next: Date? {
        waiting.compactMap(\.ready).min().map { $0.addingTimeInterval(Self.window) }
    }

    /// A session's state went from `old` to `new`. Entering a wanted Needs you state starts its wait (replacing what
    /// it had); anything else ends it, since it no longer needs you.
    public mutating func note(
        id: String, title: String, agent: String, from old: AgentState, to new: ObservedState,
        settings: NotificationSettings, at now: Date
    ) {
        guard old != new.state else { return }
        let entry = settings.wants(new.state)
            ? Entry(id: id, title: title, agent: agent, state: new.state, reason: new.reason) : nil
        note(id: id, entry, timing: Timing(settings), at: now)
    }

    /// `id` needs you as `entry` says, or (nil) no longer does. A new entry, or one whose state changed, starts its
    /// wait over; the same one again changes nothing. `seen`: it was already there (loaded from the cache at launch),
    /// so it is kept without a notification, as sessions are.
    public mutating func note(id: String, _ entry: Entry?, timing: Timing, at now: Date, seen: Bool = false) {
        let index = waiting.firstIndex { $0.entry.id == id }
        guard let entry else {
            if let index { waiting.remove(at: index) }
            return
        }
        if let index {
            guard waiting[index].entry.state != entry.state else { return }
            waiting.remove(at: index)
        }
        waiting.append(Waiting(
            entry: entry, timing: timing, stage: seen ? .done : .grace(until: now.addingTimeInterval(timing.grace))
        ))
    }

    /// Everything of one kind that needs you now, from a source read whole (the pilot's PRs, the helper tabs): new
    /// entries start their wait, ones that changed state start over, and ones of that kind not in `entries` end.
    public mutating func sync(_ kind: Kind, _ entries: [Entry], timing: Timing, at now: Date, seen: Bool = false) {
        let current = Set(entries.map(\.id))
        waiting.removeAll { $0.entry.kind == kind && !current.contains($0.entry.id) }
        for entry in entries where entry.kind == kind {
            note(id: entry.id, entry, timing: timing, at: now, seen: seen)
        }
    }

    /// Whether a drain is due.
    public func due(at now: Date) -> Bool { next.map { now >= $0 } ?? false }

    /// Once a drain is due, what is ready by `now` as one notice: each entry past its grace, or due its reminder, moves
    /// on a stage. Those whose session `onScreen` says you are looking at are left out; seen counts as notified, so the
    /// reminder still comes. In `quiet` hours nothing is shown and what came due is done: no reminder, and nothing when
    /// they end (Needs you and the Dock badge still show it). Before a drain is due, nothing changes.
    public mutating func drain(
        at now: Date, quiet: Bool = false, onScreen: (String) -> Bool = { _ in false }
    ) -> Notice? {
        guard due(at: now) else { return nil }
        var shown: [Entry] = []
        for index in waiting.indices {
            guard let ready = waiting[index].ready, ready <= now else { continue }
            var entry = waiting[index].entry
            switch waiting[index].stage {
            case .grace where !quiet:
                waiting[index].stage = .notified(remind: waiting[index].timing.reminder.map(now.addingTimeInterval))
            case .grace:
                waiting[index].stage = .done
            case .notified:
                waiting[index].stage = .done
                entry.reminder = true
            case .done:
                continue
            }
            if !quiet, !onScreen(entry.session) { shown.append(entry) }
        }
        switch shown.count {
        case 0: return nil
        case 1: return .one(shown[0])
        default: return .summary(shown.filter { $0.state == .blocked } + shown.filter { $0.state != .blocked })
        }
    }
}

public extension Notices {
    /// A PR of `session` that needs you (`PilotStatus.stuck`), as an entry; nil when it does not.
    static func pull(_ ref: PullRef, status: PilotStatus, of session: Session) -> Entry? {
        guard case let .stuck(reason) = status else { return nil }
        return Entry(
            id: "pull:\(ref)", title: "\(session.title) · #\(ref.number)", agent: session.agent, state: .asking,
            reason: reason, kind: .pull, session: session.id
        )
    }

    /// A helper tab of `session` working on `ref`, as an entry when its agent is asking or blocked.
    static func helper(pane: String, state: AgentState, agent: String, ref: PullRef, of session: Session) -> Entry? {
        guard state.needsYou else { return nil }
        return Entry(
            id: "helper:\(pane)", title: "\(session.title) · #\(ref.number) helper", agent: agent, state: state,
            kind: .helper, session: session.id
        )
    }
}
