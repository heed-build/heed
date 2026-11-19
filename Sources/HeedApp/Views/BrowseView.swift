import HeedCore
import SwiftUI

/// `gb`: the issues and PRs of an org, a repo or a Project. The rail on the left keeps saved queries and scopes with
/// their counts; the list in the middle is the query's items, cached first and fresh as GitHub answers; the reader
/// on the right is the thread under the cursor, as Attention reads one. Wide windows show all three; narrower ones
/// give the rail its icons only and drop the reader.
struct BrowseView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geometry in
            let layout = BrowseLayout.mode(width: geometry.size.width)
            content(layout: layout, width: geometry.size.width)
                .onAppear { model.browse.layout = layout }
                .onChange(of: layout) { _, new in model.browse.layout = new }
        }
    }

    @ViewBuilder private func content(layout: BrowseLayout, width: CGFloat) -> some View {
        let browse = model.browse
        let rows = browse.rows
        let cursor = model.cursor(in: .browse)
        let picked = model.pickedIDs(.browse)
        let item = rows.indices.contains(cursor) ? rows[cursor] : nil
        let railWidth = CGFloat(layout == .wide ? BrowseLayout.fullRail : layout == .half ? BrowseLayout.iconRail : 0)
        let pushed = layout != .wide && browse.reading && item != nil && picked.count < 2
        HStack(alignment: .top, spacing: 0) {
            if layout.hasRail {
                BrowseRail(compact: layout != .wide).frame(width: railWidth).shotRegion(.browseRail)
                Theme.line.frame(width: 1)
            }
            if pushed, let item {
                VStack(spacing: 0) {
                    BrowseReaderBar(layout: layout, index: cursor, count: rows.count)
                    BrowseReader(item: item, compact: layout == .third).id(item.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(Theme.bg2)
                        .shotRegion(.browseDetail)
                }
            } else {
                listColumn(layout: layout, rows: rows, cursor: cursor, picked: picked)
                    .frame(width: layout == .wide ? ((width - railWidth) * 0.56).rounded() : nil)
                    .frame(maxWidth: layout == .wide ? nil : .infinity)
                    .shotRegion(.browseList)
                if layout == .wide {
                    Theme.line.frame(width: 1)
                    Group {
                        if picked.count >= 2 {
                            BrowseBulkPanel()
                        } else if let item {
                            BrowseReader(item: item).id(item.id)
                        } else {
                            Text("").frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Theme.bg2)
                    .shotRegion(.browseDetail)
                }
            }
        }
        .overlay { if layout == .third, browse.jumpSheet { BrowseJumpSheet() } }
    }

    private func listColumn(layout: BrowseLayout, rows: [BrowseItem], cursor: Int, picked: Set<String>) -> some View {
        VStack(spacing: 0) {
            if layout == .third { BrowseCompactHeader() } else { BrowseHeader() }
            BrowseCount()
            if let refusal = model.browse.refusal {
                BrowseRefusalView(refusal: refusal)
            } else {
                ListBody(
                    count: rows.count,
                    cursor: cursor,
                    ids: rows.map(\.id),
                    empty: emptyText,
                    hintView: .browse
                ) { index in
                    if layout == .third {
                        BrowseCompactRow(item: rows[index], index: index, cursor: cursor, picked: picked)
                    } else {
                        BrowseRow(
                            item: rows[index], index: index, cursor: cursor, isPicked: picked.contains(rows[index].id),
                            anyPicked: !picked.isEmpty, narrow: layout == .half
                        )
                    }
                }
            }
            if layout != .wide, picked.count >= 2 { BrowseBulkPanel(sheet: true) }
        }
    }

    private var emptyText: String {
        let browse = model.browse
        if !model.filter(for: .browse).isEmpty { return "Nothing matches /\(model.filter(for: .browse))." }
        if case let .failed(why) = browse.load { return "GitHub did not answer: \(why)" }
        if browse.load == .loading { return "Asking GitHub…" }
        return "Nothing here in the last \(browse.cap). \(model.keyText(for: "browse.older", in: "browse")) shows older items."
    }
}

// MARK: Refusals

/// The list when Browse would not search: an org that is not checked out, or nothing checked out at all. Read only,
/// nothing is fetched, and no error banner: it says what to do.
struct BrowseRefusalView: View {
    @Environment(AppModel.self) private var model
    let refusal: BrowseFetchError

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.plus").font(.system(size: 26)).foregroundStyle(Theme.fg3)
            switch refusal {
            case .unbounded:
                Text("Check out a repo first").font(Theme.ui(15, weight: .semibold))
                Text("Browse searches the orgs and repos you have checked out.")
                    .font(Theme.ui(13)).foregroundStyle(Theme.fg2)
                button("Add or clone") { model.perform(CommandInvocation(name: "repo.add")) }
            case let .notCheckedOut(name):
                Text("\(name) isn't checked out").font(Theme.ui(15, weight: .semibold))
                Text(
                    "Browse searches orgs and repos you have checked out. Clone it (Add or clone), then it shows up here."
                )
                .font(Theme.ui(13)).foregroundStyle(Theme.fg2).multilineTextAlignment(.center)
                button("Clone \(name)") { model.openAddRepo(prefill: name) }
                HStack(spacing: 6) {
                    Text(model.keyText(for: "browse.scope", in: "browse")).font(Theme.mono(10))
                        .foregroundStyle(Theme.fg3)
                        .padding(.horizontal, 5).overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.line))
                    Text("picks an org you have checked out").font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                }
                .contentShape(Rectangle())
                .tap { model.perform(CommandInvocation(name: "browse.scope")) }
            }
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> some View {
        Text(title).font(Theme.ui(13, weight: .semibold)).foregroundStyle(Theme.ink)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.busy))
            .contentShape(Rectangle())
            .tap(action)
    }
}

// MARK: Marks

extension BrowseGlyph {
    var symbol: String {
        switch self {
        case .bolt: "bolt.fill"
        case .bug: "ladybug"
        case .sprout: "leaf"
        case .clock: "clock"
        case .flag: "flag"
        case .star: "star"
        case .pull: "arrow.triangle.pull"
        case .person: "person"
        case .tag: "tag"
        case .list: "list.bullet"
        }
    }
}

extension BrowseTint {
    var color: Color {
        switch self {
        case .amber: Theme.block
        case .red: Theme.err
        case .green: Theme.done
        case .blue: Theme.busy
        case .purple: Theme.ask
        case .teal: Color.adaptive(0x5FD3C7)
        case .gray: Theme.fg3
        }
    }
}

/// A label's color: the ones every repo has by convention, else one picked from the name.
func labelColor(_ name: String) -> Color {
    switch name.lowercased() {
    case "bug", "regression": return Theme.err
    case "enhancement", "feature": return Theme.busy
    case "good first issue", "help wanted": return Theme.done
    case "question", "idea": return Theme.ask
    case "docs", "documentation": return Color.adaptive(0x5FD3C7)
    case "perf", "performance", "redirects": return Theme.block
    case "chore", "dependencies": return Theme.fg3
    default:
        let palette = [Theme.busy, Theme.done, Theme.ask, Theme.block, Color.adaptive(0x5FD3C7), Theme.err]
        return palette[abs(name.hashValue) % palette.count]
    }
}

/// `3d`, `2w`, `5mo`: how long ago, as the list's right column says it.
func shortAge(_ date: Date, now: Date = Clock.now) -> String {
    let days = Int(max(now.timeIntervalSince(date), 0) / 86400)
    if days < 1 { return Ages.short(date, now: now) }
    if days < 14 { return "\(days)d" }
    if days < 60 { return "\(days / 7)w" }
    return "\(days / 30)mo"
}

/// A two-letter mark for what an item is: `IS` or `PR`.
struct TypeTag: View {
    let item: BrowseItem

    var body: some View {
        let tint = item.kind == .pull ? Theme.busy : Theme.done
        Text(item.kind == .pull ? "PR" : "IS")
            .font(Theme.mono(9.5, weight: .bold)).foregroundStyle(tint)
            .frame(width: 26, height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.14)))
    }
}

struct LabelPill: View {
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(labelColor(name)).frame(width: 6, height: 6)
            Text(name).font(Theme.mono(10.5)).foregroundStyle(Theme.fg2).lineLimit(1)
        }
        .padding(.horizontal, 6).padding(.vertical, 1)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
        .fixedSize()
    }
}

// MARK: Rail

/// A scroll view that shots draw unscrolled (an offscreen render does not lay out a ScrollView's content).
struct Scrolling<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if ShotMode.active {
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
        } else {
            ScrollView { content.frame(maxWidth: .infinity, alignment: .topLeading) }
        }
    }
}

struct BrowseRail: View {
    @Environment(AppModel.self) private var model
    let compact: Bool

    var body: some View {
        let browse = model.browse
        Scrolling {
            VStack(alignment: .leading, spacing: 0) {
                header("Queries") {
                    if browse.newCount > 0 {
                        Text("\(browse.newCount) NEW").font(Theme.mono(9.5)).foregroundStyle(Theme.fg3)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.line))
                    }
                }
                ForEach(browse.queries) { saved in queryRow(saved) }
                    .padding(.bottom, 8)
                header("Scopes") {
                    Text(model.keyText(for: "browse.scope", in: "browse")).font(Theme.mono(9.5))
                        .foregroundStyle(Theme.fg3)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.line))
                }
                allCheckoutsRow
                let rail = railScopes
                ForEach(rail.rows) { row in scopeRow(row.scope, indent: row.indent) }
                if rail.more > 0 { moreRow(rail.more) }
                if rail.rows.isEmpty {
                    Text("Nothing is checked out yet: Add or clone a repo.").font(Theme.ui(12))
                        .foregroundStyle(Theme.fg3)
                        .padding(.horizontal, 14).padding(.top, 4)
                }
            }
            .padding(.top, 10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bg)
        .overlay(alignment: .bottom) {
            // The icon rail has no ⌘K row: the search at its foot opens the jump.
            if compact {
                Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Theme.fg2)
                    .frame(width: 52, height: 44).contentShape(Rectangle())
                    .clickRuns(CommandInvocation(name: "browse.scope"))
            }
        }
    }

    @ViewBuilder private func header(_ title: String, @ViewBuilder trailing: () -> some View) -> some View {
        if compact {
            Theme.line.frame(height: 1).padding(.horizontal, 12).padding(.vertical, 8)
        } else {
            HStack {
                Text(title.uppercased()).font(Theme.mono(10.5, weight: .semibold)).tracking(1)
                    .foregroundStyle(Theme.fg3)
                Spacer()
                trailing()
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
        }
    }

    private func queryRow(_ saved: SavedQuery) -> some View {
        let browse = model.browse
        let active = browse.activeQuery == saved.id
        return HStack(spacing: 10) {
            Image(systemName: saved.glyph.symbol).font(.system(size: 13)).foregroundStyle(saved.tint.color)
                .frame(width: 20)
                .overlay(alignment: .topTrailing) {
                    if compact, browse.newQueries.contains(saved.id) {
                        Circle().fill(Theme.busy).frame(width: 6, height: 6).offset(x: 5, y: -3)
                    }
                }
            if !compact {
                Text(saved.name).font(Theme.ui(13)).foregroundStyle(Theme.fg).lineLimit(1)
                if browse.newQueries.contains(saved.id) {
                    Circle().fill(Theme.busy).frame(width: 6, height: 6)
                }
                Spacer(minLength: 4)
                Text(verbatim: browse.count(of: saved).map(BrowseNumber.compact) ?? "–").font(Theme.mono(11))
                    .foregroundStyle(Theme.fg3).help(browse.count(of: saved).map(BrowseNumber.exact) ?? "not searched")
            }
        }
        .padding(.horizontal, compact ? 0 : 14).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
        .background(active ? Theme.bg3 : .clear)
        .contentShape(Rectangle())
        .tap { model.browse.run(saved); model.browseOpenedQuery() }
    }

    private var railScopes: BrowseRailScopes.Result {
        BrowseRailScopes.rows(
            pinned: model.browse.scopes, checkouts: model.browse.checkouts, current: model.browse.scope
        )
    }

    /// No scope: the queries run inside every org with a checkout.
    private var allCheckoutsRow: some View {
        let browse = model.browse
        let active = browse.scope == nil
        return HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.fg)
                .frame(width: 20, height: 20)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(
                    Theme.fg2,
                    style: StrokeStyle(lineWidth: 1.2, dash: [2, 2])
                ))
            if !compact {
                Text("All checkouts").font(Theme.ui(13.5)).foregroundStyle(Theme.fg).lineLimit(1)
                Spacer(minLength: 4)
                Text(browse.checkouts.orgs.count == 1 ? "1 org" : "\(browse.checkouts.orgs.count) orgs")
                    .font(Theme.mono(11)).foregroundStyle(Theme.fg3)
            }
        }
        .padding(.horizontal, compact ? 0 : 14).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
        .background(active ? Theme.bg3 : .clear)
        .contentShape(Rectangle())
        .help("Every org you have checked out a repo of")
        .tap { model.browse.go(to: nil); model.browseOpenedQuery() }
    }

    private func scopeRow(_ scope: BrowseScope, indent: Bool) -> some View {
        let browse = model.browse
        let active = browse.scope == scope
        return HStack(spacing: 10) {
            if indent, !compact { Color.clear.frame(width: 16, height: 1) }
            scopeMark(scope)
            if !compact {
                Text(scope.title).font(Theme.ui(indent ? 13 : 13.5)).foregroundStyle(indent ? Theme.fg2 : Theme.fg)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(verbatim: browse.count(of: scope).map(BrowseNumber.compact) ?? "–").font(Theme.mono(11))
                    .foregroundStyle(Theme.fg3)
                    .help(browse.count(of: scope).map(BrowseNumber.exact) ?? "not checked out")
            }
        }
        .padding(.horizontal, compact ? 0 : 14).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
        .background(active ? Theme.bg3 : .clear)
        .opacity(browse.count(of: scope) == nil ? 0.55 : 1)
        .contentShape(Rectangle())
        .tap { model.browse.go(to: scope); model.browseOpenedQuery() }
    }

    @ViewBuilder private func scopeMark(_ scope: BrowseScope) -> some View {
        switch scope {
        case let .org(org):
            Text(String(org.prefix(1)).uppercased()).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Repo(org: org, name: "").color.foreground))
        case let .repo(repo):
            Text(String(repo.name.prefix(1)).uppercased()).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(repo.color.foreground)
                .frame(width: 18, height: 18)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(repo.color.foreground, lineWidth: 1.2))
        case .view:
            Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.ink)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Repo(org: scope.owner, name: "").color.foreground))
        case .project:
            Image(systemName: "rectangle.split.3x1").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.done)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.done.opacity(0.18)))
        }
    }

    private func moreRow(_ count: Int) -> some View {
        Text("+ \(count) more: \(model.keyText(for: "browse.scope", in: "browse"))").font(Theme.ui(12.5))
            .foregroundStyle(Theme.fg3)
            .padding(.leading, compact ? 0 : 50).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            .opacity(compact ? 0 : 1)
            .contentShape(Rectangle())
            .tap { model.perform(CommandInvocation(name: "browse.scope")) }
    }
}

// MARK: Header

/// The query as chips: the scope, then each filter, and the way to add one.
struct BrowseHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let browse = model.browse
        let query = browse.query
        FlowLayout(spacing: 8) {
            if let scope = query.scope { scopeChip(scope) } else if !query.hasOwnPlace { allCheckoutsChip }
            chip("Type", typeText(query))
            ForEach(Array(query.tokens.enumerated()), id: \.offset) { index, token in
                if let text = tokenChip(token) { chip(text.0, text.1, removable: index) }
            }
            chip(
                "Age",
                browse.settings.maxAgeDays == 0 || query.showOlder || query.hasOwnActivity
                    ? "any" : "≤ \(browse.cap)",
                dashed: true
            )
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 10))
                Text("filter").font(Theme.ui(12.5))
                Text(model.keyText(for: "browse.filter.add", in: "browse")).font(Theme.mono(10))
                    .foregroundStyle(Theme.fg3)
                    .padding(.horizontal, 5).overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.line))
            }
            .foregroundStyle(Theme.fg2).padding(.horizontal, 8).padding(.vertical, 4)
            .contentShape(Rectangle())
            .tap { model.perform(CommandInvocation(name: "browse.filter.add")) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    /// No scope: the query runs inside every org with a checkout.
    private var allCheckoutsChip: some View {
        let orgs = model.browse.checkouts.orgs.count
        return HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.fg2)
            Text("All checkouts").font(Theme.ui(12.5, weight: .semibold))
            Text(orgs == 1 ? "1 org" : "\(orgs) orgs").font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.chip))
        .help(
            "Browse searches the orgs you have checked out. \(model.keyText(for: "browse.scope", in: "browse")) picks one."
        )
    }

    private func scopeChip(_ scope: BrowseScope) -> some View {
        HStack(spacing: 6) {
            Text(String(scope.title.prefix(1)).uppercased()).font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.ink)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(Repo(org: scope.owner, name: "").color.foreground))
            Text(scope.title).font(Theme.ui(12.5, weight: .semibold))
            if case .org = scope, let count = model.browse.repoCounts[scope.owner.lowercased()] ?? fixtureRepos(scope) {
                Text("\(count) repos").font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
            }
            Image(systemName: "xmark").font(.system(size: 8)).foregroundStyle(Theme.fg3)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.chip))
        .contentShape(Rectangle())
        .tap { model.browse.go(to: nil); model.browseOpenedQuery() }
    }

    private func fixtureRepos(_ scope: BrowseScope) -> Int? {
        guard model.isFixtureWorld, case let .org(org) = scope else { return nil }
        return Fixtures.Browse.orgs.first { $0.name == org }?.repoCount
    }

    private func chip(_ name: String, _ value: String, dashed: Bool = false, removable: Int? = nil) -> some View {
        HStack(spacing: 5) {
            if !name.isEmpty { Text(name).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2) }
            Text(value).font(Theme.ui(12.5, weight: .semibold)).lineLimit(1)
            if let index = removable {
                Image(systemName: "xmark").font(.system(size: 8)).foregroundStyle(Theme.fg3)
                    .padding(3).contentShape(Rectangle())
                    .tap {
                        guard model.browse.query.tokens.indices.contains(index) else { return }
                        var next = model.browse.query
                        next.tokens.remove(at: index)
                        model.browse.applyBuilder(next)
                        model.browseOpenedQuery()
                    }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(dashed ? .clear : Theme.chip))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
            Theme.line,
            style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 3] : [])
        ))
    }

    private func typeText(_ query: BrowseQuery) -> String {
        for token in query.tokens {
            if case let .type(type) = token { return type == .issues ? "Issues" : "PRs" }
        }
        return "Issues + PRs"
    }

    private func tokenChip(_ token: BrowseToken) -> (String, String)? {
        switch token {
        case .type, .state(.open): nil
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
        case let .created(span): ("Opened", spanText(span))
        case let .activity(span): ("Activity", spanText(span))
        case let .linkedPull(linked): ("Linked PR", linked ? "yes" : "no")
        case let .language(value): ("Language", value)
        case let .archived(value): ("Archived", value ? "only" : "hidden")
        case let .text(text): ("Text", text)
        case let .raw(text): ("", text)
        case .heedClass, .heedSize, .heedReady: token.heedChip
        }
    }

    private func spanText(_ span: BrowseSpan) -> String {
        switch span {
        case let .newerThan(days): "≤ \(days)d"
        case let .olderThan(days): "\(days)d+"
        }
    }
}

/// `47 open · last 3 months  Show older ▸` over the list.
struct BrowseCount: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let browse = model.browse
        let capped = browse.settings.maxAgeDays > 0 && !browse.query.showOlder && !browse.query.hasOwnActivity
        HStack(spacing: 8) {
            // GitHub's count says nothing of heed's own filters: with one, the count is what is here.
            if browse.refusal != nil {
                Text("–").font(Theme.ui(12.5, weight: .semibold))
            } else {
                let total = browse.query.localTokens.isEmpty ? browse.meta?.total ?? browse.rows.count : browse.rows
                    .count
                Text(verbatim: BrowseNumber.compact(total)).font(Theme.ui(12.5, weight: .semibold))
                    .help(BrowseNumber.exact(total))
            }
            Text(capped ? "open · last \(browse.cap)" : "open").font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
            if browse.settings.maxAgeDays > 0, !browse.query.hasOwnActivity {
                Text(browse.query.showOlder ? "Back to \(browse.cap) ▸" : "Show older ▸")
                    .font(Theme.ui(12.5)).foregroundStyle(Theme.busy)
                    .contentShape(Rectangle())
                    .tap { model.perform(CommandInvocation(name: "browse.older")) }
            }
            Spacer()
            switch browse.load {
            case .loading: Text("asking GitHub…").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
            case _ where browse.refusal != nil: EmptyView()
            case let .failed(why): Text(why).font(Theme.ui(12)).foregroundStyle(Theme.err).lineLimit(1)
            case .idle:
                if let meta = browse.meta, meta.groupsTotal > meta.groups {
                    Text(
                        "first \(meta.groups) of \(meta.groupsTotal) org groups; narrow with \(model.keyText(for: "browse.scope", in: "browse"))"
                    )
                    .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

// MARK: Rows

struct BrowseRow: View {
    @Environment(AppModel.self) private var model
    let item: BrowseItem
    let index: Int
    let cursor: Int
    let isPicked: Bool
    /// Some row is picked: the number gives way to a checkbox on every row.
    var anyPicked = false
    /// Half width: the read is a ring beside the verb, not the three columns.
    var narrow = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if anyPicked {
                PickBox(on: isPicked).frame(width: 24, alignment: .trailing).padding(.top, 1)
            } else {
                Text(verbatim: "\(index + 1)").font(Theme.mono(11, weight: index == cursor ? .bold : .regular))
                    .foregroundStyle(index == cursor ? Theme.fg : Theme.fg3).frame(width: 24, alignment: .trailing)
                    .padding(.top, 2)
            }
            TypeTag(item: item)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    RepoChip(repo: item.repo).fixedSize()
                    if !model.browseIsCloned(item.repo) {
                        Image(systemName: "icloud").font(.system(size: 10)).foregroundStyle(Theme.fg3)
                            .help("not cloned on this Mac")
                    }
                    Text(item.title.display).font(Theme.ui(13, weight: .regular)).foregroundStyle(Theme.fg).lineLimit(1)
                    Text(verbatim: "#\(item.number)").font(Theme.mono(11)).foregroundStyle(Theme.fg3).fixedSize()
                    Spacer(minLength: 0)
                }
                FlowLayout(spacing: 5) {
                    ForEach(item.labels, id: \.self) { LabelPill(name: $0) }
                    if let viewer = model.github.viewer ?? (model.isFixtureWorld ? "you" : nil),
                       item.assignees.contains(where: { $0.caseInsensitiveCompare(viewer) == .orderedSame })
                    {
                        ReasonTag(text: "assigned to you", tint: Theme.busy)
                    }
                    if item.kind == .issue, item.hasLinkedPull {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.pull").font(.system(size: 9))
                            Text("open PR").font(Theme.ui(11.5))
                        }.foregroundStyle(Theme.fg2)
                    }
                    if item.kind == .pull, item.isDraft { ReasonTag(text: "draft", tint: Theme.fg3) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) { if !narrow { BrowseVerbHint(item: item) } }
            }
            if narrow {
                BrowseVerbHint(item: item).padding(.top, 1)
                BrowseReadRing(item: item).frame(width: 22).padding(.top, 1)
                Text(shortAge(item.updatedAt)).font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
                    .frame(width: 34, alignment: .trailing).padding(.top, 1)
            } else {
                BrowseReadColumns(item: item).padding(.top, 1)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(shortAge(item.updatedAt)).font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
                    Text("\(item.comments)").font(Theme.mono(11)).foregroundStyle(Theme.fg3.opacity(0.8))
                }
                .frame(width: 34, alignment: .trailing)
            }
        }
        .padding(.leading, 8).padding(.trailing, 16).padding(.vertical, 9)
        .overlay(alignment: .leading) { if index == cursor { Theme.busy.frame(width: 2) } }
        .background(isPicked ? Theme.block.opacity(0.16) : index == cursor ? Theme.bg3 : .clear)
        .overlay(alignment: .bottom) { Theme.line.opacity(0.6).frame(height: 1) }
    }
}

// MARK: Reader

/// The thread under the cursor: its header (where it is, its title, its state and labels), then the conversation as
/// GitHub renders it, loaded once the cursor rests on the row.
struct BrowseReader: View {
    @Environment(AppModel.self) private var model
    let item: BrowseItem
    /// Third width: the verbs in a 2x2 grid, and the extra actions behind a menu.
    var compact = false

    var body: some View {
        let run = model.browse.runs.current(for: item.id)
        if let run, run.phase != .needsClone, run.phase != .cloning || !run.worktree.isEmpty {
            // A run is on the item: the title and what it says, then the run, which takes the rest of the reader.
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 14)
                    .frame(maxWidth: 900, alignment: .leading)
                BrowseRunPanel(run: run).frame(maxWidth: 900)
            }
        } else {
            let work = if let run { AnyView(BrowseCloneCard(run: run).frame(maxWidth: 900)) } else {
                AnyView(BrowseWorkSection(item: item, compact: compact).frame(maxWidth: 900))
            }
            if ShotMode.active {
                // An offscreen render lays the thread out at its whole height: the buttons sit over its bottom instead.
                GeometryReader { geometry in
                    thread.frame(height: geometry.size.height, alignment: .top).clipped()
                        .overlay(alignment: .bottom) { work.background(Theme.bg2) }
                }
            } else {
                VStack(spacing: 0) {
                    thread.frame(maxHeight: .infinity)
                    work
                }
            }
        }
    }

    private var header: some View {
        let conversation = model.conversation(item.repo, item.number)
        return ThreadHeader(
            repo: item.repo, kind: item.kind == .pull ? .pr : .issue, number: item.number,
            title: conversation?.title ?? item.title.display,
            author: conversation?.author?.login ?? item.author,
            openedAt: conversation?.createdAt ?? item.createdAt, chips: chips
        )
    }

    private var thread: some View {
        let conversation = model.conversation(item.repo, item.number)
        let key = ThreadConversation.key(repo: item.repo, number: item.number)
        return Scrolling {
            VStack(alignment: .leading, spacing: 18) {
                ThreadHeader(
                    repo: item.repo, kind: item.kind == .pull ? .pr : .issue, number: item.number,
                    title: conversation?.title ?? item.title.display,
                    author: conversation?.author?.login ?? item.author,
                    openedAt: conversation?.createdAt ?? item.createdAt, chips: chips
                )
                BrowseReadCard(item: item)
                if model.browse.layout != .wide { BrowseItemActions(item: item, compact: compact) }
                if let conversation {
                    ThreadConversationView(conversation: conversation, seenAt: nil)
                } else if let error = model.threads[key]?.error {
                    Text("Could not load the thread: \(error)").font(Theme.ui(12)).foregroundStyle(Theme.block)
                } else {
                    Text("Loading the thread…").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                }
            }
            .padding(.horizontal, compact ? 16 : 28).padding(.vertical, 22)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var chips: [ThreadHeader.Chip] {
        var chips: [ThreadHeader.Chip] = []
        let tint: Color = item.state == .open ? Theme.done : item.state == .merged ? Theme.ask : Theme.fg2
        chips.append(.init(text: item.state.rawValue, tint: tint))
        if let viewer = model.github.viewer ?? (model.isFixtureWorld ? "you" : nil),
           item.assignees.contains(where: { $0.caseInsensitiveCompare(viewer) == .orderedSame })
        {
            chips.append(.init(text: "assigned to you", tint: Theme.busy))
        }
        chips += item.labels.map { .init(text: $0, tint: labelColor($0)) }
        if let milestone = item.milestone { chips.append(.init(text: "milestone \(milestone)")) }
        chips += item.projects.map { .init(text: $0, tint: Theme.fg2) }
        if item.kind == .pull, item.isDraft { chips.append(.init(text: "draft", tint: Theme.fg3)) }
        return chips
    }
}

// MARK: Quick jump

/// ⌘K: orgs and accounts, then the repos matching what was typed, and what a big org needs said.
struct BrowsePaletteView: View {
    @Environment(AppModel.self) private var model
    let palette: BrowsePalette

    var body: some View {
        let rows = palette.rows
        ZStack(alignment: .top) {
            Theme.scrim.opacity(0.5)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.fg2)
                    CaretText(input: palette.input).font(Theme.ui(15))
                    Spacer()
                    Text("jump or search").font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                Theme.line.frame(height: 1)
                VStack(alignment: .leading, spacing: 0) {
                    if rows.contains(where: { if case .query = $0 { true } else { false } }) {
                        section("Saved queries")
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            if case let .query(saved) = row { queryRow(saved, selected: index == palette.cursor) }
                        }
                    }
                    if rows.contains(where: { if case .org = $0 { true } else { false } }) {
                        section("Orgs and accounts")
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if case let .org(org) = row { orgRow(org, selected: index == palette.cursor) }
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if case let .search(text) = row { searchRow(text, selected: index == palette.cursor) }
                    }
                    if rows.contains(where: { if case .repo = $0 { true } else { false } }) {
                        section("Repos matching “\(palette.query)”")
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            if case let .repo(repo) = row { repoRow(repo, selected: index == palette.cursor) }
                        }
                    }
                    if case let .createOrgView(count)? = palette.guidance,
                       case let .org(org)? = rows[safeRow: palette.cursor]
                    {
                        guidance(org: org.name, repos: count)
                    }
                }
                .padding(.bottom, 12)
            }
            .frame(width: 700)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.5), radius: 30)
            .padding(.top, 100)
            .shotRegion(.browsePalette)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).font(Theme.mono(10.5, weight: .semibold)).tracking(1).foregroundStyle(Theme.fg3)
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 6)
    }

    private func queryRow(_ row: BrowsePalette.QueryRow, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: row.query.glyph.symbol).font(.system(size: 13)).foregroundStyle(row.query.tint.color)
                .frame(width: 22, height: 22)
            Text(row.query.name).font(Theme.ui(13.5, weight: .semibold))
            Spacer()
            if let count = row.count { Text("\(count)").font(Theme.mono(11.5)).foregroundStyle(Theme.fg2) }
            if selected { Text("↩").font(Theme.mono(10)).foregroundStyle(Theme.fg3) }
        }
        .padding(.horizontal, 18).padding(.vertical, 7)
        .background(selected ? Theme.bg3 : .clear)
    }

    private func searchRow(_ text: String, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.busy)
                .frame(width: 22, height: 22)
            Text("Search GitHub for “\(text)”").font(Theme.ui(13.5, weight: .semibold)).lineLimit(1)
            Spacer()
            if selected { Text("↩").font(Theme.mono(10)).foregroundStyle(Theme.fg3) }
        }
        .padding(.horizontal, 18).padding(.vertical, 7)
        .background(selected ? Theme.bg3 : .clear)
    }

    private func orgRow(_ org: BrowsePalette.Org, selected: Bool) -> some View {
        let big = org.repoCount
            .map { BrowseGuidance.advice(repoCount: $0, threshold: palette.threshold) != .browse } ?? false
        return HStack(spacing: 12) {
            Text(String(org.name.prefix(1)).uppercased()).font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.ink)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(Repo(org: org.name, name: "").color.foreground))
            Text(org.name).font(Theme.ui(13.5, weight: .semibold)).frame(width: 120, alignment: .leading)
            if big, let count = org.repoCount {
                Label(
                    "\(count.formatted()) repos · too many to browse at once",
                    systemImage: "exclamationmark.triangle"
                )
                .font(Theme.ui(13)).foregroundStyle(Theme.block)
            } else {
                Text(detail(org)).font(Theme.ui(13)).foregroundStyle(Theme.fg2)
            }
            Spacer()
            if selected { Text("↩").font(Theme.mono(10)).foregroundStyle(Theme.fg3) }
        }
        .padding(.horizontal, 18).padding(.vertical, 7)
        .background(selected ? Theme.bg3 : .clear)
    }

    private func detail(_ org: BrowsePalette.Org) -> String {
        var parts: [String] = []
        if let count = org.repoCount { parts.append("\(count.formatted()) repos") }
        if let open = org.openCount { parts.append("\(open) open") }
        if org.personal { parts.append("personal") }
        return parts.joined(separator: " · ")
    }

    private func repoRow(_ row: BrowsePalette.RepoRow, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Text(String(row.listing.repo.org.prefix(1)).uppercased()).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(row.listing.repo.color.foreground)
                .frame(width: 20, height: 20)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(
                    row.listing.repo.color.foreground,
                    lineWidth: 1.2
                ))
            Text(row.listing.repo.slug).font(Theme.ui(13.5)).frame(width: 260, alignment: .leading)
            HStack(spacing: 5) {
                if row.place.clones {
                    Image(systemName: "icloud").font(.system(size: 11))
                    Text("not cloned")
                } else {
                    Text("cloned ✓")
                }
                if let open = row.openCount { Text("· \(open) open") }
            }
            .font(Theme.ui(13)).foregroundStyle(Theme.fg2)
            Spacer()
            if selected { Text("↩").font(Theme.mono(10)).foregroundStyle(Theme.fg3) }
        }
        .padding(.horizontal, 18).padding(.vertical, 7)
        .background(selected ? Theme.bg3 : .clear)
    }

    private func guidance(org: String, repos: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "\(org) has \(repos.formatted()) repos. Start with a view of the ones you care about.",
                systemImage: "exclamationmark.triangle"
            )
            .font(Theme.ui(14, weight: .semibold))
            Text(
                "Browsing every repo is slow and mostly noise. Narrow by language or leave out archived repos; heed keeps the filters as a scope in the rail, GitHub applies them on every search, and you can still search the whole org."
            )
            .font(Theme.ui(13)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(["Language", "Archived"], id: \.self) { name in
                    Text(name).font(Theme.ui(13)).foregroundStyle(Theme.fg2).padding(.horizontal, 10).padding(
                        .vertical,
                        4
                    )
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.chip.opacity(0.5)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                }
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 10))
                    Text("narrow").font(Theme.ui(13))
                }.foregroundStyle(Theme.fg2).padding(.horizontal, 6)
            }
            HStack(spacing: 10) {
                Spacer()
                HStack(spacing: 6) {
                    Text("Browse all anyway").font(Theme.ui(13))
                    Text("⌃b").font(Theme.mono(10)).foregroundStyle(Theme.fg3)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                HStack(spacing: 8) {
                    Text("Create \(org) view").font(Theme.ui(13.5, weight: .semibold))
                    Text("↩").font(Theme.mono(10)).padding(.horizontal, 5)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.bg)).foregroundStyle(Theme.fg)
                }
                .foregroundStyle(Theme.ink).padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.block.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.block.opacity(0.5)))
        .padding(.horizontal, 18).padding(.top, 12)
    }
}

private extension Array {
    subscript(safeRow index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
