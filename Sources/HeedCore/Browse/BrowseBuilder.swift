import Foundation

/// A field the add-filter popover offers. The first eleven are what GitHub's search knows; the heed fields filter by
/// heed's own read of items, on this Mac, and are never sent to GitHub; `githubQuery` is the raw search.
public enum BrowseField: String, CaseIterable, Hashable, Sendable {
    case label, type, state, assignee, author, repo, age, activity, linkedPull, project, milestone
    case heedClass, heedSize, heedReady, githubQuery

    public var title: String {
        switch self {
        case .label: "Label"
        case .type: "Type"
        case .state: "State"
        case .assignee: "Assignee"
        case .author: "Author"
        case .repo: "Repo"
        case .age: "Age"
        case .activity: "Activity"
        case .linkedPull: "Linked PR"
        case .project: "Project"
        case .milestone: "Milestone"
        case .heedClass: "heed: class"
        case .heedSize: "heed: size"
        case .heedReady: "heed: agent-ready"
        case .githubQuery: "GitHub query"
        }
    }

    public var hint: String {
        switch self {
        case .label: "bug, good first issue…"
        case .type: "issues or pull requests"
        case .state: "open, closed, merged"
        case .assignee: "me, unassigned, a person"
        case .author: "me, a person"
        case .repo: "one repo of the scope"
        case .age: "last 3 months, older than a week"
        case .activity: "no reply in 30 days"
        case .linkedPull: "has one, has none"
        case .project: "owner/number, from the board's address"
        case .milestone: "3.2"
        case .heedClass: "bug, feature, docs…"
        case .heedSize: "S, M, L"
        case .heedReady: "at least 70%"
        case .githubQuery: "paste raw search syntax"
        }
    }

    public var symbol: String {
        switch self {
        case .label: "tag"
        case .type: "square.on.square"
        case .state: "circle.dotted"
        case .assignee, .author: "person"
        case .repo: "shippingbox"
        case .age: "calendar"
        case .activity: "clock"
        case .linkedPull: "arrow.triangle.pull"
        case .project: "rectangle.split.3x1"
        case .milestone: "flag"
        case .heedClass: "sparkle"
        case .heedSize: "sparkle"
        case .heedReady: "bolt"
        case .githubQuery: "magnifyingglass"
        }
    }

    /// Why a field cannot be used now: never at present, every field works.
    public var disabledReason: String? { nil }

    /// Whether several values may be ticked, and whether any / all / none applies to them.
    public var isMultiple: Bool { self == .label || self == .heedClass || self == .heedSize }
    public var hasMode: Bool { self == .label }

    /// Whether a token is this field's.
    public func owns(_ token: BrowseToken) -> Bool {
        switch (self, token) {
        case (.label, .label), (.type, .type), (.state, .state), (.assignee, .assignee), (.author, .author),
             (.repo, .repo), (.age, .created), (.activity, .activity), (.linkedPull, .linkedPull),
             (.project, .project), (.milestone, .milestone), (.heedClass, .heedClass), (.heedSize, .heedSize),
             (.heedReady, .heedReady): true
        case let (.assignee, .raw(text)): text == "no:assignee"
        default: false
        }
    }
}

/// How many items, by how long since they last changed, in `buckets` equal slices of the window (the oldest first):
/// the bars under "would match".
public enum BrowseHistogram {
    public static let buckets = 13

    /// `total` counts every item in `items`, `matching` those `keep` says yes to. Items older than the window fall in
    /// the oldest slice.
    public static func of(
        _ items: [BrowseItem], windowDays: Int, now: Date, keep: (BrowseItem) -> Bool
    ) -> [(total: Int, matching: Int)] {
        var result = Array(repeating: (total: 0, matching: 0), count: buckets)
        let span = Double(max(windowDays, 1)) * 86400 / Double(buckets)
        for item in items {
            let age = max(now.timeIntervalSince(item.updatedAt), 0)
            let index = buckets - 1 - min(Int(age / span), buckets - 1)
            result[index].total += 1
            if keep(item) { result[index].matching += 1 }
        }
        return result
    }
}

public extension SavedQuery {
    /// A name for a query about to be kept, from the filter that says most.
    static func suggestedName(for query: BrowseQuery) -> String {
        for token in query.tokens {
            switch token {
            case let .label(mode, names) where mode != .none: return names.joined(separator: ", ")
            case let .milestone(name): return name
            case let .assignee(name): return name == "@me" ? "Assigned to me" : "Assigned to \(name)"
            default: continue
            }
        }
        return "Saved query"
    }

    /// The queries with `id` moved `step` places (clamped), the rest in order.
    static func moved(_ queries: [SavedQuery], id: String, by step: Int) -> [SavedQuery] {
        guard let from = queries.firstIndex(where: { $0.id == id }) else { return queries }
        var result = queries
        let item = result.remove(at: from)
        result.insert(item, at: min(max(from + step, 0), result.count))
        return result
    }
}

/// The add-filter popover (`/`): a typing field over the fields, a value picker for the one chosen, an "Understood
/// as" card for words, the raw GitHub query, and the Save as query step. Pure state: the app feeds it strokes and the
/// model's answer, and acts on what comes back.
public struct BrowseBuilder: Sendable {
    public struct Context: Sendable {
        public var items: [BrowseItem]
        public var viewer: String?
        public var maxAgeDays: Int
        public var now: Date
        /// Projects the rail knows, so a title becomes the `owner/number` GitHub's `project:` takes.
        public var projects: [BrowseScope]
        /// Whether words can go to the model, or why not.
        public var wordsOff: String?
        /// heed's reads by item id.
        public var reads: BrowseReads

        public init(
            items: [BrowseItem], viewer: String? = nil, maxAgeDays: Int = 90, now: Date, projects: [BrowseScope] = [],
            wordsOff: String? = nil, reads: BrowseReads = [:]
        ) {
            self.reads = reads
            self.items = items
            self.viewer = viewer
            self.maxAgeDays = maxAgeDays
            self.now = now
            self.projects = projects
            self.wordsOff = wordsOff
        }
    }

    public enum Stage: Equatable, Sendable { case fields, values(BrowseField), raw, project, save }

    public enum Reading: Equatable, Sendable {
        case idle, reading
        case ready(BrowseUnderstanding)
        case failed(String)
    }

    /// The Save as query step: a name, a glyph and a tint.
    public struct Draft: Equatable, Sendable {
        public var name: EditableText
        public var glyph: BrowseGlyph
        public var tint: BrowseTint
        /// The saved query being renamed; nil for a new one.
        public var id: String?
        var tintChosen: Bool

        public mutating func cycleGlyph(by step: Int) {
            let all = BrowseGlyph.allCases
            glyph = all[(all.firstIndex(of: glyph)! + step + all.count) % all.count]
            if !tintChosen { tint = glyph.tint }
        }

        public mutating func cycleTint() {
            let all = BrowseTint.allCases
            tint = all[(all.firstIndex(of: tint)! + 1) % all.count]
            tintChosen = true
        }
    }

    public struct Keep: Equatable, Sendable {
        public var id: String?
        public var name: String
        public var glyph: BrowseGlyph
        public var tint: BrowseTint
        public var query: BrowseQuery

        public init(id: String?, name: String, glyph: BrowseGlyph, tint: BrowseTint, query: BrowseQuery) {
            self.id = id
            self.name = name
            self.glyph = glyph
            self.tint = tint
            self.query = query
        }
    }

    public enum Action: Equatable, Sendable {
        case none, changed, close
        case apply(BrowseQuery)
        /// Ask the model what these words mean.
        case read(String)
        case copy(String)
        case keep(Keep)
    }

    public var base: BrowseQuery
    public var context: Context
    public private(set) var stage = Stage.fields
    public var input = EditableText()
    public private(set) var cursor = 0
    public private(set) var picker: BrowsePicker?
    public private(set) var mode = BrowseLabelMode.any
    public private(set) var reading = Reading.idle
    /// Editing the tokens the words became: which one is under the cursor.
    public private(set) var editing = false
    public private(set) var tokenCursor = 0
    public var draft: Draft?
    /// Why the Project text is not accepted yet (shown under the field).
    public private(set) var projectError: String?
    private var tokens: [BrowseToken] = []

    public init(base: BrowseQuery, context: Context) {
        self.base = base
        self.context = context
    }

    /// The popover opened on the Save as query step for a query already kept (rename, glyph, tint).
    public init(renaming saved: SavedQuery, context: Context) {
        self.init(base: saved.query, context: context)
        stage = .save
        draft = Draft(
            name: EditableText(saved.name),
            glyph: saved.glyph,
            tint: saved.tint,
            id: saved.id,
            tintChosen: true
        )
    }

    // MARK: The fields

    /// The fields the typing narrows to, by what their names start with.
    public var fields: [BrowseField] {
        let text = input.text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return BrowseField.allCases }
        return BrowseField.allCases.filter { field in
            field.title.lowercased().split(separator: " ").contains { $0.hasPrefix(text) }
                || field.title.lowercased().hasPrefix(text)
        }
    }

    /// What was typed is words rather than a field name.
    public var isWords: Bool { !input.text.trimmingCharacters(in: .whitespaces).isEmpty && fields.isEmpty }

    public var sentence: String { input.text.trimmingCharacters(in: .whitespaces) }

    /// The tokens the words became, as they stand (edits included).
    public var understood: [BrowseToken] { tokens }

    public mutating func setReading(_ next: Reading) {
        reading = next
        if case let .ready(understanding) = next {
            tokens = understanding.tokens
            tokenCursor = 0
            editing = false
        }
    }

    // MARK: The query being built

    /// `query` without `field`'s tokens: what the field's choices are counted against.
    func without(_ field: BrowseField) -> BrowseQuery {
        var query = base
        query.tokens.removeAll { field.owns($0) }
        return query
    }

    /// The query with `tokens` laid over `base`: a token replaces those of its kind, words replace words.
    public static func merged(_ tokens: [BrowseToken], into base: BrowseQuery) -> BrowseQuery {
        var query = base
        for token in tokens {
            if case .raw = token {} else {
                query.tokens.removeAll { BrowseWords.sameKind($0, token) }
            }
            query.tokens.append(token)
        }
        return query
    }

    /// The query as the popover would apply it right now.
    public var preview: BrowseQuery {
        switch stage {
        case let .values(field): previewOf(field)
        default: tokens.isEmpty ? base : Self.merged(tokens, into: base)
        }
    }

    private func previewOf(_ field: BrowseField) -> BrowseQuery {
        var query = without(field)
        query.tokens += valueTokens(field)
        return query
    }

    /// The raw GitHub search, as it would be sent.
    public var raw: String { preview.rendered(maxAgeDays: context.maxAgeDays, now: context.now) }

    /// "would match N of M": N for the preview, M for the query without this field.
    public var wouldMatch: (matching: Int, of: Int) {
        guard case let .values(field) = stage else {
            return (count(preview), count(base))
        }
        return (count(previewOf(field)), count(without(field)))
    }

    private func count(_ query: BrowseQuery) -> Int {
        BrowseFilter.count(
            query,
            in: context.items,
            viewer: context.viewer,
            maxAgeDays: context.maxAgeDays,
            now: context.now,
            reads: context.reads
        )
    }

    /// The bars: items of the query without this field by when they last changed, those the preview keeps marked.
    public var histogram: [(total: Int, matching: Int)] {
        let field: BrowseField? = if case let .values(field) = stage { field } else { nil }
        let wide = field.map(without) ?? base
        let narrow = field.map(previewOf) ?? preview
        let all = BrowseFilter(
            query: wide,
            viewer: context.viewer,
            maxAgeDays: context.maxAgeDays,
            reads: context.reads
        )
        let kept = BrowseFilter(
            query: narrow, viewer: context.viewer, maxAgeDays: context.maxAgeDays, reads: context.reads
        )
        let window = context.maxAgeDays > 0 ? context.maxAgeDays : 90
        return BrowseHistogram.of(
            context.items.filter { all.matches($0, now: context.now) },
            windowDays: window,
            now: context.now
        ) {
            kept.matches($0, now: context.now)
        }
    }

    // MARK: Values

    static let agePresets: [(String, String)] = [
        ("n7", "in the last week"), ("n30", "in the last month"), ("n90", "in the last 3 months"),
        ("o7", "older than a week"), ("o30", "older than a month"), ("o90", "older than 3 months"),
    ]
    static let activityPresets: [(String, String)] = [
        ("n7", "active in the last week"), ("n30", "active in the last month"), ("o14", "no activity in 2 weeks"),
        ("o30", "no activity in 30 days"), ("o90", "no activity in 3 months"),
    ]
    static let unassigned = "~unassigned"

    func options(for field: BrowseField) -> [BrowsePicker.Option] {
        let scoped = BrowseFilter(
            query: without(field), viewer: context.viewer, maxAgeDays: context.maxAgeDays, reads: context.reads
        )
        .apply(to: context.items, now: context.now)
        let facets = BrowseFacets(of: scoped, reads: context.reads)
        func ranked(_ counts: [String: Int]) -> [BrowsePicker.Option] {
            BrowseFacets.ranked(counts).map { BrowsePicker.Option($0.name, count: $0.count) }
        }
        func counted(_ values: [(String, String)]) -> [BrowsePicker.Option] {
            values.map { value, label in
                var query = without(field)
                query.tokens += tokens(for: field, [value], mode: .any)
                return BrowsePicker.Option(value, label: label, count: count(query))
            }
        }
        switch field {
        case .label: return ranked(facets.labels)
        case .assignee:
            return [
                .init(
                    "@me",
                    label: "me",
                    count: scoped
                        .count { $0.assignees.contains { $0.lowercased() == (context.viewer ?? "@me").lowercased() } }
                ),
                .init(Self.unassigned, label: "unassigned", count: scoped.count { $0.assignees.isEmpty }),
            ] + ranked(facets.assignees)
        case .author:
            return [.init(
                "@me",
                label: "me",
                count: scoped.count { $0.author?.lowercased() == (context.viewer ?? "@me").lowercased() }
            )]
                + ranked(facets.authors)
        case .repo: return ranked(facets.repos)
        case .milestone: return ranked(facets.milestones)
        case .project: return ranked(facets.projects)
        case .type: return counted([("issues", "Issues"), ("pulls", "Pull requests")])
        case .state: return counted([("open", "Open"), ("closed", "Closed"), ("merged", "Merged")])
        case .linkedPull: return counted([("yes", "has a linked PR"), ("no", "has none")])
        case .age: return counted(Self.agePresets)
        case .activity: return counted(Self.activityPresets)
        case .heedClass:
            return BrowseClass.allCases.map {
                BrowsePicker.Option($0.rawValue, label: $0.title, count: facets.classes[$0] ?? 0)
            }
        case .heedSize:
            return BrowseSize.allCases.map {
                BrowsePicker.Option(
                    $0.rawValue, label: "\($0.rawValue) · \($0.title.lowercased())", count: facets.sizes[$0] ?? 0
                )
            }
        case .heedReady:
            return Self.readyPresets.map { value, label in
                var query = without(field)
                query.tokens += tokens(for: field, [value], mode: .any)
                return BrowsePicker.Option(value, label: label, count: count(query))
            }
        case .githubQuery: return []
        }
    }

    static let readyPresets: [(String, String)] = [
        ("90", "at least 90% agent-ready"), ("70", "at least 70%: ready for an agent"), ("50", "at least 50%"),
        ("0", "read by heed, any readiness"),
    ]

    func tokens(for field: BrowseField, _ values: [String], mode: BrowseLabelMode) -> [BrowseToken] {
        func span(_ value: String) -> BrowseSpan? {
            guard let days = Int(value.dropFirst()) else { return nil }
            return value.hasPrefix("n") ? .newerThan(days) : .olderThan(days)
        }
        guard !values.isEmpty else { return [] }
        switch field {
        case .label: return [.label(mode, values)]
        case .assignee:
            return values[0] == Self.unassigned ? [.raw("no:assignee")] : [.assignee(values[0])]
        case .author: return [.author(values[0])]
        case .repo: return [.repo(values[0])]
        case .milestone: return [.milestone(values[0])]
        case .project:
            let mapped = context.projects.compactMap { scope -> String? in
                if case let .project(owner, number, title) = scope, title == values[0] { return "\(owner)/\(number)" }
                return nil
            }.first
            return [.project(mapped ?? values[0])]
        case .type: return [.type(values[0] == "issues" ? .issues : .pulls)]
        case .state: return BrowseStateFilter(rawValue: values[0]).map { [.state($0)] } ?? []
        case .linkedPull: return [.linkedPull(values[0] == "yes")]
        case .age: return span(values[0]).map { [.created($0)] } ?? []
        case .activity: return span(values[0]).map { [.activity($0)] } ?? []
        case .heedClass: return [.heedClass(values.compactMap { BrowseClass(rawValue: $0) })]
        case .heedSize: return [.heedSize(values.compactMap { BrowseSize(rawValue: $0) })]
        case .heedReady: return Int(values[0]).map { [.heedReady($0)] } ?? []
        case .githubQuery: return []
        }
    }

    func valueTokens(_ field: BrowseField) -> [BrowseToken] {
        tokens(for: field, picker?.selected ?? [], mode: mode)
    }

    /// What `base` already says for a field, as picker values, so opening it edits rather than starts over.
    func selection(of field: BrowseField) -> [String] {
        var values: [String] = []
        for token in base.tokens where field.owns(token) {
            switch token {
            case let .label(_, names): values += names
            case let .assignee(value), let .author(value), let .repo(value), let .milestone(value): values.append(value)
            case let .project(value):
                values.append(context.projects.compactMap { scope -> String? in
                    if case let .project(owner, number, title) = scope, value == "\(owner)/\(number)" { return title }
                    return nil
                }.first ?? value)
            case .raw: values.append(Self.unassigned)
            case let .type(type): values.append(type == .issues ? "issues" : "pulls")
            case let .state(state): values.append(state.rawValue)
            case let .linkedPull(linked): values.append(linked ? "yes" : "no")
            case let .heedClass(classes): values += classes.map(\.rawValue)
            case let .heedSize(sizes): values += sizes.map(\.rawValue)
            case let .heedReady(least): values.append("\(least)")
            case let .created(span), let .activity(span):
                switch span {
                case let .newerThan(days): values.append("n\(days)")
                case let .olderThan(days): values.append("o\(days)")
                }
            default: break
            }
        }
        return values
    }

    // MARK: Opening things

    public mutating func open(_ field: BrowseField) {
        guard field.disabledReason == nil else { return }
        input = EditableText()
        if field == .githubQuery {
            stage = .raw
            input.set(BrowseQuery(tokens: base.tokens, showOlder: true)
                .rendered(maxAgeDays: context.maxAgeDays, now: context.now))
            return
        }
        if field == .project {
            stage = .project
            projectError = nil
            if case let .project(value)? = base.tokens.first(where: { field.owns($0) }) { input.set(value) }
            return
        }
        stage = .values(field)
        mode = base.tokens.compactMap { token -> BrowseLabelMode? in
            if case let .label(mode, _) = token { mode } else { nil }
        }.first ?? .any
        picker = BrowsePicker(options: options(for: field), multiple: field.isMultiple, selected: selection(of: field))
    }

    public mutating func cycleMode(by step: Int) {
        let all: [BrowseLabelMode] = [.any, .all, .none]
        mode = all[(all.firstIndex(of: mode)! + step + all.count) % all.count]
    }

    /// Ticks a value by clicking it (the keys tick the one under the cursor).
    public mutating func tick(_ value: String) {
        picker?.toggle(value)
    }

    public mutating func setEditing() {
        if case .ready = reading, !tokens.isEmpty { editing = true }
    }

    public mutating func choose(glyph: BrowseGlyph) {
        draft?.glyph = glyph
        if draft?.tintChosen == false { draft?.tint = glyph.tint }
    }

    public mutating func choose(tint: BrowseTint) {
        draft?.tint = tint
        draft?.tintChosen = true
    }

    public mutating func startSaving() {
        let query = preview
        draft = Draft(
            name: EditableText(SavedQuery.suggestedName(for: query)), glyph: BrowseGlyph.pick(for: query),
            tint: BrowseGlyph.pick(for: query).tint, id: nil, tintChosen: false
        )
        base = query
        stage = .save
    }

    /// What the raw field's text says.
    public var parsedRaw: BrowseQuery {
        BrowseQuery.parse(input.text, maxAgeDays: context.maxAgeDays, now: context.now)
    }

    // MARK: Keys

    public mutating func handle(_ stroke: KeyStroke) -> Action {
        switch stage {
        case .fields: handleFields(stroke)
        case let .values(field): handleValues(field, stroke)
        case .raw: handleRaw(stroke)
        case .project: handleProject(stroke)
        case .save: handleSave(stroke)
        }
    }

    private mutating func handleFields(_ stroke: KeyStroke) -> Action {
        if editing { return handleEditing(stroke) }
        let rows = fields
        switch stroke {
        case .escape: return .close
        case KeyStroke("c", .command): return .copy(raw)
        case KeyStroke("s", .command):
            startSaving()
            return .changed
        case KeyStroke("CR", .command) where isWords:
            return .apply(Self.merged([.text(sentence)], into: base))
        case KeyStroke("CR"):
            if isWords { return enterWords() }
            guard let field = rows[safe: cursor] else { return .none }
            open(field)
            return .changed
        case KeyStroke("Tab"):
            if case .ready = reading, !tokens.isEmpty { editing = true; return .changed }
            return .none
        case KeyStroke("Down"), KeyStroke("n", .control), KeyStroke("j", .control):
            cursor = rows.isEmpty ? 0 : min(cursor + 1, rows.count - 1)
        case KeyStroke("Up"), KeyStroke("p", .control), KeyStroke("k", .control):
            cursor = max(cursor - 1, 0)
        case KeyStroke("BS") where input.isEmpty:
            guard !base.tokens.isEmpty else { return .none }
            base.tokens.removeLast()
            return .apply(base)
        case _
            where input.isEmpty && stroke.modifiers.isEmpty && Int(stroke.key).map { (1 ... 9).contains($0) } == true:
            if let field = BrowseField.allCases[safe: Int(stroke.key)! - 1] {
                open(field)
                return .changed
            }
        default:
            let before = input.text
            guard input.handle(stroke) else { return .none }
            if input.text != before {
                cursor = 0
                reading = .idle
                tokens = []
            }
            return .changed
        }
        return .none
    }

    /// Enter on words: ask the model, apply what it understood, or (the model is off) search the words as text.
    private mutating func enterWords() -> Action {
        switch reading {
        case .ready:
            return .apply(Self.merged(tokens, into: base))
        case .reading: return .none
        case .idle, .failed:
            if context.wordsOff != nil { return .apply(Self.merged([.text(sentence)], into: base)) }
            reading = .reading
            return .read(sentence)
        }
    }

    private mutating func handleEditing(_ stroke: KeyStroke) -> Action {
        switch stroke {
        case .escape: editing = false
        case KeyStroke("Tab"), KeyStroke("Right"), KeyStroke("l", .control):
            tokenCursor = tokens.isEmpty ? 0 : (tokenCursor + 1) % tokens.count
        case KeyStroke("Tab", .shift), KeyStroke("Left"), KeyStroke("h", .control):
            tokenCursor = tokens.isEmpty ? 0 : (tokenCursor + tokens.count - 1) % tokens.count
        case KeyStroke("BS"), KeyStroke("x"), KeyStroke("Del"):
            if tokens.indices.contains(tokenCursor) { tokens.remove(at: tokenCursor) }
            tokenCursor = min(tokenCursor, max(tokens.count - 1, 0))
            if tokens.isEmpty { editing = false }
        case KeyStroke("CR"): return .apply(Self.merged(tokens, into: base))
        default: return .none
        }
        return .changed
    }

    private mutating func handleValues(_ field: BrowseField, _ stroke: KeyStroke) -> Action {
        guard var picker else { return .none }
        defer { self.picker = picker }
        switch stroke {
        case KeyStroke("c", .command): return .copy(raw)
        case KeyStroke("s", .command):
            self.picker = picker
            startSaving()
            return .changed
        case KeyStroke("Tab") where field.hasMode:
            cycleMode(by: 1)
            return .changed
        case KeyStroke("Tab", .shift) where field.hasMode:
            cycleMode(by: -1)
            return .changed
        default: break
        }
        switch picker.handle(stroke) {
        case .none: return .none
        case .changed: return .changed
        case .cancel:
            stage = .fields
            input = EditableText()
            return .changed
        case .done:
            self.picker = picker
            let applied = previewOf(field)
            base = applied
            stage = .fields
            input = EditableText()
            return .apply(applied)
        }
    }

    private mutating func handleRaw(_ stroke: KeyStroke) -> Action {
        switch stroke {
        case .escape:
            stage = .fields
            input = EditableText()
            return .changed
        case KeyStroke("c", .command): return .copy(input.text)
        case KeyStroke("CR"):
            let parsed = parsedRaw
            // heed's own filters are not part of GitHub's query: they stay as they were.
            var query = BrowseQuery(
                scope: base.scope, tokens: parsed.tokens + base.localTokens, showOlder: parsed.showOlder
            )
            if parsed.tokens
                .contains(where: { if case .org = $0 { true } else if case .repo = $0 { true } else { false } })
            {
                query.scope = nil
            }
            base = query
            stage = .fields
            input = EditableText()
            return .apply(query)
        default: return input.handle(stroke) ? .changed : .none
        }
    }

    /// The `owner/number` GitHub's `project:` qualifier takes, from what was typed: `acme/7`, `project:acme/7`, or the
    /// board's address (`github.com/orgs/acme/projects/7`). Nil when it is none of these.
    public static func projectRef(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.lowercased().hasPrefix("project:") { value = String(value.dropFirst("project:".count)) }
        let parts = value.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var owner = "", number = ""
        if value.contains("github.com"), let at = parts.firstIndex(of: "projects"), at >= 2, at + 1 < parts.count {
            owner = parts[at - 1]
            number = parts[at + 1]
        } else if parts.count == 2 {
            (owner, number) = (parts[0], parts[1])
        } else {
            return nil
        }
        let name = owner.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        guard !owner.isEmpty, name, let n = Int(number), n > 0, String(n) == number else { return nil }
        return "\(owner)/\(n)"
    }

    private mutating func handleProject(_ stroke: KeyStroke) -> Action {
        switch stroke {
        case .escape:
            stage = .fields
            input = EditableText()
            return .changed
        case KeyStroke("c", .command): return .copy(raw)
        case KeyStroke("CR"):
            let text = input.text.trimmingCharacters(in: .whitespaces)
            var applied = base
            applied.tokens.removeAll { BrowseField.project.owns($0) }
            if !text.isEmpty {
                guard let ref = Self.projectRef(text) else {
                    projectError = "Not a Project: type owner/number, like acme/7."
                    return .changed
                }
                applied.tokens.append(.project(ref))
            }
            base = applied
            stage = .fields
            input = EditableText()
            return .apply(applied)
        default:
            projectError = nil
            return input.handle(stroke) ? .changed : .none
        }
    }

    private mutating func handleSave(_ stroke: KeyStroke) -> Action {
        guard var draft else { return .close }
        defer { self.draft = draft }
        switch stroke {
        case .escape: return .close
        case KeyStroke("Tab"): draft.cycleGlyph(by: 1)
        case KeyStroke("Tab", .shift): draft.cycleGlyph(by: -1)
        case KeyStroke("t", .control): draft.cycleTint()
        case KeyStroke("CR"), KeyStroke("s", .command):
            let name = draft.name.text.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .none }
            return .keep(Keep(id: draft.id, name: name, glyph: draft.glyph, tint: draft.tint, query: base))
        default: return draft.name.handle(stroke) ? .changed : .none
        }
        return .changed
    }
}
