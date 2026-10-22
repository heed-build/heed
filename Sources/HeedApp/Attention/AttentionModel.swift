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
    /// Summaries by item id, for the update they were written for.
    private(set) var summaries: [String: (updatedAt: Date, text: String)] = [:]
    /// Items whose summary is being written.
    var summarizing: Set<String> = []
    /// A reply being drafted (`nil` text) or drafted, for one item.
    var draft: (id: String, text: String?)?

    /// Rules Settings opens on instead of the saved ones (screenshots show an edit in progress).
    var ruleDraftSeed: [String]?

    var filter: AttentionFilter = .needsMe
    var sort: AttentionSort = .recent

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
        summaries = Fixtures.attentionSummaries.mapValues { (Clock.now, $0) }
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

    func saveDetails(_ fetched: [ThreadDetail], now: Date) {
        for detail in fetched {
            details[detail.url.lowercased()] = detail
        }
        guard let store, !fetched.isEmpty else { return }
        Task { try? await store.saveDetails(fetched, now: now) }
    }

    /// The summary for `item` as it is now, from memory or the store.
    func summary(for item: AttentionItem) -> String? {
        guard let known = summaries[item.id], known.updatedAt >= item.updatedAt else { return nil }
        return known.text
    }

    func loadSummary(for item: AttentionItem) async -> String? {
        if let known = summary(for: item) { return known }
        guard let text = try? await store?.summary(for: item.id, updatedAt: item.updatedAt) else { return nil }
        summaries[item.id] = (item.updatedAt, text)
        return text
    }

    func saveSummary(_ text: String, for item: AttentionItem) {
        summaries[item.id] = (item.updatedAt, text)
        guard let store else { return }
        Task { try? await store.saveSummary(text, for: item.id, updatedAt: item.updatedAt) }
    }

    private func reload(now: Date = Date()) async {
        guard let store else { return }
        do {
            marks = try await store.marks()
            details = try await store.details()
            stored = try await store.items(now: now)
        } catch {
            NSLog("heed: could not read Attention items: \(error)")
        }
    }
}
