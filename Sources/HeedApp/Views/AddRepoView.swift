import HeedCore
import SwiftUI

/// Repos › Add or clone (`a`): one field, the tabs (your GitHub repos, each org's, a folder on this Mac), each repo
/// saying where it already is, and the footer: the root to clone into, what happens after, Cancel and Clone / Add.
struct AddRepoView: View {
    @Environment(AppModel.self) private var model
    let form: AddRepoForm

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
            VStack(alignment: .leading, spacing: 14) {
                Text("Add or clone a repo").font(Theme.ui(16, weight: .semibold))
                field
                tabs
                if form.currentTab == .folder { folder } else { list }
                if let line = form.problem ?? form.progress ?? form.typedNote {
                    Text(line).font(Theme.ui(12))
                        .foregroundStyle(form.problem != nil ? Theme.err : Theme.fg2)
                }
                Theme.line.frame(height: 1)
                footer
            }
            .padding(22)
            .frame(width: 860)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.5), radius: 30)
            .shotRegion(.addRepo)
        }
    }

    private var field: some View {
        HStack(spacing: 0) {
            CaretText(input: form.input).font(Theme.mono(14)).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.pane))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.fg3))
        .overlay(alignment: .leading) {
            if form.query.isEmpty {
                Text("owner/name, a GitHub URL or a path").font(Theme.mono(14)).foregroundStyle(Theme.fg3)
                    .padding(.leading, 24)
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: 8) {
            ForEach(Array(form.tabs.enumerated()), id: \.offset) { index, tab in
                let current = index == form.tab
                let count = form.count(tab).map { " · \($0)" } ?? ""
                Text(tab.title + count)
                    .font(Theme.ui(12.5, weight: current ? .semibold : .regular))
                    .foregroundStyle(current ? Theme.ink : Theme.fg2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(current ? Theme.inverse : .clear))
                    .overlay(Capsule().strokeBorder(current ? .clear : Theme.line))
                    .contentShape(Capsule())
                    .onTapGesture { model.editAddRepo { $0.select(tab: index) } }
            }
            Spacer(minLength: 8)
            KeyCap(text: "⇥")
            Text("next").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
        }
    }

    @ViewBuilder private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("REPO").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 62)
                Text("PUSHED").frame(width: 120, alignment: .leading)
                Text("HERE").frame(width: 220, alignment: .leading)
            }
            .font(Theme.ui(10.5, weight: .semibold)).tracking(0.7).foregroundStyle(Theme.fg3)
            .padding(.bottom, 6)
            switch form.listState {
            case .loading where form.rows.isEmpty:
                Text("asking GitHub for the list…").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                    .frame(maxWidth: .infinity, minHeight: 120)
            case let .failed(why) where form.rows.isEmpty:
                Text("gh could not list them: \(why)").font(Theme.ui(12)).foregroundStyle(Theme.err)
                    .frame(maxWidth: .infinity, minHeight: 120)
            default:
                let rows = form.rows
                if rows.isEmpty {
                    Text("Nothing matches.").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    let start = max(0, min(form.cursor - 4, rows.count - 9))
                    let shown = Array(rows.enumerated().dropFirst(start).prefix(9))
                    VStack(spacing: 2) {
                        ForEach(shown, id: \.element.listing.repo) { index, row in
                            AddRepoRow(
                                row: row, isCursor: index == form.cursor, picked: form.isPicked(row.listing.repo),
                                query: form.query
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { model.editAddRepo { $0.moveCursor(to: index) } }
                        }
                    }
                }
            }
        }
    }

    private var folder: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let note = form.folderNote {
                HStack(spacing: 8) {
                    Image(systemName: form.folderRepo != nil ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(form.folderRepo != nil ? Theme.done : Theme.fg3)
                    Text(note).font(Theme.mono(12)).foregroundStyle(form.folderRepo != nil ? Theme.fg : Theme.fg3)
                }
                .padding(.vertical, 6)
            }
            ForEach(Array(form.candidates.prefix(8).enumerated()), id: \.element) { index, path in
                HStack(spacing: 8) {
                    Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(Theme.fg3)
                    Text((path as NSString).lastPathComponent + "/").font(Theme.mono(12))
                    Spacer()
                    if index == form.candidate { KeyCap(text: "⇥") }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(index == form.candidate ? Theme.bg3 : .clear))
                .contentShape(Rectangle())
                .onTapGesture { model.editAddRepo { $0.setQuery(Paths.abbreviate(path) + "/") } }
            }
            if form.candidates.isEmpty, form.folderNote == nil {
                Text("Type a path: ~/ completes with ⇥.").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                    .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if form.currentTab != .folder {
                Text("Clone into").font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                DropdownMenu(form.root, size: .small) {
                    ForEach(form.roots, id: \.self) { root in
                        Button(root) { model.editAddRepo { $0.root = root } }
                    }
                }
                KeyCap(text: "⌃r")
            }
            Text("then").font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
            DropdownMenu(form.then.label, size: .small) {
                ForEach(AfterAdd.allCases, id: \.self) { then in
                    Button(then.label) { model.editAddRepo { $0.then = then } }
                }
            }
            KeyCap(text: "⌃t")
            Spacer(minLength: 8)
            Button { model.cancelAddRepo() } label: {
                HStack(spacing: 6) {
                    Text("Cancel")
                    KeyCap(text: "⎋")
                }
            }
            .buttonStyle(DialogButtonStyle())
            Button { model.submitAddRepo() } label: {
                HStack(spacing: 6) {
                    Text(form.submitTitle ?? (form.currentTab == .folder ? "Add" : "Clone"))
                    Text("⌘↩").font(Theme.mono(10.5)).foregroundStyle(Theme.ink.opacity(0.7))
                }
            }
            .buttonStyle(DialogButtonStyle(primary: true))
            .disabled(form.submitTitle == nil || form.progress != nil)
        }
    }
}

/// One repo in a list: picked or not, its tile and name (the typed words marked), what it is, when it was pushed, and
/// where it already is. Archived ones are dimmed.
private struct AddRepoRow: View {
    @Environment(AppModel.self) private var model
    let row: AddRepoForm.Row
    let isCursor: Bool
    let picked: Bool
    let query: String

    var body: some View {
        let listing = row.listing
        HStack(spacing: 0) {
            Image(systemName: picked ? "checkmark.square.fill" : "square")
                .font(.system(size: 14)).foregroundStyle(picked ? Theme.fg : Theme.fg3)
                .frame(width: 30)
                .contentShape(Rectangle())
                .onTapGesture { model.editAddRepo { $0.toggle(listing.repo) } }
            OrgTile(org: listing.repo.org, color: listing.repo.color, size: 16).frame(width: 32, alignment: .leading)
            HStack(spacing: 0) {
                Highlighted(text: listing.repo.slug, query: query, mark: Theme.fg).font(Theme.mono(13))
                    .foregroundStyle(Theme.fg2)
                    .lineLimit(1)
                Text(detail).font(Theme.ui(12)).foregroundStyle(Theme.fg3).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(listing.pushedText(now: Clock.now)).font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
                .frame(width: 120, alignment: .leading)
            Text(row.place.text(archived: listing.isArchived)).font(Theme.mono(11.5))
                .foregroundStyle(row.place.clones && !listing.isArchived ? Theme.busy : Theme.fg2)
                .lineLimit(2)
                .frame(width: 220, alignment: .leading)
        }
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(isCursor ? Theme.bg3 : .clear))
        .opacity(listing.isArchived ? 0.5 : 1)
    }

    private var detail: String {
        let listing = row.listing
        let words = [
            listing.description.isEmpty ? nil : listing.description, listing.isPrivate ? "private" : nil,
            listing.isArchived ? "archived" : nil, row.typed ? "on GitHub" : nil,
        ].compactMap(\.self)
        return words.isEmpty ? "" : " · " + words.joined(separator: " · ")
    }
}
