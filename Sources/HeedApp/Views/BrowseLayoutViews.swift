import HeedCore
import SwiftUI

// Browse's half and third layouts: the pushed reader's bar, the compact header and rows, the jump sheet and the
// row of extra actions. The thresholds are `BrowseLayout`'s.

/// A square that says whether a row is picked.
struct PickBox: View {
    let on: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(on ? Theme.busy : .clear)
            RoundedRectangle(cornerRadius: 4).strokeBorder(on ? Theme.busy : Theme.keyCapBorder, lineWidth: 1.4)
            if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.ink) }
        }
        .frame(width: 18, height: 18)
    }
}

/// The readiness ring without its number, for rows that have no room for the columns.
struct BrowseReadRing: View {
    @Environment(AppModel.self) private var model
    let item: BrowseItem

    var body: some View {
        if item.kind == .issue, let read = model.browseReadState(item).read {
            ReadyRing(read: read, number: false)
        } else if model.browse.reads[item.id] == nil {
            Text("unread").font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).fixedSize()
        }
    }
}

/// `← Browse esc   1 of 47   j k`: over a pushed reader. esc (or a click) goes back to the list with the cursor kept.
struct BrowseReaderBar: View {
    let layout: BrowseLayout
    let index: Int
    let count: Int

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.left").font(.system(size: 12))
                if layout == .half { Text("Browse").font(Theme.ui(14)) }
                KeyCap(text: "esc")
            }
            .foregroundStyle(Theme.fg)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.keyCapBorder))
            .contentShape(Rectangle())
            .clickRuns(CommandInvocation(name: "browse.run.close"))
            Text("\(index + 1) of \(count)").font(Theme.ui(13)).foregroundStyle(Theme.fg3)
            Spacer()
            KeyCap(text: "j")
            KeyCap(text: "k")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

/// Third width: the scope chip (opens the jump sheet), the filters chip (opens the add-filter popover) and search.
struct BrowseCompactHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let query = model.browse.query
        let filters = query.tokens.filter { token in
            switch token {
            case .type, .state(.open): false
            default: true
            }
        }.count + 2
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                if let scope = query.scope {
                    Text(String(scope.title.prefix(1)).uppercased()).font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.ink).frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Repo(org: scope.owner, name: "").color.foreground))
                    Text(scope.title).font(Theme.ui(14.5, weight: .semibold)).lineLimit(1)
                } else {
                    Text("Pick a scope").font(Theme.ui(14.5, weight: .semibold))
                }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.fg3)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
            .contentShape(Rectangle())
            .tap { model.browse.jumpSheet = true }
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11))
                Text("\(filters)").font(Theme.ui(14.5, weight: .semibold))
                Text("filters").font(Theme.ui(14.5)).foregroundStyle(Theme.fg2)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
            .contentShape(Rectangle())
            .clickRuns(CommandInvocation(name: "browse.filter.add"))
            Spacer(minLength: 0)
            Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(Theme.fg2)
                .padding(8).contentShape(Rectangle())
                .clickRuns(CommandInvocation(name: "browse.scope"))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

/// Third width: two lines a row. The title leads, then the repo, the class and the ring, the suggested verb at the
/// right, and the age.
struct BrowseCompactRow: View {
    @Environment(AppModel.self) private var model
    let item: BrowseItem
    let index: Int
    let cursor: Int
    let picked: Set<String>

    var body: some View {
        let isPicked = picked.contains(item.id)
        HStack(alignment: .top, spacing: 10) {
            if !picked.isEmpty { PickBox(on: isPicked).padding(.top, 1) }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    TypeTag(item: item)
                    Text(item.title.display).font(Theme.ui(14.5)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    RepoChip(repo: item.repo).fixedSize()
                    if let read = model.browseReadState(item).read {
                        Image(systemName: read.kind.symbol).font(.system(size: 12.5)).foregroundStyle(read.kind.tint)
                        if item.kind == .issue { ReadyRing(read: read, number: false) }
                    } else {
                        Text("unread").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                    }
                    Spacer(minLength: 0)
                    BrowseVerbHint(item: item)
                }
            }
            Text(shortAge(item.updatedAt)).font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
                .frame(width: 30, alignment: .trailing).padding(.top, 2)
        }
        .padding(.leading, picked.isEmpty ? 14 : 12).padding(.trailing, 14).padding(.vertical, 9)
        .overlay(alignment: .leading) { if index == cursor { Theme.busy.frame(width: 2) } }
        .background(isPicked ? Theme.block.opacity(0.16) : index == cursor ? Theme.bg3 : .clear)
        .overlay(alignment: .bottom) { Theme.line.opacity(0.6).frame(height: 1) }
    }
}

/// Third width: the rail's content as a sheet over the list: the saved queries, then the scopes. A click goes there;
/// ⌘K (or the search) types to find any org, repo or Project.
struct BrowseJumpSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let browse = model.browse
        ZStack(alignment: .topLeading) {
            Theme.scrim.opacity(0.55)
                .contentShape(Rectangle())
                .onTapGesture { model.browse.jumpSheet = false }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.fg2)
                    Text("jump to org, repo or query").font(Theme.ui(16)).foregroundStyle(Theme.fg2)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.browse.jumpSheet = false
                    model.perform(CommandInvocation(name: "browse.scope"))
                }
                section("Queries")
                ForEach(browse.queries) { saved in
                    row(active: browse.activeQuery == saved.id, count: browse.count(of: saved)) {
                        Image(systemName: saved.glyph.symbol).font(.system(size: 14)).foregroundStyle(saved.tint.color)
                            .frame(width: 24)
                        Text(saved.name).font(Theme.ui(15.5))
                    } go: {
                        model.browse.run(saved)
                        model.browseOpenedQuery()
                    }
                }
                section("Scopes")
                ForEach(browse.scopes, id: \.id) { scope in
                    row(active: browse.scope == scope, count: browse.count(of: scope)) {
                        scopeMark(scope)
                        Text(scope.title).font(Theme.ui(15.5))
                    } go: {
                        model.browse.go(to: scope)
                        model.browseOpenedQuery()
                    }
                }
            }
            .padding(.bottom, 10)
            .frame(maxWidth: 680, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.5), radius: 24)
            .padding(.leading, 20).padding(.trailing, 20).padding(.top, 62)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).font(Theme.mono(11, weight: .semibold)).tracking(1.2).foregroundStyle(Theme.fg3)
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)
    }

    private func row(
        active: Bool, count: Int, @ViewBuilder label: () -> some View, go: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            label()
            Spacer()
            Text("\(count)").font(Theme.mono(12)).foregroundStyle(Theme.fg3)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(active ? Theme.bg3 : .clear)
        .overlay(alignment: .leading) { if active { Theme.fg.frame(width: 2) } }
        .contentShape(Rectangle())
        .onTapGesture {
            model.browse.jumpSheet = false
            go()
        }
    }

    @ViewBuilder private func scopeMark(_ scope: BrowseScope) -> some View {
        switch scope {
        case let .org(org):
            Text(String(org.prefix(1)).uppercased()).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Repo(org: org, name: "").color.foreground))
        case let .repo(repo):
            Text(String(repo.name.prefix(1)).uppercased()).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(repo.color.foreground).frame(width: 22, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(repo.color.foreground, lineWidth: 1.2))
                .padding(.leading, 12)
        case .view:
            Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.ink).frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Repo(org: scope.owner, name: "").color.foreground))
        case .project:
            Image(systemName: "rectangle.split.3x1").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.done)
                .frame(width: 24, height: 24).background(Circle().fill(Theme.done.opacity(0.18)))
        }
    }
}

/// Session, Goal, Comment and the rest, for the item under the cursor, under its read in a pushed reader. Clicks
/// only: the keys of these are the bulk keys, which belong to a selection.
struct BrowseItemActions: View {
    @Environment(AppModel.self) private var model
    let item: BrowseItem
    let compact: Bool

    var body: some View {
        HStack(spacing: 10) {
            button("Session", "browse.run.keep")
            button("Goal", "browse.bulk.goal")
            button("Comment", "browse.bulk.comment")
            if compact {
                Menu {
                    Button("Label…") { act("browse.bulk.label") }
                    Button("Assign to me") { act("browse.bulk.assign") }
                    Button("Close as…") { act("browse.bulk.close") }
                    Button("Open on GitHub") { model.perform(CommandInvocation(name: "open.browser")) }
                } label: {
                    Text("···").font(Theme.ui(15, weight: .semibold)).frame(width: 40, height: 34)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.keyCapBorder))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            } else {
                button("Label", "browse.bulk.label")
                button("Close", "browse.bulk.close")
            }
            Spacer(minLength: 0)
        }
    }

    private func act(_ name: String) { model.perform(CommandInvocation(name: name)) }

    private func button(_ title: String, _ command: String) -> some View {
        Text(title).font(Theme.ui(14))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.keyCapBorder))
            .contentShape(Rectangle())
            .tap { act(command) }
    }
}
