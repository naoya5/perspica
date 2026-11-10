import Foundation
import Testing
@testable import YakuCore

@Suite("PDF progress coalescing")
struct PDFProgressGateTests {
    @Test("small updates accumulate against the last published value")
    func accumulatedProgress() {
        var gate = PDFProgressGate()
        #expect(gate.accepts(value: 0, stage: "Translate"))
        #expect(!gate.accepts(value: 0.004, stage: "Translate"))
        #expect(!gate.accepts(value: 0.008, stage: "Translate"))
        #expect(gate.accepts(value: 0.012, stage: "Translate"))
        #expect(!gate.accepts(value: 0.013, stage: "Translate"))
    }

    @Test("stage changes and completion publish, invalid and duplicate values do not")
    func stageAndCompletion() {
        var gate = PDFProgressGate()
        #expect(gate.accepts(value: 0.995, stage: "Translate"))
        #expect(gate.accepts(value: 0.995, stage: "Save"))
        #expect(gate.accepts(value: 1, stage: "Save"))
        #expect(!gate.accepts(value: 1, stage: "Save"))
        #expect(!gate.accepts(value: .nan, stage: "Save"))
    }
}

@Suite("PDF output names")
struct PDFOutputNameTests {
    @Test("the mono name is the original name plus .ja.pdf")
    func monoName() {
        #expect(PDFOutputName.mono(forInput: "attention.pdf") == "attention.ja.pdf")
        #expect(PDFOutputName.mono(forInput: "論文 2024.pdf") == "論文 2024.ja.pdf")
    }

    @Test("the dual name is the original name plus .ja.対訳.pdf")
    func dualName() {
        #expect(PDFOutputName.dual(forInput: "attention.pdf") == "attention.ja.対訳.pdf")
    }

    @Test("only the last extension is dropped")
    func multiDotName() {
        #expect(PDFOutputName.mono(forInput: "paper.v2.final.pdf") == "paper.v2.final.ja.pdf")
    }

    @Test("a name without an extension is kept as it is")
    func noExtension() {
        #expect(PDFOutputName.mono(forInput: "attention") == "attention.ja.pdf")
    }

    @Test("a free name is used unchanged")
    func uniqueFreeName() {
        let name = PDFOutputName.unique(preferred: "attention.ja.pdf") { _ in false }
        #expect(name == "attention.ja.pdf")
    }

    @Test("a taken name gets (2) before the extension")
    func uniqueTakenName() {
        let taken: Set<String> = ["attention.ja.pdf"]
        let name = PDFOutputName.unique(preferred: "attention.ja.pdf") { taken.contains($0) }
        #expect(name == "attention.ja (2).pdf")
    }

    @Test("further collisions count up")
    func uniqueCounting() {
        let taken: Set<String> = ["attention.ja.pdf", "attention.ja (2).pdf", "attention.ja (3).pdf"]
        let name = PDFOutputName.unique(preferred: "attention.ja.pdf") { taken.contains($0) }
        #expect(name == "attention.ja (4).pdf")
    }

    @Test("the dual name collides independently of the mono name")
    func uniqueDual() {
        let taken: Set<String> = ["attention.ja.対訳.pdf"]
        let name = PDFOutputName.unique(preferred: PDFOutputName.dual(forInput: "attention.pdf")) {
            taken.contains($0)
        }
        #expect(name == "attention.ja.対訳 (2).pdf")
    }
}

@Suite("PDF stages")
struct PDFStageTests {
    @Test("the five BabelDOC stages map onto the Japanese names")
    func knownStages() {
        #expect(PDFStage.japaneseName(for: "Translate Paragraphs") == "段落を翻訳中")
        #expect(PDFStage.japaneseName(for: "Parse Page Layout") == "レイアウトを解析中")
        #expect(PDFStage.japaneseName(for: "Typesetting") == "PDF を書き出し中")
        #expect(PDFStage.japaneseName(for: "Save PDF") == "PDF を書き出し中")
        #expect(PDFStage.japaneseName(for: "Subset font") == "PDF を書き出し中")
        #expect(
            PDFStage.japaneseName(for: "Parse PDF and Create Intermediate Representation")
                == "PDF を読み込み中"
        )
    }

    @Test("an empty stage is the preparation step")
    func emptyStage() {
        #expect(PDFStage.japaneseName(for: "") == "準備中")
    }

    @Test("an unknown stage falls back to 処理中")
    func unknownStage() {
        #expect(PDFStage.japaneseName(for: "Zzz") == "処理中")
    }
}

@Suite("PDF worker lines")
struct PDFWorkerLineTests {
    @Test("a progress line is read with its stage")
    func progressLine() {
        let event = PDFWorkerLine.parse(#"{"type":"progress","progress":0.42,"stage":"Translate Paragraphs"}"#)
        #expect(event == .progress(value: 0.42, stage: "Translate Paragraphs"))
    }

    @Test("a whole-number progress value is accepted")
    func integerProgress() {
        let event = PDFWorkerLine.parse(#"{"type":"progress","progress":1,"stage":"Save PDF"}"#)
        #expect(event == .progress(value: 1, stage: "Save PDF"))
    }

    @Test("a progress line without a stage still parses")
    func progressWithoutStage() {
        let event = PDFWorkerLine.parse(#"{"type":"progress","progress":0.1}"#)
        #expect(event == .progress(value: 0.1, stage: ""))
    }

    @Test("a done line carries both output paths and the seconds")
    func doneLine() {
        let line = #"{"type":"done","mono":"/tmp/a.ja.pdf","dual":"/tmp/a.ja.対訳.pdf","seconds":96.4}"#
        #expect(
            PDFWorkerLine.parse(line)
                == .done(mono: "/tmp/a.ja.pdf", dual: "/tmp/a.ja.対訳.pdf", seconds: 96.4)
        )
    }

    @Test("an error line carries the message")
    func errorLine() {
        let event = PDFWorkerLine.parse(#"{"type":"error","message":"engine unreachable"}"#)
        #expect(event == .error(message: "engine unreachable"))
    }

    @Test("an error line without a message still parses")
    func errorWithoutMessage() {
        #expect(PDFWorkerLine.parse(#"{"type":"error"}"#) == .error(message: "unknown error"))
    }

    @Test("blank lines and non-JSON lines are ignored")
    func ignoredLines() {
        #expect(PDFWorkerLine.parse("") == nil)
        #expect(PDFWorkerLine.parse("   ") == nil)
        #expect(PDFWorkerLine.parse("INFO: something") == nil)
        #expect(PDFWorkerLine.parse("[]") == nil)
    }

    @Test("an unknown event type is ignored rather than reported")
    func unknownType() {
        #expect(PDFWorkerLine.parse(#"{"type":"heartbeat"}"#) == nil)
    }

    @Test("surrounding whitespace does not stop a line from parsing")
    func whitespaceTolerated() {
        let event = PDFWorkerLine.parse("  {\"type\":\"error\",\"message\":\"x\"}  \n")
        #expect(event == .error(message: "x"))
    }
}

@Suite("PDF worker line splitting")
struct LineSplitterTests {
    @Test("a line split across two reads arrives whole")
    func splitAcrossReads() {
        let splitter = LineSplitter()
        #expect(splitter.feed(Data(#"{"type":"pro"#.utf8)).isEmpty)
        let lines = splitter.feed(Data(#"gress","progress":0.5,"stage":"x"}"#.utf8) + Data([0x0A]))
        #expect(lines == [#"{"type":"progress","progress":0.5,"stage":"x"}"#])
    }

    @Test("several lines in one read come back in order")
    func severalLines() {
        let splitter = LineSplitter()
        #expect(splitter.feed(Data("one\ntwo\nthree\n".utf8)) == ["one", "two", "three"])
    }

    @Test("a multi-byte character split across reads survives")
    func splitMultibyte() {
        let splitter = LineSplitter()
        let bytes = Array("あ\n".utf8)
        #expect(splitter.feed(Data(bytes[0..<2])).isEmpty)
        #expect(splitter.feed(Data(bytes[2...])) == ["あ"])
    }
}
