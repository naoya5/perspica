import Foundation

public enum EngineError: Error, Equatable {
    case notHTTP
    case httpStatus(Int)
    /// The response ended before `data: [DONE]`: the connection dropped or
    /// the server stopped, so the text so far is not the whole answer.
    case incomplete
}

/// Talks to one llama-server instance over localhost. The API key is generated
/// per engine launch, so the client is rebuilt whenever the engine restarts.
public struct EngineClient: Sendable {
    public let baseURL: URL
    public let apiKey: String
    public let model: String
    private let session: URLSession

    /// `URLSession.shared` writes every response, the streamed translation
    /// included, to `~/Library/Caches/<app>/Cache.db`, where 「履歴とキャッシュを
    /// 消す」 never reaches it.
    public static let privateSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    public init(
        baseURL: URL,
        apiKey: String,
        model: String = "plamo-3-translate",
        session: URLSession = EngineClient.privateSession
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    /// `GET /health` returns 200 once the model is loaded (503 while loading).
    public func health(timeout: TimeInterval = 1) async -> Bool {
        await healthStatus(timeout: timeout) == 200
    }

    /// The HTTP status `GET /health` answered with, or nil when the server did
    /// not answer at all (not listening yet, or gone). llama-server says 503
    /// while the model is still loading and 200 once it can serve requests.
    public func healthStatus(timeout: TimeInterval = 1) async -> Int? {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode
        } catch {
            return nil
        }
    }

    /// Like `healthStatus`, but tells a closed port apart from a slow answer.
    public func healthProbe(timeout: TimeInterval) async -> EngineHealthProbe {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await session.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else { return .timedOut }
            return .status(status)
        } catch let error as URLError where error.code == .cannotConnectToHost {
            return .refused
        } catch {
            return .timedOut
        }
    }

    /// Streams `choices[0].text` pieces as they arrive. Cancelling the task
    /// closes the connection, which makes llama-server stop generating.
    public func stream(_ completion: CompletionRequest) -> AsyncThrowingStream<String, Error> {
        let client = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: client.baseURL.appendingPathComponent("v1/completions"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(client.apiKey)", forHTTPHeaderField: "Authorization")
                    request.httpBody = try completion.body(model: client.model)
                    request.timeoutInterval = 180

                    let (bytes, response) = try await client.session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw EngineError.notHTTP
                    }
                    guard http.statusCode == 200 else {
                        throw EngineError.httpStatus(http.statusCode)
                    }

                    var parser = SSEParser()
                    var chunk: [UInt8] = []
                    chunk.reserveCapacity(1024)

                    // The parser is fed whole chunks including the newline that
                    // ends each line, so it can buffer a partial line itself.
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        chunk.append(byte)
                        guard byte == 0x0A else { continue }
                        for event in parser.feed(chunk) {
                            if client.handle(event, continuation) { return }
                        }
                        chunk.removeAll(keepingCapacity: true)
                    }

                    if !chunk.isEmpty {
                        for event in parser.feed(chunk) {
                            if client.handle(event, continuation) { return }
                        }
                    }
                    for event in parser.finish() {
                        if client.handle(event, continuation) { return }
                    }
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: EngineError.incomplete)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The engine's exact token count for a prompt (`POST /tokenize`), with
    /// the BOS the server adds to a completion and PFML3's special tokens
    /// parsed as single tokens, as `/v1/completions` does.
    public func tokenCount(_ prompt: String, timeout: TimeInterval = 5) async throws -> Int {
        try await tokenize(prompt, timeout: timeout).count
    }

    /// The token ids `tokenCount` counts.
    public func tokenize(_ prompt: String, timeout: TimeInterval = 5) async throws -> [Int] {
        var request = URLRequest(url: baseURL.appendingPathComponent("tokenize"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "content": prompt,
            "add_special": true,
            "parse_special": true,
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw EngineError.notHTTP }
        guard http.statusCode == 200 else { throw EngineError.httpStatus(http.statusCode) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [Int] else { throw EngineError.notHTTP }
        return tokens
    }

    /// Posts a ready `/v1/completions` body and streams the response bytes as
    /// they come, one SSE line (or at most 16 KB) per piece. Used by the PDF
    /// proxy, which hands the bytes to the worker unchanged. A status other
    /// than 200 is thrown before any piece. With `expectsDone` (a streamed
    /// completion), a body that ends without `data: [DONE]` throws
    /// `EngineError.incomplete` after the bytes it did carry.
    public func rawCompletion(body: Data, expectsDone: Bool) -> AsyncThrowingStream<Data, Error> {
        let client = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: client.baseURL.appendingPathComponent("v1/completions"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(client.apiKey)", forHTTPHeaderField: "Authorization")
                    request.httpBody = body
                    request.timeoutInterval = 180
                    let (bytes, response) = try await client.session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw EngineError.notHTTP }
                    guard http.statusCode == 200 else { throw EngineError.httpStatus(http.statusCode) }
                    var chunk: [UInt8] = []
                    chunk.reserveCapacity(1024)
                    var sawDone = false
                    let doneLine = Array("data: [DONE]".utf8)
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        chunk.append(byte)
                        guard byte == 0x0A || chunk.count >= 16 * 1024 else { continue }
                        if expectsDone, !sawDone, Self.isLine(chunk, doneLine) { sawDone = true }
                        continuation.yield(Data(chunk))
                        chunk.removeAll(keepingCapacity: true)
                    }
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    if !chunk.isEmpty {
                        if expectsDone, !sawDone, Self.isLine(chunk, doneLine) { sawDone = true }
                        continuation.yield(Data(chunk))
                    }
                    if expectsDone, !sawDone {
                        continuation.finish(throwing: EngineError.incomplete)
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// True when `line` is `expected` followed only by `\r` / `\n`.
    static func isLine(_ line: [UInt8], _ expected: [UInt8]) -> Bool {
        var end = line.count
        while end > 0, line[end - 1] == 0x0A || line[end - 1] == 0x0D { end -= 1 }
        return end == expected.count && line[0..<end].elementsEqual(expected)
    }

    /// Returns true when the stream is finished.
    private func handle(
        _ event: SSEParser.Event,
        _ continuation: AsyncThrowingStream<String, Error>.Continuation
    ) -> Bool {
        switch event {
        case .data(let payload):
            if let text = SSEParser.text(fromJSON: payload), !text.isEmpty {
                continuation.yield(text)
            }
            return false
        case .done:
            continuation.finish()
            return true
        }
    }
}
