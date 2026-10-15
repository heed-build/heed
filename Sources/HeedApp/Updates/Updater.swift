import AppKit
import HeedCore
import Sparkle

/// Heed updating itself, through Sparkle: once a day it reads the appcast on heed's latest GitHub release, and offers
/// (or with `[updates] install = "auto"`, downloads and installs on quit) a newer version. Sparkle installs only an
/// archive signed with the key whose public half is `SUPublicEDKey`, on top of Apple's notarization.
@MainActor
final class Updater {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController?

    /// Running: a release build with a public key, outside every fake run (fixtures, shots, the tutor check).
    var isRunning: Bool { controller != nil }

    static var allowed: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let key = info["SUPublicEDKey"] as? String ?? ""
        return !version.isEmpty && !version.contains("-dev") && !key.isEmpty
            && Bundle.main.bundlePath.hasSuffix(".app") && !ShotRunner.requested && !TutorCheck.requested
    }

    /// Starts the updater the first time (when allowed), and applies `[updates]` every time the config changes. Setting
    /// the choices here is what keeps Sparkle from asking "check automatically?" on the second launch: the config says.
    func apply(_ settings: UpdateSettings) {
        guard Self.allowed else { return }
        let controller = controller ?? SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        let updater = controller.updater
        updater.automaticallyChecksForUpdates = settings.check
        updater.automaticallyDownloadsUpdates = settings.install == .auto
        if self.controller == nil {
            self.controller = controller
            controller.startUpdater()
        }
    }

    /// `update.check` (`:update`, Heed > Check for Updates…): look now, and say so even when there is nothing new.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
