/// The title bar's middle: what you are looking at, as `lead / main tags detail` (`docs-builder / fix-anchors #2841`).
/// It is set in a monospaced font, so it is fitted in columns.
public struct TitleCrumb: Equatable, Sendable {
    /// The repo, or what kind of thing this is. Always whole.
    public var lead: String?
    /// The branch, number or name. Cut in the middle when it does not fit.
    public var main: String
    /// Identifiers after it (a PR number, a host): whole or not at all, never cut to a dangling `#`.
    public var tags: [String]
    /// Prose after it (a title). Cut at the end, and the first to go.
    public var detail: String?

    public init(lead: String? = nil, main: String, tags: [String] = [], detail: String? = nil) {
        self.lead = lead
        self.main = main
        self.tags = tags
        self.detail = detail
    }

    /// The crumb cut to `columns`, each part and each gap between parts a column wide per character. The main part
    /// gives way first, down to `minMain` columns; past that the tags go, last first, and the main part is cut further.
    public func fitted(columns: Int, minMain: Int = 12) -> TitleCrumb {
        // The lead and its slash, with a gap after each.
        let fixed = lead.map { $0.count + 3 } ?? 0
        let room = max(columns - fixed, 1)
        var kept = tags
        func tagWidth() -> Int { kept.reduce(0) { $0 + $1.count + 1 } }
        while !kept.isEmpty, room - tagWidth() < min(main.count, minMain) {
            kept.removeLast()
        }
        let mainWidth = max(min(main.count, room - tagWidth()), 1)
        // A gap, then at least two columns of title ("F…" is the least that says there is one).
        let left = room - tagWidth() - mainWidth - 1
        let shownDetail = detail.flatMap { left >= 2 ? Self.cutEnd($0, to: left) : nil }
        return TitleCrumb(lead: lead, main: Self.cutMiddle(main, to: mainWidth), tags: kept, detail: shownDetail)
    }

    static func cutMiddle(_ text: String, to width: Int) -> String {
        guard text.count > width else { return text }
        guard width > 1 else { return "…" }
        let head = width / 2, tail = width - 1 - head
        return String(text.prefix(head)) + "…" + String(text.suffix(tail))
    }

    static func cutEnd(_ text: String, to width: Int) -> String {
        guard text.count > width else { return text }
        guard width > 1 else { return "…" }
        return String(text.prefix(width - 1)) + "…"
    }
}
