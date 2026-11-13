import Foundation

/// OTLP/protobuf (`http/protobuf`, Codex's `binary`), read without a protobuf library: the wire format is small, and
/// heed needs only the fields it reads. Each message becomes the object the JSON mapping would have (camelCase
/// names, ids as hex, 64-bit numbers as strings), so `OTLPJSON` reads both the same way. Unknown fields are skipped.
public enum OTLPProtobuf {
    public static func decode(_ data: Data, signal: OTLPSignal) throws -> OTLPBatch {
        let schema = switch signal {
        case .traces: Schemas.traces
        case .logs: Schemas.logs
        case .metrics: Schemas.metrics
        }
        var reader = WireReader(bytes: [UInt8](data))
        guard let root = try? reader.message(schema) else { throw OTLPError.notProtobuf }
        return try OTLPJSON.decode(root: root, signal: signal)
    }

    // MARK: Schemas

    /// How one field becomes a JSON-mapping value.
    enum Field {
        case string(String)
        /// Bytes as lowercase hex (trace and span ids).
        case hex(String)
        /// Bytes as base64 (`bytesValue`).
        case base64(String)
        /// A varint, as a decimal string (int64 in the JSON mapping).
        case varintString(String)
        /// A varint as a number (an enum, a bool, a small int).
        case varint(String)
        case bool(String)
        /// fixed64 as a decimal string (times, counts).
        case fixed64String(String)
        /// sfixed64 as a decimal string (`asInt`).
        case sfixed64String(String)
        case double(String)
        case message(String, Schema)
        case repeated(String, Schema)
    }

    /// A message's fields by number. A class, so messages can hold themselves (`AnyValue` in an array).
    final class Schema: @unchecked Sendable {
        var fields: [Int: Field] = [:]
        init(_ fields: [Int: Field] = [:]) { self.fields = fields }
    }

    enum Schemas {
        static let anyValue: Schema = {
            let any = Schema()
            let keyValue = Schema([1: .string("key"), 2: .message("value", any)])
            any.fields = [
                1: .string("stringValue"), 2: .bool("boolValue"), 3: .varintString("intValue"),
                4: .double("doubleValue"), 5: .message("arrayValue", Schema([1: .repeated("values", any)])),
                6: .message("kvlistValue", Schema([1: .repeated("values", keyValue)])), 7: .base64("bytesValue"),
            ]
            return any
        }()

        static let keyValue = Schema([1: .string("key"), 2: .message("value", anyValue)])
        static let resource = Schema([1: .repeated("attributes", keyValue)])
        static let scope = Schema([1: .string("name"), 2: .string("version")])

        static let span = Schema([
            1: .hex("traceId"), 2: .hex("spanId"), 4: .hex("parentSpanId"), 5: .string("name"), 6: .varint("kind"),
            7: .fixed64String("startTimeUnixNano"), 8: .fixed64String("endTimeUnixNano"),
            9: .repeated("attributes", keyValue),
            15: .message("status", Schema([2: .string("message"), 3: .varint("code")])),
        ])
        static let traces = Schema([1: .repeated("resourceSpans", Schema([
            1: .message("resource", resource),
            2: .repeated("scopeSpans", Schema([1: .message("scope", scope), 2: .repeated("spans", span)])),
        ]))])

        static let logRecord = Schema([
            1: .fixed64String("timeUnixNano"), 11: .fixed64String("observedTimeUnixNano"),
            2: .varint("severityNumber"), 3: .string("severityText"), 5: .message("body", anyValue),
            6: .repeated("attributes", keyValue), 9: .hex("traceId"), 10: .hex("spanId"), 12: .string("eventName"),
        ])
        static let logs = Schema([1: .repeated("resourceLogs", Schema([
            1: .message("resource", resource),
            2: .repeated("scopeLogs", Schema([1: .message("scope", scope), 2: .repeated("logRecords", logRecord)])),
        ]))])

        static let numberPoint = Schema([
            7: .repeated("attributes", keyValue), 2: .fixed64String("startTimeUnixNano"),
            3: .fixed64String("timeUnixNano"), 4: .double("asDouble"), 6: .sfixed64String("asInt"),
        ])
        static let histogramPoint = Schema([
            9: .repeated("attributes", keyValue), 2: .fixed64String("startTimeUnixNano"),
            3: .fixed64String("timeUnixNano"), 4: .fixed64String("count"), 5: .double("sum"),
        ])
        static let metric = Schema([
            1: .string("name"), 2: .string("description"), 3: .string("unit"),
            5: .message("gauge", Schema([1: .repeated("dataPoints", numberPoint)])),
            7: .message("sum", Schema([
                1: .repeated("dataPoints", numberPoint), 2: .varint("aggregationTemporality"),
                3: .bool("isMonotonic"),
            ])),
            9: .message("histogram", Schema([
                1: .repeated("dataPoints", histogramPoint), 2: .varint("aggregationTemporality"),
            ])),
        ])
        static let metrics = Schema([1: .repeated("resourceMetrics", Schema([
            1: .message("resource", resource),
            2: .repeated("scopeMetrics", Schema([1: .message("scope", scope), 2: .repeated("metrics", metric)])),
        ]))])
    }

    // MARK: Wire format

    enum WireError: Error { case truncated, badWireType }

    struct WireReader {
        let bytes: [UInt8]
        var index: Int
        let end: Int

        init(bytes: [UInt8], index: Int = 0, end: Int? = nil) {
            self.bytes = bytes
            self.index = index
            self.end = end ?? bytes.count
        }

        mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard index < end, shift < 64 else { throw WireError.truncated }
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
        }

        mutating func fixed64() throws -> UInt64 {
            guard end - index >= 8 else { throw WireError.truncated }
            var value: UInt64 = 0
            for offset in 0 ..< 8 {
                value |= UInt64(bytes[index + offset]) << (8 * UInt64(offset))
            }
            index += 8
            return value
        }

        mutating func lengthDelimited() throws -> Range<Int> {
            let length = try Int(exactly: varint()) ?? Int.max
            guard length >= 0, end - index >= length else { throw WireError.truncated }
            defer { index += length }
            return index ..< index + length
        }

        mutating func skip(_ wireType: UInt64) throws {
            switch wireType {
            case 0: _ = try varint()
            case 1: _ = try fixed64()
            case 2: _ = try lengthDelimited()
            case 5:
                guard end - index >= 4 else { throw WireError.truncated }
                index += 4
            default: throw WireError.badWireType
            }
        }

        /// The message from here to `end`, as the JSON mapping's object.
        mutating func message(_ schema: Schema) throws -> [String: Any] {
            var out: [String: Any] = [:]
            while index < end {
                let key = try varint()
                let number = Int(key >> 3)
                let wireType = key & 7
                guard let field = schema.fields[number] else {
                    try skip(wireType)
                    continue
                }
                switch (field, wireType) {
                case let (.string(name), 2):
                    out[name] = try String(decoding: bytes[lengthDelimited()], as: UTF8.self)
                case let (.hex(name), 2):
                    out[name] = try bytes[lengthDelimited()].map { String(format: "%02x", $0) }.joined()
                case let (.base64(name), 2):
                    out[name] = try Data(bytes[lengthDelimited()]).base64EncodedString()
                case let (.varintString(name), 0):
                    out[name] = try String(Int64(bitPattern: varint()))
                case let (.varint(name), 0):
                    out[name] = try NSNumber(value: Int64(bitPattern: varint()))
                case let (.bool(name), 0):
                    out[name] = try varint() != 0
                case let (.fixed64String(name), 1):
                    out[name] = try String(fixed64())
                case let (.sfixed64String(name), 1):
                    out[name] = try String(Int64(bitPattern: fixed64()))
                case let (.double(name), 1):
                    out[name] = try NSNumber(value: Double(bitPattern: fixed64()))
                case let (.message(name, inner), 2):
                    let range = try lengthDelimited()
                    var nested = WireReader(bytes: bytes, index: range.lowerBound, end: range.upperBound)
                    out[name] = try nested.message(inner)
                case let (.repeated(name, inner), 2):
                    let range = try lengthDelimited()
                    var nested = WireReader(bytes: bytes, index: range.lowerBound, end: range.upperBound)
                    var list = out[name] as? [[String: Any]] ?? []
                    try list.append(nested.message(inner))
                    out[name] = list
                default:
                    // A field heed knows sent with another wire type than it expects: skipped, not guessed at.
                    try skip(wireType)
                }
            }
            return out
        }
    }
}
