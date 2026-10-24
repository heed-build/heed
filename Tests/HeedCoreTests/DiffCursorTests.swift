import Foundation
@testable import HeedCore
import Testing

/// The diff overlay's cursor and selection, as keys and the mouse move them.
struct DiffCursorTests {
    private func line(_ kind: DiffLine.Kind, old: Int?, new: Int?) -> DiffLine {
        DiffLine(kind: kind, oldNumber: old, newNumber: new, text: "x")
    }

    /// Two hunks: rows 0 (header) 1–3, then 4 (header) 5–6.
    private var file: FileDiff {
        FileDiff(
            repo: nil, path: "src/A.swift", oldPath: nil, status: .modified,
            hunks: [
                Hunk(header: "@@ -10,2 +10,3 @@", oldStart: 10, newStart: 10, lines: [
                    line(.context, old: 10, new: 10), line(.deleted, old: 11, new: nil), line(
                        .added,
                        old: nil,
                        new: 11
                    ),
                ]),
                Hunk(header: "@@ -40,1 +41,2 @@", oldStart: 40, newStart: 41, lines: [
                    line(.context, old: 40, new: 41), line(.added, old: nil, new: 42),
                ]),
            ],
            binary: false, staged: false
        )
    }

    private var other: FileDiff {
        var other = file
        other.path = "src/B.swift"
        other.hunks.removeLast()
        return other
    }

    @Test func rowsAreEachHunksHeaderThenItsLines() {
        let rows = file.rows
        #expect(rows.count == 7)
        #expect(rows.map(\.hunk) == [0, 0, 0, 0, 1, 1, 1])
        #expect(rows[0] == .header(hunk: 0, text: "@@ -10,2 +10,3 @@"))
        #expect(rows[4] == .header(hunk: 1, text: "@@ -40,1 +41,2 @@"))
        #expect(file.hunkRows(1) == 4 ... 6)
        #expect(file.hunkRows(2) == nil)
    }

    @Test func clickingALineMovesTheCursorThereAndDropsTheSelection() {
        var cursor = DiffCursor()
        cursor.extend(to: 3, in: [file])
        #expect(cursor.selection == 0 ... 3)
        cursor.moveTo(file: 0, row: 5, in: [file, other])
        #expect(cursor.row == 5)
        #expect(cursor.selection == nil)
        // Clamped to the file's rows.
        cursor.moveTo(file: 0, row: 99, in: [file, other])
        #expect(cursor.row == 6)
        cursor.moveTo(file: 0, row: -4, in: [file, other])
        #expect(cursor.row == 0)
    }

    @Test func clickingAFileMovesToItsTop() {
        var cursor = DiffCursor()
        cursor.moveTo(file: 0, row: 5, in: [file, other])
        cursor.moveTo(file: 1, row: 0, in: [file, other])
        #expect(cursor.file == 1)
        #expect(cursor.row == 0)
        // A file that is not there changes nothing.
        cursor.moveTo(file: 7, row: 2, in: [file, other])
        #expect(cursor.file == 1)
        #expect(cursor.row == 0)
    }

    @Test func dragOrShiftClickExtendsFromWhereTheCursorWas() {
        var cursor = DiffCursor()
        cursor.moveTo(file: 0, row: 2, in: [file])
        cursor.extend(to: 5, in: [file])
        #expect(cursor.anchor == 2)
        #expect(cursor.row == 5)
        #expect(cursor.selection == 2 ... 5)
        // Dragging back past the start keeps the start, as VISUAL does.
        cursor.extend(to: 1, in: [file])
        #expect(cursor.selection == 1 ... 2)
        cursor.extend(to: 40, in: [file])
        #expect(cursor.selection == 2 ... 6)
    }

    @Test func selectingARangeAndAHunk() {
        var cursor = DiffCursor()
        cursor.select(1 ... 5, in: [file])
        #expect(cursor.anchor == 1)
        #expect(cursor.row == 5)
        cursor.selectHunk(1, in: [file])
        #expect(cursor.selection == 4 ... 6)
        #expect(cursor.row == 6)
        cursor.selectHunk(9, in: [file])
        #expect(cursor.selection == 4 ... 6)
    }

    @Test func keysMoveTheCursorAndKeepTheSelectionsStart() {
        var cursor = DiffCursor()
        cursor.startSelection()
        cursor.move(by: 2, in: [file])
        #expect(cursor.selection == 0 ... 2)
        cursor.move(by: 20, in: [file])
        #expect(cursor.row == 6)
        cursor.clearSelection()
        #expect(cursor.selection == nil)
        #expect(cursor.row == 6)
        cursor.moveTo(row: 3, in: [file])
        #expect(cursor.row == 3)
    }

    @Test func aNewFileOrANewDiffStartsAtTheTop() {
        var cursor = DiffCursor()
        cursor.moveTo(file: 1, row: 1, in: [file, other])
        cursor.extend(to: 3, in: [file, other])
        cursor.reset(in: [file])
        #expect(cursor.file == 0)
        #expect(cursor.row == 0)
        #expect(cursor.selection == nil)
        cursor.moveTo(file: 0, row: 3, in: [file, other])
        cursor.moveFile(by: 1, in: [file, other])
        #expect(cursor.file == 1)
        #expect(cursor.row == 0)
        cursor.moveFile(by: 5, in: [file, other])
        #expect(cursor.file == 1)
    }

    @Test func aRightClickInsideTheSelectionKeepsItElsewhereMovesTheCursor() {
        var cursor = DiffCursor()
        cursor.select(1 ... 3, in: [file])
        cursor.point(file: 0, row: 2, in: [file])
        #expect(cursor.selection == 1 ... 3)
        cursor.point(file: 0, row: 5, in: [file])
        #expect(cursor.selection == nil)
        #expect(cursor.row == 5)
    }

    @Test func theSelectionsLinesAreItsNewSideSpan() {
        var cursor = DiffCursor()
        #expect(cursor.lines(in: file) == nil)
        cursor.select(1 ... 3, in: [file])
        #expect(cursor.lines(in: file) == 10 ... 11)
        // A header stands for its hunk's start; a deleted line for the old side.
        cursor.select(2 ... 4, in: [file])
        #expect(cursor.lines(in: file) == 11 ... 41)
        cursor.select(2 ... 2, in: [file])
        #expect(cursor.lines(in: file) == 11 ... 11)
    }

    @Test func theHunkIsTheCursorsOrTheSelectionsFirst() {
        var cursor = DiffCursor()
        cursor.moveTo(file: 0, row: 5, in: [file])
        #expect(cursor.hunk(in: file) == 1)
        cursor.select(2 ... 5, in: [file])
        #expect(cursor.hunk(in: file) == 0)
        #expect(cursor.noteRow == 5)
    }

    @Test func whatIsCopiedAndAskedAbout() {
        var cursor = DiffCursor()
        cursor.moveTo(file: 0, row: 5, in: [file])
        #expect(cursor.location(in: file) == "src/A.swift:41")
        #expect(cursor.question(in: file) == "About src/A.swift around line 41 (the hunk in my diff): ")
        cursor.select(1 ... 3, in: [file])
        #expect(cursor.location(in: file) == "src/A.swift:10-11")
        #expect(cursor.question(in: file) == "About src/A.swift lines 10-11 (selected in my diff): ")
        cursor.select(3 ... 3, in: [file])
        #expect(cursor.location(in: file) == "src/A.swift:11")
    }
}
