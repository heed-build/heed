import Foundation

/// Audit's writes to `heed.sqlite`, one after another in the order they were made. A write that fails is kept and
/// written in front of the next one, so nothing is dropped and the order holds; `status` hears how many rows are
/// waiting, and why, each time that changes.
public final class AuditWriter: Sendable {
    /// Rows recorded but not yet in the log.
    public struct Status: Hashable, Sendable {
        public var unsaved: Int
        /// Why the last write failed; nil once the rows are written.
        public var problem: String?

        public init(unsaved: Int, problem: String?) {
            self.unsaved = unsaved
            self.problem = problem
        }

        public static let saved = Status(unsaved: 0, problem: nil)
    }

    private enum Job: Sendable {
        case records([AuditRecord])
        case flush(CheckedContinuation<Void, Never>)
    }

    private let jobs: AsyncStream<Job>.Continuation

    public init(
        write: @escaping @Sendable ([AuditRecord]) async throws -> Void,
        status: @escaping @Sendable (Status) async -> Void
    ) {
        let (stream, jobs) = AsyncStream.makeStream(of: Job.self)
        self.jobs = jobs
        Task {
            var waiting: [AuditRecord] = []
            for await job in stream {
                switch job {
                case let .records(records):
                    let batch = waiting + records
                    do {
                        try await write(batch)
                        if !waiting.isEmpty {
                            waiting = []
                            await status(.saved)
                        }
                    } catch {
                        waiting = batch
                        await status(Status(unsaved: batch.count, problem: "\(error)"))
                    }
                case let .flush(done):
                    done.resume()
                }
            }
        }
    }

    public convenience init(log: EventLog, status: @escaping @Sendable (Status) async -> Void) {
        self.init(write: { try await log.appendAudit($0) }, status: status)
    }

    deinit { jobs.finish() }

    /// Queues `records` after everything queued before.
    public func append(_ records: [AuditRecord]) {
        guard !records.isEmpty else { return }
        jobs.yield(.records(records))
    }

    /// Returns once everything queued before has been tried.
    public func flush() async {
        await withCheckedContinuation { done in jobs.yield(.flush(done)) }
    }
}
