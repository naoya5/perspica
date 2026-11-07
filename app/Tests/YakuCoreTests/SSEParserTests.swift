import Foundation
import Testing
@testable import YakuCore

@Suite("SSEParser")
struct SSEParserTests {
    private func data(_ payload: String) -> SSEParser.Event { .data(payload) }

    @Test("reads one data line per newline")
    func oneLinePerNewline() {
        var parser = SSEParser()
        let events = parser.feed("data: {\"a\":1}\ndata: [DONE]\n")
        #expect(events == [data("{\"a\":1}"), .done])
    }

    @Test("a line split across chunks is only emitted when it is complete")
    func splitLine() {
        var parser = SSEParser()
        #expect(parser.feed("data: {\"cho") == [])
        #expect(parser.feed("ices\":[]}") == [])
        #expect(parser.feed("\n") == [data("{\"choices\":[]}")])
    }

    @Test("a multi-byte character split across chunks survives")
    func splitMultibyte() {
        let line = Array("data: あ\n".utf8)
        var parser = SSEParser()
        // Cut in the middle of the three UTF-8 bytes of あ.
        #expect(parser.feed(Array(line[0..<7])) == [])
        #expect(parser.feed(Array(line[7...])) == [data("あ")])
    }

    @Test("carriage returns are tolerated")
    func carriageReturns() {
        var parser = SSEParser()
        #expect(parser.feed("data: hello\r\n") == [data("hello")])
    }

    @Test("a final line without a newline is flushed by finish()")
    func finishFlush() {
        var parser = SSEParser()
        #expect(parser.feed("data: tail") == [])
        #expect(parser.finish() == [data("tail")])
        #expect(parser.finish() == [])
    }

    @Test("blank lines, comments and other fields are ignored")
    func ignoredLines() {
        var parser = SSEParser()
        let events = parser.feed("\n: keep-alive\nevent: message\nid: 3\ndata:\n")
        #expect(events == [])
    }

    @Test("extracts choices[0].text")
    func extractsText() {
        let payload = #"{"choices":[{"text":"こんに","index":0}]}"#
        #expect(SSEParser.text(fromJSON: payload) == "こんに")
    }

    @Test("returns nil when there is no text")
    func noText() {
        #expect(SSEParser.text(fromJSON: #"{"choices":[]}"#) == nil)
        #expect(SSEParser.text(fromJSON: "not json") == nil)
    }
}
