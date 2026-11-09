import Foundation
import Testing
@testable import YakuCore

/// Serves a canned SSE body so `EngineClient` can be exercised without an engine.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var chunks: [Data] = []
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    static func reset(status: Int = 200, chunks: [Data]) {
        statusCode = status
        self.chunks = chunks
        lastRequest = nil
        lastBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.bodyStreamData()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in Self.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private extension URLRequest {
    /// `URLSession` turns `httpBody` into a stream before it reaches a URLProtocol.
    func bodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return data
    }
}

@Suite("EngineClient", .serialized)
struct EngineClientTests {
    private func makeClient() -> EngineClient {
        EngineClient(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            apiKey: "secret-key",
            session: StubURLProtocol.makeSession()
        )
    }

    private func sse(_ pieces: [String]) -> Data {
        var text = ""
        for piece in pieces {
            let payload = #"{"choices":[{"text":"\#(piece)","index":0}]}"#
            text += "data: \(payload)\n\n"
        }
        text += "data: [DONE]\n\n"
        return Data(text.utf8)
    }

    @Test("streams the text pieces in order and finishes at [DONE]")
    func streamsPieces() async throws {
        StubURLProtocol.reset(chunks: [sse(["こんに", "ちは。", "世界。"])])

        var received = ""
        for try await piece in makeClient().stream(CompletionRequest(prompt: "P", maxTokens: 256)) {
            received += piece
        }
        #expect(received == "こんにちは。世界。")
    }

    @Test("a piece split across two network chunks still arrives whole")
    func splitChunk() async throws {
        let body = sse(["分割", "された"])
        let middle = body.count / 2
        StubURLProtocol.reset(chunks: [body.prefix(middle), body.suffix(body.count - middle)])

        var received = ""
        for try await piece in makeClient().stream(CompletionRequest(prompt: "P", maxTokens: 256)) {
            received += piece
        }
        #expect(received == "分割された")
    }

    @Test("sends the bearer token, the JSON content type and the PFML3 body")
    func requestShape() async throws {
        StubURLProtocol.reset(chunks: [sse(["x"])])
        let request = CompletionRequest(prompt: "<|plamo:tag|>dataset", source: "hello")
        _ = try await makeClient().stream(request).reduce(into: "") { $0 += $1 }

        let sent = try #require(StubURLProtocol.lastRequest)
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(sent.url?.path == "/v1/completions")

        let body = try #require(StubURLProtocol.lastBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["prompt"] as? String == "<|plamo:tag|>dataset")
        #expect(object["stream"] as? Bool == true)
    }

    @Test("a non-200 response throws")
    func httpError() async {
        StubURLProtocol.reset(status: 503, chunks: [Data()])
        await #expect(throws: EngineError.httpStatus(503)) {
            for try await _ in makeClient().stream(CompletionRequest(prompt: "P", maxTokens: 256)) {}
        }
    }

    @Test("the default session keeps no response on disk or in memory")
    func defaultSessionHasNoCache() {
        let configuration = EngineClient.privateSession.configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test("health is true only for 200")
    func health() async {
        StubURLProtocol.reset(status: 200, chunks: [Data("{}".utf8)])
        #expect(await makeClient().health() == true)

        StubURLProtocol.reset(status: 503, chunks: [Data("{}".utf8)])
        #expect(await makeClient().health() == false)
    }

    @Test("cancelling the consumer cancels the request")
    func cancellation() async throws {
        StubURLProtocol.reset(chunks: [sse(["a", "b", "c"])])
        let stream = makeClient().stream(CompletionRequest(prompt: "P", maxTokens: 256))

        let task = Task { () -> String in
            var received = ""
            for try await piece in stream {
                received += piece
                if received == "a" { break }
            }
            return received
        }
        #expect(try await task.value == "a")
    }
}
