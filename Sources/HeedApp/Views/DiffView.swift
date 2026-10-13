import HeedCore
import SwiftUI

/// `gd` over a session: commits, files grouped by repo, and the diff (design/screens/Diff.png).
struct DiffOverlayView: View {
    @Environment(AppModel.self) private var model

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
            KeyCap(text: "⇥")
            Text("scope").foregroundStyle(Theme.fg3)
            if model.diffLoading { Text("loading…").foregroundStyle(Theme.fg3) }
            Spacer()
            HStack(spacing: 0) {
                segment("Unified", on: !model.diffSplit)
                segment("Split", on: model.diffSplit)
            }
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            KeyCap(text: "t")
            KeyCap(text: "gd")
            Text("or").foregroundStyle(Theme.fg3)
            KeyCap(text: "⎋")
        }
        .font(Theme.ui(12))
        .padding(.horizontal, 20)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

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
                KeyCap(text: "c")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            commitRow("all", "\(model.diffCommits.count) commits vs base", on: !isCommitScope)
            ForEach(model.diffCommits) { commit in
                commitRow(commit.sha, commit.subject, on: model.diffScope == .commit(commit.sha))
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
                                    ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                                        hunkHeader(hunk.header, isCursor: false)
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
                                    }
                                } else {
                                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                                        Group {
                                            switch row {
                                            case let .header(_, text): hunkHeader(
                                                    text,
                                                    isCursor: index == model.diffRow
                                                )
                                            case let .line(_, line): UnifiedLine(
                                                    line: line,
                                                    isCursor: index == model.diffRow
                                                )
                                            }
                                        }
                                        .id(index)
                                    }
                                }
                            }
                            .padding(.bottom, 20)
                        }
                        .defaultScrollAnchor(.topLeading)
                        .onChange(of: model.diffRow) { proxy.scrollTo(model.diffRow, anchor: .center) }
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

    private func hunkHeader(_ text: String, isCursor: Bool) -> some View {
        Text(text)
            .font(Theme.mono(11.5))
            .foregroundStyle(Theme.fg3)
            .padding(.leading, 116)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .background(isCursor ? Theme.bg3 : Theme.bg2)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("n N", "hunk")
            hint("]f [f", "file")
            hint("a", "ask the agent about this hunk")
            hint("y", "copy path:line")
            hint("e", "open in editor")
            Spacer()
        }
        .font(Theme.ui(12))
        .padding(.horizontal, 20)
        .frame(height: 38)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            KeyCap(text: key)
            Text(label).foregroundStyle(Theme.fg2).fixedSize()
        }
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
