import Foundation

/// Token counts, normalized across agents: `input` is what was sent and not read from the prompt cache, so everything
/// sent is `input + cacheRead + cacheWrite`.
public struct TokenCounts: Codable, Hashable, Sendable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    /// Every input token, cached or not.
    public var allInput: Int { input + cacheRead + cacheWrite }
    public var isEmpty: Bool { allInput == 0 && output == 0 }

    public static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs = lhs + rhs
    }

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: lhs.input + rhs.input, output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite
        )
    }
}

/// One model request's tokens, by the agent's own id for it, so a request read twice counts once.
public struct RequestUsage: Codable, Equatable, Sendable {
    public var id: String
    public var tokens: TokenCounts
    /// What the agent says it cost, when it says (opencode).
    public var costUSD: Double?

    public init(id: String, tokens: TokenCounts, costUSD: Double? = nil) {
        self.id = id
        self.tokens = tokens
        self.costUSD = costUSD
    }
}

/// What a hook learned about the agent's model and spend. Every part is optional: each agent reports what it has.
public struct UsageReport: Codable, Equatable, Sendable {
    public var model: String?
    /// The session's totals so far (codex): they replace what was known.
    public var totals: TokenCounts?
    /// With `totals`: the session's cost so far, when the agent reports one.
    public var costUSD: Double?
    /// Requests in the order they were made (claude, opencode): those after the last one counted are added.
    public var requests: [RequestUsage]?
    /// The size of the last request's context, and the model's window when the agent says.
    public var contextTokens: Int?
    public var contextWindow: Int?
    /// When the rate limit the agent ran into (or is closest to) lifts.
    public var rateLimitResetsAt: Date?

    public init(
        model: String? = nil, totals: TokenCounts? = nil, costUSD: Double? = nil, requests: [RequestUsage]? = nil,
        contextTokens: Int? = nil, contextWindow: Int? = nil, rateLimitResetsAt: Date? = nil
    ) {
        self.model = model
        self.totals = totals
        self.costUSD = costUSD
        self.requests = requests
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.rateLimitResetsAt = rateLimitResetsAt
    }

    public var isEmpty: Bool { self == UsageReport() }
}

/// What a session's (or a run's) agent used: its latest model, tokens so far, and what is known about its context and
/// rate limit. Kept with the session in the domain cache.
public struct AgentUsage: Codable, Hashable, Sendable {
    public var model: String?
    public var tokens: TokenCounts
    /// What the agent reported it cost, summed; nil when it reports none (heed may then estimate one, `UsagePrices`).
    public var costUSD: Double?
    public var contextTokens: Int?
    public var contextWindow: Int?
    public var rateLimitResetsAt: Date?
    /// The last request counted, so one read again (the next hook reads the same transcript) is not counted twice.
    public var lastRequestID: String?

    public init(
        model: String? = nil, tokens: TokenCounts = TokenCounts(), costUSD: Double? = nil, contextTokens: Int? = nil,
        contextWindow: Int? = nil, rateLimitResetsAt: Date? = nil, lastRequestID: String? = nil
    ) {
        self.model = model
        self.tokens = tokens
        self.costUSD = costUSD
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.rateLimitResetsAt = rateLimitResetsAt
        self.lastRequestID = lastRequestID
    }

    private enum CodingKeys: String, CodingKey {
        case model, tokens, costUSD, contextTokens, contextWindow, rateLimitResetsAt, lastRequestID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        tokens = try container.decodeIfPresent(TokenCounts.self, forKey: .tokens) ?? TokenCounts()
        costUSD = try container.decodeIfPresent(Double.self, forKey: .costUSD)
        contextTokens = try container.decodeIfPresent(Int.self, forKey: .contextTokens)
        contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow)
        rateLimitResetsAt = try container.decodeIfPresent(Date.self, forKey: .rateLimitResetsAt)
        lastRequestID = try container.decodeIfPresent(String.self, forKey: .lastRequestID)
    }

    /// This usage with a report laid over it.
    public func applying(_ report: UsageReport) -> AgentUsage {
        var next = self
        if let model = report.model, !model.isEmpty { next.model = model }
        if let totals = report.totals {
            next.tokens = totals
            next.costUSD = report.costUSD
        }
        if let requests = report.requests, let last = requests.last {
            let seen = lastRequestID.flatMap { id in requests.lastIndex { $0.id == id } }
            let new = requests[(seen.map { $0 + 1 } ?? 0)...]
            for request in new {
                next.tokens += request.tokens
                if let cost = request.costUSD { next.costUSD = (next.costUSD ?? 0) + cost }
            }
            next.lastRequestID = last.id
        }
        if let tokens = report.contextTokens { next.contextTokens = tokens }
        if let window = report.contextWindow { next.contextWindow = window }
        if let resets = report.rateLimitResetsAt { next.rateLimitResetsAt = resets }
        return next
    }

    /// How full the context is, 0–100, when both its size and the window are known.
    public var contextPercent: Double? {
        guard let contextTokens, let contextWindow, contextWindow > 0 else { return nil }
        return min(100, Double(contextTokens) / Double(contextWindow) * 100)
    }

    /// `model-a · 12.3k in / 4.1k out · ≈$0.42 · ctx 38%`: only the parts known. `cost` is the reported or estimated
    /// cost (`UsagePrices.cost`), nil to leave it out.
    public func summary(cost: Double?, includeModel: Bool = true) -> String {
        var parts: [String] = []
        if includeModel, let model { parts.append(model) }
        if !tokens.isEmpty {
            parts.append("\(Self.count(tokens.allInput)) in / \(Self.count(tokens.output)) out")
        }
        if let cost { parts.append("≈" + Self.dollars(cost)) }
        if let percent = contextPercent {
            parts.append("ctx \(Int(percent.rounded()))%")
        } else if let contextTokens {
            parts.append("ctx \(Self.count(contextTokens))")
        }
        return parts.joined(separator: " · ")
    }

    /// `resets at 18:20`, when the reset is still ahead.
    public func resetText(now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        guard let resets = rateLimitResetsAt, resets > now else { return nil }
        return "resets at \(Self.clock(resets, timeZone: timeZone))"
    }

    /// `950`, `12.3k`, `4.2M`.
    public static func count(_ value: Int) -> String {
        let text = switch value {
        case ..<1000: "\(value)"
        case ..<1_000_000: String(format: value < 100_000 ? "%.1fk" : "%.0fk", Double(value) / 1000)
        default: String(format: "%.1fM", Double(value) / 1_000_000)
        }
        return text.replacingOccurrences(of: ".0", with: "")
    }

    /// `$0.42`, `$12`, `<$0.01`.
    public static func dollars(_ value: Double) -> String {
        if value > 0, value < 0.01 { return "<$0.01" }
        return value >= 10 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }

    /// `18:20`.
    public static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

/// `[usage]`: whether a cost shows, and the prices heed estimates one from when the agent reports none.
public struct UsageSettings: Equatable, Sendable {
    public var showCost = true
    public var prices = UsagePrices()

    public init(showCost: Bool = true, prices: UsagePrices = UsagePrices()) {
        self.showCost = showCost
        self.prices = prices
    }

    /// The cost to show for `usage`: what the agent reported, else an estimate from the prices; nil when neither, or
    /// costs are off.
    public func cost(of usage: AgentUsage) -> Double? {
        guard showCost else { return nil }
        return usage.costUSD ?? prices.estimate(usage)
    }
}

/// USD per million tokens, by model name prefix (`[usage.prices]`). None are built in: prices change more often than
/// heed does, so a cost is estimated only from prices you set.
public struct UsagePrices: Equatable, Sendable {
    public struct Price: Equatable, Sendable {
        public var input: Double
        public var output: Double
        public var cacheRead: Double
        public var cacheWrite: Double

        /// Cache reads and writes default to a tenth and a quarter more than input, the usual discount and premium.
        public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead ?? input * 0.1
            self.cacheWrite = cacheWrite ?? input * 1.25
        }

        /// `"3 / 15"` (input / output), or `"3 / 15 / 0.3 / 3.75"` (with cache read / cache write).
        public init?(parsing text: String) {
            let numbers = text.split(separator: "/").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard [2, 4].contains(numbers.count), numbers.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
            let values = numbers.compactMap(\.self)
            self.init(
                input: values[0], output: values[1],
                cacheRead: values.count == 4 ? values[2] : nil, cacheWrite: values.count == 4 ? values[3] : nil
            )
        }
    }

    public var byPrefix: [String: Price]

    public init(_ byPrefix: [String: Price] = [:]) {
        self.byPrefix = byPrefix
    }

    /// The price of `model`: the longest prefix that matches it (or its name after a `provider/`), ignoring case.
    public func price(for model: String) -> Price? {
        let names = [model.lowercased(), model.split(separator: "/").last.map { $0.lowercased() } ?? ""]
        return byPrefix
            .filter { prefix, _ in names.contains { $0.hasPrefix(prefix.lowercased()) } }
            .max { $0.key.count < $1.key.count }?.value
    }

    /// An estimate at the session's latest model's price: every token as if that model handled it.
    public func estimate(_ usage: AgentUsage) -> Double? {
        guard let model = usage.model, let price = price(for: model), !usage.tokens.isEmpty else { return nil }
        let tokens = usage.tokens
        let micros = Double(tokens.input) * price.input + Double(tokens.output) * price.output
            + Double(tokens.cacheRead) * price.cacheRead + Double(tokens.cacheWrite) * price.cacheWrite
        return micros / 1_000_000
    }
}

/// Reads what the agents write about their requests: Claude Code's transcript and Codex's rollout, both JSON lines.
/// Only the tail is read, and every line is parsed defensively: a hook must stay fast and never fail.
public enum UsageTranscripts {
    /// The last `maxBytes` of a file, from its first whole line.
    public static func tail(path: String, maxBytes: Int = 256 * 1024) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, var data = try? handle.readToEnd() else { return nil }
        if start > 0, let newline = data.firstIndex(of: 0x0A) { data = data[(newline + 1)...] }
        return Data(data)
    }

    /// Lines as JSON objects, skipping what does not parse. `containing` cheaply skips lines that cannot matter.
    static func objects(_ data: Data, containing marker: String) -> [[String: Any]] {
        let needle = Data(marker.utf8)
        return data.split(separator: 0x0A).compactMap { line in
            guard line.range(of: needle) != nil else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
        }
    }

    static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }

    // MARK: Claude Code

    /// From a Claude Code transcript: its requests (an assistant reply is written as several lines sharing a
    /// `requestId`; the last one wins), the latest model, the last context's size, and when a rate limit it hit
    /// resets.
    public static func claude(_ data: Data, now: Date = Date()) -> UsageReport? {
        var order: [String] = []
        var byID: [String: TokenCounts] = [:]
        var model: String?
        var context: Int?
        var resets: Date?
        for line in objects(data, containing: "\"assistant\"") {
            guard line["type"] as? String == "assistant", let message = line["message"] as? [String: Any] else {
                continue
            }
            if line["isApiErrorMessage"] as? Bool == true {
                if line["error"] as? String == "rate_limit" {
                    let text = ((message["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }
                        .joined(separator: " ")
                    let at = (line["timestamp"] as? String).flatMap(parseTimestamp) ?? now
                    resets = claudeReset(in: text, after: at) ?? resets
                }
                continue
            }
            if let name = message["model"] as? String, !name.isEmpty, !name.hasPrefix("<") { model = name }
            guard let id = line["requestId"] as? String, let usage = message["usage"] as? [String: Any] else {
                continue
            }
            let tokens = TokenCounts(
                input: int(usage["input_tokens"]), output: int(usage["output_tokens"]),
                cacheRead: int(usage["cache_read_input_tokens"]), cacheWrite: int(usage["cache_creation_input_tokens"])
            )
            if byID.updateValue(tokens, forKey: id) == nil { order.append(id) }
            context = tokens.allInput
        }
        let requests = order.suffix(200).map { RequestUsage(id: $0, tokens: byID[$0]!) }
        let report = UsageReport(
            model: model, requests: requests.isEmpty ? nil : requests, contextTokens: context,
            rateLimitResetsAt: resets
        )
        return report.isEmpty ? nil : report
    }

    /// `You've hit your session limit · resets 6:20pm (Europe/Amsterdam)`: the next such time after `date`, in the
    /// zone named (else this Mac's). A date before the time (`resets Oct 20, 3pm`) is honoured.
    static func claudeReset(in text: String, after date: Date) -> Date? {
        let pattern = #"resets\s+(?:([A-Za-z]{3})[a-z]*\s+(\d{1,2}),?\s+(?:at\s+)?)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)(?:\s*\(([^)]+)\))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        guard var hour = group(3).flatMap({ Int($0) }), (1 ... 12).contains(hour) else { return nil }
        let minute = group(4).flatMap { Int($0) } ?? 0
        if hour == 12 { hour = 0 }
        if group(5)?.lowercased() == "pm" { hour += 12 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = group(6).flatMap { TimeZone(identifier: $0) } ?? .current
        var parts = calendar.dateComponents([.year, .month, .day], from: date)
        parts.hour = hour
        parts.minute = minute
        if let monthName = group(1), let day = group(2).flatMap({ Int($0) }) {
            let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            guard let month = months.firstIndex(of: monthName.lowercased()) else { return nil }
            parts.month = month + 1
            parts.day = day
            guard let candidate = calendar.date(from: parts) else { return nil }
            return candidate > date ? candidate : calendar.date(byAdding: .year, value: 1, to: candidate)
        }
        guard let candidate = calendar.date(from: parts) else { return nil }
        return candidate > date ? candidate : calendar.date(byAdding: .day, value: 1, to: candidate)
    }

    // MARK: Codex

    /// From a Codex rollout: the session's totals and last context (its latest `token_count` event), the model of
    /// its latest turn, and the rate limit window closest to its limit.
    public static func codex(_ data: Data, now: Date = Date()) -> UsageReport? {
        var report = UsageReport()
        for line in objects(data, containing: "\"token_count\"") + objects(data, containing: "\"turn_context\"") {
            guard let payload = line["payload"] as? [String: Any] else { continue }
            let type = payload["type"] as? String ?? line["type"] as? String
            if type == "turn_context" || line["type"] as? String == "turn_context" {
                if let model = payload["model"] as? String, !model.isEmpty { report.model = model }
                continue
            }
            guard type == "token_count" else { continue }
            if let info = payload["info"] as? [String: Any] {
                if let total = info["total_token_usage"] as? [String: Any] {
                    let cached = int(total["cached_input_tokens"])
                    report.totals = TokenCounts(
                        input: max(0, int(total["input_tokens"]) - cached), output: int(total["output_tokens"]),
                        cacheRead: cached
                    )
                }
                if let last = info["last_token_usage"] as? [String: Any] {
                    report.contextTokens = int(last["total_tokens"])
                }
                if let window = info["model_context_window"] as? NSNumber { report.contextWindow = window.intValue }
            }
            if let limits = payload["rate_limits"] as? [String: Any] {
                let at = (line["timestamp"] as? String).flatMap(parseTimestamp) ?? now
                let windows = ["primary", "secondary"].compactMap { limits[$0] as? [String: Any] }
                if let fullest = windows
                    .max(by: { ($0["used_percent"] as? Double ?? 0) < ($1["used_percent"] as? Double ?? 0) })
                {
                    report.rateLimitResetsAt = codexReset(fullest, at: at) ?? report.rateLimitResetsAt
                }
            }
        }
        return report.isEmpty ? nil : report
    }

    /// `resets_at` (epoch seconds, or an ISO date), else `resets_in_seconds` from when the event was written.
    static func codexReset(_ window: [String: Any], at date: Date) -> Date? {
        if let epoch = window["resets_at"] as? NSNumber { return Date(timeIntervalSince1970: epoch.doubleValue) }
        if let text = window["resets_at"] as? String { return parseTimestamp(text) }
        if let seconds = window["resets_in_seconds"] as? NSNumber {
            return date.addingTimeInterval(seconds.doubleValue)
        }
        return nil
    }

    static func parseTimestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
