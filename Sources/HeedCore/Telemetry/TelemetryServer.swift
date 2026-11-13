import Foundation

/// One HTTP/1.1 request, as `HTTPRequestReader` cut it from a connection.
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data
}

/// Reads HTTP/1.1 requests from a connection's bytes as they arrive: a body by `Content-Length` or chunked, several
/// requests one after the other on one kept-alive connection. Bodies past `maxBody` fail the connection.
public struct HTTPRequestReader: Sendable {
    public enum Failure: Error, Equatable {
        case malformed
        case tooLarge
    }

    public static let defaultMaxBody = 16 * 1024 * 1024

    private var buffer = Data()
    private let maxBody: Int

    public init(maxBody: Int = Self.defaultMaxBody) {
        self.maxBody = maxBody
    }

    /// Adds what arrived, and returns every request it completed.
    public mutating func feed(_ bytes: Data) throws(Failure) -> [HTTPRequest] {
        buffer.append(bytes)
        var out: [HTTPRequest] = []
        while let request = try next() {
            out.append(request)
        }
        return out
    }

    private static let headerEnd = Data("\r\n\r\n".utf8)
    private static let lineEnd = Data("\r\n".utf8)

    private mutating func next() throws(Failure) -> HTTPRequest? {
        guard let end = buffer.range(of: Self.headerEnd) else {
            if buffer.count > 64 * 1024 { throw .malformed }
            return nil
        }
        let head = String(decoding: buffer[buffer.startIndex ..< end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { throw .malformed }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let bodyStart = end.upperBound
        var body = Data()
        var consumed: Int
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let (chunks, length) = try chunked(from: bodyStart) else { return nil }
            body = chunks
            consumed = length
        } else {
            let length = Int(headers["content-length"] ?? "0") ?? 0
            guard length >= 0 else { throw .malformed }
            guard length <= maxBody else { throw .tooLarge }
            guard buffer.endIndex - bodyStart >= length else { return nil }
            body = Data(buffer[bodyStart ..< bodyStart + length])
            consumed = bodyStart - buffer.startIndex + length
        }
        buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + consumed)
        buffer = Data(buffer)
        return HTTPRequest(
            method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: body
        )
    }

    /// The chunks from `start`, and how many bytes from the buffer's start the request took; nil until it is whole.
    private func chunked(from start: Data.Index) throws(Failure) -> (Data, Int)? {
        var body = Data()
        var position = start
        while true {
            guard let lineEnd = buffer.range(of: Self.lineEnd, in: position ..< buffer.endIndex) else { return nil }
            let sizeText = String(decoding: buffer[position ..< lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(sizeText, radix: 16), size >= 0 else { throw .malformed }
            let dataStart = lineEnd.upperBound
            if size == 0 {
                // The last chunk, then (trailers and) an empty line.
                guard let close = buffer.range(of: Self.lineEnd, in: dataStart ..< buffer.endIndex) else { return nil }
                return (body, close.upperBound - buffer.startIndex)
            }
            guard body.count + size <= maxBody else { throw .tooLarge }
            guard buffer.endIndex - dataStart >= size + 2 else { return nil }
            body.append(buffer[dataStart ..< dataStart + size])
            position = dataStart + size + 2
        }
    }
}

/// What the receiver answers one request with, and what it read from it.
public enum OTLPHTTP {
    public struct Reply: Equatable, Sendable {
        public var status: Int
        public var body: String
        public var records: TelemetryRecords?
    }

    /// The reply to `request`: OTLP/JSON posted to `/v1/traces`, `/v1/logs` or `/v1/metrics` (gzip or not) is read
    /// and answered with an empty success; protobuf is refused with 415, so an exporter set to it says why.
    public static func handle(_ request: HTTPRequest) -> Reply {
        if request.method == "GET" { return Reply(status: 200, body: #"{"heed":"otlp"}"#) }
        guard request.method == "POST" else { return Reply(status: 405, body: #"{"message":"POST only"}"#) }
        let type = (request.headers["content-type"] ?? "application/json").lowercased()
        guard type.contains("json") else {
            return Reply(status: 415, body: #"{"message":"heed takes OTLP/HTTP JSON (http/json)"}"#)
        }
        var body = request.body
        if request.headers["content-encoding"]?.lowercased() == "gzip" {
            guard let inflated = Gzip.inflate(body) else {
                return Reply(status: 400, body: #"{"message":"bad gzip"}"#)
            }
            body = inflated
        }
        do {
            let batch = try OTLPJSON.decode(body, signal: OTLPSignal(path: request.path))
            return Reply(status: 200, body: "{}", records: TelemetryReader.records(batch))
        } catch {
            return Reply(status: 400, body: #"{"message":"\#(error)"}"#)
        }
    }

    static func response(_ reply: Reply) -> Data {
        let reason = switch reply.status {
        case 200: "OK"
        case 400: "Bad Request"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        default: "Unsupported Media Type"
        }
        let body = Data(reply.body.utf8)
        let head = "HTTP/1.1 \(reply.status) \(reason)\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// gzip, as an exporter set to compress sends it: the header and trailer around raw DEFLATE.
enum Gzip {
    static func inflate(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 {
            guard index + 2 <= bytes.count else { return nil }
            index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8
        }
        for flag in [UInt8(0x08), 0x10] where flags & flag != 0 {
            while index < bytes.count, bytes[index] != 0 {
                index += 1
            }
            index += 1
        }
        if flags & 0x02 != 0 { index += 2 }
        guard index < bytes.count - 8 else { return nil }
        let deflated = Data(bytes[index ..< bytes.count - 8])
        return try? (deflated as NSData).decompressed(using: .zlib) as Data
    }
}

/// heed's OTLP/HTTP receiver: listens on 127.0.0.1 only (never another interface, so nothing off this Mac can send
/// to it, and it sends nothing anywhere), reads each export on its own queue and hands what it read to `records`.
public final class TelemetryServer: @unchecked Sendable {
    public let port: Int
    public let records: AsyncStream<TelemetryRecords>

    private let continuation: AsyncStream<TelemetryRecords>.Continuation
    private let queue = DispatchQueue(label: "heed.telemetry")
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: (DispatchSourceRead, HTTPRequestReader)] = [:]

    public init(port: Int) {
        self.port = port
        (records, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    deinit { stop() }

    /// Binds 127.0.0.1:`port`. Throws when the port is taken (another collector, another heed).
    public func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HookServerError.system("socket", errno) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw HookServerError.system("bind 127.0.0.1:\(port)", code)
        }
        guard listen(fd, 64) == 0 else {
            close(fd)
            throw HookServerError.system("listen", errno)
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        queue.sync {
            listener = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptClients() }
            source.resume()
            acceptSource = source
        }
    }

    public func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            for (fd, client) in clients {
                client.0.cancel()
                close(fd)
            }
            clients = [:]
            if listener >= 0 {
                close(listener)
                listener = -1
            }
        }
        continuation.finish()
    }

    private func acceptClients() {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var no: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &no, socklen_t(MemoryLayout<Int32>.size))
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.read(fd) }
            clients[fd] = (source, HTTPRequestReader())
            source.resume()
        }
    }

    private func drop(_ fd: Int32) {
        clients[fd]?.0.cancel()
        clients[fd] = nil
        close(fd)
    }

    private func read(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        guard count > 0, var reader = clients[fd]?.1 else { return drop(fd) }
        do {
            let requests = try reader.feed(Data(buffer[0 ..< count]))
            clients[fd]?.1 = reader
            for request in requests {
                let reply = OTLPHTTP.handle(request)
                if let records = reply.records, !records.isEmpty { continuation.yield(records) }
                send(OTLPHTTP.response(reply), to: fd)
            }
        } catch {
            send(OTLPHTTP.response(.init(status: error == .tooLarge ? 413 : 400, body: "{}")), to: fd)
            drop(fd)
        }
    }

    /// Replies are small; a socket that will not take one is dropped rather than waited on.
    private func send(_ data: Data, to fd: Int32) {
        var offset = 0
        var tries = 0
        while offset < data.count, tries < 100 {
            let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, data.count - offset) }
            if written > 0 {
                offset += written
            } else if errno == EAGAIN || errno == EINTR {
                tries += 1
                usleep(1000)
            } else {
                return
            }
        }
    }
}
