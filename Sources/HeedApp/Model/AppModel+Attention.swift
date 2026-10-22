import Foundation
import HeedCore

/// Attention's glue on the app model: its items from the domain, kept in its store after each GitHub sync.
extension AppModel {
    /// PRs the pilot is driving (getting green, feeding back, waiting on checks): their CI is the pilot's to act on,
    /// so it is no reason in Attention until the pilot stalls or needs you.
    var pilotDriving: Set<PullRef> {
        let driving: Set<PilotStatus.Group> = [.failing, .changes, .feeding, .pending]
        return Set(sessions.flatMap(\.trackedPRs).filter { driving.contains(pilotStatus(for: $0).group) })
    }

    /// Every Attention item, from the domain as it is now.
    var attentionItems: [AttentionItem] {
        AttentionFeed.items(
            github: github, sessions: sessions, details: attention.details, pilotDriving: pilotDriving
        )
    }

    /// After a GitHub sync: keeps what Attention shows, so muted and ignored items stay listed for 30 days.
    func attentionSynced() async {
        guard !isFixture else { return }
        await attention.record(attentionItems, now: Clock.now)
    }
}
