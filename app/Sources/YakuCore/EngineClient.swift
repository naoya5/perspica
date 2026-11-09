import Foundation

public enum EngineError: Error, Equatable {
    case notHTTP
    case httpStatus(Int)
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
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
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
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
