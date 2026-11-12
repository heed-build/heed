import AppKit
import HeedCore

/// heed's own nudge, while one is up: what's new since the version last opened, or the settings worth a look.
enum NudgeDialog {
    case whatsNew(WhatsNewContent)
    case gaps([SettingsGap])
}

/// heed's own nudges: "New in heed X" once after an update, the settings worth a look at most once per `[nudges]
/// gaps`, and the title bar pill between them. `NudgePolicy` (HeedCore) decides; this gathers what it reads (mode,
/// dialogs, whether heed is in front and idle), shows what it says, and remembers the last seen version and the last
/// gap nudge in preferences. Nothing here activates heed or raises its window: a nudge is drawn in the window and
/// waits there. Live only: fixtures, shots and the tutor never nudge on their own.
extension AppModel {
    private enum NudgeKeys {
        /// The version what's new was last recorded for.
        static let lastSeen = "heed.whatsNewLastSeen"
        /// What the last what's new went back to, for `whatsnew.show` ("" when it did not know).
        static let since = "heed.whatsNewSince"
        /// When the gap nudge last showed, or its clock started.
        static let lastGap = "heed.gapNudgeAt"
    }

    /// How often the safe moment is looked for.
    private static let nudgeCheckSeconds = 15

    /// The version running: `0.37.0`, or `0.1.0-dev` for a local build.
    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// The high-impact settings still at their default and not decided in Configure…, with what each needs done.
    var highImpactGaps: [SettingsGap] { settingsGaps.filter { $0.entry.impact == .high } }

    /// The pill's count; nil while it does not show. Screenshots show it only where a shot asks.
    var nudgePill: Int? {
        guard tutor == nil, tutorPicker == nil else { return nil }
        if isFixture || ShotMode.active, !nudgePillInShots { return nil }
        let count = highImpactGaps.count
        return NudgePolicy.showsPill(
            highImpactGaps: count, settings: config.nudges, hiddenThisLaunch: nudgePillHidden, nudgeUp: nudge != nil
        ) ? count : nil
    }

    /// Checks once now that the launch's own dialogs had their chance, then every few seconds for a safe moment.
    func startNudges() {
        guard !isFixture, !ShotMode.active else { return }
        checkNudges(atLaunch: true)
        nudgeTask?.cancel()
        nudgeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.nudgeCheckSeconds))
                self?.checkNudges(atLaunch: false)
            }
        }
    }

    /// Asks the policy, and does what it says.
    private func checkNudges(atLaunch: Bool) {
        guard !isFixture, tutor == nil else { return }
        let defaults = UserDefaults.standard
        let gaps = highImpactGaps
        let inputs = NudgeInputs(
            now: Clock.now, currentVersion: appVersion, lastSeenVersion: defaults.string(forKey: NudgeKeys.lastSeen),
            lastGapNudge: defaults.object(forKey: NudgeKeys.lastGap) as? Date, settings: config.nudges,
            firstLaunch: configCreatedThisLaunch, highImpactGaps: gaps.count, mode: mode, dialogUp: nudgeDialogUp,
            frontmost: heedFrontmost, idleSeconds: Self.idleSeconds, atLaunch: atLaunch,
            whatsNewPostponed: whatsNewPostponed
        )
        let decision = NudgePolicy.decide(inputs)
        if let version = decision.recordVersion { defaults.set(version, forKey: NudgeKeys.lastSeen) }
        if decision.restartGapClock { defaults.set(Clock.now, forKey: NudgeKeys.lastGap) }
        switch decision.show {
        case let .whatsNew(since, version):
            let content = WhatsNew.items(since: since, upTo: version)
            defaults.set(since ?? "", forKey: NudgeKeys.since)
            if content.isEmpty {
                // A patch with nothing to say: seen.
                defaults.set(version, forKey: NudgeKeys.lastSeen)
            } else {
                nudge = .whatsNew(content)
            }
        case .gaps:
            nudge = .gaps(gaps)
        case nil:
            break
        }
    }

    /// Anything up that a nudge must not cover: every dialog `busy` knows (mode included), readers, the goal and
    /// swarm forms, the tutor's picker, a text field with the keyboard, Configure… itself.
    private var nudgeDialogUp: Bool {
        busy || reader != nil || issueReader != nil || goals.form != nil || goals.sourceForm != nil
            || goals.swarmForm != nil || goals.planDraft != nil || goals.draft != nil || tutorPicker != nil
            || textInputActive || diffNote != nil || configure != nil
    }

    /// heed is the active app with its main window key: not Settings, not another app.
    private var heedFrontmost: Bool {
        NSApp.isActive && NSApp.keyWindow?.identifier == Self.mainWindowID
    }

    /// Seconds since the last key, click or mouse move anywhere in this login session.
    private static var idleSeconds: TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    // MARK: Commands

    /// `whatsnew.show` (Help › What's New in Heed): now, whatever the policy says, going back as far as the last one
    /// did.
    func showWhatsNew() {
        let defaults = UserDefaults.standard
        let since = isFixture ? nil : defaults.string(forKey: NudgeKeys.since).flatMap { $0.isEmpty ? nil : $0 }
        let content = WhatsNew.items(since: since, upTo: appVersion)
        guard !content.isEmpty else { return flash = "nothing new in heed \(content.version.short)" }
        nudge = .whatsNew(content)
    }

    /// `nudges.hide [always]`, or the pill's ×: hidden until the next launch; `always` turns the gap nudge off in
    /// config.toml (`[nudges] gaps = "off"`).
    func hideNudgePill(always: Bool) {
        if always {
            if !isFixture { setConfig(["nudges", "gaps"], .string(NudgeSettings.Cadence.off.rawValue)) }
            flash = "no more reminders about settings; Settings › Notifications turns them back on"
        } else {
            guard nudgePill != nil else { return flash = "no settings reminder here" }
            flash = "hidden until the next launch; Configure… still lists them"
        }
        nudgePillHidden = true
    }

    // MARK: The dialogs

    /// Closes the nudge. What's new closed as seen records the version running (a release only); Not now (`seen`
    /// false) leaves it for the next launch.
    func closeNudge(seen: Bool) {
        guard let shown = nudge else { return }
        nudge = nil
        guard case .whatsNew = shown else { return }
        if seen {
            if !isFixture, let version = HeedVersion(appVersion) {
                UserDefaults.standard.set(version.description, forKey: NudgeKeys.lastSeen)
            }
        } else {
            whatsNewPostponed = true
        }
    }

    /// Don't show what's new: off in config.toml (`[nudges] whats_new = false`); `:whatsnew.show` still opens it.
    func turnOffWhatsNew() {
        if !isFixture { setConfig(["nudges", "whats_new"], .bool(false)) }
        closeNudge(seen: true)
        flash = "what's new off; :whatsnew.show still opens it"
    }

    /// The same switch flipped back, when what's new was opened by hand while off.
    func turnOnWhatsNew() {
        if !isFixture { setConfig(["nudges", "whats_new"], .bool(true)) }
        flash = "what's new on: it opens after an update"
    }

    /// Don't remind me, on the gap nudge.
    func turnOffGapNudge() {
        closeNudge(seen: true)
        hideNudgePill(always: true)
    }

    /// Configure… from a nudge or the pill: the nudge closed as seen, then the wizard.
    func configureFromNudge() {
        closeNudge(seen: true)
        openConfigure()
    }

    /// A gap's Set up & test, in the gap nudge: what Settings › Model calls' one click does, written and tested.
    func setUpModelCallsFromNudge() {
        closeNudge(seen: true)
        applySuggestedSetup()
    }

    /// A feature's Show me: its command, or Settings on its setting's page.
    func showMe(_ target: WhatsNewTarget) {
        closeNudge(seen: true)
        switch target {
        case let .command(line):
            perform(CommandInvocation(parsing: line))
        case let .setting(id):
            guard let entry = SettingsCatalog.entry(id) else { return }
            settingsPage = entry.page
            openSettings?()
        }
    }

    /// The nudge's keys: ⎋ is Not now, ↩ Done. A text field of a row in it keeps its typing.
    func answerNudge(_ stroke: KeyStroke) -> Bool {
        if stroke == .escape || stroke == KeyStroke("q") && !editingInWindow {
            closeNudge(seen: false)
            return true
        }
        if editingInWindow { return false }
        if stroke == KeyStroke("CR") { closeNudge(seen: true) }
        return true
    }

    /// A text field in the main window has the keyboard (a row's field in a nudge).
    private var editingInWindow: Bool {
        guard let window = NSApp.keyWindow, window.identifier == Self.mainWindowID else { return false }
        return window.firstResponder is NSText
    }
}
