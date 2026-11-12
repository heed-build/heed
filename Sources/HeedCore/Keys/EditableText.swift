import Foundation

/// Text typed through the key router (Start work's prompt, the command line, a filter, a picker's query): the text, a
/// cursor in it and, while ⇧ is held over a motion, a selection. Keys edit at the cursor, as in any text field:
///
/// - `←` `→` by a character, `⌥←` `⌥→` by a word, `⌘←` `⌘→` `Home` `End` `⌃a` `⌃e` to the line's start or end;
///   with several lines `↑` `↓` move a line and `⌘↑` `⌘↓` go to the start or end of the text. `⇧` with any of
///   them selects, `⌘a` selects everything.
/// - `⌫` and `⌦` delete a character (or the selection), `⌥⌫` `⌃w` the word before the cursor, `⌃u` `⌘⌫` back to
///   the line's start. Typing or pasting replaces the selection.
///
/// The cursor and selection are offsets in characters (grapheme clusters), so an emoji or an accented letter is one
/// step. A value with no `multiline` treats `↑` and `↓` as not its own, so a picker can move its list with them.
public struct EditableText: Hashable, Sendable {
    public private(set) var text: String
    /// Where typing goes: 0 is before the first character, `text.count` after the last.
    public private(set) var cursor: Int
    /// The other end of the selection, when there is one; the cursor is the end that moves.
    public private(set) var anchor: Int?
    /// `↑` `↓` move between lines; `⇧↩` and `⌥↩` break the line.
    public var multiline: Bool

    /// `text` with the cursor at its end.
    public init(_ text: String = "", multiline: Bool = false) {
        self.text = text
        cursor = text.count
        anchor = nil
        self.multiline = multiline
    }

    public var isEmpty: Bool { text.isEmpty }

    /// The selected characters, as offsets; nil when nothing is selected.
    public var selection: Range<Int>? {
        guard let anchor, anchor != cursor else { return nil }
        return min(anchor, cursor) ..< max(anchor, cursor)
    }

    /// Replaces the whole text, the cursor at its end (a completion, a name heed picked, a cleared field).
    public mutating func set(_ text: String) {
        self.text = text
        cursor = text.count
        anchor = nil
    }

    /// Types `string` at the cursor, over the selection if there is one.
    public mutating func insert(_ string: String) {
        let range = selection ?? cursor ..< cursor
        replace(range, with: string)
    }

    /// Pasted text goes in where typing would.
    public mutating func paste(_ string: String) { insert(string) }

    /// Puts the cursor at `offset` (a click), dropping the selection.
    public mutating func moveCursor(to offset: Int) {
        cursor = Self.clamp(offset, text.count)
        anchor = nil
    }

    /// Edits for `stroke`; false when the stroke is not an editing key, so the caller can give it its own meaning.
    /// Characters typed with ⌥ type the character (the router hands over the plain key for those).
    @discardableResult
    public mutating func handle(_ stroke: KeyStroke) -> Bool {
        let shift = stroke.modifiers.contains(.shift)
        let modifiers = stroke.modifiers.subtracting(.shift)
        switch (stroke.key, modifiers) {
        case ("Left", []): if !shift, let range = selection { collapse(to: range.lowerBound) } else {
                move(to: cursor - 1, selecting: shift)
            }
        case ("Right", []): if !shift, let range = selection { collapse(to: range.upperBound) } else {
                move(to: cursor + 1, selecting: shift)
            }
        case ("Left", .option): move(to: wordStart(before: cursor), selecting: shift)
        case ("Right", .option): move(to: wordEnd(after: cursor), selecting: shift)
        case ("Left", .command), ("Home", []), ("a", .control): move(to: lineStart(of: cursor), selecting: shift)
        case ("Right", .command), ("End", []), ("e", .control): move(to: lineEnd(of: cursor), selecting: shift)
        case ("Up", .command) where multiline, ("Home", .command): move(to: 0, selecting: shift)
        case ("Down", .command) where multiline, ("End", .command): move(to: text.count, selecting: shift)
        case ("Up", []) where multiline: move(to: verticalTarget(by: -1), selecting: shift)
        case ("Down", []) where multiline: move(to: verticalTarget(by: 1), selecting: shift)
        case ("a", .command):
            anchor = 0
            cursor = text.count
        case ("BS", []):
            if let range = selection { replace(range, with: "") } else if cursor > 0 {
                replace(cursor - 1 ..< cursor, with: "")
            }
        case ("Del", []):
            if let range = selection { replace(range, with: "") } else if cursor < text.count {
                replace(cursor ..< cursor + 1, with: "")
            }
        case ("BS", .option), ("w", .control):
            if let range = selection { replace(range, with: "") } else {
                replace(Self.lastWordStart(in: prefix(cursor)) ..< cursor, with: "")
            }
        case ("u", .control), ("BS", .command):
            if let range = selection { replace(range, with: "") } else {
                replace(lineStart(of: cursor) ..< cursor, with: "")
            }
        case ("Space", []):
            insert(" ")
        case ("CR", .option) where multiline, ("CR", []) where multiline && shift:
            insert("\n")
        default:
            guard !stroke.isNamed, stroke.modifiers.subtracting(.option).isEmpty else { return false }
            insert(stroke.key)
        }
        return true
    }

    // MARK: Positions

    private func prefix(_ offset: Int) -> Substring { text.prefix(offset) }

    private func character(at offset: Int) -> Character? {
        guard offset >= 0, offset < text.count else { return nil }
        return text[text.index(text.startIndex, offsetBy: offset)]
    }

    private func lineStart(of offset: Int) -> Int {
        var position = offset
        while position > 0, character(at: position - 1) != "\n" {
            position -= 1
        }
        return position
    }

    private func lineEnd(of offset: Int) -> Int {
        var position = offset
        while position < text.count, character(at: position) != "\n" {
            position += 1
        }
        return position
    }

    /// The same column one line up or down, or the text's start or end past the first or last line.
    private func verticalTarget(by lines: Int) -> Int {
        let start = lineStart(of: cursor)
        let column = cursor - start
        if lines < 0 {
            guard start > 0 else { return 0 }
            let previous = lineStart(of: start - 1)
            return min(previous + column, start - 1)
        }
        let end = lineEnd(of: cursor)
        guard end < text.count else { return text.count }
        let next = end + 1
        return min(next + column, lineEnd(of: next))
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// The start of the word before `offset`, skipping what is not a word first (as ⌥← does in a text field).
    private func wordStart(before offset: Int) -> Int {
        var position = offset
        while position > 0, let previous = character(at: position - 1), !Self.isWordCharacter(previous) {
            position -= 1
        }
        while position > 0, let previous = character(at: position - 1), Self.isWordCharacter(previous) {
            position -= 1
        }
        return position
    }

    private func wordEnd(after offset: Int) -> Int {
        var position = offset
        while let next = character(at: position), !Self.isWordCharacter(next) {
            position += 1
        }
        while let next = character(at: position), Self.isWordCharacter(next) {
            position += 1
        }
        return position
    }

    /// Where ⌥⌫ deletes back to: trailing spaces, then the run of non-spaces before them, as it always did.
    private static func lastWordStart(in text: Substring) -> Int {
        var position = text.count
        var index = text.endIndex
        while index > text.startIndex, text[text.index(before: index)].isWhitespace {
            index = text.index(before: index)
            position -= 1
        }
        while index > text.startIndex, !text[text.index(before: index)].isWhitespace {
            index = text.index(before: index)
            position -= 1
        }
        return position
    }

    // MARK: Editing

    private mutating func move(to offset: Int, selecting: Bool) {
        let target = Self.clamp(offset, text.count)
        if selecting {
            if anchor == nil { anchor = cursor }
        } else {
            anchor = nil
        }
        cursor = target
    }

    private mutating func collapse(to offset: Int) {
        cursor = offset
        anchor = nil
    }

    private mutating func replace(_ range: Range<Int>, with string: String) {
        let lower = text.index(text.startIndex, offsetBy: range.lowerBound)
        let upper = text.index(lower, offsetBy: range.count)
        text.replaceSubrange(lower ..< upper, with: string)
        cursor = range.lowerBound + string.count
        anchor = nil
    }

    private static func clamp(_ offset: Int, _ count: Int) -> Int { min(max(offset, 0), count) }
}
