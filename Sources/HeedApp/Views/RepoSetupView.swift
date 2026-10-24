import HeedCore
import SwiftUI

/// The setup wizard (`repo.setup`): Sample, Propose, Validate, Write, as tabs across the top. Every step works with
/// the keys (j k move, h l change, space writes a setting or not, ↩ next, ⌫ back, ⎋ close) and the mouse (a tab,
/// a value, a checkbox, the buttons).
struct RepoSetupView: View {
    @Environment(AppModel.self) private var model
    let wizard: RepoSetupWizard

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.5).onTapGesture { model.closeRepoSetup() }
                dialog.frame(maxHeight: max(geometry.size.height - 120, 300))
            }
        }
    }

    private var dialog: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Group {
                switch wizard.step {
                case .sample: SampleStepView(wizard: wizard)
                case .propose: ProposeStepView(wizard: wizard)
                case .validate: ValidateStepView(wizard: wizard)
                case .write: WriteStepView(wizard: wizard)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            footer
        }
        .frame(width: 780)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.5), radius: 30)
        .shotRegion(.dialog)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                OrgTile(org: wizard.repo.org, color: wizard.repo.color, size: 18)
                Text("Set up merging and green").font(Theme.ui(15, weight: .semibold))
                Text(wizard.repo.slug).font(Theme.mono(13)).foregroundStyle(Theme.fg2)
                Spacer()
            }
            HStack(spacing: 6) {
                ForEach(RepoSetupWizard.Step.allCases, id: \.self) { step in
                    let current = step == wizard.step
                    let reachable = step == .sample || wizard.sample != nil
                    HStack(spacing: 6) {
                        Text("\(step.rawValue + 1)").font(Theme.mono(11, weight: .bold))
                            .foregroundStyle(current ? Theme.ink : Theme.fg3)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(current ? Theme.inverse : Theme.chip))
                        Text(step.title).font(Theme.ui(12.5, weight: current ? .semibold : .regular))
                            .foregroundStyle(current ? Theme.fg : reachable ? Theme.fg2 : Theme.fg3)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(current ? Theme.bg3 : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { model.repoSetupGo(step) }
                    if step != .write { Text("›").foregroundStyle(Theme.fg3) }
                }
            }
        }
        .padding(18)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(hint).font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
            Spacer()
            button("Cancel", key: "⎋") { model.closeRepoSetup() }
            if wizard.step != .sample { button("Back", key: "⌫") { model.repoSetupBack() } }
            let last = wizard.step == .write
            HStack(spacing: 6) {
                Text(last ? "Write config" : "Next").fontWeight(.semibold)
                KeyCap(text: "↩")
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.inverse))
            .opacity(wizard.sample == nil ? 0.4 : 1)
            .contentShape(Rectangle())
            .onTapGesture { model.repoSetupNext() }
        }
        .font(Theme.ui(12.5))
        .padding(14)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }

    private func button(_ title: String, key: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title)
            KeyCap(text: key)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    private var hint: String {
        switch wizard.step {
        case .sample: wizard.sample == nil ? "reading GitHub · ⎋ close" : "↩ see what heed proposes · ⎋ close"
        case .propose: "j k move · h l change · space write or not · ↩ validate · ⌫ back"
        case .validate: "j k move · o open the GitHub setting · ↩ preview · ⌫ back"
        case .write: "↩ write to config.toml · ⌫ back · ⎋ close without writing"
        }
    }
}

/// Step 1: what is read, as it is read, then what it amounted to and what it cost.
private struct SampleStepView: View {
    let wizard: RepoSetupWizard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("heed reads how this repo merges and how its CI fails. Reads only: nothing on GitHub changes.")
                .font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
            ForEach(GitHub.SampleStep.allCases, id: \.self) { step in
                HStack(spacing: 10) {
                    switch wizard.progress[step] ?? .waiting {
                    case .waiting: StateGlyph(state: .idle)
                    case .running: StateGlyph(state: .working)
                    case .done: StateGlyph(state: .done)
                    }
                    Text(step.rawValue).font(Theme.ui(13))
                        .foregroundStyle(wizard.progress[step] == nil ? Theme.fg3 : Theme.fg)
                }
            }
            if let failure = wizard.failure {
                Text(failure).font(Theme.mono(12)).foregroundStyle(Theme.err).fixedSize(
                    horizontal: false,
                    vertical: true
                )
            }
            if let sample = wizard.sample {
                VStack(alignment: .leading, spacing: 5) {
                    line("\(sample.pulls.count) merged PRs into \(sample.settings.defaultBranch)")
                    line("\(sample.ci.runs) CI runs on PRs, \(sample.ci.failures.count) failed jobs looked at")
                    line(
                        "\(sample.runs.count) get it green run\(sample.runs.count == 1 ? "" : "s") of heed's on this repo"
                    )
                    line("you have \(sample.settings.viewerPermission?.lowercased() ?? "unknown") rights here")
                    Text("\(sample.calls) GitHub calls, \(sample.cost) GraphQL points; each is in the call log (:log).")
                        .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).padding(.top, 4)
                }
                .padding(.top, 6)
            }
        }
        .padding(18)
    }

    private func line(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("·").foregroundStyle(Theme.fg3)
            Text(text).font(Theme.ui(12.5))
        }
    }
}

/// Step 2: each setting with its value, the other values a click away, what applies now, and why.
private struct ProposeStepView: View {
    @Environment(AppModel.self) private var model
    let wizard: RepoSetupWizard

    var body: some View {
        let rows = wizard.rows
        ScrollViewReader { proxy in
            ListScroll {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(SetupField.Section.allCases, id: \.self) { section in
                        Text(section.rawValue.uppercased()).font(Theme.ui(10.5, weight: .semibold)).tracking(0.7)
                            .foregroundStyle(Theme.fg3).padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 4)
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            if fieldIndex(row).map({ wizard.fields[$0].section == section }) == true {
                                rowView(row, index: index).id(index)
                            }
                        }
                        if section == .green {
                            ForEach(wizard.notes, id: \.self) { note in
                                Text(note).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 18).padding(.vertical, 2)
                            }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .onChange(of: wizard.cursor) { proxy.scrollTo(wizard.cursor) }
        }
    }

    private func fieldIndex(_ row: RepoSetupWizard.Row) -> Int? {
        switch row {
        case let .field(index), let .item(index, _): index
        }
    }

    @ViewBuilder private func rowView(_ row: RepoSetupWizard.Row, index: Int) -> some View {
        let isCursor = index == wizard.cursor
        Group {
            switch row {
            case let .field(position):
                fieldView(wizard.fields[position], position: position, row: index)
            case let .item(position, item):
                let field = wizard.fields[position]
                let entry = field.items[item]
                HStack(spacing: 10) {
                    checkbox(entry.on && field.include, row: index)
                    Text(entry.name).font(Theme.mono(12)).foregroundStyle(entry.on ? Theme.fg : Theme.fg3)
                    Text(entry.why).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 40)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .background(isCursor ? Theme.bg3 : .clear)
        .overlay(alignment: .leading) { if isCursor { Theme.block.frame(width: 2) } }
        .contentShape(Rectangle())
        .onTapGesture { model.repoSetupPoint(index) }
    }

    private func fieldView(_ field: SetupField, position: Int, row: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                checkbox(field.include, row: row)
                Text(field.label).font(Theme.ui(13, weight: .medium)).frame(width: 150, alignment: .leading)
                if field.kind == .list {
                    Text(field.items
                        .isEmpty ? "none proposed" : "\(field.items.count { $0.on }) of \(field.items.count)")
                        .font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
                } else {
                    FlowLayout(spacing: 4) {
                        ForEach(Array(field.choices.enumerated()), id: \.offset) { choice, value in
                            let chosen = choice == field.choice
                            Text(value.isEmpty ? "default" : value.count > 40 ? "\(value.prefix(38))…" : value)
                                .font(Theme.mono(11.5))
                                .foregroundStyle(chosen ? Theme.ink : Theme.fg2)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(chosen ? Theme.inverse : Theme.chip))
                                .onTapGesture { model.repoSetupChoose(field: position, choice: choice) }
                        }
                    }
                }
                Spacer(minLength: 8)
                Text("now: \(field.current.isEmpty ? "default" : field.current)")
                    .font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 170, alignment: .trailing)
            }
            Text(field.why).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                .fixedSize(horizontal: false, vertical: true).padding(.leading, 26)
        }
    }

    private func checkbox(_ on: Bool, row: Int) -> some View {
        Image(systemName: on ? "checkmark.square.fill" : "square")
            .font(.system(size: 12)).foregroundStyle(on ? Theme.done : Theme.fg3)
            .frame(width: 16)
            .contentShape(Rectangle())
            .onTapGesture { model.repoSetupToggle(row) }
    }
}

/// Step 3: the merge rules replayed over the sample, and the settings against GitHub's.
private struct ValidateStepView: View {
    @Environment(AppModel.self) private var model
    let wizard: RepoSetupWizard

    var body: some View {
        let validation = wizard.validation
        let fixes = wizard.fixes
        ListScroll {
            VStack(alignment: .leading, spacing: 10) {
                Text("REPLAY").font(Theme.ui(10.5, weight: .semibold)).tracking(0.7).foregroundStyle(Theme.fg3)
                Text(validation?.summary ?? "").font(Theme.ui(13, weight: .medium))
                ForEach(validation?.held.prefix(8) ?? [], id: \.number) { held in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("#\(String(held.number))").font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
                            .frame(width: 54, alignment: .leading)
                        Text(held.title).font(Theme.ui(12)).lineLimit(1).frame(width: 260, alignment: .leading)
                        Text(held.reasons.joined(separator: ", ")).font(Theme.ui(11.5)).foregroundStyle(Theme.block)
                            .lineLimit(1)
                    }
                }
                if let more = validation.map({ $0.held.count - 8 }), more > 0 {
                    Text("and \(more) more").font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                }
                Text("REPO SETTINGS").font(Theme.ui(10.5, weight: .semibold)).tracking(0.7).foregroundStyle(Theme.fg3)
                    .padding(.top, 8)
                ForEach(validation?.checks ?? []) { check in
                    let fix = fixes.firstIndex(of: check)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(symbol(check.level)).font(Theme.mono(12, weight: .bold))
                            .foregroundStyle(color(check.level))
                            .frame(width: 14)
                        Text(check.text).font(Theme.ui(12.5)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if let fix {
                            Text("open in GitHub ↗").font(Theme.ui(11.5)).foregroundStyle(Theme.busy)
                                .onTapGesture { model.repoSetupOpenFix(fix) }
                        }
                    }
                    .padding(.vertical, 4).padding(.horizontal, 8)
                    .background(fix == wizard.cursor && fix != nil ? Theme.bg3 : .clear)
                    .overlay(alignment: .leading) { if fix == wizard.cursor, fix != nil { Theme.block.frame(width: 2) }
                    }
                }
                if validation?.checks.isEmpty == true {
                    Text("Merging is off: nothing to check against GitHub.").font(Theme.ui(12))
                        .foregroundStyle(Theme.fg3)
                }
                Text("heed never changes GitHub's settings: a check that fails says what to change there.")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).padding(.top, 6)
            }
            .padding(18)
        }
    }

    private func symbol(_ level: RepoSetupValidation.Check.Level) -> String {
        switch level {
        case .ok: "✓"
        case .warn: "!"
        case .fail: "✕"
        }
    }

    private func color(_ level: RepoSetupValidation.Check.Level) -> Color {
        switch level {
        case .ok: Theme.done
        case .warn: Theme.block
        case .fail: Theme.err
        }
    }
}

/// Step 4: the exact lines, before anything is written.
private struct WriteStepView: View {
    @Environment(AppModel.self) private var model
    let wizard: RepoSetupWizard

    var body: some View {
        let preview = wizard.preview
        VStack(alignment: .leading, spacing: 10) {
            Text(preview.isEmpty ? "Nothing to write: what heed proposes is already so, or left out."
                :
                "These lines go into \(Paths.abbreviate(model.configFile.path)). Comments and every other key stay as they are.")
                .font(Theme.ui(12.5)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
            if !preview.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(preview.enumerated()), id: \.offset) { index, line in
                        Text(line).font(Theme.mono(12)).foregroundStyle(index == 0 ? Theme.ask : Theme.fg)
                            .textSelection(.enabled).lineLimit(2)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.pane))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
            }
            let fixes = wizard.fixes.count
            if fixes > 0 {
                Text(
                    "\(fixes) GitHub setting\(fixes == 1 ? "" : "s") to change by you (Validate lists them); heed changes none."
                )
                .font(Theme.ui(12)).foregroundStyle(Theme.block)
            }
        }
        .padding(18)
    }
}
