#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// One request the loopback proxy received.
public struct ProxyRequest: Sendable {
    public let method: String
    public let path: String
    /// Header names are lowercased.
    public let headers: [String: String]
    public let body: Data
}

/// What the proxy answers. The status line is written when the body yields
/// its first piece or finishes, so a body that fails first can still choose
/// the status by throwing `ProxyHTTPError`.
public struct ProxyReply: Sendable {
    public var status: Int
    public var contentType: String
    public var body: AsyncThrowingStream<Data, Error>

    public init(status: Int, contentType: String, body: AsyncThrowingStream<Data, Error>) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    public static func json(status: Int, _ object: [String: Any]) -> ProxyReply {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return ProxyReply(status: status, contentType: "application/json", body: AsyncThrowingStream { continuation in
            continuation.yield(data)
            continuation.finish()
        })
    }

    public static func error(status: Int, _ message: String) -> ProxyReply {
        json(status: status, ["error": ["code": status, "message": message]])
    }
}

/// Thrown by a reply body before its first piece to answer with this status.
public struct ProxyHTTPError: Error, Sendable, Equatable {
    public let status: Int
    public let message: String

    public init(status: Int, message: String) {
        self.status = status
        self.message = message
    }
}

/// Parsing of the one HTTP/1.1 request a proxy connection carries.
public enum HTTPRequestHead {
    public static let maximumHeadBytes = 64 * 1024
    public static let maximumBodyBytes = 8 * 1024 * 1024

    public enum Failure: Error, Equatable {
        case malformed
        case tooLarge
        /// Chunked request bodies are not accepted (411 Length Required).
        case lengthRequired
        /// Raised by the proxy, before the body is read.
        case unauthorized
    }

    public struct Head: Equatable, Sendable {
        public let method: String
        public let path: String
        public let headers: [String: String]
        public let contentLength: Int
    }

    /// The offset just past `\r\n\r\n`, or nil while the head is incomplete.
    public static func headEnd(in data: [UInt8]) -> Int? {
        guard data.count >= 4 else { return nil }
        for index in 3..<data.count
        where data[index - 3] == 13 && data[index - 2] == 10 && data[index - 1] == 13 && data[index] == 10 {
            return index + 1
        }
        return nil
    }

    public static func parse(_ bytes: ArraySlice<UInt8>) throws -> Head {
        guard let text = String(bytes: bytes, encoding: .utf8) else { throw Failure.malformed }
        var lines = text.components(separatedBy: "\r\n")
        while lines.last == "" { lines.removeLast() }
        guard let requestLine = lines.first else { throw Failure.malformed }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { throw Failure.malformed }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw Failure.malformed }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw Failure.malformed }
            headers[name] = value
        }
        if let encoding = headers["transfer-encoding"], encoding.lowercased() != "identity" {
            throw Failure.lengthRequired
        }
        var length = 0
        if let value = headers["content-length"] {
            guard let parsed = Int(value), parsed >= 0 else { throw Failure.malformed }
            guard parsed <= maximumBodyBytes else { throw Failure.tooLarge }
            length = parsed
        }
        var path = String(parts[1])
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        return Head(method: String(parts[0]).uppercased(), path: path, headers: headers, contentLength: length)
    }

    public static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 411: "Length Required"
        case 413: "Payload Too Large"
        case 499: "Client Closed Request"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }

    public static func responseHead(status: Int, contentType: String) -> Data {
        var head = "HTTP/1.1 \(status) \(reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Cache-Control: no-cache\r\n"
        // The body length is not known while a translation streams, so the
        // body ends when the connection closes.
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8)
    }

    /// Compares the bearer token in constant time.
    public static func authorized(_ headers: [String: String], apiKey: String) -> Bool {
        guard let value = headers["authorization"] else { return false }
        let prefix = "Bearer "
        guard value.hasPrefix(prefix) else { return false }
        let given = Array(value.dropFirst(prefix.count).utf8)
        let expected = Array(apiKey.utf8)
        var difference = UInt8(given.count == expected.count ? 0 : 1)
        for index in 0..<max(given.count, expected.count) {
            let a = index < given.count ? given[index] : 0
            let b = index < expected.count ? expected[index] : 0
            difference |= a ^ b
        }
        return difference == 0 && !expected.isEmpty
    }
}

/// A small HTTP server on 127.0.0.1 that puts the PDF worker's engine traffic
/// through the same slots and priorities as the app's own requests (SPEC 7.3).
///
/// Each connection carries one request and is closed after the reply. Every
/// request needs `Authorization: Bearer <apiKey>`; the key is made per app
/// launch and is not the engine's own key. When the client closes its
/// connection, the handler's task is cancelled, which releases its slot and
/// closes the upstream request, so the engine stops generating.
public final class EngineProxy: @unchecked Sendable {
    public typealias Handler = @Sendable (ProxyRequest) async -> ProxyReply

    public let apiKey: String
    private let handler: Handler
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var stopped = false
    /// Connections still open. A descriptor is closed only after it leaves
    /// this set (under the lock), so `stop()` never shuts down a number the
    /// system has already handed to another file.
    private var openConnections: Set<Int32> = []
    private var boundPort: UInt16 = 0

    public var port: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return boundPort
    }

    public init(apiKey: String, handler: @escaping Handler) {
        self.apiKey = apiKey
        self.handler = handler
    }

    public enum StartError: Error { case socket, bind, listen }

    /// Binds 127.0.0.1 on a port the OS picks and starts accepting.
    @discardableResult
    public func start() throws -> UInt16 {
        #if canImport(Darwin)
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard descriptor >= 0 else { throw StartError.socket }
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(descriptor); throw StartError.bind }
        guard listen(descriptor, 16) == 0 else { close(descriptor); throw StartError.listen }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        let chosen = UInt16(bigEndian: address.sin_port)
        lock.lock()
        listener = descriptor
        boundPort = chosen
        stopped = false
        lock.unlock()

        let thread = Thread { [weak self] in self?.acceptLoop(descriptor) }
        thread.name = "EngineProxy.accept"
        thread.start()
        return chosen
    }

    /// Stops accepting and shuts down open connections, which cancels their
    /// work. The accept thread closes the listener itself once it sees the
    /// flag, so the descriptor is never closed under a running `poll`.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        listener = -1
        boundPort = 0
        for connection in openConnections { shutdown(connection, Int32(SHUT_RDWR)) }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop(_ descriptor: Int32) {
        defer { close(descriptor) }
        while !isStopped {
            // Polled with a timeout so `stop()` ends the loop on every
            // platform; closing a socket does not wake a blocked accept on Linux.
            var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, 250)
            if ready <= 0 { continue }
            let connection = accept(descriptor, nil, nil)
            guard connection >= 0 else { continue }
            #if canImport(Darwin)
            var yes: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            #endif
            // A client that stops reading must not hold a writer forever.
            var sendTimeout = timeval(tv_sec: 30, tv_usec: 0)
            setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
            lock.lock()
            if stopped {
                lock.unlock()
                close(connection)
                break
            }
            openConnections.insert(connection)
            lock.unlock()
            let thread = Thread { [self] in
                serve(connection)
                lock.lock()
                openConnections.remove(connection)
                close(connection)
                lock.unlock()
            }
            thread.name = "EngineProxy.connection"
            thread.start()
        }
    }

    // MARK: one connection

    private func serve(_ connection: Int32) {
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let request: ProxyRequest
        switch readRequest(connection) {
        case .success(let read):
            request = read
        case .failure(let failure):
            let status: Int = switch failure {
            case .lengthRequired: 411
            case .tooLarge: 413
            case .malformed: 400
            case .unauthorized: 401
            }
            _ = writeAll(connection, Self.errorBody(status: status, status == 401 ? "unauthorized" : "bad request"))
            return
        }

        let outbox = Outbox()
        let handler = self.handler
        let task = Task.detached {
            await Self.produce(handler(request), into: outbox)
        }
        // Writes happen here, on this connection's own thread, so a slow
        // reader never blocks the shared task pool. Between writes the socket
        // is watched: a client that closed reads as EOF, which cancels the work.
        while true {
            let (pieces, finished) = outbox.next(timeout: .milliseconds(100))
            for piece in pieces where !writeAll(connection, piece) {
                task.cancel()
                outbox.waitUntilFinished()
                return
            }
            if finished { return }
            if pieces.isEmpty, clientClosed(connection) || isStopped {
                task.cancel()
                outbox.waitUntilFinished()
                return
            }
        }
    }

    /// Turns a reply into the bytes to write: the head when the first piece
    /// arrives, or an error status if the body fails before it.
    private static func produce(_ reply: ProxyReply, into outbox: Outbox) async {
        var headWritten = false
        do {
            for try await piece in reply.body {
                if !headWritten {
                    headWritten = true
                    outbox.put(HTTPRequestHead.responseHead(status: reply.status, contentType: reply.contentType))
                }
                outbox.put(piece)
            }
            if !headWritten {
                outbox.put(HTTPRequestHead.responseHead(status: reply.status, contentType: reply.contentType))
            }
        } catch {
            // After the head, a failure can only be told by closing early.
            if !headWritten {
                if let http = error as? ProxyHTTPError {
                    outbox.put(errorBody(status: http.status, http.message))
                } else if !(error is CancellationError) {
                    outbox.put(errorBody(status: 502, "engine request failed"))
                }
            }
        }
        outbox.finish()
    }

    /// Bytes handed from the reply's task to the connection's thread.
    private final class Outbox: @unchecked Sendable {
        private let lock = NSLock()
        private let signal = DispatchSemaphore(value: 0)
        private let done = DispatchSemaphore(value: 0)
        private var pieces: [Data] = []
        private var finished = false

        func put(_ data: Data) {
            lock.lock()
            pieces.append(data)
            lock.unlock()
            signal.signal()
        }

        func finish() {
            lock.lock()
            finished = true
            lock.unlock()
            signal.signal()
            done.signal()
        }

        /// Waits up to `timeout` for bytes; `finished` is true once
        /// everything has been handed out.
        func next(timeout: DispatchTimeInterval) -> ([Data], Bool) {
            _ = signal.wait(timeout: .now() + timeout)
            lock.lock()
            defer { lock.unlock() }
            let out = pieces
            pieces.removeAll()
            return (out, finished && pieces.isEmpty)
        }

        func waitUntilFinished() {
            done.wait()
        }
    }

    static func errorBody(status: Int, _ message: String) -> Data {
        let object: [String: Any] = ["error": ["code": status, "message": message]]
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return HTTPRequestHead.responseHead(status: status, contentType: "application/json") + body
    }

    private func readRequest(_ connection: Int32) -> Result<ProxyRequest, HTTPRequestHead.Failure> {
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        var headEnd: Int?
        while headEnd == nil {
            let count = recv(connection, &chunk, chunk.count, 0)
            guard count > 0 else { return .failure(.malformed) }
            buffer.append(contentsOf: chunk[0..<count])
            headEnd = HTTPRequestHead.headEnd(in: buffer)
            if headEnd == nil, buffer.count > HTTPRequestHead.maximumHeadBytes { return .failure(.tooLarge) }
        }
        guard let end = headEnd else { return .failure(.malformed) }
        let head: HTTPRequestHead.Head
        do {
            head = try HTTPRequestHead.parse(buffer[0..<end])
        } catch let failure as HTTPRequestHead.Failure {
            return .failure(failure)
        } catch {
            return .failure(.malformed)
        }
        // Checked before the body, so a caller without the key cannot make
        // the proxy read megabytes.
        guard HTTPRequestHead.authorized(head.headers, apiKey: apiKey) else { return .failure(.unauthorized) }
        while buffer.count - end < head.contentLength {
            let count = recv(connection, &chunk, chunk.count, 0)
            guard count > 0 else { return .failure(.malformed) }
            buffer.append(contentsOf: chunk[0..<count])
        }
        let body = Data(buffer[end..<(end + head.contentLength)])
        return .success(ProxyRequest(method: head.method, path: head.path, headers: head.headers, body: body))
    }

    private func clientClosed(_ connection: Int32) -> Bool {
        var item = pollfd(fd: connection, events: Int16(POLLIN), revents: 0)
        let ready = poll(&item, 1, 0)
        guard ready > 0 else { return false }
        if item.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return true }
        var byte: UInt8 = 0
        let count = recv(connection, &byte, 1, Int32(MSG_PEEK | MSG_DONTWAIT))
        if count == 0 { return true }
        if count < 0 { return errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR }
        return false
    }

    private func writeAll(_ connection: Int32, _ data: Data) -> Bool {
        #if canImport(Darwin)
        let flags: Int32 = 0
        #else
        let flags = Int32(MSG_NOSIGNAL)
        #endif
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                #if canImport(Darwin)
                let sent = Darwin.send(connection, base + offset, raw.count - offset, flags)
                #else
                let sent = Glibc.send(connection, base + offset, raw.count - offset, flags)
                #endif
                if sent < 0, errno == EINTR { continue }
                guard sent > 0 else { return false }
                offset += sent
            }
            return true
        }
    }
}
