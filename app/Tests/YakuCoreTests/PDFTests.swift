import Foundation
import Testing
@testable import YakuCore

@Suite("PDF progress coalescing")
struct PDFProgressGateTests {
    @Test("small updates accumulate against the last published value")
    func accumulatedProgress() {
        var gate = PDFProgressGate()
        let results = [0, 0.004, 0.008, 0.012, 0.013].map { gate.accepts(value: $0, stage: "Translate") }
        #expect(results == [true, false, false, true, false])
    }

    @Test("stage changes and completion publish, invalid and duplicate values do not")
    func stageAndCompletion() {
        var gate = PDFProgressGate()
        let steps: [(Double, String)] = [(0.995, "Translate"), (0.995, "Save"), (1, "Save"), (1, "Save"), (.nan, "Save")]
        let results = steps.map { gate.accepts(value: $0.0, stage: $0.1) }
        #expect(results == [true, true, true, false, false])
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
    @Test("the translator's stage names show as they are")
    func knownStages() {
        for stage in [PDFStage.preparing, PDFStage.reading, PDFStage.layout, PDFStage.translating, PDFStage.writing] {
            #expect(PDFStage.displayName(for: stage) == stage)
        }
    }

    @Test("an empty stage is the preparation step")
    func emptyStage() {
        #expect(PDFStage.displayName(for: "") == "準備中")
    }

    @Test("a stage saved by an older version falls back to 処理中")
    func unknownStage() {
        #expect(PDFStage.displayName(for: "Translate Paragraphs") == "処理中")
    }
}
