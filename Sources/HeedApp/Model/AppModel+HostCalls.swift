import Foundation
import HeedCore

/// `heed goal` and `heed swarm` from a host: the agents heed runs there (a session, a swarm's lead and workers) have
/// no control socket to reach, so their `heed` (`HostSetup.heedScript`) writes the call to the host's event log, and
/// heed answers it here, as it answers the `heed goal` on this Mac, then writes the answer back to the host over its
/// shared ssh connection.
extension AppModel {
    func answerHostCall(_ call: HostCall, host: String) {
        guard !isFixture else { return }
        Task { [weak self] in
            guard let self else { return }
            let text = await call.answer(
                call: { [weak self] request in await self?.controlGoal(request) },
                sleep: { try? await Task.sleep(for: .seconds($0)) }, clock: { Date() }
            )
            await HostCall.send(text, for: call, to: host)
        }
    }
}
