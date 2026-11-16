import Foundation
import HeedCore
import Observation

/// Insights' Audit (`history.audit`): what heed and the agents did outside this Mac, from `heed.sqlite`, newest first,
/// narrowed by `/`; or the grants heed gave (⇥). Records are appended here and to the log; causes are written only
/// once something names them. Fixtures (and shots) read `Fixtures.audit`, with no IO.
@MainActor
@Observable
final class AuditBrowser {
    enum Section: String {
        case actions
        case grants
    }

    private(set) var book = AuditBook()
    /// `book`'s rows that `/` leaves, newest first.
    private(set) var rows: [AuditBook.Row] = []
    private(set) var grantRows: [AuditBook.GrantRow] = []
    private(set) var cursor = 0
    private(set) var grantCursor = 0
    private(set) var section = Section.actions
    /// Always rules already in the settings of repos heed knows, found when Audit opened.
    private(set) var before: [AuditGrant] = []
    /// When Audit started keeping a record on this Mac: releases from before are not its business.
    private(set) var startedAt: Date
    @ObservationIgnored private var search = ""
    @ObservationIgnored private(set) var log: EventLog?
    /// Writes to the log in order (`AuditWriter`).
    @ObservationIgnored private var writer: AuditWriter?
    /// Rows recorded but not in the log yet, and why: shown under the header until they are written.
    private(set) var writeStatus = AuditWriter.Status.saved
    /// Until the log is read, records wait in `buffered` (and show), and are written once it is.
    @ObservationIgnored private var loading: Bool
    @ObservationIgnored private var buffered: [(causes: [String], record: AuditRecord)] = []
    /// Causes in the log (or about to be): one is written the first time a row names it.
    @ObservationIgnored private var written: Set<String> = []
    /// Causes made this run that nothing has named yet: a key press that changes nothing outside is never written.
    @ObservationIgnored private var pending: [String: Cause] = [:]
    /// Which cause each session, and each pane heed started with a prompt, carries.
    @ObservationIgnored private(set) var sessionCauses: [String: String] = [:]
    @ObservationIgnored private(set) var paneCauses: [String: String] = [:]
    /// The last note heed gave auto mode in each pane (or session), as a cause: what the agent there does next hangs
    /// below it (`AppModel.auditOriginNote`).
    @ObservationIgnored private var toldCauses: [String: String] = [:]

    init(fixture: Bool, now: Date = Clock.now) {
        loading = !fixture
        startedAt = fixture ? now.addingTimeInterval(-30 * 86400)
            : UserDefaults.standard.object(forKey: "audit.startedAt") as? Date ?? now
        if fixture {
            book = AuditBook(Fixtures.audit(now: now))
            before = Fixtures.auditBefore
            refilter()
        } else if UserDefaults.standard.object(forKey: "audit.startedAt") == nil {
            UserDefaults.standard.set(now, forKey: "audit.startedAt")
        }
    }

    var selected: AuditBook.Row? { rows.indices.contains(cursor) ? rows[cursor] : nil }
    var selectedGrant: AuditBook.GrantRow? { grantRows.indices.contains(grantCursor) ? grantRows[grantCursor] : nil }

    /// What the tab says: actions in the last 7 days.
    func weekCount(now: Date = Clock.now) -> Int { book.count(since: now.addingTimeInterval(-7 * 86400)) }

    /// Reads what the log keeps, prunes what is past a year, and lists the rules already in `roots`' settings. What is
    /// recorded until the log is read waits, and is written once after it, so a cause the log has is not written again.
    func attach(log: EventLog?, roots: @escaping @Sendable () async -> [String]) {
        self.log = log
        guard let log else { return adopt(AuditBook(), before: []) }
        writer = AuditWriter(log: log) { [weak self] status in
            await MainActor.run { self?.writeStatus = status }
        }
        Task { [weak self] in
            await log.pruneAudit(now: Date())
            let loaded = await (try? log.audit()).map { AuditBook($0.records, broken: $0.broken) } ?? AuditBook()
            let paths = await roots()
            let known = loaded.grantIdentities
            let before = await Task.detached { AlwaysRules.beforeAudit(roots: paths, known: known) }.value
            self?.adopt(loaded, before: before)
        }
    }

    private func adopt(_ loaded: AuditBook, before: [AuditGrant]) {
        written.formUnion(loaded.causes.keys)
        for cause in loaded.causes.values {
            if let session = cause.session, sessionCauses[session] == nil { sessionCauses[session] = cause.id }
        }
        book = loaded
        self.before = before
        loading = false
        // What was recorded while the log was being read, in order, as if it came now.
        let waiting = buffered
        buffered = []
        for (causes, record) in waiting {
            append(causes, record)
        }
        refilter()
    }

    // MARK: Causes

    /// Keeps `cause` for later: written only when an action or grant names it.
    func note(_ cause: Cause) {
        guard !written.contains(cause.id), book.causes[cause.id] == nil else { return }
        pending[cause.id] = cause
    }

    func cause(_ id: String?) -> Cause? { id.flatMap { pending[$0] ?? book.causes[$0] } }

    /// `cause`, hung under `parent` when it is a trigger nothing names yet: a PR event that reached a session is
    /// that session's. A cause already written, or with a parent, is left as it is.
    func reparent(_ cause: Cause, under parent: Cause) -> Cause {
        guard cause.parent == nil, cause.id != parent.id, !written.contains(cause.id), book.causes[cause.id] == nil
        else { return cause }
        var hung = pending[cause.id] ?? cause
        hung.parent = parent.id
        hung.session = hung.session ?? parent.session
        hung.sessionTitle = hung.sessionTitle ?? parent.sessionTitle
        hung.agent = hung.agent ?? parent.agent
        note(parent)
        pending[cause.id] = hung
        return hung
    }

    /// The session's cause, and the one its pane started with when heed knows it.
    func cause(session: String?, pane: String?) -> Cause? {
        if let pane, let id = paneCauses[pane], let cause = cause(id) { return cause }
        return session.flatMap { sessionCauses[$0] }.flatMap(cause)
    }

    func bind(session: String, to cause: Cause) {
        note(cause)
        sessionCauses[session] = cause.id
    }

    func bind(pane: String, to cause: Cause) {
        note(cause)
        paneCauses[pane] = cause.id
    }

    func bind(told key: String, to cause: Cause) {
        note(cause)
        toldCauses[key] = cause.id
    }

    func toldCause(_ key: String) -> Cause? { toldCauses[key].flatMap(cause) }

    /// The records that write `id`'s chain, each cause once.
    private func chainRecords(_ id: String?) -> [AuditRecord] {
        var records: [AuditRecord] = []
        var next = id
        var seen: Set<String> = []
        while let current = next, !written.contains(current), seen.insert(current).inserted,
              let cause = pending[current] ?? book.causes[current]
        {
            records.insert(.cause(cause), at: 0)
            written.insert(current)
            pending[current] = nil
            next = cause.parent
        }
        return records
    }

    // MARK: Recording

    func record(_ action: AuditAction) { append([action.cause].compactMap(\.self), .action(action)) }

    func record(_ grant: AuditGrant) { append([grant.cause].compactMap(\.self), .grant(grant)) }

    func record(_ revocation: AuditRevocation) {
        append([revocation.cause].compactMap(\.self), .revoke(revocation))
    }

    private func append(_ causes: [String], _ record: AuditRecord) {
        if loading {
            buffered.append((causes, record))
            book.apply(causes.compactMap { cause($0) }.map(AuditRecord.cause) + [record])
            return refilter()
        }
        let records = causes.flatMap(chainRecords) + [record]
        book.apply(records)
        refilter()
        writer?.append(records)
    }

    /// `d` on `grant` was confirmed: false while a try is under way, or once it is taken back.
    func startRevoke(_ grant: AuditGrant) -> Bool {
        guard book.startRevoke(grant, at: Clock.now) else { return false }
        refilter()
        return true
    }

    /// The whole record as stored, for the export, once what is queued is written.
    func exportText() async -> String? {
        await writer?.flush()
        guard let log, let rows = try? await log.auditRows() else { return nil }
        return AuditChain.exportLines(rows)
    }

    // MARK: The list

    func toggleSection() {
        section = section == .actions ? .grants : .actions
    }

    func setCursor(_ index: Int) {
        switch section {
        case .actions:
            guard !rows.isEmpty else { return }
            cursor = min(max(index, 0), rows.count - 1)
        case .grants:
            guard !grantRows.isEmpty else { return }
            grantCursor = min(max(index, 0), grantRows.count - 1)
        }
    }

    var currentCursor: Int { section == .actions ? cursor : grantCursor }
    var currentCount: Int { section == .actions ? rows.count : grantRows.count }

    /// The ids of the list shown.
    var rowIDs: [String] {
        switch section {
        case .actions: rows.map(\.id)
        case .grants: grantRows.map(\.id)
        }
    }

    func setSearch(_ text: String) {
        guard text != search else { return }
        search = text
        cursor = 0
        grantCursor = 0
        refilter()
    }

    private func refilter() {
        let current = selected?.id
        let fresh = book.rows.filter { row in
            FilterQuery.matches(
                search,
                [
                    row.action.what, row.action.command, row.action.tag.rawValue, row.action.repo ?? "",
                    row.action.sessionTitle ?? "", row.action.agent ?? "", row.trigger,
                ] + row.authors.compactMap(\.login)
            )
        }
        if fresh != rows { rows = fresh }
        if let current, let index = rows.firstIndex(where: { $0.id == current }) {
            cursor = index
        } else {
            cursor = min(cursor, max(rows.count - 1, 0))
        }
        let grants = book.grantRows(before: before).filter { row in
            FilterQuery.matches(search, [row.grant.subject, row.grant.scope, row.grant.kind.label, row.grant.why])
        }
        if grants != grantRows { grantRows = grants }
        grantCursor = min(grantCursor, max(grantRows.count - 1, 0))
    }
}
