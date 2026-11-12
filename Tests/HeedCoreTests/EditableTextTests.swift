import Foundation
@testable import HeedCore
import Testing

/// Typing through the key router edits at a cursor: arrows, words, lines, selection, as in any text field.
struct EditableTextTests {
    private func press(_ notation: String, _ text: inout EditableText) throws {
        for stroke in try KeyNotation.parse(notation) {
            text.handle(stroke)
        }
    }

    private func typed(_ string: String, multiline: Bool = false) -> EditableText {
        var text = EditableText(multiline: multiline)
        for character in string {
            text.handle(character == " " ? KeyStroke("Space") : KeyStroke(String(character)))
        }
        return text
    }

    @Test func typingGoesInAtTheCursor() throws {
        var text = typed("fix anchors")
        try press("<Left><Left><Left><Left><Left><Left><Left>", &text)
        try press("the<Space>", &text)
        #expect(text.text == "fix the anchors")
        #expect(text.cursor == 8)
    }

    @Test func backspaceAndDeleteWorkEitherSideOfTheCursor() throws {
        var text = typed("abcd")
        try press("<Left><Left><BS>", &text)
        #expect(text.text == "acd")
        try press("<Del>", &text)
        #expect(text.text == "ad")
        #expect(text.cursor == 1)
    }

    @Test func optionArrowsMoveByWord() throws {
        var text = typed("look at redirects.yml now")
        try press("<M-Left>", &text)
        #expect(text.cursor == 22)
        try press("<M-Left><M-Left>", &text)
        #expect(text.cursor == 8)
        try press("<M-Right>", &text)
        #expect(text.cursor == 17)
    }

    @Test func optionBackspaceDeletesTheWordBeforeTheCursorOnly() throws {
        var text = typed("one two three")
        try press("<M-Left>", &text)
        try press("<M-BS>", &text)
        #expect(text.text == "one three")
        try press("<C-w>", &text)
        #expect(text.text == "three")
    }

    @Test func commandArrowsHomeEndAndEmacsKeysGoToTheLineEnds() throws {
        var text = EditableText("first line\nsecond line", multiline: true)
        try press("<D-Left>", &text)
        #expect(text.cursor == 11)
        try press("<C-e>", &text)
        #expect(text.cursor == 22)
        try press("<Home>", &text)
        #expect(text.cursor == 11)
        try press("<End>", &text)
        #expect(text.cursor == 22)
        try press("<C-a>", &text)
        #expect(text.cursor == 11)
        try press("<D-Up>", &text)
        #expect(text.cursor == 0)
        try press("<D-Down>", &text)
        #expect(text.cursor == 22)
    }

    @Test func upAndDownKeepTheColumnAcrossLines() throws {
        var text = EditableText("abcdef\nab\nabcdef", multiline: true)
        try press("<Up>", &text)
        #expect(text.cursor == 9) // "ab" is short: its end
        try press("<Up>", &text)
        #expect(text.cursor == 2)
        try press("<Down><Down>", &text)
        #expect(text.cursor == 12)
        try press("<Down>", &text)
        #expect(text.cursor == 16) // past the last line: the end
        try press("<Up><Up><Up><Up>", &text)
        #expect(text.cursor == 0)
    }

    @Test func upAndDownAreNotOnesOwnOnOneLine() throws {
        var text = EditableText("query")
        #expect(text.handle(KeyStroke("Up")) == false)
        #expect(text.handle(KeyStroke("Down")) == false)
        #expect(text.cursor == 5)
    }

    @Test func controlUDeletesBackToTheLineStart() throws {
        var text = EditableText("keep\ndrop this", multiline: true)
        try press("<M-Left>", &text)
        try press("<C-u>", &text)
        #expect(text.text == "keep\nthis")
        #expect(text.cursor == 5)
    }

    @Test func shiftSelectsAndTypingReplacesTheSelection() throws {
        var text = typed("fix the anchors")
        try press("<S-M-Left>", &text)
        #expect(text.selection == 8 ..< 15)
        try press("links", &text)
        #expect(text.text == "fix the links")
        #expect(text.selection == nil)
        try press("<S-Left><S-Left><BS>", &text)
        #expect(text.text == "fix the lin")
    }

    @Test func anArrowWithoutShiftCollapsesTheSelectionToItsSide() throws {
        var text = typed("abcdef")
        try press("<S-Left><S-Left><S-Left>", &text)
        try press("<Right>", &text)
        #expect(text.selection == nil)
        #expect(text.cursor == 6)
        try press("<S-Left><S-Left><Left>", &text)
        #expect(text.cursor == 4)
    }

    @Test func commandASelectsEverythingAndPasteReplacesIt() throws {
        var text = typed("old")
        try press("<D-a>", &text)
        #expect(text.selection == 0 ..< 3)
        text.paste("new text")
        #expect(text.text == "new text")
        #expect(text.cursor == 8)
    }

    @Test func anEmojiOrAccentedLetterIsOneStep() throws {
        var text = EditableText("café 👩🏽‍💻 ok")
        try press("<M-Left><Left>", &text)
        #expect(text.cursor == 6)
        try press("<BS>", &text)
        #expect(text.text == "café  ok")
        try press("<Left><BS>", &text)
        #expect(text.text == "caf  ok")
    }

    @Test func breakingTheLineIsOnlyForSeveralLines() throws {
        var single = EditableText("a")
        #expect(single.handle(KeyStroke("CR", .option)) == false)
        var multi = EditableText("ab", multiline: true)
        try press("<Left><M-CR>", &multi)
        #expect(multi.text == "a\nb")
        try press("<S-CR>", &multi)
        #expect(multi.text == "a\n\nb")
    }

    @Test func otherCommandKeysAreLeftToTheCaller() throws {
        var text = EditableText("a")
        #expect(text.handle(KeyStroke("CR", .command)) == false)
        #expect(text.handle(KeyStroke("Tab")) == false)
        #expect(text.handle(KeyStroke("s", .command)) == false)
        #expect(text.text == "a")
    }
}

/// Where the cursor lives: Start work's fields and the pickers.
struct EditingAtTheCursorTests {
    private let records = ["docs-toolkit"].map {
        RepoRecord(repo: Repo(org: "o", name: $0), path: "/code/\($0)", defaultBranch: "main")
    }

    private func press(_ notation: String, into form: inout StartWorkForm) throws {
        for stroke in try KeyNotation.parse(notation) {
            _ = form.handle(stroke)
        }
    }

    @Test func thePromptEditsInTheMiddle() throws {
        var form = StartWorkForm(repos: records, settings: .default, prompt: "fix anchors")
        try press("<M-Left>the<Space>", into: &form)
        #expect(form.prompt == "fix the anchors")
        #expect(form.caret.cursor == 8)
    }

    @Test func pasteGoesInAtThePromptsCursor() throws {
        var form = StartWorkForm(repos: records, settings: .default, prompt: "fix anchors")
        try press("<M-Left>", into: &form)
        form.paste("broken ")
        #expect(form.prompt == "fix broken anchors")
    }

    @Test func returnStillBreaksThePromptsLineAtTheCursor() throws {
        var form = StartWorkForm(repos: records, settings: .default, prompt: "one two")
        try press("<M-Left><CR>", into: &form)
        #expect(form.prompt == "one \ntwo")
    }

    @Test func theWorktreeNameKeepsItsCursorThroughBranchSafety() throws {
        var form = StartWorkForm(repos: records, settings: .default, prompt: "fix anchors")
        form.focus(field: .worktree, edit: true)
        let name = form.name
        try press("<M-Left><Left>", into: &form)
        try press("<Space>x", into: &form)
        #expect(name == "fix/anchors")
        #expect(form.name == "fix-x/anchors")
        #expect(form.caret.text == form.name)
    }

    @Test func aFieldStartsWithItsCursorAtTheEnd() throws {
        var form = StartWorkForm(repos: records, settings: .default, prompt: "fix anchors")
        try press("<M-Left>", into: &form)
        form.focus(field: .worktree, edit: true)
        #expect(form.caret.cursor == form.name.count)
        form.focus(field: .prompt, edit: true)
        #expect(form.caret.cursor == 4)
    }

    @Test func aPickerMovesItsListWithUpAndDownAndItsCursorWithLeftAndRight() throws {
        var picker = Typeahead(items: ["alpha", "beta", "gamma"]) { [$0] }
        _ = picker.handle(KeyStroke("a"))
        _ = picker.handle(KeyStroke("Down"))
        #expect(picker.cursor == 1)
        _ = picker.handle(KeyStroke("Left"))
        _ = picker.handle(KeyStroke("m"))
        #expect(picker.query == "ma")
        #expect(picker.cursor == 0)
        picker.paste("g")
        #expect(picker.query == "mga")
    }
}
