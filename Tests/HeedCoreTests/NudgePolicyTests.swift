import Foundation
@testable import HeedCore
import Testing

/// When heed's own nudges may show: what's new once after an update, the gap nudge once per cadence, and only at a
/// safe moment. Every "never" is a test of its own.
struct NudgePolicyTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let day: TimeInterval = 86400

    /// heed in front, idle two minutes, in NORMAL, nothing up: a safe moment, with an update waiting.
    static func idle(
        current: String = "0.37.0", lastSeen: String? = "0.36.0", lastGap: Date? = nil,
        settings: NudgeSettings = NudgeSettings(), gaps: Int = 2
    ) -> NudgeInputs {
        NudgeInputs(
            now: now, currentVersion: current, lastSeenVersion: lastSeen, lastGapNudge: lastGap, settings: settings,
            highImpactGaps: gaps, mode: .normal, dialogUp: false, frontmost: true, idleSeconds: 120
        )
    }

    // MARK: What's new

    @Test func whatsNewShowsOnceAfterAnUpdate() {
        let decision = NudgePolicy.decide(Self.idle())
        #expect(decision.show == .whatsNew(since: "0.36.0", version: "0.37.0"))
        // Recorded when it closes as seen, not before.
        #expect(decision.recordVersion == nil)
        // Recorded, the next check shows it no more (the gap clock restarted with it).
        let after = NudgePolicy.decide(Self.idle(lastSeen: "0.37.0", lastGap: Self.now))
        #expect(after.show == nil)
    }

    /// Not now: not again this launch, back at the next one.
    @Test func notNowPutsItOffUntilTheNextLaunch() {
        var later = Self.idle(lastGap: Self.now)
        later.whatsNewPostponed = true
        #expect(NudgePolicy.decide(later).show == nil)
        #expect(NudgePolicy.decide(later).recordVersion == nil)
        var next = Self.idle(lastGap: Self.now)
        next.atLaunch = true
        #expect(NudgePolicy.decide(next).show == .whatsNew(since: "0.36.0", version: "0.37.0"))
    }

    @Test func whatsNewShowsOnLaunchEvenWhenNotInFront() {
        var inputs = Self.idle()
        inputs.frontmost = false
        inputs.idleSeconds = 0
        inputs.atLaunch = true
        #expect(NudgePolicy.decide(inputs).show == .whatsNew(since: "0.36.0", version: "0.37.0"))
    }

    @Test func aFirstLaunchRecordsTheVersionAndShowsNothing() {
        var inputs = Self.idle(lastSeen: nil)
        inputs.firstLaunch = true
        inputs.atLaunch = true
        let decision = NudgePolicy.decide(inputs)
        #expect(decision.show == nil)
        #expect(decision.recordVersion == "0.37.0")
        // The gap nudge waits a cadence from here.
        #expect(decision.restartGapClock)
    }

    /// A heed from before what's new existed never recorded a version: it shows this version's own.
    @Test func anUpdateFromBeforeWhatsNewShowsThisVersion() {
        let decision = NudgePolicy.decide(Self.idle(lastSeen: nil))
        #expect(decision.show == .whatsNew(since: nil, version: "0.37.0"))
    }

    @Test func neverForTheSameVersionOrADowngrade() {
        #expect(NudgePolicy.decide(Self.idle(lastSeen: "0.37.0", gaps: 0)) == .nothing)
        #expect(NudgePolicy.decide(Self.idle(current: "0.36.0", lastSeen: "0.37.0", gaps: 0)) == .nothing)
    }

    @Test func neverInADevBuild() {
        #expect(NudgePolicy.decide(Self.idle(current: "0.1.0-dev")) == .nothing)
        var first = Self.idle(current: "0.1.0-dev", lastSeen: nil)
        first.firstLaunch = true
        // Not even recorded: a later release still knows where you were.
        #expect(NudgePolicy.decide(first) == .nothing)
    }

    @Test func dontShowWhatsNewRecordsQuietlyAndLetsTheGapsThrough() {
        let off = NudgeSettings(whatsNew: false)
        let decision = NudgePolicy.decide(Self.idle(settings: off))
        #expect(decision.recordVersion == "0.37.0")
        #expect(decision.show == .gaps)
        // Recorded even when the moment is not safe.
        var busy = Self.idle(settings: off)
        busy.mode = .insert
        #expect(NudgePolicy.decide(busy) == NudgeDecision(recordVersion: "0.37.0"))
    }

    @Test func whatsNewComesBeforeTheGapsAndRestartsTheirClock() {
        let decision = NudgePolicy.decide(Self.idle(gaps: 3))
        #expect(decision.show == .whatsNew(since: "0.36.0", version: "0.37.0"))
        #expect(decision.restartGapClock)
        #expect(!NudgePolicy.decide(Self.idle(gaps: 0)).restartGapClock)
    }

    // MARK: Gaps

    @Test func gapsShowAtMostOncePerCadence() {
        func show(_ ago: TimeInterval, _ cadence: NudgeSettings.Cadence) -> Nudge? {
            NudgePolicy.decide(Self.idle(
                lastSeen: "0.37.0", lastGap: Self.now - ago, settings: NudgeSettings(gaps: cadence)
            )).show
        }
        #expect(show(2.9 * Self.day, .threeDays) == nil)
        #expect(show(3 * Self.day, .threeDays) == .gaps)
        #expect(show(6.9 * Self.day, .weekly) == nil)
        #expect(show(7 * Self.day, .weekly) == .gaps)
        // Never shown: due.
        #expect(NudgePolicy.decide(Self.idle(lastSeen: "0.37.0")).show == .gaps)
        #expect(NudgePolicy.decide(Self.idle(lastSeen: "0.37.0")).restartGapClock)
        // A clock that went back past the last one: due, rather than waiting until then.
        #expect(show(-30 * Self.day, .threeDays) == .gaps)
    }

    @Test func neverWhenTheGapsAreOff() {
        let decision = NudgePolicy.decide(Self.idle(lastSeen: "0.37.0", settings: NudgeSettings(gaps: .off)))
        #expect(decision == .nothing)
    }

    @Test func neverWithoutAHighImpactGap() {
        #expect(NudgePolicy.decide(Self.idle(lastSeen: "0.37.0", gaps: 0)) == .nothing)
    }

    @Test func highImpactGapsAreTheWizardsHighOnes() throws {
        let gaps = NudgePolicy.highImpactGaps(in: .default, chosen: ChosenSettings())
        #expect(!gaps.isEmpty)
        #expect(gaps.allSatisfy { $0.impact == .high })
        #expect(gaps.map(\.id) == SettingsCatalog.gaps(in: .default, chosen: ChosenSettings())
            .filter { $0.impact == .high }.map(\.id))
        let chosen = ChosenSettings(Set(gaps.map(\.id)))
        #expect(NudgePolicy.highImpactGaps(in: .default, chosen: chosen).isEmpty)
    }

    // MARK: Safe moments: every never

    @Test(arguments: [Mode.insert, .command, .visual, .hint])
    func neverWhileTyping(mode: Mode) {
        var inputs = Self.idle()
        inputs.mode = mode
        #expect(NudgePolicy.decide(inputs).show == nil)
        inputs.atLaunch = true
        #expect(NudgePolicy.decide(inputs).show == nil)
        var gaps = Self.idle(lastSeen: "0.37.0")
        gaps.mode = mode
        #expect(NudgePolicy.decide(gaps).show == nil)
    }

    @Test func neverOverAnotherDialog() {
        var inputs = Self.idle()
        inputs.dialogUp = true
        #expect(NudgePolicy.decide(inputs).show == nil)
        inputs.atLaunch = true
        #expect(NudgePolicy.decide(inputs).show == nil)
        // Nothing recorded: it shows at the next safe moment instead.
        #expect(NudgePolicy.decide(inputs).recordVersion == nil)
    }

    @Test func neverOutsideLaunchUnlessInFront() {
        var inputs = Self.idle()
        inputs.frontmost = false
        inputs.idleSeconds = 3600
        #expect(NudgePolicy.decide(inputs).show == nil)
    }

    @Test func neverBeforeAMinuteIdle() {
        var inputs = Self.idle()
        inputs.idleSeconds = 59
        #expect(NudgePolicy.decide(inputs).show == nil)
        inputs.idleSeconds = 60
        #expect(NudgePolicy.decide(inputs).show != nil)
    }

    @Test func aSafeMomentIsNormalAndClearThenLaunchOrIdleInFront() {
        func safe(_ mode: Mode = .normal, dialog: Bool = false, front: Bool, idle: TimeInterval, launch: Bool) -> Bool {
            NudgePolicy.isSafeMoment(mode: mode, dialogUp: dialog, frontmost: front, idleSeconds: idle, atLaunch: launch)
        }
        #expect(safe(front: false, idle: 0, launch: true))
        #expect(safe(front: true, idle: 60, launch: false))
        #expect(!safe(front: true, idle: 10, launch: false))
        #expect(!safe(front: false, idle: 600, launch: false))
        #expect(!safe(.insert, front: true, idle: 600, launch: true))
        #expect(!safe(dialog: true, front: true, idle: 600, launch: true))
    }

    // MARK: The pill

    @Test func thePillShowsBetweenNudgesWhileThereAreGaps() {
        let on = NudgeSettings()
        #expect(NudgePolicy.showsPill(highImpactGaps: 2, settings: on, hiddenThisLaunch: false, nudgeUp: false))
        #expect(!NudgePolicy.showsPill(highImpactGaps: 0, settings: on, hiddenThisLaunch: false, nudgeUp: false))
        #expect(!NudgePolicy.showsPill(highImpactGaps: 2, settings: on, hiddenThisLaunch: true, nudgeUp: false))
        #expect(!NudgePolicy.showsPill(highImpactGaps: 2, settings: on, hiddenThisLaunch: false, nudgeUp: true))
        let off = NudgeSettings(gaps: .off)
        #expect(!NudgePolicy.showsPill(highImpactGaps: 2, settings: off, hiddenThisLaunch: false, nudgeUp: false))
    }

    // MARK: Config

    @Test func nudgesReadFromConfig() throws {
        #expect(HeedConfig.default.nudges == NudgeSettings(whatsNew: true, gaps: .threeDays))
        let config = try #require(ConfigLoader.decode("[nudges]\nwhats_new = false\ngaps = \"weekly\"").config)
        #expect(config.nudges == NudgeSettings(whatsNew: false, gaps: .weekly))
        let (_, problems) = ConfigLoader.decode("[nudges]\ngaps = \"daily\"")
        #expect(problems.map(\.path) == ["nudges.gaps"])
        #expect(NudgeSettings.Cadence.threeDays.interval == 3 * Self.day)
        #expect(NudgeSettings.Cadence.off.interval == nil)
    }
}
