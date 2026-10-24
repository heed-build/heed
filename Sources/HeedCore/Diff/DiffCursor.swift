import Foundation

/// One row of a file's unified diff: a hunk's header, or one of its lines.
public enum DiffRow: Hashable, Sendable {
    case header(hunk: Int, text: String)
    case line(hunk: Int, DiffLine)

    public var hunk: Int {
        switch self {
        case let .header(hunk, _), let .line(hunk, _): hunk
        }
    }
}

public extension FileDiff {
    /// The unified view's rows: each hunk's header, then its lines.
    var rows: [DiffRow] {
        hunks.enumerated().flatMap { index, hunk in
            [DiffRow.header(hunk: index, text: hunk.header)] + hunk.lines.map { DiffRow.line(hunk: index, $0) }
        }
    }

    /// The rows of hunk `index`, its header through its last line.
    func hunkRows(_ index: Int) -> ClosedRange<Int>? {
        guard hunks.indices.contains(index) else { return nil }
        let start = hunks[..<index].reduce(0) { $0 + 1 + $1.lines.count }
        return start ... start + hunks[index].lines.count
    }

    /// The file line a row stands for: a line's new side, else its old side; a header its hunk's start.
    func line(at row: Int) -> Int? {
        let rows = rows
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case let .line(_, line): return line.newNumber ?? line.oldNumber
        case let .header(hunk, _): return hunks[hunk].newStart
        }
    }
}

/// Where the diff overlay's cursor is: the file, the row of its unified diff, and where a selection started (VISUAL,
/// a drag, a shift-click or a click on a hunk's header). Keys and clicks move it through these functions only.
public struct DiffCursor: Hashable, Sendable {
    public private(set) var file = 0
    public private(set) var row = 0
    /// The row a selection started on; nil without one.
    public private(set) var anchor: Int?

    public init() {}

    /// The selected rows, from the anchor to the cursor, either way round.
    public var selection: ClosedRange<Int>? {
        anchor.map { min($0, row) ... max($0, row) }
    }

    /// The row a note's comment box opens under: the selection's last, else the cursor's.
    public var noteRow: Int { selection?.upperBound ?? row }

    /// A click on a line, or on a file in the list (`row` 0): the cursor goes there and a selection is dropped.
    /// A file that is not in `files` changes nothing.
    public mutating func moveTo(file index: Int, row target: Int, in files: [FileDiff]) {
        guard files.indices.contains(index) else { return }
        file = index
        anchor = nil
        row = Self.clamp(target, files[index])
    }

    /// `gg`, `G`: the cursor to a row of the current file, keeping a selection's start (it extends in VISUAL).
    public mutating func moveTo(row target: Int, in files: [FileDiff]) {
        guard files.indices.contains(file) else { return }
        row = Self.clamp(target, files[file])
    }

    /// `j`, `k`: by `delta` rows, keeping a selection's start.
    public mutating func move(by delta: Int, in files: [FileDiff]) {
        moveTo(row: row + delta, in: files)
    }

    /// `]f`, `[f`: the next or previous file, at its top.
    public mutating func moveFile(by delta: Int, in files: [FileDiff]) {
        guard !files.isEmpty else { return }
        moveTo(file: min(max(file + delta, 0), files.count - 1), row: 0, in: files)
    }

    /// A drag, or a shift-click: the selection runs from where the cursor was (or where it already started) to
    /// `target`.
    public mutating func extend(to target: Int, in files: [FileDiff]) {
        guard files.indices.contains(file) else { return }
        if anchor == nil { anchor = row }
        row = Self.clamp(target, files[file])
    }

    /// Selects `range` of the current file's rows, the cursor on its last.
    public mutating func select(_ range: ClosedRange<Int>, in files: [FileDiff]) {
        guard files.indices.contains(file) else { return }
        anchor = Self.clamp(range.lowerBound, files[file])
        row = Self.clamp(range.upperBound, files[file])
    }

    /// A click on a hunk's header: the hunk, header through its last line.
    public mutating func selectHunk(_ hunk: Int, in files: [FileDiff]) {
        guard files.indices.contains(file), let rows = files[file].hunkRows(hunk) else { return }
        select(rows, in: files)
    }

    /// `v`: a selection starts on the cursor's row.
    public mutating func startSelection() { anchor = row }

    public mutating func clearSelection() { anchor = nil }

    /// A right-click: inside the selection it stays, for the menu to act on; anywhere else the cursor moves there.
    public mutating func point(file index: Int, row target: Int, in files: [FileDiff]) {
        if index == file, selection?.contains(target) == true { return }
        moveTo(file: index, row: target, in: files)
    }

    /// The diff came back (a new scope or commit): the same file if it is still there, at its top.
    public mutating func reset(in files: [FileDiff]) {
        file = min(file, max(files.count - 1, 0))
        row = 0
        anchor = nil
    }

    /// The file lines the selection covers (see `FileDiff.line(at:)`); nil without a selection.
    public func lines(in file: FileDiff) -> ClosedRange<Int>? {
        guard let selection else { return nil }
        let numbers = selection.compactMap { file.line(at: $0) }
        guard let low = numbers.min(), let high = numbers.max() else { return nil }
        return low ... high
    }

    /// What `y` copies: `path:line`, or `path:first-last` for selected lines.
    public func location(in file: FileDiff) -> String {
        if let lines = lines(in: file) {
            return lines.count == 1 ? "\(file.path):\(lines.lowerBound)"
                : "\(file.path):\(lines.lowerBound)-\(lines.upperBound)"
        }
        return "\(file.path):\(file.line(at: row) ?? 1)"
    }

    /// What `A` types into the agent's pane, for you to finish: about the selected lines, else the cursor's hunk.
    public func question(in file: FileDiff) -> String {
        if let lines = lines(in: file) {
            let span = lines.count == 1 ? "line \(lines.lowerBound)" : "lines \(lines.lowerBound)-\(lines.upperBound)"
            return "About \(file.path) \(span) (selected in my diff): "
        }
        return "About \(file.path) around line \(file.line(at: row) ?? 1) (the hunk in my diff): "
    }

    /// The hunk a note or a question is about: the selection's first row's, else the cursor's.
    public func hunk(in file: FileDiff) -> Int? {
        let rows = file.rows
        let at = selection?.lowerBound ?? row
        return rows.indices.contains(at) ? rows[at].hunk : nil
    }

    private static func clamp(_ row: Int, _ file: FileDiff) -> Int {
        let count = file.hunks.reduce(0) { $0 + 1 + $1.lines.count }
        return min(max(row, 0), max(count - 1, 0))
    }
}
