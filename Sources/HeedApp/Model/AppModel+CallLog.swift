import Foundation
import HeedCore

/// The call log (`log.sqlite`, beside the domain file): opened first on launch, so the tool detection's own commands
/// are in it, and pruned to `[log]` a minute after launch (once config.toml is read), then every hour.
extension AppModel {
    func startCallLog(beside file: URL) async {
        let log = await CallLog.open(at: file.deletingLastPathComponent().appendingPathComponent("log.sqlite"))
        CallLog.install(log)
        guard let log else { return }
        Task.detached(priority: .background) { [weak self] in
            var wait = Duration.seconds(60)
            while !Task.isCancelled {
                try? await Task.sleep(for: wait)
                wait = .seconds(3600)
                guard let retention = await self?.config.log else { return }
                await log.store.prune(now: Date(), retention: retention)
            }
        }
    }
}
