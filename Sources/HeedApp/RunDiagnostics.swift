import AppKit
import HeedCore
import MetricKit

/// Leaves a trail for the runs that end without a crash report: `heed.log` (lifecycle, sleep and wake, memory
/// pressure, signals, a heartbeat every minute with the memory the OS charges and what the domain store wrote), a
/// `run.json` the next launch reads to tell a clean quit from a lost run, and the diagnostics macOS hands over through
/// MetricKit (crashes, hangs, disk-write and CPU exceptions), kept under `diagnostics/`.
@MainActor
final class RunDiagnostics: NSObject {
    static let shared = RunDiagnostics()

    static let heartbeat: Duration = .seconds(60)
    /// A footprint past this is logged as a warning on every heartbeat.
    static let heavyMB = 2048

    private let directory = RunLog.defaultDirectory()
    private var journal: RunJournal?
    private var beat: Task<Void, Never>?
    private var signalSources: [DispatchSourceSignal] = []
    private var pressure: DispatchSourceMemoryPressure?
    private var observers: [NSObjectProtocol] = []
    private let launched = Date()
    private var stats: (@Sendable () async -> DomainStore.Stats?)?

    /// Opens the log, says what became of the last run, and starts the heartbeat. `stats` reads the domain store's
    /// counters (nil before it exists).
    func start(stats: @escaping @Sendable () async -> DomainStore.Stats?) {
        guard journal == nil else { return }
        self.stats = stats
        let log = RunLog.open(directory: directory)
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let boot = ProcessStats.bootTime()
        if let previous = RunJournal.read(in: directory), let lost = previous.lostRun(
            rebootedSince: boot,
            now: launched
        ) {
            log.write(.warn, lost)
        }
        log.write(
            .info,
            "launch \(version), macOS \(ProcessInfo.processInfo.operatingSystemVersionString), "
                + "up since \(RunLog.format(boot)), \(ProcessStats.footprintMB()) MB"
        )
        let journal = RunJournal(
            pid: ProcessInfo.processInfo.processIdentifier, version: version, started: launched, lastBeat: launched,
            boot: boot, footprintMB: ProcessStats.footprintMB()
        )
        journal.write(in: directory)
        self.journal = journal
        watchSystem()
        watchSignals()
        watchMemoryPressure()
        MXMetricManager.shared.add(self)
        beat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeat)
                await self?.heartbeat()
            }
        }
    }

    /// The quit is Heed's own: the next launch will not call this run lost.
    func quit(_ reason: String) {
        guard var journal else { return }
        beat?.cancel()
        journal.clean = true
        journal.reason = reason
        journal.lastBeat = Date()
        journal.write(in: directory)
        self.journal = journal
        RunLog.info("quit (\(reason)) after \(Int(Date().timeIntervalSince(launched) / 60)) min")
        RunLog.shared?.drain()
    }

    private func heartbeat() async {
        let footprint = ProcessStats.footprintMB()
        let written = await stats?()
        var line = "alive \(footprint) MB, \(ProcessStats.threadCount()) threads, \(ProcessStats.openFileCount()) fds"
        if let written { line += "; store: \(written.summary)" }
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal != .nominal { line += "; thermal \(thermal.rawValue)" }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { line += "; low power" }
        if footprint >= Self.heavyMB { RunLog.warn(line) } else { RunLog.info(line) }
        journal?.lastBeat = Date()
        journal?.footprintMB = footprint
        journal?.write(in: directory)
    }

    private func watchSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, String)] = [
            (NSWorkspace.willSleepNotification, "system will sleep"),
            (NSWorkspace.didWakeNotification, "system woke"),
            (NSWorkspace.screensDidSleepNotification, "screens asleep"),
            (NSWorkspace.screensDidWakeNotification, "screens awake"),
            (NSWorkspace.sessionDidResignActiveNotification, "user session inactive (fast user switch or lock)"),
            (NSWorkspace.sessionDidBecomeActiveNotification, "user session active"),
            (NSWorkspace.willPowerOffNotification, "system is powering off or logging out"),
        ]
        for (name, text) in events {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                RunLog.info(text)
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { _ in
            RunLog.info("thermal state \(ProcessInfo.processInfo.thermalState.rawValue)")
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            // A quit that did not come through applicationShouldTerminate (it already marked the run) still is one.
            Task { @MainActor in
                if RunDiagnostics.shared.journal?.clean == false { RunDiagnostics.shared.quit("terminate") }
            }
        })
    }

    /// A signal that would end the process is logged first, then let through: the default action is put back and the
    /// signal raised again, so Heed ends exactly as it would have. (SIGKILL cannot be seen; its absence is the clue.)
    private func watchSignals() {
        for signalNumber in [SIGTERM, SIGHUP, SIGINT, SIGQUIT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                self?.quit("signal \(signalNumber)")
                RunLog.warn("received signal \(signalNumber); exiting")
                RunLog.shared?.drain()
                signal(signalNumber, SIG_DFL)
                raise(signalNumber)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak source] in
            let level = source?.data.contains(.critical) == true ? "critical" : "warning"
            RunLog.warn("memory pressure \(level), \(ProcessStats.footprintMB()) MB")
        }
        source.resume()
        pressure = source
    }
}

extension RunDiagnostics: MXMetricManagerSubscriber {
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let directory = RunLog.defaultDirectory().appendingPathComponent("diagnostics", isDirectory: true)
        for payload in payloads {
            let crashes = payload.crashDiagnostics?.count ?? 0
            let hangs = payload.hangDiagnostics?.count ?? 0
            let cpu = payload.cpuExceptionDiagnostics?.count ?? 0
            let disk = payload.diskWriteExceptionDiagnostics?.count ?? 0
            let name = "diagnostics-\(Int(payload.timeStampEnd.timeIntervalSince1970)).json"
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? payload.jsonRepresentation().write(to: directory.appendingPathComponent(name))
            RunLog
                .warn(
                    "macOS diagnostics: \(crashes) crashes, \(hangs) hangs, \(cpu) cpu, \(disk) disk writes; kept as diagnostics/\(name)"
                )
        }
    }
}
