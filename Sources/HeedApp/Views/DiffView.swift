import AppKit
import HeedCore
import SwiftUI

/// `gd` over a session: commits, files grouped by repo, and the diff (design/screens/Diff.png).
struct DiffOverlayView: View {
    @Environment(AppModel.self) private var model
    /// The diff body's visible width: the comment box spans it, not the longest line.
    @State private var bodyWidth: CGFloat = 800
    /// Where each row of the unified diff is drawn, for a drag to find the rows it passes over.
    @State private var rowFrames = DiffRowFrames()

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                Color.black.opacity(0.45).frame(width: min(280, geometry.size.width * 0.2))
                VStack(spacing: 0) {
                    header
                    HStack(spacing: 0) {
                        if geometry.size.width >= 900 { sidebar }
                        content
                    }
                    footer
                }
                .background(Theme.bg)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            SectionHeader(title: "Changes")
            HStack(spacing: 0) {
                ForEach(DiffScope.cycle, id: \.self) { scope in
                    segment(scope.title, on: model.diffScope == scope)
                }
                if case let .commit(sha) = model.diffScope { segment(sha, on: true) }
            }
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            KeyHint("diff.scope.next", scope: "diff", label: "scope")
            if model.diffLoading { Text("loading…").foregroundStyle(Theme.fg3) }
            Spacer()
            // The view you are not in switches to it, as t does.
            HStack(spacing: 0) {
                segment("Unified", on: !model.diffSplit).clickRuns(model.diffSplit ? splitToggle : nil)
                segment("Split", on: model.diffSplit).clickRuns(model.diffSplit ? nil : splitToggle)
            }
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            KeyHint("diff.split", scope: "diff") { EmptyView() }
            KeyHint("overlay.diff", key: "gd") { EmptyView() }
            Text("or").foregroundStyle(Theme.fg3)
            KeyHint("overlay.close", scope: "diff") { EmptyView() }
        }
        .font(Theme.ui(12))
        .padding(.horizontal, 20)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    private var splitToggle: CommandInvocation { CommandInvocation(name: "diff.split") }

    private func segment(_ label: String, on: Bool) -> some View {
        Text(label)
            .font(Theme.ui(12, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? Theme.ink : Theme.fg2)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(on ? Theme.inverse : .clear)
            .fixedSize()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                SectionHeader(title: "Commits")
                KeyHint("diff.commit", scope: "diff") { EmptyView() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            // A click shows that commit alone, or the whole branch again.
            commitRow("all", "\(model.diffCommits.count) commits vs base", on: !isCommitScope)
                .clickRuns(isCommitScope ? CommandInvocation(name: "diff.commit", arguments: ["all"]) : nil)
            ForEach(model.diffCommits) { commit in
                let on = model.diffScope == .commit(commit.sha)
                commitRow(commit.sha, commit.subject, on: on)
                    .clickRuns(on ? nil : CommandInvocation(name: "diff.commit", arguments: [commit.sha]))
            }
            SectionHeader(title: "Files").padding(.horizontal, 14).padding(.top, 18).padding(.bottom, 8)
            ListScroll {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.diffFiles.enumerated()), id: \.element.id) { index, file in
                        if index == 0 || model.diffFiles[index - 1].repo != file.repo, let repo = file.repo {
                            RepoChip(repo: repo).padding(.horizontal, 14).padding(.vertical, 6)
                        }
                        HStack(spacing: 8) {
                            Text(file.status.rawValue).font(Theme.mono(11, weight: .bold))
                                .foregroundStyle(statusColor(file.status))
                            Circle().fill(file.staged ? Theme.done : .clear).overlay(Circle().strokeBorder(Theme.done))
                                .frame(width: 7, height: 7)
                            Text((file.path as NSString).lastPathComponent).font(Theme.mono(12)).lineLimit(1)
                            Spacer()
                            Text("+\(file.additions)").font(Theme.mono(11)).foregroundStyle(Theme.done)
                            if file
                                .deletions >
                                0 { Text("−\(file.deletions)").font(Theme.mono(11)).foregroundStyle(Theme.err) }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(index == model.diffFileIndex ? Theme.bg3 : .clear)
                        .modifier(DiffRowHover(pointer: true))
                        .onTapGesture { model.clickDiffFile(index) }
                        .help(file.path)
                        .rightClickMenu { model.rightClickDiff(file: index, row: nil) } _: {
                            model.diffMenu(file: index, row: nil)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle().fill(Theme.done).frame(width: 7, height: 7)
                    Text("staged")
                }
                HStack(spacing: 4) {
                    Circle().strokeBorder(Theme.done).frame(width: 7, height: 7)
                    Text("not staged")
                }
            }
            .font(Theme.ui(11.5))
            .foregroundStyle(Theme.fg3)
            .padding(14)
        }
        .frame(width: 290)
        .background(Theme.bg2)
        .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
    }

    private var isCommitScope: Bool {
        if case .commit = model.diffScope { true } else { false }
    }

    private func commitRow(_ sha: String, _ subject: String, on: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(sha).font(Theme.mono(11.5)).foregroundStyle(Theme.fg3).frame(width: 56, alignment: .leading)
            Text(subject).font(Theme.mono(11.5)).lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(on ? Theme.bg3 : .clear)
    }

    private func statusColor(_ status: FileDiff.Status) -> Color {
        switch status {
        case .added: Theme.done
        case .deleted: Theme.err
        case .modified, .renamed: Theme.block
        }
    }

    @ViewBuilder private var content: some View {
        if let file = model.currentDiffFile {
            let rows = model.diffRows
            let notes = file.noteCounts(model.sessionNotes)
            let draft = model.diffNote.flatMap { $0.fileID == file.id ? $0 : nil }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text(file.path).font(Theme.mono(12.5, weight: .medium)).lineLimit(1).truncationMode(.head)
                    Text(
                        "\(file.hunks.count) hunk\(file.hunks.count == 1 ? "" : "s") · +\(file.additions) −\(file.deletions)"
                    )
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.fg3)
                    Spacer()
                    Text("\(model.diffFileIndex + 1)/\(model.diffFiles.count)").font(Theme.mono(11.5))
                        .foregroundStyle(Theme.fg3)
                }
                .padding(.horizontal, 18)
                .frame(height: 40)
                .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
                if file.binary {
                    Text("Binary file").foregroundStyle(Theme.fg3).padding(18)
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ListScroll(model.diffSplit ? .vertical : [.vertical, .horizontal]) {
                            ListStack(alignment: .leading, spacing: 0) {
                                if model.diffSplit {
                                    ForEach(Array(file.hunks.enumerated()), id: \.offset) { index, hunk in
                                        hunkHeader(hunk.header, isCursor: false, notes: notes[index] ?? 0)
                                        ForEach(
                                            Array(DiffParser.splitRows(hunk).enumerated()),
                                            id: \.offset
                                        ) { _, pair in
                                            HStack(spacing: 0) {
                                                SplitHalf(line: pair.left, side: .old).frame(
                                                    maxWidth: .infinity,
                                                    alignment: .leading
                                                )
                                                Theme.line.frame(width: 1)
                                                SplitHalf(line: pair.right, side: .new).frame(
                                                    maxWidth: .infinity,
                                                    alignment: .leading
                                                )
                                            }
                                        }
                                        if let draft, draft.hunk == index { NoteBox(draft: draft) }
                                    }
                                } else {
                                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                                        Group {
                                            switch row {
                                            case let .header(hunk, text): hunkHeader(
                                                    text,
                                                    isCursor: index == model.diffRow,
                                                    notes: notes[hunk] ?? 0
                                                )
                                                .modifier(DiffRowHover(pointer: true))
                                                .help("Click to select the hunk")
                                            case let .line(_, line): UnifiedLine(
                                                    line: line,
                                                    isCursor: index == model.diffRow
                                                )
                                                .modifier(DiffRowHover(pointer: false))
                                            }
                                        }
                                        .overlay {
                                            if selection?.contains(index) == true {
                                                Theme.block.opacity(0.18).allowsHitTesting(false)
                                            }
                                        }
                                        .onTapGesture { click(row, at: index) }
                                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                                            model.clickDiffLine(index, open: true)
                                        })
                                        .onGeometryChange(for: CGRect.self) {
                                            $0.frame(in: .named(DiffRowFrames.space))
                                        } action: { rowFrames.rows[index] = $0 }
                                        .rightClickMenu {
                                            model.rightClickDiff(file: model.diffFileIndex, row: index)
                                        } _: {
                                            model.diffMenu(file: model.diffFileIndex, row: index)
                                        }
                                        .id(index)
                                        if let draft, draft.row == index {
                                            NoteBox(draft: draft).frame(width: bodyWidth)
                                        }
                                    }
                                }
                            }
                            .coordinateSpace(.named(DiffRowFrames.space))
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 4, coordinateSpace: .named(DiffRowFrames.space))
                                    .onChanged { drag in
                                        guard !model.diffSplit, let start = rowFrames.row(at: drag.startLocation.y),
                                              let end = rowFrames.row(at: drag.location.y)
                                        else { return }
                                        model.dragDiff(from: start, to: end)
                                    }
                            )
                            .padding(.bottom, 20)
                        }
                        .defaultScrollAnchor(.topLeading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { bodyWidth = $0 }
                        .onChange(of: model.diffRow) { proxy.scrollTo(model.diffRow, anchor: .center) }
                        .onChange(of: file.id) { rowFrames.rows = [:] }
                    }
                }
            }
        } else {
            Text(model.diffLoading ? "Loading the diff…" : "No changes in this scope.")
                .font(Theme.ui(12.5))
                .foregroundStyle(Theme.fg3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selection: ClosedRange<Int>? { model.diffCursor.selection }

    /// A click on a hunk's header selects the hunk, on a line moves the cursor there; ⇧ selects from the cursor.
    private func click(_ row: DiffRow, at index: Int) {
        let shift = NSEvent.modifierFlags.contains(.shift)
        if case let .header(hunk, _) = row, !shift {
            model.clickDiffHunk(hunk)
        } else {
            model.clickDiffLine(index, extend: shift)
        }
    }

    private func hunkHeader(_ text: String, isCursor: Bool, notes: Int) -> some View {
        HStack(spacing: 10) {
            Text(text)
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.fg3)
            if notes > 0 {
                // Notes queued on this hunk, not sent yet.
                HStack(spacing: 4) {
                    Image(systemName: "text.bubble").font(.system(size: 10))
                    Text("\(notes) note\(notes == 1 ? "" : "s")").font(Theme.ui(11, weight: .medium))
                }
                .foregroundStyle(Theme.block)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.block.opacity(0.16)))
                .fixedSize()
            }
        }
        .padding(.leading, 116)
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        .background(isCursor ? Theme.bg3 : Theme.bg2)
    }

    private var footer: some View {
        // Buttons as well as hints: a click runs what the key runs, on the selected lines when there are some.
        let lines = selection != nil
        return HStack(spacing: 14) {
            KeyHint("diff.hunk.next", key: "n N", label: "hunk", color: Theme.fg2)
            KeyHint("diff.file.next", key: "]f [f", label: "file", color: Theme.fg2)
            KeyHint(
                "diff.ask",
                scope: "diff",
                label: lines ? "note on these lines" : "note on this hunk",
                color: Theme.fg2
            )
            KeyHint(
                "diff.ask.now", scope: "diff", label: lines ? "ask about these lines now" : "ask the agent now",
                color: Theme.fg2
            )
            KeyHint("diff.copy", scope: "diff", label: lines ? "copy path:lines" : "copy path:line", color: Theme.fg2)
            KeyHint("diff.edit", scope: "diff", label: "open in editor", color: Theme.fg2)
            if !lines { KeyHint(keys: "v", label: "select lines", color: Theme.fg2) }
            Spacer()
        }
        .font(Theme.ui(12))
        .padding(.horizontal, 20)
        .frame(height: 38)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }
}

/// The unified diff's row frames, in the body's coordinates: a drag looks up the rows under it. Not observed, so a
/// frame changing redraws nothing.
@MainActor final class DiffRowFrames {
    static let space = "diffRows"
    var rows: [Int: CGRect] = [:]

    /// The row at `y`: the last that starts above it, so a drag past the end or over a comment box stays on a row.
    func row(at y: CGFloat) -> Int? {
        rows.filter { $0.value.minY <= y }.max { $0.value.minY < $1.value.minY }?.key
            ?? rows.min { $0.value.minY < $1.value.minY }?.key
    }
}

/// A row of the diff says it can be clicked: a faint highlight while hovered, and the pointing hand where a click
/// does more than move the cursor (a file, a hunk's header).
private struct DiffRowHover: ViewModifier {
    let pointer: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay { if hovering { Theme.fg.opacity(0.04).allowsHitTesting(false) } }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .pointerStyle(pointer ? .link : nil)
    }
}

/// The comment box `a` opens under a hunk: a note for the agent, queued with the PR's feedback (or the session's own
/// queue before it has a PR).
private struct NoteBox: View {
    @Environment(AppModel.self) private var model
    let draft: HunkNoteDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble").font(.system(size: 11))
                Text("Feedback on this hunk").font(Theme.ui(12, weight: .medium))
                Text(verbatim: "\(draft.path):\(draft.line)").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                    .lineLimit(1).truncationMode(.head)
                Spacer()
                let queued = model.queuedNotes(repo: draft.repo)
                if queued > 0 { Text("\(queued) queued").font(Theme.mono(11)).foregroundStyle(Theme.block) }
            }
            .foregroundStyle(Theme.fg2)
            HStack(alignment: .bottom, spacing: 0) {
                Text(draft.text.isEmpty ? " " : draft.text)
                    .font(Theme.ui(13)).foregroundStyle(Theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
                // The caret, as in the filter and Start work's prompt.
                Rectangle().fill(Theme.busy).frame(width: 1.5, height: 15).padding(.bottom, 1)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pane))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.busy.opacity(0.6)))
            // Clickable: each presses its keys into the box.
            HStack(spacing: 12) {
                KeyHint(keys: "<CR>", label: "queue", font: Theme.ui(11.5))
                KeyHint(keys: "<D-CR>", label: "queue and send", font: Theme.ui(11.5))
                KeyHint(keys: "<S-CR>", label: "new line", font: Theme.ui(11.5))
                KeyHint(keys: "<Esc>", label: "cancel", font: Theme.ui(11.5))
                Spacer()
                Text(model.noteDestination(repo: draft.repo)).foregroundStyle(Theme.fg3).lineLimit(1)
            }
            .font(Theme.ui(11.5))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg3))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

private struct UnifiedLine: View {
    let line: DiffLine
    let isCursor: Bool

    var body: some View {
        HStack(spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "").frame(width: 46, alignment: .trailing)
            Text(line.newNumber.map(String.init) ?? "").frame(width: 46, alignment: .trailing)
            Text(marker).frame(width: 24)
            Text(Highlighter.attributed(line)).fixedSize()
            Spacer(minLength: 0)
        }
        .font(Theme.mono(12))
        .foregroundStyle(Theme.fg3)
        .frame(minHeight: 21)
        .background(background)
        .overlay { if isCursor { Rectangle().strokeBorder(Theme.fg2) } }
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .deleted: "−"
        case .context: ""
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: Theme.done.opacity(0.12)
        case .deleted: Theme.err.opacity(0.12)
        case .context: .clear
        }
    }
}

private struct SplitHalf: View {
    enum Side { case old, new }
    let line: DiffLine?
    let side: Side

    var body: some View {
        HStack(spacing: 0) {
            Text(number).frame(width: 46, alignment: .trailing).foregroundStyle(Theme.fg3)
            Text("  ")
            if let line { Text(Highlighter.attributed(line)).lineLimit(1).truncationMode(.tail) }
            Spacer(minLength: 0)
        }
        .font(Theme.mono(12))
        .frame(minHeight: 21)
        .background(background)
    }

    private var number: String {
        guard let line else { return "" }
        return (side == .old ? line.oldNumber : line.newNumber).map(String.init) ?? ""
    }

    private var background: Color {
        switch line?.kind {
        case .added: Theme.done.opacity(0.12)
        case .deleted: Theme.err.opacity(0.12)
        case .context: .clear
        case nil: Theme.bg2
        }
    }
}

/// A small language-agnostic highlighter: comments, strings, numbers and common keywords, plus the word-level
/// change of a paired line. Tree-sitter can replace it per language later.
enum Highlighter {
    static let keywords: Set<String> = [
        "public", "private", "protected", "internal", "static", "final", "sealed", "class", "struct", "enum",
        "interface", "protocol", "extension", "func", "fn", "def", "let", "var", "const", "val", "if", "else", "for",
        "while", "return", "new", "true", "false", "null", "nil", "none", "import", "using", "namespace", "package",
        "async", "await", "try", "catch", "throw", "throws", "switch", "case", "default", "break", "continue", "in",
        "is", "as", "void", "bool", "string", "int", "readonly", "override", "virtual", "self", "this", "super",
        "guard", "where", "type", "impl", "pub", "mut", "match", "from", "export", "function",
    ]

    static func attributed(_ line: DiffLine) -> AttributedString {
        let text = line.text
        var result = AttributedString(text)
        result.foregroundColor = line.kind == .context ? Theme.terminalText : Theme.fg
        let chars = Array(text)
        var index = 0
        func range(_ start: Int, _ end: Int) -> Range<AttributedString.Index>? {
            let lower = result.index(result.startIndex, offsetByCharacters: start)
            let upper = result.index(result.startIndex, offsetByCharacters: end)
            return lower ..< upper
        }
        while index < chars.count {
            let char = chars[index]
            let slashes = char == "/" && index + 1 < chars.count && chars[index + 1] == "/"
            let hash = char == "#" && chars[..<index].allSatisfy(\.isWhitespace)
            if slashes || hash {
                if let span = range(index, chars.count) { result[span].foregroundColor = Theme.dim }
                break
            }
            if char == "\"" || char == "'" || char == "`" {
                var end = index + 1
                while end < chars.count, chars[end] != char {
                    end += chars[end] == "\\" ? 2 : 1
                }
                end = min(end + 1, chars.count)
                if let span = range(index, end) { result[span].foregroundColor = Color(hex: 0xC2D58A) }
                index = end
                continue
            }
            if char.isLetter || char == "_" {
                var end = index
                while end < chars.count, chars[end].isLetter || chars[end].isNumber || chars[end] == "_" {
                    end += 1
                }
                if keywords.contains(String(chars[index ..< end])), let span = range(index, end) {
                    result[span].foregroundColor = Theme.busy
                }
                index = end
                continue
            }
            if char.isNumber, let span = range(index, index + 1) { result[span].foregroundColor = Color(hex: 0xFFB88F) }
            index += 1
        }
        if let changed = line.changed, let span = range(changed.lowerBound, changed.upperBound) {
            result[span].backgroundColor = line.kind == .added ? Theme.done.opacity(0.32) : Theme.err.opacity(0.32)
        }
        return result
    }
}
