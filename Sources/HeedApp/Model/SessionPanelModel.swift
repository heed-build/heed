import Foundation
import HeedCore
import Observation

/// Personas in sessions, as the window keeps them: each session's panel record (kept across launches), the looks
/// under way, PRs held for the panel, the popover and its cursor, and a chat with one persona. The domain is
/// HeedCore's (`SessionMilestones`, `SessionPanelPolicy`, `SessionPanelInvites`, `SessionLook`, `PRGate`).
@MainActor
@Observable
final class SessionPanelModel {
    /// Each session's record, by session id.
    var records: [String: SessionPanelRecord] = [:] {
        didSet { if persists { save() } }
    }

    /// Looks under way, by session.
    var looking: [String: SessionMilestone] = [:]
    /// PRs held for the panel, by session.
    var holds: [String: PRHold] = [:]
    /// The session whose popover is open.
    var open: String?
    /// The persona under the popover's cursor.
    var row = 0
    /// The persona under the cursor shows its full reasoning, in place (↩, or a click).
    var expanded = false
    /// Talking to one persona, and what you are typing to it.
    var chat: PersonaChat?
    var typing: String?
    var replying = false

    /// Waiting for your choice on a held PR, by ask id.
    @ObservationIgnored var choices: [String: CheckedContinuation<PRGate.Choice?, Never>] = [:]
    /// The hold under way for an ask, so a hook that comes back after a drop joins it.
    @ObservationIgnored var gates: [String: Task<PermissionAnswer?, Never>] = [:]
    @ObservationIgnored private var persists = false

    static let key = "sessionPanel"

    /// Loads the records kept on this Mac, and keeps them from now on; never in the fake world.
    func load() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([String: SessionPanelRecord].self, from: data)
        {
            records = saved
        }
        persists = true
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    func record(_ id: String) -> SessionPanelRecord? { records[id] }

    /// Changes a session's record, when it has one.
    func change(_ id: String, _ edit: (inout SessionPanelRecord) -> Void) {
        guard var record = records[id] else { return }
        edit(&record)
        records[id] = record
    }

    /// Answers a held PR's wait, once.
    func choose(_ askID: String, _ choice: PRGate.Choice?) {
        choices.removeValue(forKey: askID)?.resume(returning: choice)
    }
}
