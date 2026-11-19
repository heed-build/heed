import Foundation

/// What Browse does when GitHub does not answer a search: which failures are worth asking again, how much smaller to
/// ask, how long to wait, and what to tell the person when it still fails. Pure, so the ladder is tested without gh.
///
/// A search over a big org asks for heavy nodes (labels, checks, reviewers) and GitHub can time out on a page of a
/// hundred of them, answering HTTP 502 or 504. The same page asked at a smaller size usually works.
public enum BrowseFetchPolicy {
    /// One step of the ladder: how many nodes a page asks for, and whether a pull request's heavy parts (checks,
    /// requested reviewers, closing references) are asked at all.
    public struct Rung: Equatable, Sendable {
        public let size: Int
        public let light: Bool
    }

    /// 100, 50, 25, 10, then 10 again without the heavy parts of a pull request: those cost GitHub the most, and a page
    /// that still times out at ten is worth one try without them (the checks then show as unknown, never as passing).
    public static let rungs: [Rung] = [
        Rung(size: 100, light: false), Rung(size: 50, light: false), Rung(size: 25, light: false),
        Rung(size: 10, light: false), Rung(size: 10, light: true),
    ]

    /// The wait before the retry that follows the failure at rung `index`: 0.5 s, 1 s, 2 s, then 2 s.
    public static func backoff(afterRung index: Int) -> Duration {
        let steps: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2)]
        return steps[min(max(index, 0), steps.count - 1)]
    }

    /// The longest Browse waits out a secondary rate limit, once per search.
    public static let rateLimitCap: Duration = .seconds(30)
    /// The wait when GitHub does not say how long.
    public static let rateLimitDefault: Duration = .seconds(10)

    public enum Kind: Equatable, Sendable {
        /// Asking again, smaller or later, can work. `code` is the HTTP status when the text carries one.
        case transient(code: Int?)
        /// Too many requests too fast: wait, then ask again.
        case rateLimited(wait: Duration?)
        /// Asking again cannot help: not signed in, no access, a query GitHub refuses.
        case permanent
    }

    /// Sorts the text of a failure (gh's message, a timeout's description, a GraphQL error) into a kind.
    public static func classify(_ text: String) -> Kind {
        let lower = text.lowercased()
        if lower.contains("secondary rate limit") || lower.contains("submitted too quickly")
            || lower.contains("abuse detection")
        {
            return .rateLimited(wait: retryAfter(in: lower))
        }
        // These win over a transient marker: asking again cannot fix them.
        let permanent = [
            "gh auth login", "not logged", "not signed in", "http 401", "http 403", "http 404", "saml",
            "could not resolve", "bad credentials", "requires authentication", "resource not accessible",
            "gh is not installed", "could not start", "parse error", "validation failed", "unprocessable",
            "field '", "doesn't exist on type",
        ]
        if permanent.contains(where: lower.contains) { return .permanent }
        let code = httpCode(in: text)
        if let code, [502, 503, 504].contains(code) { return .transient(code: code) }
        let transient = [
            "bad gateway", "did not answer", "service unavailable", "gateway time-out", "gateway timeout", "timeout",
            "timed out",
            "something went wrong while executing your query", "unexpected eof", ": eof", "connection reset",
            "connection refused", "broken pipe", "i/o timeout", "no such host", "tls handshake",
        ]
        return transient.contains(where: lower.contains) ? .transient(code: nil) : .permanent
    }

    /// The HTTP status a failure names (`HTTP 502`, `502 Bad Gateway`), if any.
    public static func httpCode(in text: String) -> Int? {
        for pattern in [
            #"HTTP[ /]\d\.?\d? (\d{3})"#,
            #"HTTP (\d{3})"#,
            #"\b(50[234]) (?:Bad Gateway|Service Unavailable|Gateway)"#,
        ] {
            if let match = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
               let digits = text[match].range(of: #"\d{3}"#, options: .regularExpression),
               let code = Int(text[match][digits])
            {
                return code
            }
        }
        return nil
    }

    /// `retry-after: 12` or `try again in 12 seconds`, as a wait.
    static func retryAfter(in lower: String) -> Duration? {
        for pattern in [#"retry-after:?\s*(\d+)"#, #"(?:retry|try again) (?:after|in) (\d+) ?(?:s|sec)"#] {
            if let match = lower.range(of: pattern, options: .regularExpression),
               let digits = lower[match].range(of: #"\d+"#, options: .regularExpression),
               let seconds = Int(lower[match][digits])
            {
                return .seconds(seconds)
            }
        }
        return nil
    }

    /// What to do after a failure at rung `index`.
    public enum Next: Equatable, Sendable {
        /// Ask the same page again at `rung`, after `wait`.
        case retry(rung: Int, wait: Duration)
        /// Wait, then ask the same page again at the same rung; allowed once.
        case waitThenRetry(Duration)
        case fail(String)
    }

    public static func next(after failure: String, rung index: Int, rateLimitWaited: Bool) -> Next {
        switch classify(failure) {
        case .permanent:
            return .fail(message(for: failure))
        case let .rateLimited(wait):
            let seconds = wait ?? rateLimitDefault
            if rateLimitWaited || seconds > rateLimitCap {
                return .fail("GitHub is limiting how fast Browse can search. Wait a minute, then try again.")
            }
            return .waitThenRetry(seconds)
        case let .transient(code):
            guard index + 1 < rungs.count else { return .fail(timedOut(code: code)) }
            return .retry(rung: index + 1, wait: backoff(afterRung: index))
        }
    }

    /// The message when the ladder is spent.
    public static func timedOut(code: Int?) -> String {
        let status = code.map { " (HTTP \($0))" } ?? ""
        return "GitHub timed out running this search\(status). Narrow it: a repo, a label, or a shorter age, then try again."
    }

    /// A failure as a person reads it: never a JSON or HTML body, never a bare status.
    public static func message(for failure: String) -> String {
        let text = failure.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .transient = classify(text) { return timedOut(code: httpCode(in: text)) }
        if text.hasPrefix("{") || text.hasPrefix("<") || text.isEmpty { return "GitHub refused the request." }
        return text
    }

    /// The text of any error a gh call throws.
    static func text(of error: Error) -> String {
        (error as? GitHub.Failure)?.description ?? "\(error)"
    }

    public typealias Sleeper = @Sendable (Duration) async throws -> Void
    public static let realSleep: Sleeper = { try await Task.sleep(for: $0) }

    /// Runs a call that has no page size (a count, a repo list) and asks it again after a transient failure, waiting
    /// 0.5 s, 1 s, then 2 s, at most three more times. What still fails is thrown as it was.
    static func retrying<T>(sleep: Sleeper = realSleep, _ call: () async throws -> T) async throws -> T {
        var retries = 0
        var waited = false
        while true {
            do { return try await call() } catch is CancellationError { throw CancellationError() } catch {
                let wait: Duration
                switch classify(text(of: error)) {
                case .permanent: throw error
                case let .rateLimited(seconds):
                    let asked = seconds ?? rateLimitDefault
                    if waited || asked > rateLimitCap { throw error }
                    waited = true
                    wait = asked
                case .transient:
                    guard retries < 3 else { throw error }
                    wait = backoff(afterRung: retries)
                    retries += 1
                }
                try await sleep(wait)
            }
        }
    }
}

/// The page size each search text settled on, kept for the rest of the session so a search that needed 25 does not
/// climb back to 100 on the next page or the next refresh. A text carries its scope, its query and its group of orgs,
/// so another scope or query starts over and each group of an all-orgs search has its own size.
public final class BrowseFetchMemory: @unchecked Sendable {
    public static let shared = BrowseFetchMemory()
    private let lock = NSLock()
    private var rungs: [String: Int] = [:]

    public init() {}

    /// The rung to start at for `key` (the search text).
    public func rung(for key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return rungs[key] ?? 0
    }

    public func settle(_ rung: Int, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        // A session that has searched this much has moved on; keep the table small.
        if rungs.count > 200, rungs[key] == nil { rungs.removeAll() }
        rungs[key] = max(rungs[key] ?? 0, rung)
    }
}
