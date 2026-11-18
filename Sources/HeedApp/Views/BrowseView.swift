import HeedCore
import SwiftUI

/// `gv`: the issues and PRs of an org, a repo or a Project. The rail on the left keeps saved queries and scopes with
/// their counts; the list in the middle is the query's items, cached first and fresh as GitHub answers; the reader
/// on the right is the thread under the cursor, as Attention reads one. Wide windows show all three; narrower ones
/// give the rail its icons only and drop the reader.
struct BrowseView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let browse = model.browse
        let rows = browse.rows
        let cursor = model.cursor(in: .browse)
        GeometryReader { geometry in
            let wide = geometry.size.width >= 1100
            let railWidth: CGFloat = geometry.size.width >= 640 ? (wide ? 224 : 52) : 0
            HStack(alignment: .top, spacing: 0) {
                if railWidth > 0 {
                    BrowseRail(compact: !wide).frame(width: railWidth).shotRegion(.browseRail)
                    Theme.line.frame(width: 1)
                }
                VStack(spacing: 0) {
                    BrowseHeader()
                    BrowseCount()
                    ListBody(
                        count: rows.count, cursor: cursor, ids: rows.map(\.id), empty: emptyText, hintView: .browse
                    ) { index in
                        BrowseRow(
                            item: rows[index], index: index, cursor: cursor,
                            isPicked: model.pickedIDs(.browse).contains(rows[index].id)
                        )
                    }
                }
                .frame(
                    width: wide ? ((geometry.size.width - railWidth) * 0.56).rounded() : nil
                )
                .frame(maxWidth: wide ? nil : .infinity)
                .shotRegion(.browseList)
                if wide {
                    Theme.line.frame(width: 1)
                    Group {
                        if let item = rows.indices.contains(cursor) ? rows[cursor] : nil {
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
    }

    private var emptyText: String {
        let browse = model.browse
        if !model.filter(for: .browse).isEmpty { return "Nothing matches /\(model.filter(for: .browse))." }
        if browse.scope == nil, browse.query.tokens.isEmpty {
            return "Pick an org, a repo or a Project with \(model.keyText(for: "browse.scope", in: "browse"))."
        }
        if case let .failed(why) = browse.load { return "GitHub did not answer: \(why)" }
        if browse.load == .loading { return "Asking GitHub…" }
        return "Nothing here in the last \(browse.cap). \(model.keyText(for: "browse.older", in: "browse")) shows older items."
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
private func shortAge(_ date: Date, now: Date = Clock.now) -> String {
    let days = Int(max(now.timeIntervalSince(date), 0) / 86400)
    if days < 1 { return Ages.short(date, now: now) }
    if days < 14 { return "\(days)d" }
    if days < 60 { return "\(days / 7)w" }
    return "\(days / 30)mo"
}

/// A two-letter mark for what an item is: `IS` or `PR`.
private struct TypeTag: View {
    let item: BrowseItem

    var body: some View {
        let tint = item.kind == .pull ? Theme.busy : Theme.done
        Text(item.kind == .pull ? "PR" : "IS")
            .font(Theme.mono(9.5, weight: .bold)).foregroundStyle(tint)
            .frame(width: 26, height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.14)))
    }
}

private struct LabelPill: View {
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
private struct Scrolling<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if ShotMode.active {
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
        } else {
            ScrollView { content.frame(maxWidth: .infinity, alignment: .topLeading) }
        }
    }
}

private struct BrowseRail: View {
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
                ForEach(scopeRows, id: \.id) { row in
                    scopeRow(row.scope, indent: row.indent)
                    if let more = row.more { moreRow(more) }
                }
                if browse.scopes.isEmpty {
                    Text("⌘K finds an org or a repo.").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                        .padding(.horizontal, 14).padding(.top, 4)
                }
            }
            .padding(.top, 10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bg)
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
            if !compact {
                Text(saved.name).font(Theme.ui(13)).foregroundStyle(Theme.fg).lineLimit(1)
                if browse.newQueries.contains(saved.id) {
                    Circle().fill(Theme.busy).frame(width: 6, height: 6)
                }
                Spacer(minLength: 4)
                Text("\(browse.count(of: saved))").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
            }
        }
        .padding(.horizontal, compact ? 0 : 14).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
        .background(active ? Theme.bg3 : .clear)
        .contentShape(Rectangle())
        .tap { model.browse.run(saved); model.browseOpenedQuery() }
    }

    struct ScopeRow {
        var scope: BrowseScope
        var indent: Bool
        var more: Int?
        var id: String { scope.id }
    }

    /// Orgs first with their repos indented under them, then Projects.
    private var scopeRows: [ScopeRow] {
        let scopes = model.browse.scopes
        var rows: [ScopeRow] = []
        var placed = Set<String>()
        for case let .org(org) in scopes {
            let repos = scopes
                .filter { if case let .repo(repo) = $0 { repo.org.lowercased() == org.lowercased() } else { false } }
            let total = model.browse.repoCounts[org.lowercased()]
            rows.append(ScopeRow(
                scope: .org(org),
                indent: false,
                more: total.map { $0 - repos.count }.flatMap { $0 > 0 ? $0 : nil }.flatMap { repos.isEmpty ? nil : $0 }
            ))
            placed.insert(BrowseScope.org(org).id)
            // The more-row sits under the repos, not the org.
            rows[rows.count - 1].more = nil
            for repo in repos {
                rows.append(ScopeRow(scope: repo, indent: true, more: nil))
                placed.insert(repo.id)
            }
            if let last = rows.indices.last, let total, !repos.isEmpty,
               total > repos.count { rows[last].more = total - repos.count }
        }
        for scope in scopes where !placed.contains(scope.id) {
            rows.append(ScopeRow(
                scope: scope,
                indent: false,
                more: nil
            ))
        }
        return rows
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
                Text("\(browse.count(of: scope))").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
            }
        }
        .padding(.horizontal, compact ? 0 : 14).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
        .background(active ? Theme.bg3 : .clear)
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
        Text("+ \(count) more repos…").font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
            .padding(.leading, compact ? 0 : 50).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            .opacity(compact ? 0 : 1)
            .contentShape(Rectangle())
            .tap { model.perform(CommandInvocation(name: "browse.scope")) }
    }
}

// MARK: Header

/// The query as chips: the scope, then each filter, and the way to add one.
private struct BrowseHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let browse = model.browse
        let query = browse.query
        FlowLayout(spacing: 8) {
            if let scope = query.scope { scopeChip(scope) }
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
        case let .topic(value): ("Topic", value)
        case let .team(value): ("Team", value)
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
private struct BrowseCount: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let browse = model.browse
        let capped = browse.settings.maxAgeDays > 0 && !browse.query.showOlder && !browse.query.hasOwnActivity
        HStack(spacing: 8) {
            // GitHub's count says nothing of heed's own filters: with one, the count is what is here.
            Text("\(browse.query.localTokens.isEmpty ? browse.meta?.total ?? browse.rows.count : browse.rows.count)")
                .font(Theme.ui(12.5, weight: .semibold))
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
            case let .failed(why): Text(why).font(Theme.ui(12)).foregroundStyle(Theme.err).lineLimit(1)
            case .idle: EmptyView()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

// MARK: Rows

private struct BrowseRow: View {
    @Environment(AppModel.self) private var model
    let item: BrowseItem
    let index: Int
    let cursor: Int
    let isPicked: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: "\(index + 1)").font(Theme.mono(11, weight: index == cursor ? .bold : .regular))
                .foregroundStyle(index == cursor ? Theme.fg : Theme.fg3).frame(width: 24, alignment: .trailing)
                .padding(.top, 2)
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
                .overlay(alignment: .trailing) { BrowseVerbHint(item: item) }
            }
            BrowseReadColumns(item: item).padding(.top, 1)
            VStack(alignment: .trailing, spacing: 3) {
                Text(shortAge(item.updatedAt)).font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
                Text("\(item.comments)").font(Theme.mono(11)).foregroundStyle(Theme.fg3.opacity(0.8))
            }
            .frame(width: 34, alignment: .trailing)
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
private struct BrowseReader: View {
    @Environment(AppModel.self) private var model
    let item: BrowseItem

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
                AnyView(BrowseWorkSection(item: item).frame(maxWidth: 900))
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
                if let conversation {
                    ThreadConversationView(conversation: conversation, seenAt: nil)
                } else if let error = model.threads[key]?.error {
                    Text("Could not load the thread: \(error)").font(Theme.ui(12)).foregroundStyle(Theme.block)
                } else {
                    Text("Loading the thread…").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
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
                    Text("org, repo or project").font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                Theme.line.frame(height: 1)
                VStack(alignment: .leading, spacing: 0) {
                    section("Orgs and accounts")
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if case let .org(org) = row { orgRow(org, selected: index == palette.cursor) }
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
                "Browsing every repo is slow and mostly noise. Pick what matters; heed keeps it as a scope in the rail and you can still search the whole org."
            )
            .font(Theme.ui(13)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(["Topic", "Team", "Language", "Archived"], id: \.self) { name in
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
