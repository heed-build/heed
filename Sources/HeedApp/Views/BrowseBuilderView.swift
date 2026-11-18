import HeedCore
import SwiftUI

/// The add-filter popover (`/`): the fields, the "Understood as" card for words, a field's value picker with the live
/// count and the raw query, and the Save as query step. It draws a `BrowseBuilder`; the keys are the model's.
struct BrowseBuilderView: View {
    @Environment(AppModel.self) private var model
    let builder: BrowseBuilder

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.scrim.opacity(0.22)
            Group {
                switch builder.stage {
                case .fields: FieldsCard(builder: builder)
                case let .values(field): ValuesCard(builder: builder, field: field)
                case .raw: RawCard(builder: builder)
                case .save: SaveCard(builder: builder)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.5), radius: 30)
            .padding(.leading, builder.stage == .fields ? 340 : 470).padding(.top, builder.stage == .fields ? 122 : 122)
            .shotRegion(.browseBuilder)
        }
    }
}

private func cap(_ text: String) -> some View {
    Text(text).font(Theme.mono(10)).foregroundStyle(Theme.fg3)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.line))
}

private func tokenText(_ token: BrowseToken) -> (String, String) {
    switch token {
    case let .type(type): ("Type", type == .issues ? "Issues" : "PRs")
    case let .state(state): ("State", state.rawValue)
    case let .label(mode, names): (
            mode == .none ? "No label" : mode == .all ? "Labels" : "Label",
            names.joined(separator: ", ")
        )
    case let .repo(value): ("Repo", value)
    case let .org(value): ("Org", value)
    case let .assignee(value): ("Assignee", value)
    case let .author(value): ("Author", value)
    case let .milestone(value): ("Milestone", value)
    case let .project(value): ("Project", value)
    case let .created(span): ("Opened", spanWords(span))
    case let .activity(span): ("Activity", spanWords(span))
    case let .linkedPull(linked): ("Linked PR", linked ? "yes" : "none")
    case let .topic(value): ("Topic", value)
    case let .team(value): ("Team", value)
    case let .language(value): ("Language", value)
    case let .archived(value): ("Archived", value ? "only" : "hidden")
    case let .text(text): ("Text", text)
    case let .raw(text): ("", text)
    case .heedClass, .heedSize, .heedReady: token.heedChip ?? ("", "")
    }
}

private func spanWords(_ span: BrowseSpan) -> String {
    switch span {
    case let .newerThan(days): "within \(days) days"
    case let .olderThan(days): "none in \(days) days"
    }
}

private struct TokenChip: View {
    let token: BrowseToken
    var focused = false

    var body: some View {
        let text = tokenText(token)
        HStack(spacing: 5) {
            if !text.0.isEmpty { Text(text.0).foregroundStyle(Theme.fg2) }
            Text(text.1).fontWeight(.semibold)
        }
        .font(Theme.ui(12.5)).lineLimit(1)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.chip))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
            focused ? Theme.busy : Theme.line,
            lineWidth: focused ? 1.5 : 1
        ))
    }
}

// MARK: Fields

private struct FieldsCard: View {
    @Environment(AppModel.self) private var model
    let builder: BrowseBuilder

    var body: some View {
        let rows = builder.isWords ? BrowseField.allCases : builder.fields
        VStack(alignment: .leading, spacing: 0) {
            if builder.isWords { UnderstoodCard(builder: builder) }
            Text(builder.isWords ? "OR ADD A FILTER" : "ADD A FILTER").font(Theme.mono(10.5, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Theme.fg3).padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 6)
            if rows.isEmpty {
                Text("No filter by that name.").font(Theme.ui(13)).foregroundStyle(Theme.fg3)
                    .padding(.horizontal, 20).padding(.vertical, 8)
            }
            ForEach(Array(rows.enumerated()), id: \.element) { index, field in
                row(field, index: index, selected: index == builder.cursor && !builder.isWords)
            }
            Theme.line.frame(height: 1).padding(.top, 6)
            HStack {
                if builder.input.isEmpty {
                    Text("Type words or a filter name").font(Theme.ui(13)).foregroundStyle(Theme.fg3)
                } else {
                    CaretText(input: builder.input).font(Theme.ui(13.5))
                }
                Spacer()
                cap("esc")
                Text("close").font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
            }
            .padding(.horizontal, 20).padding(.vertical, 11)
        }
        .frame(width: 780)
    }

    private func hint(_ field: BrowseField) -> String {
        if let reason = field.disabledReason { return reason }
        let facets = BrowseFacets(of: builder.context.items)
        func top(_ counts: [String: Int]) -> String {
            let names = BrowseFacets.ranked(counts).prefix(2).map(\.name)
            return names.isEmpty ? field.hint : names.joined(separator: ", ") + "…"
        }
        switch field {
        case .label: return top(facets.labels)
        case .milestone: return top(facets.milestones)
        case .project: return top(facets.projects)
        case .repo: return top(facets.repos)
        default: return field.hint
        }
    }

    private func row(_ field: BrowseField, index: Int, selected: Bool) -> some View {
        let disabled = field.disabledReason != nil
        return HStack(spacing: 14) {
            Image(systemName: field.symbol).font(.system(size: 14)).frame(width: 22)
                .foregroundStyle(field == .heedClass || field == .heedSize || field == .heedReady ? Theme.busy : Theme
                    .fg2)
            Text(field.title).font(Theme.ui(14.5, weight: .semibold)).frame(width: 190, alignment: .leading)
            Text(hint(field)).font(Theme.ui(13.5)).foregroundStyle(Theme.fg2).lineLimit(1)
            Spacer()
            if index < 9, builder.input.isEmpty { cap("\(index + 1)") }
        }
        .padding(.horizontal, 20).padding(.vertical, 7)
        .opacity(disabled ? 0.5 : 1)
        .background(selected ? Theme.bg3 : .clear)
        .contentShape(Rectangle())
        .tap { model.browse.builder?.open(field) }
    }
}

private struct UnderstoodCard: View {
    @Environment(AppModel.self) private var model
    let builder: BrowseBuilder

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("UNDERSTOOD AS", systemImage: "sparkle").font(Theme.mono(11.5, weight: .semibold)).tracking(1)
                .foregroundStyle(Theme.busy)
            content
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    @ViewBuilder private var content: some View {
        if let off = builder.context.wordsOff {
            Text(off).font(Theme.ui(13)).foregroundStyle(Theme.block)
            actions(apply: "Search the words", applyKey: "↩", canEdit: false)
        } else {
            switch builder.reading {
            case .idle:
                Text("“\(builder.sentence)”").font(Theme.ui(13.5))
                Text("↩ asks heed to turn it into filters you can edit. ⌘↩ searches the words as they are.")
                    .font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
            case .reading:
                Text("Reading “\(builder.sentence)”…").font(Theme.ui(13.5)).foregroundStyle(Theme.fg2)
            case let .failed(why):
                Text(why).font(Theme.ui(12.5)).foregroundStyle(Theme.err).lineLimit(3)
                Text("⌘↩ searches the words as text.").font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
            case let .ready(understanding):
                FlowLayout(spacing: 8) {
                    ForEach(Array(builder.understood.enumerated()), id: \.offset) { index, token in
                        TokenChip(token: token, focused: builder.editing && index == builder.tokenCursor)
                    }
                }
                ForEach(understanding.dropped, id: \.self) { line in
                    Label("left out: \(line)", systemImage: "exclamationmark.triangle").font(Theme.ui(12))
                        .foregroundStyle(Theme.block)
                }
                actions(apply: "Apply", applyKey: "↩", canEdit: true)
            }
        }
    }

    private func actions(apply: String, applyKey: String, canEdit: Bool) -> some View {
        HStack(spacing: 14) {
            let match = builder.wouldMatch
            HStack(spacing: 4) {
                Text("\(match.matching)").fontWeight(.semibold)
                Text("of \(match.of) match").foregroundStyle(Theme.fg2)
            }
            .font(Theme.ui(13.5))
            Spacer()
            HStack(spacing: 8) {
                Text(apply).font(Theme.ui(13.5, weight: .semibold))
                Text(applyKey).font(Theme.mono(10)).padding(.horizontal, 5)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.ink))
                    .foregroundStyle(Theme.fg)
            }
            .foregroundStyle(Theme.ink).padding(.horizontal, 16).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
            if canEdit {
                HStack(spacing: 8) {
                    Text("Edit tokens").font(Theme.ui(13.5))
                    cap("⇥")
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                .tap { model.browse.builder?.setEditing() }
            }
        }
    }
}

// MARK: Values

private struct ValuesCard: View {
    @Environment(AppModel.self) private var model
    let builder: BrowseBuilder
    let field: BrowseField

    var body: some View {
        let picker = builder.picker ?? BrowsePicker(options: [], multiple: false)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text(field.title).font(Theme.ui(15, weight: .semibold))
                if field.hasMode { segment }
                Spacer()
                cap("esc")
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Theme.line.frame(height: 1)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.fg2)
                if picker.input.isEmpty {
                    Text("filter \(picker.options.count) \(plural)…").foregroundStyle(Theme.fg3)
                } else {
                    CaretText(input: picker.input)
                }
                Spacer()
            }
            .font(Theme.ui(13.5)).padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
            .padding(.horizontal, 20).padding(.vertical, 12)
            options(picker)
            Theme.line.frame(height: 1).padding(.top, 6)
            footer
        }
        .frame(width: 580)
    }

    private var plural: String {
        switch field {
        case .label: "labels"
        case .repo: "repos"
        case .assignee, .author: "people"
        default: "values"
        }
    }

    private var segment: some View {
        HStack(spacing: 0) {
            ForEach(
                [(BrowseLabelMode.any, "is any of"), (.all, "is all of"), (.none, "is none of")],
                id: \.0
            ) { mode, text in
                Text(text).font(Theme.ui(13)).padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(builder.mode == mode ? Theme.chip : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(builder.mode == mode ? Theme.line : .clear))
                    .foregroundStyle(builder.mode == mode ? Theme.fg : Theme.fg2)
                    .contentShape(Rectangle())
                    .tap { while model.browse.builder?.mode != mode {
                        model.browse.builder?.cycleMode(by: 1)
                    } }
            }
        }
        .padding(2).background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
    }

    @ViewBuilder private func options(_ picker: BrowsePicker) -> some View {
        let visible = picker.visible
        let window = Array(visible.enumerated()).filter { index, _ in
            let first = max(0, min(picker.cursor - 3, visible.count - 7))
            return index >= first && index < first + 7
        }
        let top = max(visible.compactMap(\.count).max() ?? 1, 1)
        VStack(spacing: 0) {
            ForEach(window, id: \.element.value) { index, option in
                let on = picker.selected.contains(option.value)
                HStack(spacing: 12) {
                    Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 16))
                        .foregroundStyle(on ? Theme.busy : Theme.fg3)
                    if field == .label { Circle().fill(labelColor(option.value)).frame(width: 9, height: 9) }
                    Text(option.label).font(Theme.ui(14))
                    Spacer()
                    if let count = option.count {
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.chip).frame(width: 126, height: 4)
                            Capsule().fill(field == .label ? labelColor(option.value) : Theme.busy)
                                .frame(width: max(126 * CGFloat(count) / CGFloat(top), 4), height: 4)
                        }
                        Text("\(count)").font(Theme.mono(12)).foregroundStyle(Theme.fg2).frame(
                            width: 30,
                            alignment: .trailing
                        )
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 7)
                .background(index == picker.cursor ? Theme.bg3 : .clear)
                .contentShape(Rectangle())
                .tap { model.browse.builder?.tick(option.value) }
            }
            if visible.isEmpty {
                Text("Nothing by that name in the \(builder.context.items.count) items Browse holds.")
                    .font(Theme.ui(13)).foregroundStyle(Theme.fg3).padding(.vertical, 12)
            }
        }
    }

    private var footer: some View {
        let match = builder.wouldMatch
        let bars = builder.histogram
        let top = max(bars.map(\.total).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("would match").font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(match.matching)").font(Theme.ui(26, weight: .bold))
                        Text("of \(match.of) · live").font(Theme.ui(13)).foregroundStyle(Theme.fg2)
                    }
                }
                Spacer()
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.chip)
                                .frame(width: 16, height: max(4, 34 * CGFloat(bar.total) / CGFloat(top)))
                            RoundedRectangle(cornerRadius: 2).fill(Theme.busy)
                                .frame(
                                    width: 16,
                                    height: bar.matching == 0 ? 0 : max(4, 34 * CGFloat(bar.matching) / CGFloat(top))
                                )
                        }
                        .frame(height: 34, alignment: .bottom)
                    }
                }
            }
            HStack(alignment: .top) {
                Text(builder.raw).font(Theme.mono(12)).foregroundStyle(Theme.fg).fixedSize(
                    horizontal: false,
                    vertical: true
                )
                Spacer(minLength: 8)
                cap("⌘C")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Text("Done").font(Theme.ui(14, weight: .semibold))
                    Text("↩").font(Theme.mono(10)).padding(.horizontal, 5)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.bg)).foregroundStyle(Theme.fg)
                }
                .foregroundStyle(Theme.ink).padding(.horizontal, 16).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
                HStack(spacing: 8) {
                    Text("Save as query").font(Theme.ui(14))
                    cap("⌘S")
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                .tap { model.browse.builder?.startSaving() }
                Spacer()
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }
}

// MARK: Raw and save

private struct RawCard: View {
    let builder: BrowseBuilder

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("GitHub query").font(Theme.ui(15, weight: .semibold))
                Spacer()
                cap("esc")
            }
            CaretText(input: builder.input).font(Theme.mono(13))
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
            let parsed = builder.parsedRaw
            FlowLayout(spacing: 8) {
                ForEach(Array(parsed.tokens.enumerated()), id: \.offset) { _, token in TokenChip(token: token) }
            }
            Text("Paste or type any GitHub search. ↩ reads it into filters; what heed does not model stays as written.")
                .font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
        }
        .padding(20).frame(width: 640)
    }
}

private struct SaveCard: View {
    @Environment(AppModel.self) private var model
    let builder: BrowseBuilder

    var body: some View {
        let draft = builder.draft
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(draft?.id == nil ? "Save as query" : "Rename query").font(Theme.ui(15, weight: .semibold))
                Spacer()
                cap("esc")
            }
            if let draft {
                CaretText(input: draft.name).font(Theme.ui(14))
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                HStack(spacing: 6) {
                    ForEach(BrowseGlyph.allCases, id: \.self) { glyph in
                        Image(systemName: glyph.symbol).font(.system(size: 14)).frame(width: 32, height: 32)
                            .foregroundStyle(draft.tint.color)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(glyph == draft.glyph ? Theme.chip : .clear))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(glyph == draft.glyph ? Theme.fg2 : Theme.line))
                            .tap { model.browse.builder?.choose(glyph: glyph) }
                    }
                }
                HStack(spacing: 8) {
                    ForEach(BrowseTint.allCases, id: \.self) { tint in
                        Circle().fill(tint.color).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(Theme.fg, lineWidth: tint == draft.tint ? 2 : 0))
                            .tap { model.browse.builder?.choose(tint: tint) }
                    }
                }
            }
            HStack(spacing: 10) {
                Text("Save").font(Theme.ui(14, weight: .semibold)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
                Text("↩ save · ⇥ next glyph · ⌃t next tint").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
            }
            Text(builder.raw).font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
        }
        .padding(20).frame(width: 520)
    }
}
