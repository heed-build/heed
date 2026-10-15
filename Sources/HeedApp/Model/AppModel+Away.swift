import AppKit
import HeedCore

/// While you were away: the summary opens on launch, and when heed is active again after `[summary] away_hours`, when
/// there is something to show; `summary` (gZ) opens it any time. When heed was last active is a preference, not domain:
/// kept in UserDefaults, and never read or written by fixtures, shots or the tutor.
extension AppModel {
    private enum AwayKeys {
        /// When heed was last the active app.
        static let lastActive = "heed.lastActive"
        /// Since when the last summary that opened on its own went back, and when it opened.
        static let since = "heed.awaySince"
        static let shownAt = "heed.awayShownAt"
    }

    /// `summary`: since the start of yesterday, or since the last absence when its summary opened recently.
    func showAwaySummary() {
        let defaults = UserDefaults.standard
        let since = AwaySummary.askedSince(
            lastAway: isFixture ? nil : defaults.object(forKey: AwayKeys.since) as? Date,
            shownAt: isFixture ? nil : defaults.object(forKey: AwayKeys.shownAt) as? Date,
            now: Clock.now
        )
        awaySummary = buildAwaySummary(since: since)
    }

    private func buildAwaySummary(since: Date) -> AwaySummary {
        AwaySummary.build(
            events: AwaySummary.events(from: currentDomain), waiting: AwaySummary.waiting(from: list.ordered),
            since: since, now: Clock.now
        )
    }

    /// Watches heed going inactive and coming back (the app, the screens, the login session), and offers the summary
    /// once on launch. Live only: fixtures never open it on their own.
    func startAwayTracking() {
        guard !isFixture else { return }
        let app = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        app.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            UserDefaults.standard.set(Clock.now, forKey: AwayKeys.lastActive)
        }
        // Heed in front when the Mac sleeps or locks: it was looked at until then.
        let away: [(NotificationCenter, Notification.Name)] = [
            (app, NSApplication.willTerminateNotification), (workspace, NSWorkspace.screensDidSleepNotification),
            (workspace, NSWorkspace.willSleepNotification), (workspace, NSWorkspace.sessionDidResignActiveNotification),
        ]
        let back: [(NotificationCenter, Notification.Name)] = [
            (app, NSApplication.didBecomeActiveNotification), (workspace, NSWorkspace.screensDidWakeNotification),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification),
        ]
        for (center, name) in away {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wentAway() }
            }
        }
        for (center, name) in back {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cameBack() }
            }
        }
        offerAwaySummary()
    }

    /// The Mac sleeps or locks, or heed quits: when heed is in front, it was active until now. (Already inactive, the
    /// time it went inactive stands.)
    private func wentAway() {
        guard NSApp.isActive else { return }
        UserDefaults.standard.set(Clock.now, forKey: AwayKeys.lastActive)
    }

    private func cameBack() {
        guard NSApp.isActive else { return }
        offerAwaySummary()
    }

    /// Opens the summary when heed was last active `away_hours` ago or more, and there is something to show; waits
    /// for the resume dialog to close first. Heed counts as active from here on, so it opens once per absence.
    private func offerAwaySummary() {
        let defaults = UserDefaults.standard
        let now = Clock.now
        let last = defaults.object(forKey: AwayKeys.lastActive) as? Date
        defaults.set(now, forKey: AwayKeys.lastActive)
        guard let last, awaySummary == nil, pendingAwaySince == nil,
              AwaySummary.shouldOffer(lastActive: last, now: now, awayHours: Double(config.summaryAwayHours))
        else { return }
        if resume != nil {
            pendingAwaySince = last
        } else {
            showAwaySummary(since: last)
        }
    }

    /// After the resume dialog: the summary it held back.
    func showPendingAwaySummary() {
        guard let since = pendingAwaySince else { return }
        pendingAwaySince = nil
        showAwaySummary(since: since)
    }

    private func showAwaySummary(since: Date) {
        let summary = buildAwaySummary(since: since)
        guard !summary.isEmpty else { return }
        UserDefaults.standard.set(since, forKey: AwayKeys.since)
        UserDefaults.standard.set(Clock.now, forKey: AwayKeys.shownAt)
        awaySummary = summary
    }
}
