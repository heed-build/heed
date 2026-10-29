import HeedCore
import SwiftUI

/// The Start work dialog (design/screens/StartWork.png). Draws `AppModel.startWork`; keys reach the form through the
/// key router, never through a text field, so focus never leaves the window's one key path.
struct StartWorkView: View {
    @Environment(AppModel.self) private var model
    /// In its own panel over other apps: just the dialog, sized to its content, no backdrop.
    var standalone = false

    var body: some View {
        if standalone {
            if let form = model.startWork {
                let screen = NSScreen.main?.visibleFrame.height ?? 900
                dialog(form, promptCap: max(96, min(320, screen * 0.3)))
                    .frame(width: 780)
                    .shotRegion(.dialog)
                    .padding(30) // room for the shadow inside the transparent panel
            }
        } else if let form = model.startWork {
            GeometryReader { geometry in
                ZStack {
                    // A click on the backdrop cancels, as a click away from the floating panel does.
                    Color.black.opacity(0.55)
                        .onTapGesture { model.cancelStartWork() }
                    // Up to the design's 780pt wide, never wider than the window; the prompt grows with what is typed
                    // up to a cap and scrolls past it, and the whole dialog scrolls only if the window is very short.
                    ListScroll {
                        dialog(form, promptCap: max(96, min(320, geometry.size.height * 0.35)))
                            .frame(width: min(780, max(geometry.size.width - 48, 360)))
                            .shotRegion(.dialog)
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                            .contentShape(Rectangle())
                            .onTapGesture { model.cancelStartWork() }
                    }
                    .scrollIndicators(.never)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func dialog(_ form: StartWorkForm, promptCap: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(form.promotion != nil ? "Promote chat" : form.chat == nil ? "Start work" : "New chat")
                    .font(Theme.ui(15, weight: .semibold))
                Spacer()
                KeyCap(text: "⎋")
                Text(form.editing ? "normal" : "cancel").foregroundStyle(Theme.fg2)
            }
            .font(Theme.ui(12))
            .padding(20)

            if let promotion = form.promotion { promotionNote(promotion, form).padding(.horizontal, 20) }
            promptBox(form, cap: promptCap).padding(.horizontal, 20).padding(.bottom, 16)
            section("Repo", .repo, form) { repoField(form) }
            if form.chat != nil {
                section("Folder", .worktree, form) { folderField(form) }
            } else {
                section("Worktree", .worktree, form) { worktreeField(form) }
            }
            section("Agent", .agent, form) { agentField(form) }
            if form.fields.contains(.model) || form.fields.contains(.effort) {
                section("Model", form.fields.contains(.model) ? .model : .effort, form, also: .effort) {
                    modelField(form)
                }
            }
            section("Options", .options, form) { optionsField(form) }
            commandPreview(form)
            actions(form)
            footer(form)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg2))
        // A click on the dialog where nothing answers it stays in the dialog: it never reaches the backdrop.
        .contentShape(Rectangle())
        .onTapGesture {}
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.5), radius: 30)
    }

    private func promptBox(_ form: StartWorkForm, cap: CGFloat) -> some View {
        let active = form.field == .prompt
        // Grows with the text up to `cap`, then scrolls, kept at the end where the typing happens.
        return ListScroll {
            (Text(form.prompt.isEmpty && !active ? form.chat == nil ? "Describe the task…" : "Ask anything…" : form
                    .prompt)
                .foregroundStyle(form.prompt.isEmpty ? Theme.fg3 : Theme.fg)
                + Text(active && form.editing ? "▌" : "").foregroundStyle(Theme.done))
                .font(Theme.mono(13))
                .lineSpacing(4)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                .padding(14)
        }
        .defaultScrollAnchor(.bottom)
        .scrollBounceBehavior(.basedOnSize)
        .frame(minHeight: 92, maxHeight: cap)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.pane))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(active ? Theme.fg2 : Theme.line))
        .contentShape(Rectangle())
        .onTapGesture { model.clickStartWork { $0.focus(field: .prompt, edit: true) } }
    }

    private func section(
        _ title: String, _ field: StartWorkForm.Field, _ form: StartWorkForm, also: StartWorkForm.Field? = nil,
        @ViewBuilder content: () -> some View
    ) -> some View {
        let active = form.field == field || (also != nil && form.field == also)
        return HStack(alignment: .top, spacing: 0) {
            SectionHeader(title: title, tint: active ? Theme.fg : Theme.fg3)
                .frame(width: 96, alignment: .leading)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 8) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(active ? Theme.bg3.opacity(0.5) : .clear)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
        // A click on the section, not on one of its chips: that field has focus.
        .contentShape(Rectangle())
        .onTapGesture { model.clickStartWork { $0.focus(field: field) } }
    }

    private func repoField(_ form: StartWorkForm) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout {
                ForEach(Array(form.repoChoices.enumerated()), id: \.element.repo.id) { index, guess in
                    let selected = form.selectedRepos.contains(guess.repo.id)
                    let primary = form.selectedRepos.first == guess.repo.id
                    choice(
                        (selected && !primary ? "+ " : "") + guess.repo.repo.name
                            + (guess.repo.location.hostName.map { " @\($0)" } ?? ""),
                        detail: guess.confidence > 0 ? "\(guess.confidence)%" : nil,
                        selected: primary, secondary: selected && !primary,
                        focused: form.field == .repo && form.repoCursor == index
                    )
                    .onTapGesture { model.clickStartWork { $0.pickRepo(at: index) } }
                }
                // Typed repos that are not on this Mac yet: cloned when the work starts; a click drops one.
                ForEach(form.typedRepos, id: \.self) { slug in
                    choice("+ " + slug, detail: "clones", selected: false, secondary: true, focused: false)
                        .onTapGesture { model.clickStartWork { $0.dropTyped(slug) } }
                        .help(
                            "Not on this Mac yet: cloned into \(form.cloneRoot) when the work starts. Click to drop it."
                        )
                }
                if form.repoSearch == nil, !form.guesses.isEmpty {
                    choice(
                        "other repo…", detail: "/", selected: false,
                        focused: form.field == .repo && form.repoCursor == form.repoChoices.count
                    )
                    .opacity(0.85)
                    .onTapGesture { model.clickStartWork { $0.pickRepo(at: $0.repoChoices.count) } }
                }
                if form.promotion == nil {
                    choice(
                        "chat, no repo", selected: form.chat != nil,
                        focused: form.field == .repo && form.repoCursor == form.chatChipIndex
                    )
                    .onTapGesture { model.clickStartWork { $0.pickRepo(at: $0.chatChipIndex) } }
                }
            }
            if let search = form.repoSearch { repoSearch(search, note: form.searchNote) }
            FieldNoteView(note: form.cloneNote)
            if form.chat != nil {
                Text("A chat: the agent works in a folder, with no repo, worktree or branch.")
                    .foregroundStyle(Theme.fg3)
            } else if form.guesses.isEmpty {
                Text("No repos known yet: they appear once the repo scan finishes.").foregroundStyle(Theme.fg3)
            } else if let reason = form.guesses.first(where: { form.selectedRepos.first == $0.repo.id })?.reason,
                      !reason.isEmpty
            {
                Text(reason).foregroundStyle(Theme.fg3)
            }
        }
        .font(Theme.ui(12))
    }

    /// Any repo by name: what is typed, then the best matches (most recently worked in first), the cursor on one.
    private func repoSearch(_ search: Typeahead<RepoRecord>, note: FieldNote?) -> some View {
        let matches = search.matches
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.fg3)
                Text(search.query + "▌").font(Theme.mono(12.5))
                Spacer()
                Text("\(matches.count) of \(search.items.count)").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
            ForEach(Array(matches.prefix(8).enumerated()), id: \.element.id) { index, record in
                HStack(spacing: 8) {
                    OrgTile(org: record.repo.org, color: record.repo.color, size: 14)
                    Text(record.repo.slug).font(Theme.mono(12)).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(index == search.cursor ? Theme.bg3 : .clear)
                .contentShape(Rectangle())
                .onTapGesture { model.clickStartWork { $0.pickSearchMatch(at: index) } }
            }
            if matches.count > 8 {
                Text("\(matches.count - 8) more: keep typing").font(Theme.ui(11)).foregroundStyle(Theme.fg3)
                    .padding(.horizontal, 10).padding(.vertical, 5)
            }
            // Nothing heed knows matches: what is typed is read as any repo (owner/name, a GitHub URL, a path).
            if note != nil {
                FieldNoteView(note: note).padding(.horizontal, 10).padding(.vertical, 5)
            }
            Text("⌃n ⌃p move · ↩ add · any repo: owner/name, a GitHub URL or a path · ⎋ close").font(Theme.ui(11))
                .foregroundStyle(Theme.fg3)
                .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .frame(maxWidth: 460, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pane))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.fg2))
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
                    // The on-device model is thinking about a better name (and repo): the name may still change.
                    Text(form.thinking ? "thinking…" : "auto-named").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(width: 380)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pane))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(form.field == .worktree ? Theme.fg2 : Theme.line))
                .contentShape(Rectangle())
                .onTapGesture { model.clickStartWork { $0.focus(field: .worktree, edit: true) } }
                if let primary = form.selectedRecords.first {
                    choice("from origin/\(form.plan.base(for: primary))", selected: false, focused: false)
                }
            }
            ForEach(form.selectedRecords) { record in
                Text(Paths.abbreviate(StartWork.worktreePath(
                    for: record, name: form.name, settings: model.settings, hosts: model.config.hosts
                )))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.fg3)
                .lineLimit(1)
                .truncationMode(.middle)
            }
        }
    }

    /// A chat's folder: a scratch folder heed makes (its name editable) or one you pick (its path typed), and where
    /// it runs.
    private func folderField(_ form: StartWorkForm) -> some View {
        let chips = form.chatChips
        let cursor = form.chat?.cursor ?? 0
        let picked = form.chat?.kind == .folder
        let plan = form.plan.chat
        return VStack(alignment: .leading, spacing: 8) {
            FlowLayout {
                ForEach(Array(chips.enumerated()), id: \.offset) { index, chip in
                    choice(
                        chip.label, selected: chip.selected,
                        focused: form.field == .worktree && !form.editing && cursor == index
                    )
                    .onTapGesture { model.clickStartWork { $0.pickChatChip(index) } }
                    .padding(.leading, index == 2 ? 12 : 0)
                }
            }
            HStack {
                Text((picked ? form.chat?.path ?? "" : form.name) +
                    (form.field == .worktree && form.editing ? "▌" : ""))
                    .font(Theme.mono(12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                Text(picked ? "path" : "auto-named").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(width: 380)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pane))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(form.field == .worktree ? Theme.fg2 : Theme.line))
            .contentShape(Rectangle())
            .onTapGesture { model.clickStartWork { $0.focus(field: .worktree, edit: true) } }
            if let plan {
                Text(picked ? "The agent works in this folder with its normal permissions; heed never removes it."
                    :
                    "\(Paths.tilde(plan.path)) · an empty folder heed makes; with cleanup on, the sweep removes it 30 days after the chat closes, unless pinned")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.fg3)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
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
                .onTapGesture { model.clickStartWork { $0.pickAgent(at: index) } }
            }
        }
    }

    /// The agent's model and effort: chips that `h l` step through (a click opens the list), and the custom id typed
    /// in once Custom… is picked.
    @ViewBuilder private func modelField(_ form: StartWorkForm) -> some View {
        if let catalog = form.catalog {
            let efforts = ModelPicker.efforts(catalog, model: form.model, current: form.effort)
            VStack(alignment: .leading, spacing: 6) {
                FlowLayout {
                    if catalog.takesModel {
                        let option = ModelPicker.models(catalog).first { $0.tag == form.modelSelection }
                        menu(ModelPicker.models(catalog).map { ($0.tag, ModelMenuPicker.text($0)) }) { tag in
                            model.clickStartWork { $0.pickModel(tag) }
                        } label: {
                            choice(
                                modelLabel(option, form), detail: option?.detail, selected: false,
                                focused: form.field == .model && !form.editing
                            )
                        }
                    }
                    if form.customModel {
                        Text((form.model ?? "") + (form.field == .model && form.editing ? "▌" : ""))
                            .font(Theme.mono(12.5))
                            .foregroundStyle(Theme.fg)
                            .frame(minWidth: 160, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pane))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(form.field == .model && form.editing ? Theme.fg2 : Theme.line))
                            .overlay(alignment: .leading) {
                                if (form.model ?? "").isEmpty, !(form.field == .model && form.editing) {
                                    Text("model id").font(Theme.mono(12.5)).foregroundStyle(Theme.fg3).padding(
                                        .leading,
                                        10
                                    )
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { model.clickStartWork { $0.focus(field: .model, edit: true) } }
                    }
                    if !efforts.isEmpty {
                        let picked = efforts.first { $0.tag == (form.effort ?? ModelPicker.defaultTag) }
                        menu(efforts.map { ($0.tag, $0.label) }) { tag in
                            model.clickStartWork { $0.pickEffort(tag) }
                        } label: {
                            choice(
                                "effort: " + (picked?.label ?? form.effort ?? ""), selected: false,
                                focused: form.field == .effort
                            )
                        }
                    }
                }
                if let problem = form.modelProblem, form.field == .model {
                    Text(problem).font(Theme.ui(11.5)).foregroundStyle(Theme.block)
                }
            }
        }
    }

    private func modelLabel(_ option: ModelPicker.Option?, _ form: StartWorkForm) -> String {
        option?.label ?? form.model ?? "agent's default"
    }

    /// A chip that opens a menu of `items` (tag, title) on a click; the chip alone in shots.
    @ViewBuilder private func menu(
        _ items: [(String, String)], pick: @escaping (String) -> Void, @ViewBuilder label: () -> some View
    ) -> some View {
        if ShotMode.active {
            label()
        } else {
            Menu {
                ForEach(items, id: \.0) { item in Button(item.1) { pick(item.0) } }
            } label: { label() }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }

    private func optionsField(_ form: StartWorkForm) -> some View {
        FlowLayout(spacing: 20) {
            toggle(
                "Autostart agent with prompt",
                form.autostart,
                .autostart,
                form
            )
            toggle("Plan first", form.planFirst, .planFirst, form)
            toggle("Open shell split", form.shellSplit, .shellSplit, form)
            if form.options.contains(.copyFiles), let promotion = form.promotion {
                toggle(
                    "Copy its \(promotion.files.count) file\(promotion.files.count == 1 ? "" : "s") into the worktree",
                    promotion.copyFiles, .copyFiles, form
                )
            }
        }
    }

    /// What the new agent gets of the chat: its conversation resumed (claude to claude), or a handoff prompt.
    private func promotionNote(_ promotion: Promotion, _ form: StartWorkForm) -> some View {
        let resumed = promotion.resuming(with: form.agent) != nil
        let parts = [
            promotion.transcript.map { _ in "its transcript" },
            "\(promotion.prompts.count) prompt\(promotion.prompts.count == 1 ? "" : "s")",
            promotion.files
                .isEmpty ? nil : "\(promotion.files.count) file\(promotion.files.count == 1 ? "" : "s") listed",
        ].compactMap(\.self)
        return HStack(alignment: .top, spacing: 8) {
            ChatGlyph(size: 12).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("From the chat “\(promotion.chatTitle)”").font(Theme.ui(12.5, weight: .medium))
                Text(resumed
                    ? "claude resumes the chat's conversation in the new worktree; the chat closes into History."
                    : "\(form.agent?.name ?? "The agent") starts on a handoff prompt: "
                    + parts.joined(separator: ", ") + ". The chat closes into History.")
                    .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.pane))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
        .padding(.bottom, 12)
    }

    private func commandPreview(_ form: StartWorkForm) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: runsWhere(form))
            HStack(spacing: 6) {
                Text("$").foregroundStyle(Theme.done)
                Text(form.plan.command?.posix ?? "(shell only)").lineLimit(4).truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(Theme.mono(12))
            if let error = form.error ?? model.startWorkError {
                Text(error).font(Theme.ui(12)).foregroundStyle(Theme.err)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }

    /// Where the first pane runs: here, or on a host in zmx (or plain ssh, which a dropped link ends).
    private func runsWhere(_ form: StartWorkForm) -> String {
        guard let host = form.plan.location.hostName else { return "Will run in pane 1" }
        if case let .connected(info) = model.hostStatus(host), info.zmxPath != nil {
            return "Will run on @\(host) in zmx"
        }
        return "Will run on @\(host) · not persistent"
    }

    /// Cancel and Start, for the mouse: exactly ⎋ (in NORMAL) and ⌘↩.
    private func actions(_ form: StartWorkForm) -> some View {
        let label = form.promotion != nil ? "Promote" : form.chat == nil ? "Start" : "Start chat"
        return HStack(spacing: 10) {
            Spacer()
            HStack(spacing: 6) {
                Text("Cancel")
                if !form.editing { KeyCap(text: "⎋") }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
            .contentShape(Rectangle())
            .onTapGesture { model.cancelStartWork() }
            .opacity(model.startingWork ? 0.5 : 1)
            .disabled(model.startingWork)
            HStack(spacing: 6) {
                Text(model.startingWork ? "Starting…" : label).fontWeight(.semibold)
                KeyCap(text: "⌘↩")
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.inverse))
            .contentShape(Rectangle())
            .onTapGesture { model.startWorkClicked() }
            .opacity(model.startingWork ? 0.5 : 1)
            .disabled(model.startingWork)
        }
        .font(Theme.ui(12.5))
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
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

    private func toggle(
        _ label: String, _ on: Bool, _ option: StartWorkForm.Option, _ form: StartWorkForm
    ) -> some View {
        let focused = form.field == .options && form.options.firstIndex(of: option) == form.optionCursor
        return HStack(spacing: 8) {
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
        .contentShape(Rectangle())
        .onTapGesture { model.clickStartWork { $0.toggleOption(option) } }
    }
}
