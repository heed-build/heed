import CoreGraphics
import Foundation
import HeedCore
import IOKit.ps

/// What the Mac is doing, for when Hunch may train: time since the last input, power source, heat, Low Power Mode.
/// None of these needs a permission.
enum MacConditions {
    static var now: HunchConditions {
        HunchConditions(
            idleSeconds: idleSeconds, onPower: onPower,
            thermal: ProcessInfo.processInfo.thermalState.rawValue,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    /// Seconds since the last keyboard, mouse or trackpad event in this login session.
    static var idleSeconds: Double {
        // ~0 is kCGAnyInputEventType: any kind of input.
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    /// On AC power (a Mac without a battery always is).
    static var onPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return true }
        return (source as String) == kIOPMACPowerKey
    }

    /// This Mac can run Hunch: MLX needs Apple silicon.
    static var appleSilicon: Bool {
        #if arch(arm64)
            true
        #else
            false
        #endif
    }
}
