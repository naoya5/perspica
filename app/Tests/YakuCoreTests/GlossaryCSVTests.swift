import Foundation
import Testing
@testable import YakuCore

@Suite("Glossary CSV")
struct GlossaryCSVTests {
    @Test("round trip keeps source, target and enabled")
    func roundTrip() {
        let rows = [
            GlossaryCSV.Row(source: "Attention", target: "アテンション", enabled: true),
            GlossaryCSV.Row(source: "Transformer", target: "Transformer", enabled: false),
        ]
        let text = GlossaryCSV.encode(rows)
        #expect(text.hasPrefix("source,target,enabled\n"))
        #expect(GlossaryCSV.parse(text) == rows)
    }

    @Test("fields with a comma, a quote or a newline survive")
    func quoting() {
        let rows = [
            GlossaryCSV.Row(source: "a,b", target: "say \"hi\"", enabled: true),
            GlossaryCSV.Row(source: "two\nlines", target: "x", enabled: false),
        ]
        let parsed = GlossaryCSV.parse(GlossaryCSV.encode(rows))
        #expect(parsed.count == 2)
        #expect(parsed[0].source == "a,b")
        #expect(parsed[0].target == "say \"hi\"")
        #expect(parsed[1].source == "two\nlines")
        #expect(parsed[1].enabled == false)
    }

    @Test("the header is optional and empty sources are dropped")
    func headerAndEmpty() {
        let withHeader = GlossaryCSV.parse("source,target,enabled\nAttention,アテンション,true\n")
        #expect(withHeader.map(\.source) == ["Attention"])

        let withoutHeader = GlossaryCSV.parse("Attention,アテンション\n")
        #expect(withoutHeader.map(\.source) == ["Attention"])
        #expect(withoutHeader[0].enabled)

        let emptySource = GlossaryCSV.parse("source,target,enabled\n,アテンション,true\n")
        #expect(emptySource.isEmpty)
    }

    @Test("enabled understands several spellings and defaults to true")
    func enabledSpellings() {
        #expect(GlossaryCSV.parse("a,b,false")[0].enabled == false)
        #expect(GlossaryCSV.parse("a,b,0")[0].enabled == false)
        #expect(GlossaryCSV.parse("a,b,no")[0].enabled == false)
        #expect(GlossaryCSV.parse("a,b,無効")[0].enabled == false)
        #expect(GlossaryCSV.parse("a,b,yes")[0].enabled)
        #expect(GlossaryCSV.parse("a,b,true")[0].enabled)
        #expect(GlossaryCSV.parse("a,b")[0].enabled)
    }

    @Test("CRLF line endings are accepted")
    func crlf() {
        let rows = GlossaryCSV.parse("source,target,enabled\r\nAttention,アテンション,true\r\n")
        #expect(rows.map(\.source) == ["Attention"])
        #expect(rows[0].target == "アテンション")
        #expect(rows[0].enabled)
    }

    @Test("a lone CR also ends a line")
    func carriageReturnOnly() {
        let rows = GlossaryCSV.parse("Attention,アテンション\rTransformer,Transformer")
        #expect(rows.map(\.source) == ["Attention", "Transformer"])
    }

    @Test("a file with only a header parses to nothing")
    func headerOnly() {
        #expect(GlossaryCSV.parse("source,target,enabled\n").isEmpty)
    }
}
