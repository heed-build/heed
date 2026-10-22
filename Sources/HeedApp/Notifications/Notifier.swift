import AppKit
import HeedCore
@preconcurrency import UserNotifications

/// macOS notifications when sessions start needing you (`[notifications]`): asked for, never taken, so Heed stays out
/// of the way until you choose Open. When and what is `Notices`' call: a grace first, a burst as one summary, one
/// reminder. Nothing is shown for the session you are looking at, and permission to notify is asked the first time
/// there is something to say, not at launch.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private weak var model: AppModel?
    private var notices = Notices()
    private var drainTask: Task<Void, Never>?
    /// When `drainTask` wakes.
    private var wake: Date?
    /// Entries with a notification in Notification Center, by kind: taken back when they stop needing you.
    private var shown: [String: Notices.Kind] = [:]

    private static let open = "heed.open"
    private static let allow = "heed.allow"
    private static let sessionCategory = "heed.session"
    private static let blockedCategory = "heed.blocked"

    /// Only the real app can post: a bundle macOS knows, and never a fake run (fixtures, shots, the tutor check).
    private static var allowed: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") && !ShotRunner.requested
            && !TutorCheck.requested
    }

    private var center: UNUserNotificationCenter? { Self.allowed ? UNUserNotificationCenter.current() : nil }

    /// Called once the live model starts; responses to notifications reach it from then on.
    func attach(_ model: AppModel) {
        guard !model.isFixture, let center else { return }
        self.model = model
        center.delegate = self
        let open = UNNotificationAction(identifier: Self.open, title: "Open", options: [.foreground])
        let allow = UNNotificationAction(identifier: Self.allow, title: "Allow", options: [.authenticationRequired])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.sessionCategory, actions: [open], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.blockedCategory, actions: [open, allow], intentIdentifiers: []),
        ])
    }

    /// A session's state changed. Called for every change; what is not worth a notification falls out here.
    func note(_ session: Session, from old: AgentState, settings: NotificationSettings) {
        guard model != nil, center != nil else { return }
        notices.note(
            id: session.id, title: session.title, agent: session.agent, from: old, to: session.state,
            settings: settings, at: Date()
        )
        if !session.state.state.needsYou, shown.removeValue(forKey: session.id) != nil {
            center?.removeDeliveredNotifications(withIdentifiers: [Self.identifier(session.id)])
        }
        schedule()
    }

    /// Everything of one kind that needs you now (PRs, helper tabs), read whole; what is gone is taken back.
    func sync(_ kind: Notices.Kind, _ entries: [Notices.Entry], settings: NotificationSettings, seen: Bool) {
        guard model != nil, center != nil else { return }
        notices.sync(kind, entries, timing: Notices.Timing(settings), at: Date(), seen: seen)
        let current = Set(entries.map(\.id))
        let gone = shown.filter { $0.value == kind && !current.contains($0.key) }.map(\.key)
        if !gone.isEmpty {
            gone.forEach { shown.removeValue(forKey: $0) }
            center?.removeDeliveredNotifications(withIdentifiers: gone.map(Self.identifier))
        }
        schedule()
    }

    /// Wakes when `Notices` says the next drain is due (the grace, the burst window, a reminder), and only then.
    private func schedule() {
        let next = notices.next
        guard next != wake else { return }
        wake = next
        drainTask?.cancel()
        guard let next else { return drainTask = nil }
        drainTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            await drain()
        }
    }

    private func drain() async {
        wake = nil
        drainTask = nil
        guard let model else { return }
        let notice = notices.drain(at: Date()) { model.isOnScreen(sessionID: $0) }
        schedule()
        await post(notice)
    }

    private static func identifier(_ id: String) -> String { "heed.session.\(id)" }

    private func post(_ notice: Notices.Notice?) async {
        guard let notice, let center, await authorized(center) else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        content.userInfo = ["session": notice.session ?? ""]
        let identifier: String
        switch notice {
        case let .one(entry):
            identifier = Self.identifier(entry.id)
            // Allow presses Return in the session's own agent pane, so only a session's prompt gets it.
            content.categoryIdentifier = entry.kind == .session && entry.state == .blocked && entry.agent == "claude"
                ? Self.blockedCategory : Self.sessionCategory
            shown[entry.id] = entry.kind
        case .summary:
            identifier = "heed.summary"
            content.categoryIdentifier = Self.sessionCategory
        }
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    /// Asks the first time; after that, whatever you answered (System Settings › Notifications changes it).
    private func authorized(_ center: UNUserNotificationCenter) async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: await (try? center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Shown while Heed is in front too: it was only posted because that session is not the one on screen.
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter, willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let session = response.notification.request.content.userInfo["session"] as? String ?? ""
        await MainActor.run {
            guard let model = self.model, !session.isEmpty else { return }
            if action == Self.allow {
                model.allowPermission(sessionID: session)
            } else if action == Self.open || action == UNNotificationDefaultActionIdentifier {
                model.show(sessionID: session)
            }
        }
    }
}
