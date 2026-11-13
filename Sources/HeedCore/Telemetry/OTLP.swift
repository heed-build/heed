import Foundation

/// The three things OTLP carries, by the path an exporter posts them to (`/v1/traces`, `/v1/logs`, `/v1/metrics`).
public enum OTLPSignal: String, Hashable, Sendable, CaseIterable {
    case traces, logs, metrics

    /// From a request path: the last component that names a signal (`/v1/logs`, `/logs`); nil for anything else.
    public init?(path: String) {
        let parts = path.split(separator: "?").first.map { $0.split(separator: "/").map(String.init) } ?? []
        guard let match = parts.reversed().compactMap(OTLPSignal.init(rawValue:)).first else { return nil }
        self = match
    }
}

/// One span as an exporter sent it, attributes flattened to text.
public struct OTLPSpan: Hashable, Sendable {
    public var traceID: String
    public var spanID: String
    public var parentID: String?
    public var name: String
    public var start: Date
    public var end: Date
    public var failed: Bool
    public var statusMessage: String?
    public var attributes: [String: String]
    public var resource: [String: String]

    public init(
        traceID: String, spanID: String, parentID: String? = nil, name: String, start: Date, end: Date,
        failed: Bool = false, statusMessage: String? = nil, attributes: [String: String] = [:],
        resource: [String: String] = [:]
    ) {
        self.traceID = traceID
        self.spanID = spanID
        self.parentID = parentID
        self.name = name
        self.start = start
        self.end = end
        self.failed = failed
        self.statusMessage = statusMessage
        self.attributes = attributes
        self.resource = resource
    }
}

/// One log record: for the agents, an event (`claude_code.tool_result`, `codex.api_request`), named by its
/// `event.name` attribute or its body.
public struct OTLPLog: Hashable, Sendable {
    public var time: Date
    public var name: String
    public var attributes: [String: String]
    public var resource: [String: String]

    public init(time: Date, name: String, attributes: [String: String] = [:], resource: [String: String] = [:]) {
        self.time = time
        self.name = name
        self.attributes = attributes
        self.resource = resource
    }
}

/// One data point of a sum or gauge (a histogram's sum), with its metric's name.
public struct OTLPPoint: Hashable, Sendable {
    public var name: String
    public var time: Date
    public var value: Double
    /// A cumulative sum's points are running totals, not increments.
    public var cumulative: Bool
    public var attributes: [String: String]
    public var resource: [String: String]

    public init(
        name: String, time: Date, value: Double, cumulative: Bool = false, attributes: [String: String] = [:],
        resource: [String: String] = [:]
    ) {
        self.name = name
        self.time = time
        self.value = value
        self.cumulative = cumulative
        self.attributes = attributes
        self.resource = resource
    }
}

/// What one export request held.
public struct OTLPBatch: Hashable, Sendable {
    public var spans: [OTLPSpan] = []
    public var logs: [OTLPLog] = []
    public var points: [OTLPPoint] = []

    public init(spans: [OTLPSpan] = [], logs: [OTLPLog] = [], points: [OTLPPoint] = []) {
        self.spans = spans
        self.logs = logs
        self.points = points
    }

    public var isEmpty: Bool { spans.isEmpty && logs.isEmpty && points.isEmpty }
    public var count: Int { spans.count + logs.count + points.count }
}

public enum OTLPError: Error, Equatable, CustomStringConvertible {
    case notJSON
    case unknownSignal
    case notProtobuf

    public var description: String {
        switch self {
        case .notJSON: "the body is not OTLP JSON"
        case .unknownSignal: "neither traces, logs nor metrics"
        case .notProtobuf: "the body is not OTLP protobuf"
        }
    }
}

/// OTLP/JSON (the protobuf messages in proto3's JSON mapping): `resourceSpans`, `resourceLogs`, `resourceMetrics`.
/// Field names are taken in lowerCamelCase and snake_case, 64-bit numbers as strings or numbers, ids as hex, as the
/// spec says, or base64, as some exporters still send them.
public enum OTLPJSON {
    /// The signal is the path's when it has one, else whichever top-level key the body has.
    public static func decode(_ data: Data, signal: OTLPSignal? = nil) throws -> OTLPBatch {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw OTLPError.notJSON }
        return try decode(root: root, signal: signal)
    }

    /// From the JSON mapping's objects, however they were read (`OTLPProtobuf` builds the same ones).
    static func decode(root: [String: Any], signal: OTLPSignal?) throws -> OTLPBatch {
        var batch = OTLPBatch()
        let wanted = signal.map { [$0] } ?? OTLPSignal.allCases
        var known = false
        for signal in wanted {
            switch signal {
            case .traces:
                guard let list = array(root, "resourceSpans") else { continue }
                known = true
                batch.spans += list.flatMap(spans)
            case .logs:
                guard let list = array(root, "resourceLogs") else { continue }
                known = true
                batch.logs += list.flatMap(logs)
            case .metrics:
                guard let list = array(root, "resourceMetrics") else { continue }
                known = true
                batch.points += list.flatMap(points)
            }
        }
        // An empty object is a valid (empty) export of the signal the path named.
        guard known || (signal != nil && root.isEmpty) else { throw OTLPError.unknownSignal }
        return batch
    }

    // MARK: Signals

    private static func spans(_ resourceSpans: [String: Any]) -> [OTLPSpan] {
        let resource = attributes(object(resourceSpans, "resource").flatMap { array($0, "attributes") })
        let scopes = array(resourceSpans, "scopeSpans") ?? array(resourceSpans, "instrumentationLibrarySpans") ?? []
        return scopes.flatMap { scope in
            (array(scope, "spans") ?? []).compactMap { span -> OTLPSpan? in
                guard let traceID = id(field(span, "traceId")), let spanID = id(field(span, "spanId")) else {
                    return nil
                }
                let status = object(span, "status")
                let code = status.flatMap { field($0, "code") }
                let failed = (code as? String).map { $0 == "STATUS_CODE_ERROR" || $0 == "2" }
                    ?? (number(code) == 2)
                let start = time(field(span, "startTimeUnixNano")) ?? Date(timeIntervalSince1970: 0)
                return OTLPSpan(
                    traceID: traceID, spanID: spanID, parentID: id(field(span, "parentSpanId")),
                    name: field(span, "name") as? String ?? "", start: start,
                    end: time(field(span, "endTimeUnixNano")) ?? start, failed: failed,
                    statusMessage: (status.flatMap { field($0, "message") } as? String)
                        .flatMap { $0.isEmpty ? nil : $0 },
                    attributes: attributes(array(span, "attributes")), resource: resource
                )
            }
        }
    }

    private static func logs(_ resourceLogs: [String: Any]) -> [OTLPLog] {
        let resource = attributes(object(resourceLogs, "resource").flatMap { array($0, "attributes") })
        let scopes = array(resourceLogs, "scopeLogs") ?? array(resourceLogs, "instrumentationLibraryLogs") ?? []
        return scopes.flatMap { scope in
            (array(scope, "logRecords") ?? []).map { record in
                let attributes = attributes(array(record, "attributes"))
                let body = object(record, "body").flatMap(text)
                // Claude Code sends `event.name` without its namespace (`api_request`) and the full name as the body.
                let short = attributes["event.name"] ?? field(record, "eventName") as? String
                let name = switch (short, body) {
                case let (short?, body?) where !short.contains(".") && body.hasSuffix("." + short): body
                case let (short?, _): short
                default: body ?? ""
                }
                let time = time(field(record, "timeUnixNano")) ?? time(field(record, "observedTimeUnixNano"))
                    ?? attributes["event.timestamp"].flatMap(isoDate) ?? Date(timeIntervalSince1970: 0)
                return OTLPLog(time: time, name: name, attributes: attributes, resource: resource)
            }
        }
    }

    private static func points(_ resourceMetrics: [String: Any]) -> [OTLPPoint] {
        let resource = attributes(object(resourceMetrics, "resource").flatMap { array($0, "attributes") })
        let scopes = array(resourceMetrics, "scopeMetrics") ?? array(resourceMetrics, "instrumentationLibraryMetrics")
            ?? []
        return scopes.flatMap { scope in
            (array(scope, "metrics") ?? []).flatMap { metric -> [OTLPPoint] in
                let name = field(metric, "name") as? String ?? ""
                if let sum = object(metric, "sum") {
                    let temporality = field(sum, "aggregationTemporality")
                    let cumulative = (temporality as? String).map { $0.contains("CUMULATIVE") || $0 == "2" }
                        ?? (number(temporality) == 2)
                    return numberPoints(sum, name: name, cumulative: cumulative, resource: resource)
                }
                if let gauge = object(metric, "gauge") {
                    return numberPoints(gauge, name: name, cumulative: false, resource: resource)
                }
                if let histogram = object(metric, "histogram") {
                    return (array(histogram, "dataPoints") ?? []).compactMap { point in
                        guard let value = number(field(point, "sum")) else { return nil }
                        return OTLPPoint(
                            name: name, time: time(field(point, "timeUnixNano")) ?? Date(timeIntervalSince1970: 0),
                            value: value, attributes: attributes(array(point, "attributes")), resource: resource
                        )
                    }
                }
                return []
            }
        }
    }

    private static func numberPoints(
        _ data: [String: Any], name: String, cumulative: Bool, resource: [String: String]
    ) -> [OTLPPoint] {
        (array(data, "dataPoints") ?? []).compactMap { point in
            guard let value = number(field(point, "asDouble")) ?? number(field(point, "asInt")) else { return nil }
            return OTLPPoint(
                name: name, time: time(field(point, "timeUnixNano")) ?? Date(timeIntervalSince1970: 0), value: value,
                cumulative: cumulative, attributes: attributes(array(point, "attributes")), resource: resource
            )
        }
    }

    // MARK: Values

    /// `[{key, value: {stringValue|intValue|doubleValue|boolValue|arrayValue}}]` as `key: text`.
    static func attributes(_ list: [[String: Any]]?) -> [String: String] {
        var out: [String: String] = [:]
        for entry in list ?? [] {
            guard let key = entry["key"] as? String else { continue }
            if let value = object(entry, "value").flatMap(text) { out[key] = value }
        }
        return out
    }

    /// An `AnyValue` as text: a string as it is, a number or a bool written out, an array joined with commas.
    static func text(_ value: [String: Any]) -> String? {
        if let string = field(value, "stringValue") as? String { return string }
        if let int = field(value, "intValue") { return (int as? String) ?? number(int).map { String(Int64($0)) } }
        if let double = number(field(value, "doubleValue")) {
            return double == double.rounded() && abs(double) < 1e15 ? String(Int64(double)) : String(double)
        }
        if let bool = field(value, "boolValue") as? Bool { return bool ? "true" : "false" }
        if let array = object(value, "arrayValue").flatMap({ self.array($0, "values") }) {
            return array.compactMap(text).joined(separator: ",")
        }
        return nil
    }

    /// A field by its lowerCamelCase name, or its snake_case one.
    static func field(_ object: [String: Any], _ name: String) -> Any? {
        if let value = object[name] { return value }
        var snake = ""
        for character in name {
            if character.isUppercase { snake += "_" + character.lowercased() } else { snake.append(character) }
        }
        return object[snake]
    }

    private static func object(_ object: [String: Any], _ name: String) -> [String: Any]? {
        field(object, name) as? [String: Any]
    }

    private static func array(_ object: [String: Any], _ name: String) -> [[String: Any]]? {
        field(object, name) as? [[String: Any]]
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber where !(number === kCFBooleanTrue || number === kCFBooleanFalse):
            number.doubleValue
        case let text as String: Double(text)
        default: nil
        }
    }

    /// Nanoseconds since 1970, as a string or a number; nil for none or zero.
    static func time(_ value: Any?) -> Date? {
        if let text = value as? String, let nanos = UInt64(text), nanos > 0 {
            return Date(timeIntervalSince1970: Double(nanos / 1000) / 1_000_000)
        }
        guard let nanos = number(value), nanos > 0 else { return nil }
        return Date(timeIntervalSince1970: nanos / 1e9)
    }

    /// A trace or span id as lowercase hex: hex as sent, base64 decoded; nil when empty or all zero.
    static func id(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        let isHex = text.count % 2 == 0 && text.allSatisfy(\.isHexDigit)
        let hex = isHex ? text.lowercased()
            : Data(base64Encoded: text).map { $0.map { String(format: "%02x", $0) }.joined() } ?? text
        return hex.allSatisfy { $0 == "0" } ? nil : hex
    }

    private static func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
