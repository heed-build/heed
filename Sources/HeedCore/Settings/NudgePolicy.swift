import Foundation

// When heed may put one of its own nudges in front of you: "New in heed X" once after an update, and the settings
// worth a look (high-impact gaps) at most once per `[nudges] gaps`. Only at a safe moment: on launch, or with heed in
// front and idle a minute in NORMAL mode; never while you type (INSERT, the : line, VISUAL, hints), never over another
// dialog or overlay. Showing a nudge never activates or raises heed: it is drawn in the window, and seen when you look.

/// Everything the decision reads. Pure values: the app gathers them, the policy decides.
public struct NudgeInputs: Sendable {
    public var now: Date
    /// The version running (`CFBundleShortVersionString`).
    public var currentVersion: String
    /// The version what's new was last recorded for; nil: none yet.
    public var lastSeenVersion: String?
    /// When the gap nudge last showed (or its clock started); nil: never.
    public var lastGapNudge: Date?
    /// `[nudges]`: `whats_new` (false is Don't show what's new) and `gaps` ("off" is Don't remind me).
    public var settings: NudgeSettings
    /// config.toml was written this launch: heed's very first, which has its own dialog.
    public var firstLaunch: Bool
    /// The high-impact settings still at their default and not chosen.
    public var highImpactGaps: Int
    public var mode: Mode
    /// A dialog, overlay, sheet or form is up (or a nudge already is).
    public var dialogUp: Bool
    /// heed is the active app and its main window is key.
    public var frontmost: Bool
    /// Seconds since the last key, click or mouse move.
    public var idleSeconds: TimeInterval
    /// The check right after launch, once the launch's own dialogs had their chance.
    public var atLaunch: Bool
    /// What's new was put off with Not now this launch: it comes back at the next one.
    public var whatsNewPostponed: Bool

    public init(
        now: Date, currentVersion: String, lastSeenVersion: String?, lastGapNudge: Date?,
        settings: NudgeSettings = NudgeSettings(), firstLaunch: Bool = false, highImpactGaps: Int = 0,
        mode: Mode = .normal, dialogUp: Bool = false, frontmost: Bool = false, idleSeconds: TimeInterval = 0,
        atLaunch: Bool = false, whatsNewPostponed: Bool = false
    ) {
        self.now = now
        self.currentVersion = currentVersion
        self.lastSeenVersion = lastSeenVersion
        self.lastGapNudge = lastGapNudge
        self.settings = settings
        self.firstLaunch = firstLaunch
        self.highImpactGaps = highImpactGaps
        self.mode = mode
        self.dialogUp = dialogUp
        self.frontmost = frontmost
        self.idleSeconds = idleSeconds
        self.atLaunch = atLaunch
        self.whatsNewPostponed = whatsNewPostponed
    }
}

/// A nudge to show.
public enum Nudge: Equatable, Sendable {
    /// "New in heed `version`", since `since` (nil: not known, this version's own).
    case whatsNew(since: String?, version: String)
    /// The settings worth a look.
    case gaps
}

/// What to do now: show at most one nudge, and what to remember.
public struct NudgeDecision: Equatable, Sendable {
    public var show: Nudge?
    /// Record this as the last seen version now, without showing anything. (A what's new shown is recorded when it
    /// is closed as seen: Done, Show me, Configure…, Don't show; Not now leaves it for the next launch.)
    public var recordVersion: String?
    /// Start the gap nudge's clock again from now.
    public var restartGapClock = false

    public init(show: Nudge? = nil, recordVersion: String? = nil, restartGapClock: Bool = false) {
        self.show = show
        self.recordVersion = recordVersion
        self.restartGapClock = restartGapClock
    }

    public static let nothing = NudgeDecision()
}

public enum NudgePolicy {
    /// How long heed must sit idle in front before a nudge may show outside launch.
    public static let idleSeconds: TimeInterval = 60

    /// A moment a nudge may take: NORMAL mode and nothing else up, and then either the launch or heed in front and
    /// idle for a minute. Never while typing in a terminal, on the : line, selecting or picking a hint.
    public static func isSafeMoment(
        mode: Mode, dialogUp: Bool, frontmost: Bool, idleSeconds: TimeInterval, atLaunch: Bool
    ) -> Bool {
        guard mode == .normal, !dialogUp else { return false }
        return atLaunch || (frontmost && idleSeconds >= Self.idleSeconds)
    }

    public static func decide(_ inputs: NudgeInputs) -> NudgeDecision {
        // A dev or pre-release build: nothing shows and nothing is recorded, so a later release still knows.
        guard let current = HeedVersion(inputs.currentVersion) else { return .nothing }
        var decision = NudgeDecision()
        let lastSeen = inputs.lastSeenVersion.flatMap(HeedVersion.init)
        // The very first launch: first run has its own dialog. Remember the version, and start the gap clock so the
        // settings nudge waits its cadence.
        if lastSeen == nil, inputs.firstLaunch {
            return NudgeDecision(recordVersion: current.description, restartGapClock: inputs.lastGapNudge == nil)
        }
        // An update (or a heed from before what's new, which never recorded one). A downgrade is not.
        let updated = lastSeen.map { current > $0 } ?? true
        if updated, !inputs.settings.whatsNew {
            // Don't show what's new: remember the version quietly, so turning it back on starts from here.
            decision.recordVersion = current.description
        }
        let whatsNewDue = updated && inputs.settings.whatsNew && !inputs.whatsNewPostponed
        guard isSafeMoment(
            mode: inputs.mode, dialogUp: inputs.dialogUp, frontmost: inputs.frontmost,
            idleSeconds: inputs.idleSeconds, atLaunch: inputs.atLaunch
        ) else { return decision }
        if whatsNewDue {
            // Its footer points at the gaps too, so the gap nudge waits a full cadence after it.
            return NudgeDecision(
                show: .whatsNew(since: lastSeen?.description, version: current.description),
                restartGapClock: inputs.highImpactGaps > 0
            )
        }
        if gapsDue(inputs) {
            decision.show = .gaps
            decision.restartGapClock = true
        }
        return decision
    }

    /// The gap nudge is due: a cadence, a high-impact gap, and a full cadence since it last showed (or a clock that
    /// went back past it).
    static func gapsDue(_ inputs: NudgeInputs) -> Bool {
        guard let interval = inputs.settings.gaps.interval, inputs.highImpactGaps > 0 else { return false }
        guard let last = inputs.lastGapNudge else { return true }
        return last > inputs.now || inputs.now.timeIntervalSince(last) >= interval
    }

    /// The gaps the nudge and the pill are about: the wizard's, high impact only.
    public static func highImpactGaps(
        in config: HeedConfig, chosen: ChosenSettings, facts: GapFacts = GapFacts()
    ) -> [SettingsGap] {
        SettingsCatalog.gaps(in: config, chosen: chosen, facts: facts).filter { $0.entry.impact == .high }
    }

    /// The title bar's pill between nudges ("N settings worth a look"): while there are high-impact gaps and the gap
    /// nudge is not off, not hidden for this launch, and no nudge is up.
    public static func showsPill(
        highImpactGaps: Int, settings: NudgeSettings, hiddenThisLaunch: Bool, nudgeUp: Bool
    ) -> Bool {
        highImpactGaps > 0 && settings.gaps != .off && !hiddenThisLaunch && !nudgeUp
    }
}
