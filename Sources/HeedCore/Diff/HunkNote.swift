import Foundation

/// The comment box `a` opens under a hunk in the diff overlay. While it is open every key types into it, as in the
/// filter or Start work's prompt: ↩ queues the note, ⌘↩ queues and sends it, ⇧↩ breaks the line, ⎋ cancels.
public struct HunkNoteDraft: Hashable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case handled
        case cancel
        /// Queue the note; `send` is ⌘↩, which sends what is queued right away.
        case queue(send: Bool)
    }

    /// The file it is on (`FileDiff.id`), the hunk and the row of the overlay it opened under.
    public var fileID: String
    public var hunk: Int
    public var row: Int
    public var path: String
    /// The new side's line under the cursor, else the hunk's start.
    public var line: Int
    public var repo: Repo?
    public private(set) var text = ""

    public init(fileID: String, hunk: Int, row: Int, path: String, line: Int, repo: Repo?) {
        self.fileID = fileID
        self.hunk = hunk
        self.row = row
        self.path = path
        self.line = line
        self.repo = repo
    }

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public mutating func handle(_ stroke: KeyStroke) -> Outcome {
        switch stroke {
        case .escape:
            return .cancel
        case KeyStroke("CR"):
            return isEmpty ? .handled : .queue(send: false)
        case KeyStroke("CR", .command):
            return isEmpty ? .handled : .queue(send: true)
        case KeyStroke("CR", .shift), KeyStroke("CR", .option):
            text += "\n"
        case KeyStroke("BS"):
            if !text.isEmpty { text.removeLast() }
        case KeyStroke("BS", .option), KeyStroke("w", .control):
            text = StartWorkForm.deletingLastWord(text)
        case KeyStroke("u", .control):
            text = ""
        case KeyStroke("Space"):
            text += " "
        default:
            guard !stroke.isNamed, stroke.modifiers.subtracting([.option, .shift]).isEmpty else { return .handled }
            text += stroke.key
        }
        return .handled
    }

    public mutating func paste(_ pasted: String) { text += pasted }
}

public extension Hunk {
    /// Whether a new-side line falls in this hunk (a hunk that only deletes covers its start).
    func contains(newLine line: Int) -> Bool {
        let last = lines.compactMap(\.newNumber).max() ?? newStart
        return line >= newStart && line <= max(last, newStart)
    }
}

public extension FileDiff {
    /// How many of `notes` (not yet sent) sit on each of its hunks, by hunk index.
    func noteCounts(_ notes: [FeedbackItem]) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for note in notes where note.status == .new || note.status == .queued {
            guard case let .note(notePath, line, noteRepo) = note.kind, notePath == path,
                  noteRepo == nil || repo == nil || noteRepo == repo,
                  let index = hunks.firstIndex(where: { $0.contains(newLine: line) })
            else { continue }
            counts[index, default: 0] += 1
        }
        return counts
    }
}
