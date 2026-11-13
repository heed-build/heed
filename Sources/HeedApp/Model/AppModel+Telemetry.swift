import Foundation
import HeedCore

/// The agents' own OpenTelemetry: `telemetry.sqlite` beside the domain file, heed's OTLP/HTTP receiver on 127.0.0.1
/// (`[telemetry]`), what heed adds to the agents it starts so they send there, and the commands of Insights ›
/// OpenTelemetry and a session's trace. The receiver reads on its own queue; exports are written and summed off the
/// main actor, and only the board and the sessions' reported cost come back to it.
extension AppModel {
    func startTelemetry(beside file: URL) async {
        guard !isFixture else { return }
        let path = file.deletingLastPathComponent().appendingPathComponent("telemetry.sqlite").path
        let store = await Task.detached(priority: .utility) { () -> TelemetryStore? in
            do { return try TelemetryStore(path: path) } catch {
                NSLog("heed: could not open \(path) (\(error)); no telemetry is kept")
                return nil
            }
        }.value
        telemetry.store = store
        telemetryReady = true
        applyTelemetrySettings()
        guard let store else { return }
        Task.detached(priority: .background) { [weak self] in
            var wait = Duration.seconds(90)
            while !Task.isCancelled {
                try? await Task.sleep(for: wait)
                wait = .seconds(3600)
                guard let settings = await self?.config.telemetry else { return }
                await store.prune(now: Date(), settings: settings)
            }
        }
    }

    /// What heed knows of its sessions, for the telemetry to be read against.
    var telemetryContext: TelemetryContext {
        .from(sessions: sessions + history.map(\.session))
    }

    /// Starts, stops or moves the receiver to what `[telemetry]` says now, and decides again whom heed points at
    /// it and what it forwards. Runs on every config change; the receiver restarts only when it is turned on or off
    /// or moves port, so panes already started keep their forwards (turning `proxy` off changes the next launches).
    func applyTelemetrySettings() {
        guard telemetryReady, !isFixture else { return }
        let settings = config.telemetry
        guard settings != telemetrySettingsRunning else { return }
        let before = telemetrySettingsRunning
        telemetrySettingsRunning = settings
        let restart = before == nil || before?.enabled != settings.enabled || before?.port != settings.port
        if restart {
            telemetryServer?.stop()
            telemetryServer = nil
            integration.telemetry = nil
            telemetry.setExport(nil)
            telemetry.setForwarding([:])
            guard settings.enabled else {
                telemetry.setReceiver(.off)
                return
            }
            guard telemetry.store != nil else {
                telemetry.setReceiver(.failed("telemetry.sqlite could not be opened"))
                return
            }
            let server = TelemetryServer(port: settings.port)
            do {
                try server.start()
            } catch {
                // Panes start exactly as they would without heed: nothing points at a receiver that is not there.
                telemetry.setReceiver(.failed("\(error)"))
                return
            }
            telemetryServer = server
            telemetry.setReceiver(.listening(port: settings.port))
            Task { [weak self] in
                for await records in server.records {
                    await self?.receivedTelemetry(records)
                }
            }
            // What the forwarder did, for Settings and the banner: counts only, every few seconds.
            Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, telemetryServer === server else { return }
                    telemetry.setForwarding(server.forwarder.stats())
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
        guard let server = telemetryServer else { return }
        Task { [weak self] in
            let export = await Self.decideExport(settings)
            guard let self, telemetrySettingsRunning == settings, telemetryServer === server else { return }
            integration.telemetry = export
            telemetry.setExport(export)
            // Forwards only ever add while the receiver runs: a pane started with one keeps it.
            server.addRoutes(export.routes)
        }
    }

    /// `telemetry.proxy.off`, from the banner: `[telemetry] proxy = false`.
    func stopTelemetryProxy() {
        setConfig(["telemetry", "proxy"], .bool(false))
        flash = "heed stops forwarding: each agent exports only to its own endpoint again from its pane's next launch."
    }

    /// Reads, off the main actor, what you set up yourself: heed's environment, your login shell's OTEL variables,
    /// Claude Code's settings and Codex's config.
    nonisolated static func decideExport(_ settings: TelemetrySettings) async -> TelemetryExport {
        let process = ProcessInfo.processInfo.environment
        var shell: [String: String] = [:]
        if let path = PaneShell.loginShellPath() {
            let arguments = PaneShell(name: path) == .fish ? ["-l", "-c", TelemetryExport.shellProbe]
                : ["-l", "-i", "-c", TelemetryExport.shellProbe]
            if let result = try? await ProcessRunner.run(
                path, arguments, timeout: .seconds(8), caller: "telemetry.shell"
            ) {
                shell = TelemetryExport.environment(fromProbe: result.stdout)
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claude = try? String(
            contentsOf: home.appendingPathComponent(".claude/settings.json"), encoding: .utf8
        )
        let codexHome = process["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        let codex = try? String(contentsOf: codexHome.appendingPathComponent("config.toml"), encoding: .utf8)
        return TelemetryExport.decide(
            settings: settings, process: process, shell: shell, claudeSettings: claude, codexConfig: codex
        )
    }

    /// An export arrived: kept, the reported cost of the sessions it was about brought up to date, the views redrawn.
    func receivedTelemetry(_ records: TelemetryRecords) async {
        guard let store = telemetry.store else { return }
        await store.insert(records)
        telemetry.received(records, showing: view == .telemetry || view == .trace)
        guard records.spans.contains(where: { $0.cost != nil }) || records.usage.contains(where: { $0.cost != nil })
        else { return }
        let context = telemetryContext
        let touched = Set(records.spans.compactMap { context.session(of: $0) }
            + records.usage.compactMap { sample in
                sample.heedSession ?? sample.agentSession.flatMap { context.byAgentSession[$0] }
            })
        guard !touched.isEmpty else { return }
        let since = sessions.filter { touched.contains($0.id) }.map(\.createdAt).min()
            ?? Date().addingTimeInterval(-86400)
        let costs = await Task.detached(priority: .utility) { () -> [String: Double] in
            guard let all = try? await store.records(since: since, limit: 200_000) else { return [:] }
            return TelemetryResolve.costs(all, context: context)
        }.value
        applyTelemetryCosts(costs.filter { touched.contains($0.key) })
    }

    /// The cost the agents' telemetry reports wins over the hooks' and any estimate (`UsageSettings.cost`); it only
    /// grows, so a pruned store never lowers what was shown.
    func applyTelemetryCosts(_ costs: [String: Double]) {
        for (id, cost) in costs {
            guard var session = sessions.first(where: { $0.id == id }) else { continue }
            var usage = session.usage ?? AgentUsage()
            guard cost > (usage.telemetryCostUSD ?? 0) + 0.000_001 else { continue }
            usage.telemetryCostUSD = cost
            session.usage = usage
            commit(.sessionUpserted(session))
        }
    }

    // MARK: Commands

    func performTelemetry(_ command: CommandInvocation) {
        let argument = command.arguments.first
        switch command.name {
        case "telemetry.range": telemetry.cycleRange(argument)
        case "telemetry.agent": telemetry.cycleAgent(argument)
        case "telemetry.repo": telemetry.cycleRepo(argument)
        case "telemetry.model": telemetry.cycleModel(argument)
        case "telemetry.kind": telemetry.cycleKinds(argument)
        case "telemetry.live": telemetry.toggleLive()
        case "telemetry.proxy.off": stopTelemetryProxy()
        case "telemetry.banner.hide": telemetry.hideBanner()
        case "telemetry.open":
            guard let row = telemetry.selected, let session = row.session else {
                flash = "That span is from no session heed knows."
                return
            }
            openTrace(session: session, turn: row.span.traceID)
        default: break
        }
    }

    /// `session.trace`: the session under the cursor's (or the named one's) trace.
    func performTrace(_ command: CommandInvocation) {
        switch command.name {
        case "trace.turn.next": telemetry.moveTurn(1)
        case "trace.turn.prev": telemetry.moveTurn(-1)
        case "trace.span.next": telemetry.moveSegment(1)
        case "trace.span.prev": telemetry.moveSegment(-1)
        case "session.trace":
            if view == .trace {
                view = AppView(rawValue: telemetry.traceReturn ?? "") ?? .sessions
                return
            }
            // A right-click's session is selected by now; `:trace <name>` names one by id or title.
            let named = command.arguments.isEmpty ? nil : command.arguments.joined(separator: " ")
            let id = named.flatMap { name in
                sessions.first { $0.id == name || $0.title.localizedCaseInsensitiveContains(name) }?.id
            } ?? currentSession?.id
            guard let id else {
                flash = "No session to trace."
                return
            }
            openTrace(session: id)
        default: break
        }
    }

    func openTrace(session: String, turn: String? = nil) {
        if view != .trace { telemetry.traceReturn = view.rawValue }
        telemetry.openTrace(session: session, turn: turn)
        view = .trace
    }
}
