import Foundation

/// The Start work dialog while it is open: the form, where it shows (the window, or its own panel over other apps),
/// and how far starting it got. Editing until ⌘↩; waiting on a trust confirmation; launching; failed (why, shown in
/// the dialog, which stays open to try again). A trust answer that comes for an earlier start, or after the dialog
/// was closed, starts nothing.
public struct StartWorkSession: Sendable {
    public enum Presentation: Equatable, Sendable {
        case window
        /// Its own panel (`[keys] global_start_work`), which has no status bar and cannot show a confirmation.
        case standalone
    }

    public enum Phase: Equatable, Sendable {
        case editing
        /// The repo's trust offer is asked; the id of this start.
        case awaitingTrust(UUID)
        case launching
        case failed(String)
    }

    public var form: StartWorkForm
    public var presentation: Presentation
    public private(set) var phase: Phase = .editing

    public init(form: StartWorkForm, presentation: Presentation = .window) {
        self.form = form
        self.presentation = presentation
    }

    /// Starting: the dialog's buttons wait, and clicking away from the panel does not close it.
    public var isStarting: Bool {
        switch phase {
        case .awaitingTrust, .launching: true
        case .editing, .failed: false
        }
    }

    /// Why the last start failed, while the dialog shows it.
    public var error: String? {
        if case let .failed(why) = phase { why } else { nil }
    }

    /// A start may begin: not while one is going.
    public var canStart: Bool { !isStarting }

    /// The start waits for the trust offer's answer: its id, or nil while one is going.
    public mutating func awaitTrust() -> UUID? {
        guard canStart else { return nil }
        let id = UUID()
        phase = .awaitingTrust(id)
        return id
    }

    /// The trust offer `id` was answered (either way): true when the start may launch, false when the answer is for
    /// a start that is no longer waiting.
    public mutating func trustAnswered(_ id: UUID) -> Bool {
        guard phase == .awaitingTrust(id) else { return false }
        phase = .launching
        return true
    }

    /// Launching without asking (nothing to trust, or the standalone panel). False while a start is going.
    @discardableResult
    public mutating func launch() -> Bool {
        guard canStart else { return false }
        phase = .launching
        return true
    }

    /// The start failed, or could not begin: back to editing with why.
    public mutating func fail(_ why: String) {
        phase = .failed(why)
    }

    /// The dialog is opened again on what it had: a failure shown before is forgotten.
    public mutating func clearFailure() {
        if case .failed = phase { phase = .editing }
    }

    /// The start ended without starting anything and nothing to say (a trust offer gone unanswered): editing again.
    public mutating func stop() {
        if isStarting { phase = .editing }
    }
}
