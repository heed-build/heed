import Foundation
import Synchronization

/// Where an agent's export went before heed sat in between: your collector, for one signal, in the protocol your
/// setup asked for. heed forwards what the agent sends there unchanged.
public struct TelemetryUpstream: Hashable, Sendable {
    public enum Wire: String, Hashable, Sendable {
        case json = "http/json"
        case protobuf = "http/protobuf"
        case grpc
    }

    public var url: URL
    public var wire: Wire

    public init(url: URL, wire: Wire) {
        self.url = url
        self.wire = wire
    }

    /// What Settings and the banner show: the host, never a path's secrets or a header.
    public var host: String { url.host ?? url.absoluteString }
}

/// One export to pass on, as it arrived: its bytes, its content type and encoding, and the headers the agent sent
/// (yours, from your setup). Held in memory only, until it is delivered or dropped.
public struct ForwardedRequest: Sendable {
    public var url: URL
    public var body: Data
    public var headers: [String: String]

    public init(url: URL, body: Data, headers: [String: String]) {
        self.url = url
        self.body = body
        self.headers = headers
    }

    /// Headers that belong to one connection, not to the request: never passed on.
    static let hopByHop: Set<String> = [
        "host", "content-length", "connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade",
        "proxy-connection", "proxy-authorization", "expect",
    ]

    /// The request as an agent sent it to heed, for `upstream`.
    public static func from(_ request: HTTPRequest, to upstream: URL) -> ForwardedRequest {
        ForwardedRequest(
            url: upstream, body: request.body, headers: request.headers.filter { !hopByHop.contains($0.key) }
        )
    }
}

/// Passes exports on to your own collector, off the main actor: in order, one at a time, retried with backoff while
/// it is down (a network error, 408, 429, 5xx), and kept in a bounded buffer meanwhile. When the buffer is full the
/// oldest export goes, and is counted. One a collector refuses for good (another 4xx) is counted too. Nothing here is
/// written to disk or the call log: the headers carry your credentials.
public final class TelemetryForwarder: Sendable {
    /// What Settings shows per host.
    public struct Stats: Equatable, Sendable {
        public var forwarded = 0
        public var dropped = 0
        public var refused = 0
        public var pending = 0
        /// The last failure, as a status or an error's kind; never a header or a body.
        public var lastError: String?

        public init() {}
    }

    public typealias Send = @Sendable (URLRequest) async throws -> Int

    private struct State {
        var queue: [ForwardedRequest] = []
        var bytes = 0
        var running = false
        var stats: [String: Stats] = [:]
    }

    private let state = Mutex(State())
    private let capacity: Int
    private let maxBytes: Int
    private let send: Send
    private let backoff: @Sendable (Int) -> Duration

    public init(
        capacity: Int = 512, maxBytes: Int = 32 * 1024 * 1024, send: Send? = nil,
        backoff: (@Sendable (Int) -> Duration)? = nil
    ) {
        self.capacity = capacity
        self.maxBytes = maxBytes
        self.send = send ?? Self.urlSession
        self.backoff = backoff ?? { attempt in .seconds(min(60, 1 << min(max(attempt - 1, 0), 6))) }
    }

    /// A session of its own: no cookies, no cache, nothing kept.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private static let urlSession: Send = { request in
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    public func stats() -> [String: Stats] { state.withLock { $0.stats } }

    /// Queues `request`; the oldest go when the buffer is full. Never waits.
    public func enqueue(_ request: ForwardedRequest) {
        let host = request.url.host ?? ""
        let start = state.withLock { state in
            state.queue.append(request)
            state.bytes += request.body.count
            state.stats[host, default: Stats()].pending += 1
            while state.queue.count > capacity || state.bytes > maxBytes, state.queue.count > 1 {
                let dropped = state.queue.removeFirst()
                state.bytes -= dropped.body.count
                let key = dropped.url.host ?? ""
                state.stats[key, default: Stats()].dropped += 1
                state.stats[key, default: Stats()].pending -= 1
            }
            defer { state.running = true }
            return !state.running
        }
        guard start else { return }
        Task.detached(priority: .utility) { [self] in await drain() }
    }

    /// Waits until everything queued now was delivered, refused or dropped (tests).
    public func flushed() async {
        while state.withLock({ !$0.queue.isEmpty || $0.running }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func drain() async {
        var attempt = 0
        while let request = state.withLock({ $0.queue.first }) {
            var urlRequest = URLRequest(url: request.url)
            urlRequest.httpMethod = "POST"
            urlRequest.httpBody = request.body
            for (name, value) in request.headers {
                urlRequest.setValue(value, forHTTPHeaderField: name)
            }
            let outcome: (done: Bool, refused: Bool, error: String?)
            do {
                let status = try await send(urlRequest)
                switch status {
                case 200 ..< 300: outcome = (true, false, nil)
                case 408, 429, 500 ..< 600, 0: outcome = (false, false, "HTTP \(status)")
                default: outcome = (true, true, "HTTP \(status)")
                }
            } catch {
                outcome = (false, false, (error as? URLError).map { "\($0.code)" } ?? "unreachable")
            }
            let host = request.url.host ?? ""
            if outcome.done {
                attempt = 0
                state.withLock { state in
                    // Only if it is still the first: it may have been dropped while it was sent.
                    if let first = state.queue.first, first.url == request.url, first.body == request.body {
                        state.queue.removeFirst()
                        state.bytes -= request.body.count
                        state.stats[host, default: Stats()].pending -= 1
                    }
                    if outcome.refused {
                        state.stats[host, default: Stats()].refused += 1
                        state.stats[host, default: Stats()].lastError = outcome.error
                    } else {
                        state.stats[host, default: Stats()].forwarded += 1
                    }
                }
            } else {
                state.withLock { $0.stats[host, default: Stats()].lastError = outcome.error }
                attempt += 1
                try? await Task.sleep(for: backoff(attempt))
            }
        }
        // Stops only with the queue empty, in the same lock an enqueue checks `running` under.
        let again = state.withLock { state in
            if state.queue.isEmpty { state.running = false }
            return state.running
        }
        if again { await drain() }
    }
}
