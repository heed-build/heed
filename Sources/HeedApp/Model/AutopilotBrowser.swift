import Foundation
import HeedCore
import Observation

/// Where you are in Autopilot: the card picked on Can do, the cell under the cursor on Where, and the line and the
/// narrowing on Done. What the views show is the domain's (`AppModel+Autopilot`); this holds only the input state.
@MainActor
@Observable
final class AutopilotBrowser {
    /// Can do's cards, three to a row.
    static let columns = 3

    private(set) var card = 0
    /// Where's cursor: the repo's row and the capability's column.
    private(set) var row = 0
    private(set) var column = 0
    /// Done's line, and what it is narrowed to.
    private(set) var doneCursor = 0
    var doneCapability: Capability?
    var doneRepo: String?

    var capability: Capability { Capability.allCases[min(card, Capability.allCases.count - 1)] }

    func pick(_ capability: Capability) {
        card = Capability.allCases.firstIndex(of: capability) ?? 0
        if let index = AutopilotBrowser.whereColumns.firstIndex(of: capability) { column = index }
    }

    /// Can do: h l along a row, j k between rows.
    func moveCard(_ direction: String) {
        let count = Capability.allCases.count
        let next = switch direction {
        case "h": card - 1
        case "l": card + 1
        case "j": card + Self.columns
        case "k": card - Self.columns
        default: card
        }
        card = min(max(next, 0), count - 1)
    }

    /// Where's columns: the per-repo capabilities, then the global ones a repo's work goes through (Continue and Names
    /// are about sessions, not repos: Can do has them).
    static let whereColumns: [Capability] = [.green, .merge, .copilot, .reviewers, .cleanup, .goals, .summaries]

    var whereCapability: Capability { Self.whereColumns[min(column, Self.whereColumns.count - 1)] }

    func moveCell(_ direction: String, rows: Int) {
        switch direction {
        case "h": column = max(column - 1, 0)
        case "l": column = min(column + 1, Self.whereColumns.count - 1)
        case "j": row = min(row + 1, max(rows - 1, 0))
        case "k": row = max(row - 1, 0)
        default: break
        }
    }

    func setCell(row: Int, column: Int, rows: Int) {
        self.row = min(max(row, 0), max(rows - 1, 0))
        self.column = min(max(column, 0), Self.whereColumns.count - 1)
    }

    func setRow(_ index: Int, rows: Int) {
        row = min(max(index, 0), max(rows - 1, 0))
    }

    func setDoneCursor(_ index: Int, count: Int) {
        doneCursor = min(max(index, 0), max(count - 1, 0))
    }

    /// Can do's card for `index` in the row-major grid.
    func setCard(_ index: Int) {
        card = min(max(index, 0), Capability.allCases.count - 1)
    }
}
