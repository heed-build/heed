import Foundation
import HeedCore
import Observation

/// Attention's own state, beside the domain: the store (`attention.sqlite`), what you did to items, the thread details
/// and summaries fetched for them, and how the view is filtered and sorted. The items themselves are built from the
/// domain (`AttentionFeed.items`); this keeps what the domain does not.
@MainActor
@Observable
final class AttentionModel {
    private(set) var store: AttentionStore?
    private(set) var marks: [String: AttentionMark] = [:]
    private(set) var details: [String: ThreadDetail] = [:]
    /// Items seen in the last 30 days, live or not: what Muted lists and rules are tried against.
    private(set) var stored: [StoredAttentionItem] = []
    /// Catch-up summaries by item id: what was new since you last looked, and what each covers.
    private(set) var catchUps: [String: CatchUpSummary] = [:]
    /// Summaries being written (or queued ahead), by item id.
    var summaryRuns: [String: SummaryRun] = [:]
    /// Why the last attempt at an item's summary failed, until one is written.
    var summaryFailures: [String: SummaryFailure] = [:]
    /// The ahead queue at work: for the list's footer.
    var summaryProgress: SummaryProgress?
    /// A reply being drafted (`nil` text) or drafted, for one item.
    var draft: (id: String, text: String?)?

    /// Whether the first sync's items were handed to the notifications (as already seen).
    var notified = false
    /// The Decider's suggested weight for items no rule matched, for the update it was asked about.
    var suggestions: [String: (updatedAt: Date, level: String?)] = [:]

    /// Rules Settings opens on instead of the saved ones (screenshots show an edit in progress).
    var ruleDraftSeed: [String]?
    /// A rule Settings' editor opens with, half built (screenshots show the editor at work).
    var ruleFormSeed: AttentionRuleForm?

    var filter: AttentionFilter = .forYou
    var sort: AttentionSort = .recent

    /// When you last looked at each thread and at Attention, as it is now: what the dots and the reader's fold read.
    private(set) var seen = AttentionSeen()
    /// The same, as it was when you came into Attention: what For you's sections are decided by, so rows stay where
    /// they are while you read them.
    var sectionSeen = AttentionSeen()
    /// Mentioned before listed rather than folded (`za`).
    var unfoldBefore = false
    /// The thread in the reader, since when, and whether you opened it on purpose.
    var visit: AttentionVisit?
    /// A request to scroll the reader by half its height: down (1) or up (-1), and a count so the same twice moves
    /// twice.
    var readerScroll: (direction: Int, count: Int) = (0, 0)

    /// Opens `attention.sqlite` beside the domain file and loads what it keeps.
    func open(beside file: URL) async {
        store = await AttentionStore
            .open(at: file.deletingLastPathComponent().appendingPathComponent("attention.sqlite"))
        await reload()
    }

    /// The fake world's: no store, what the fixtures say.
    func adoptFixtures() {
        marks = Fixtures.attentionMarks
        details = Fixtures.attentionDetails
        stored = Fixtures.attentionStored
        catchUps = Fixtures.attentionCatchUps
        seen = Fixtures.attentionSeen
        sectionSeen = seen
        suggestions = Fixtures.attentionSuggestions.mapValues { (Clock.now, $0) }
    }

    /// Keeps the live items (seen now), drops what is past 30 days, and reloads.
    func record(_ items: [AttentionItem], now: Date) async {
        guard let store else { return }
        do {
            try await store.record(items, now: now)
            try await store.prune(now: now)
        } catch {
            NSLog("heed: could not keep Attention items: \(error)")
        }
        await reload(now: now)
    }

    func setMark(_ mark: AttentionMark, for id: String) {
        marks[id] = mark == AttentionMark() ? nil : mark
        guard let store else { return }
        Task {
            do { try await store.setMark(mark, for: id) } catch {
                NSLog("heed: could not keep an Attention mark: \(error)")
            }
        }
    }

    /// You looked at a thread at `at` (later times only).
    func markSeen(_ id: String, at: Date) {
        guard seen.threads[id].map({ $0 < at }) ?? true else { return }
        seen.threads[id] = at
        guard let store else { return }
        Task {
            do { try await store.setSeen(id, at: at) } catch {
                NSLog("heed: could not keep when a thread was seen: \(error)")
            }
        }
    }

    /// You left Attention at `at`: New since starts there next time.
    func left(at: Date) {
        seen.leftAt = at
        guard let store else { return }
        Task { try? await store.setLeft(at: at) }
    }

    func saveDetails(_ fetched: [ThreadDetail], now: Date) {
        for detail in fetched {
            details[detail.url.lowercased()] = detail
        }
        guard let store, !fetched.isEmpty else { return }
        Task { try? await store.saveDetails(fetched, now: now) }
    }

    func saveCatchUp(_ summary: CatchUpSummary, for id: String) {
        catchUps[id] = summary
        summaryFailures[id] = nil
        guard let store else { return }
        Task {
            do { try await store.saveCatchUp(summary, for: id) } catch {
                NSLog("heed: could not keep a summary: \(error)")
            }
        }
    }

    /// Fixtures and shots: a summary in memory only.
    func setCatchUp(_ summary: CatchUpSummary?, for id: String) {
        catchUps[id] = summary
    }

    private func reload(now: Date = Date()) async {
        guard let store else { return }
        do {
            marks = try await store.marks()
            details = try await store.details()
            stored = try await store.items(now: now)
            // What was written while it loaded stays.
            catchUps = try await store.catchUps().merging(catchUps) { stored, written in
                written.writtenAt >= stored.writtenAt ? written : stored
            }
            let loaded = try await store.seen()
            // What was marked while it loaded stays (the later of the two).
            seen.threads.merge(loaded.threads) { max($0, $1) }
            seen.leftAt = [seen.leftAt, loaded.leftAt].compactMap(\.self).max()
            if sectionSeen == AttentionSeen() { sectionSeen = seen }
        } catch {
            NSLog("heed: could not read Attention items: \(error)")
        }
    }
}
