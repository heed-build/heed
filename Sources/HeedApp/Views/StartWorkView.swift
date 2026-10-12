import HeedCore
import SwiftUI

/// The Start work dialog (design/screens/StartWork.png). Draws `AppModel.startWork`; keys reach the form through the
/// key router, never through a text field, so focus never leaves the window's one key path.
struct StartWorkView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let form = model.startWork {
            GeometryReader { geometry in
                ZStack {
                    Color.black.opacity(0.55)
                    // Up to the design's 780pt, never wider than the window allows; tall content scrolls.
                    ScrollView {
                        dialog(form)
                            .frame(width: min(780, max(geometry.size.width - 48, 360)))
                            .padding(.vertical, 24)
                    }
                    .scrollIndicators(.never)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func dialog(_ form: StartWorkForm) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Start work").font(Theme.ui(15, weight: .semibold))
                Spacer()
                KeyCap(text: "⌘↩")
                Text(model.startingWork ? "starting…" : "start").foregroundStyle(Theme.fg2)
                KeyCap(text: "⎋")
                Text(form.editing ? "normal" : "cancel").foregroundStyle(Theme.fg2)
            }
            .font(Theme.ui(12))
            .padding(20)

            promptBox(form).padding(.horizontal, 20).padding(.bottom, 16)
            section("Repo", .repo, form) { repoField(form) }
            section("Worktree", .worktree, form) { worktreeField(form) }
            section("Agent", .agent, form) { agentField(form) }
            section("Options", .options, form) { optionsField(form) }
            commandPreview(form)
            footer(form)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.5), radius: 30)
    }

    private func promptBox(_ form: StartWorkForm) -> some View {
        let active = form.field == .prompt
        return HStack(alignment: .top, spacing: 0) {
            (Text(form.prompt.isEmpty && !active ? "Describe the task…" : form.prompt)
                .foregroundStyle(form.prompt.isEmpty ? Theme.fg3 : Theme.fg)
                + Text(active && form.editing ? "▌" : "").foregroundStyle(Theme.done))
                .font(Theme.mono(13))
                .lineSpacing(4)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.pane))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(active ? Theme.fg2 : Theme.line))
    }

    private func section(
        _ title: String, _ field: StartWorkForm.Field, _ form: StartWorkForm, @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            SectionHeader(title: title, tint: form.field == field ? Theme.fg : Theme.fg3)
                .frame(width: 96, alignment: .leading)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 8) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(form.field == field ? Theme.bg3.opacity(0.5) : .clear)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }

    private func repoField(_ form: StartWorkForm) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout {
                ForEach(Array(form.guesses.prefix(6).enumerated()), id: \.element.repo.id) { index, guess in
                    let selected = form.selectedRepos.contains(guess.repo.id)
                    let primary = form.selectedRepos.first == guess.repo.id
                    choice(
                        (selected && !primary ? "+ " : "") + guess.repo.repo.name,
                        detail: guess.confidence > 0 ? "\(guess.confidence)%" : nil,
                        selected: primary, secondary: selected && !primary,
                        focused: form.field == .repo && form.repoCursor == index
                    )
                }
            }
            if form.guesses.isEmpty {
                Text("No repos known yet: they appear once the repo scan finishes.").foregroundStyle(Theme.fg3)
            } else if let reason = form.guesses.first(where: { form.selectedRepos.first == $0.repo.id })?.reason,
                      !reason.isEmpty
            {
                Text(reason).foregroundStyle(Theme.fg3)
            }
        }
        .font(Theme.ui(12))
    }

    private func worktreeField(_ form: StartWorkForm) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout {
                HStack {
                    Text(form.name + (form.field == .worktree && form.editing ? "▌" : ""))
                        .font(Theme.mono(12.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 12)
                    Text("auto-named").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(width: 300)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pane))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(form.field == .worktree ? Theme.fg2 : Theme.line))
                if let primary = form.selectedRecords.first {
                    choice("from origin/\(form.plan.base(for: primary))", selected: false, focused: false)
                }
            }
            ForEach(form.selectedRecords) { record in
                Text(Paths.abbreviate(model.settings.worktreePath(repo: record.repo, name: form.name)))
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.fg3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func agentField(_ form: StartWorkForm) -> some View {
        FlowLayout {
            ForEach(Array(form.agents.enumerated()), id: \.offset) { index, agent in
                choice(
                    agent?.name ?? "none, shell only", selected: index == form.agentIndex,
                    focused: form.field == .agent && index == form.agentIndex
                )
            }
        }
    }

    private func optionsField(_ form: StartWorkForm) -> some View {
        FlowLayout(spacing: 20) {
            toggle(
                "Autostart agent with prompt",
                form.autostart,
                focused: form.field == .options && form.optionCursor == 0
            )
            toggle("Plan first", form.planFirst, focused: form.field == .options && form.optionCursor == 1)
            toggle("Open shell split", form.shellSplit, focused: form.field == .options && form.optionCursor == 2)
        }
    }

    private func commandPreview(_ form: StartWorkForm) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Will run in pane 1")
            HStack(spacing: 6) {
                Text("$").foregroundStyle(Theme.done)
                Text(form.plan.command ?? "(shell only)").lineLimit(4).truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(Theme.mono(12))
            if let error = form.error {
                Text(error).font(Theme.ui(12)).foregroundStyle(Theme.err)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }

    private func footer(_ form: StartWorkForm) -> some View {
        HStack(spacing: 0) {
            Text(form.editing ? "INSERT" : "NORMAL")
                .font(Theme.mono(11.5, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity)
                .background(form.editing ? Theme.done : Theme.inverse)
            Text(form.editing
                ? "⇥ next field · ⌃n ⌃p cycle guess · ⌘V paste · ⎋ then j k h l"
                : "j k field · h l choose · space toggle · i edit · ⌘↩ start · ⎋ cancel")
                .foregroundStyle(Theme.fg3)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 12)
            Spacer()
        }
        .font(Theme.mono(11.5))
        .frame(height: 28)
        .background(Theme.bg3)
    }

    private func choice(
        _ label: String, detail: String? = nil, selected: Bool, secondary: Bool = false, focused: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Text(label).font(Theme.mono(12.5, weight: selected ? .semibold : .regular)).lineLimit(1).fixedSize()
            if let detail { Text(detail).font(Theme.mono(10.5)).foregroundStyle(selected ? Theme.bg3 : Theme.fg3) }
        }
        .foregroundStyle(selected ? Theme.ink : Theme.fg)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.inverse : .clear))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
            focused ? Theme.fg : Theme.line,
            style: StrokeStyle(lineWidth: focused ? 1.5 : 1, dash: secondary ? [3, 2] : [])
        ))
    }

    private func toggle(_ label: String, _ on: Bool, focused: Bool) -> some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(on ? Theme.done : Theme.selected)
                .frame(width: 28, height: 16)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(Theme.fg).frame(width: 12, height: 12).padding(2)
                }
            Text(label).font(Theme.ui(12.5)).foregroundStyle(focused ? Theme.fg : Theme.fg2).fixedSize()
        }
        .padding(4)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Theme.fg2 : .clear))
    }
}
