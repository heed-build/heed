import Foundation

/// The TOML Heed's config needs: tables (`[a."b"]`), dotted and quoted keys, strings (basic, literal, multi-line),
/// integers, floats, booleans, arrays and inline tables, comments. Arrays of tables are rejected. Every value keeps
/// the source range it came from, so `TOMLDocument.setting` can change one value in place and leave comments and
/// layout alone.
public indirect enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case float(Double)
    case bool(Bool)
    case array([TOMLValue])
    case table(TOMLTable)

    public var string: String? { if case let .string(value) = self { value } else { nil } }
    public var integer: Int? { if case let .integer(value) = self { value } else { nil } }
    public var bool: Bool? { if case let .bool(value) = self { value } else { nil } }
    public var table: TOMLTable? { if case let .table(value) = self { value } else { nil } }
    public var array: [TOMLValue]? { if case let .array(value) = self { value } else { nil } }

    /// The value written as TOML.
    public var literal: String {
        switch self {
        case let .string(text): TOMLValue.quote(text)
        case let .integer(value): String(value)
        case let .float(value): String(value)
        case let .bool(value): value ? "true" : "false"
        case let .array(items): "[" + items.map(\.literal).joined(separator: ", ") + "]"
        case let .table(table): "{ " + table.keys.map { "\(TOMLValue.key($0)) = \(table[$0]!.literal)" }
            .joined(separator: ", ") + " }"
        }
    }

    static func quote(_ text: String) -> String {
        var out = "\""
        for char in text {
            switch char {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.append(char)
            }
        }
        return out + "\""
    }

    static func key(_ key: String) -> String {
        let bare = !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return bare ? key : quote(key)
    }
}

/// A table that remembers key order.
public struct TOMLTable: Equatable, Sendable {
    public private(set) var keys: [String] = []
    private var values: [String: TOMLValue] = [:]

    public init() {}

    public subscript(key: String) -> TOMLValue? {
        get { values[key] }
        set {
            if values[key] == nil, newValue != nil { keys.append(key) }
            if newValue == nil { keys.removeAll { $0 == key } }
            values[key] = newValue
        }
    }

    public func value(at path: [String]) -> TOMLValue? {
        guard let first = path.first else { return .table(self) }
        guard let value = values[first] else { return nil }
        if path.count == 1 { return value }
        return value.table?.value(at: Array(path.dropFirst()))
    }
}

public struct TOMLError: Error, Equatable, Sendable, CustomStringConvertible {
    public let line: Int
    public let message: String
    public var description: String { "line \(line): \(message)" }
}

/// A parsed document: the root table plus where each value and table header sits in the source.
public struct TOMLDocument: Sendable {
    public let source: String
    public let root: TOMLTable
    /// Source range of each key's value, by full key path.
    let valueRanges: [[String]: Range<String.Index>]
    /// End of each table's last line (where a new key goes), by table path. `[]` is the top level.
    let tableEnds: [[String]: String.Index]

    public init(_ source: String) throws(TOMLError) {
        var parser = TOMLParser(source)
        try parser.parseDocument()
        self.source = source
        root = parser.root
        valueRanges = parser.valueRanges
        tableEnds = parser.tableEnds
    }

    /// The source with the value at `path` replaced (or added to its table, creating the table if needed). Comments,
    /// order and spacing elsewhere are untouched.
    public func setting(_ path: [String], to value: TOMLValue) -> String {
        precondition(!path.isEmpty)
        if let range = valueRanges[path] {
            var text = source
            text.replaceSubrange(range, with: value.literal)
            return text
        }
        let table = Array(path.dropLast())
        let line = "\(TOMLValue.key(path.last!)) = \(value.literal)"
        if let end = tableEnds[table] {
            var text = source
            let needsNewline = end > text.startIndex && text[text.index(before: end)] != "\n"
            text.insert(contentsOf: (needsNewline ? "\n" : "") + line + "\n", at: end)
            return text
        }
        var text = source
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        if !table.isEmpty { text += "\n[" + table.map(TOMLValue.key).joined(separator: ".") + "]\n" }
        return text + line + "\n"
    }
}

struct TOMLParser {
    let text: String
    var index: String.Index
    var line = 1
    var root = TOMLTable()
    var currentTable: [String] = []
    var definedTables: Set<[String]> = []
    var valueRanges: [[String]: Range<String.Index>] = [:]
    var tableEnds: [[String]: String.Index] = [:]

    init(_ text: String) {
        self.text = text
        index = text.startIndex
    }

    var atEnd: Bool { index >= text.endIndex }
    var peek: Character? { atEnd ? nil : text[index] }

    func error(_ message: String) -> TOMLError { TOMLError(line: line, message: message) }

    mutating func advance() {
        if text[index] == "\n" { line += 1 }
        index = text.index(after: index)
    }

    mutating func skipSpaces() {
        while let char = peek, char == " " || char == "\t" {
            advance()
        }
    }

    mutating func skipComment() {
        if peek == "#" { while let char = peek, char != "\n" {
            advance()
        } }
    }

    /// Spaces, comments and newlines (inside arrays).
    mutating func skipTrivia() {
        while let char = peek {
            if char == " " || char == "\t" || char == "\n" || char == "\r" {
                advance()
            } else if char == "#" {
                skipComment()
            } else {
                break
            }
        }
    }

    mutating func endOfLine() throws(TOMLError) {
        skipSpaces()
        skipComment()
        if peek == "\r" { advance() }
        guard atEnd || peek == "\n" else { throw error("expected the end of the line") }
        if !atEnd { advance() }
    }

    mutating func parseDocument() throws(TOMLError) {
        tableEnds[[]] = text.startIndex
        while !atEnd {
            skipTrivia()
            guard let char = peek else { break }
            if char == "[" {
                try parseHeader()
            } else {
                try parseKeyValue(into: currentTable)
                tableEnds[currentTable] = index
            }
        }
    }

    mutating func parseHeader() throws(TOMLError) {
        advance()
        if peek == "[" { throw error("arrays of tables ([[...]]) are not supported in Heed's config") }
        skipSpaces()
        let path = try parseKey()
        skipSpaces()
        guard peek == "]" else { throw error("expected ] after the table name") }
        advance()
        if definedTables.contains(path) { throw error("table [\(path.joined(separator: "."))] is defined twice") }
        definedTables.insert(path)
        try ensureTable(path)
        currentTable = path
        try endOfLine()
        tableEnds[path] = index
    }

    mutating func parseKeyValue(into table: [String]) throws(TOMLError) {
        let key = try parseKey()
        skipSpaces()
        guard peek == "=" else { throw error("expected = after \(key.joined(separator: "."))") }
        advance()
        skipSpaces()
        let start = index
        let value = try parseValue(path: table + key)
        valueRanges[table + key] = start ..< index
        try insert(value, at: table + key)
        try endOfLine()
    }

    mutating func parseKey() throws(TOMLError) -> [String] {
        var parts: [String] = []
        repeat {
            skipSpaces()
            if peek == "." { advance(); skipSpaces() }
            if peek == "\"" {
                try parts.append(parseBasicString())
            } else if peek == "'" {
                try parts.append(parseLiteralString())
            } else {
                var bare = ""
                while let char = peek, char.isLetter || char.isNumber || char == "_" || char == "-" {
                    bare.append(char)
                    advance()
                }
                guard !bare.isEmpty else { throw error("expected a key") }
                parts.append(bare)
            }
            skipSpaces()
        } while peek == "."
        return parts
    }

    mutating func parseValue(path: [String]) throws(TOMLError) -> TOMLValue {
        guard let char = peek else { throw error("expected a value") }
        switch char {
        case "\"":
            if text[index...].hasPrefix("\"\"\"") { return try .string(parseMultiline(quote: "\"")) }
            return try .string(parseBasicString())
        case "'":
            if text[index...].hasPrefix("'''") { return try .string(parseMultiline(quote: "'")) }
            return try .string(parseLiteralString())
        case "[":
            return try parseArray(path: path)
        case "{":
            return try parseInlineTable(path: path)
        case "t", "f":
            if text[index...].hasPrefix("true") {
                for _ in 0 ..< 4 {
                    advance()
                }
                return .bool(true)
            }
            if text[index...].hasPrefix("false") {
                for _ in 0 ..< 5 {
                    advance()
                }
                return .bool(false)
            }
            throw error("expected a value")
        default:
            var number = ""
            while let next = peek, next.isNumber || "+-._eE".contains(next) {
                number.append(next)
                advance()
            }
            let clean = number.replacingOccurrences(of: "_", with: "")
            if let integer = Int(clean) { return .integer(integer) }
            if let float = Double(clean) { return .float(float) }
            throw error(number.isEmpty ? "expected a value" : "'\(number)' is not a number")
        }
    }

    mutating func parseBasicString() throws(TOMLError) -> String {
        advance()
        var out = ""
        while let char = peek {
            if char == "\"" {
                advance()
                return out
            }
            if char == "\n" { break }
            if char == "\\" {
                advance()
                guard let escaped = peek else { break }
                switch escaped {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "r": out.append("\r")
                default: throw error("unknown escape \\\(escaped)")
                }
                advance()
                continue
            }
            out.append(char)
            advance()
        }
        throw error("unterminated string")
    }

    mutating func parseLiteralString() throws(TOMLError) -> String {
        advance()
        var out = ""
        while let char = peek, char != "\n" {
            advance()
            if char == "'" { return out }
            out.append(char)
        }
        throw error("unterminated string")
    }

    mutating func parseMultiline(quote: Character) throws(TOMLError) -> String {
        for _ in 0 ..< 3 {
            advance()
        }
        if peek == "\n" { advance() }
        var out = ""
        let close = String(repeating: quote, count: 3)
        while !atEnd {
            if text[index...].hasPrefix(close) {
                for _ in 0 ..< 3 {
                    advance()
                }
                return out
            }
            if quote == "\"", peek == "\\" {
                advance()
                switch peek {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                default: out.append("\\")
                    continue
                }
                advance()
                continue
            }
            out.append(peek!)
            advance()
        }
        throw error("unterminated multi-line string")
    }

    mutating func parseArray(path: [String]) throws(TOMLError) -> TOMLValue {
        advance()
        var items: [TOMLValue] = []
        while true {
            skipTrivia()
            if peek == "]" {
                advance()
                return .array(items)
            }
            try items.append(parseValue(path: path))
            skipTrivia()
            if peek == "," {
                advance()
            } else if peek != "]" {
                throw error("expected , or ] in the array")
            }
        }
    }

    mutating func parseInlineTable(path: [String]) throws(TOMLError) -> TOMLValue {
        advance()
        var table = TOMLTable()
        skipSpaces()
        if peek == "}" {
            advance()
            return .table(table)
        }
        while true {
            skipSpaces()
            let key = try parseKey()
            skipSpaces()
            guard peek == "=" else { throw error("expected = in the inline table") }
            advance()
            skipSpaces()
            let value = try parseValue(path: path + key)
            table = try TOMLParser.inserting(value, at: key, into: table, line: line)
            skipSpaces()
            if peek == "}" {
                advance()
                return .table(table)
            }
            guard peek == "," else { throw error("expected , or } in the inline table") }
            advance()
        }
    }

    mutating func ensureTable(_ path: [String]) throws(TOMLError) {
        var current: [String] = []
        for part in path {
            current.append(part)
            switch root.value(at: current) {
            case nil: try insert(.table(TOMLTable()), at: current)
            case .table: continue
            default: throw error("\(current.joined(separator: ".")) is already a value, not a table")
            }
        }
    }

    mutating func insert(_ value: TOMLValue, at path: [String]) throws(TOMLError) {
        root = try TOMLParser.inserting(value, at: path, into: root, line: line)
    }

    static func inserting(
        _ value: TOMLValue,
        at path: [String],
        into table: TOMLTable,
        line: Int
    ) throws(TOMLError) -> TOMLTable {
        var table = table
        let key = path[0]
        if path.count == 1 {
            if let existing = table[key], !(existing.table != nil && value.table != nil) {
                throw TOMLError(line: line, message: "\(key) is set twice")
            }
            if table[key] == nil { table[key] = value }
            return table
        }
        let child = table[key]?.table ?? TOMLTable()
        if let existing = table[key], existing.table == nil {
            throw TOMLError(line: line, message: "\(key) is a value, not a table")
        }
        table[key] = try .table(inserting(value, at: Array(path.dropFirst()), into: child, line: line))
        return table
    }
}
