import Foundation
import HeedCore
import Observation

/// Attention's own state, beside the domain: the store (`attention.sqlite`), what you did to items, and the thread
/// details fetched for them. The items themselves are built from the domain (`AttentionFeed.items`); this keeps what
/// the domain does not.
@MainActor
@Observable
final class AttentionModel {
    private(set) var store: AttentionStore?
    private(set) var marks: [String: AttentionMark] = [:]
    private(set) var details: [String: ThreadDetail] = [:]
    /// Items seen in the last 30 days, live or not: what Muted lists and rules are tried against.
    private(set) var stored: [StoredAttentionItem] = []

    /// Opens `attention.sqlite` beside the domain file and loads what it keeps.
    func open(beside file: URL) async {
        store = await AttentionStore
            .open(at: file.deletingLastPathComponent().appendingPathComponent("attention.sqlite"))
        await reload()
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
