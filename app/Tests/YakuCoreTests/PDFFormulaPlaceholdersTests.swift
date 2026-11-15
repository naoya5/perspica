import CoreGraphics
import Testing
@testable import YakuCore

@Suite struct PDFFormulaPlaceholdersTests {
    let segments: [PDFTextSegment] = [
        .text("keys of dimension "),
        .formula(text: "dk", bounds: CGRect(x: 0, y: 0, width: 10, height: 8), baseline: 2),
        .text(", values of dimension "),
        .formula(text: "dv", bounds: CGRect(x: 20, y: 0, width: 10, height: 8), baseline: 2),
        .text("."),
    ]

    @Test func sourceNumbersFormulasInOrder() {
        let (text, formulas) = PDFFormulaPlaceholders.source(for: segments)
        #expect(text == "keys of dimension {v0}, values of dimension {v1}.")
        #expect(formulas.count == 2)
    }

    @Test func piecesFollowTheTranslationOrder() {
        let pieces = PDFFormulaPlaceholders.pieces(from: "値の次元は{v1}、キーは{v0}。", formulaCount: 2)
        #expect(pieces == [.text("値の次元は"), .formula(1), .text("、キーは"), .formula(0), .text("。")])
    }

    @Test func missingOrRepeatedTokensAreRejected() {
        #expect(PDFFormulaPlaceholders.pieces(from: "キーは{v0}。", formulaCount: 2) == nil)
        #expect(PDFFormulaPlaceholders.pieces(from: "{v0}と{v0}と{v1}", formulaCount: 2) == nil)
        #expect(PDFFormulaPlaceholders.pieces(from: "{v2}", formulaCount: 2) == nil)
    }

    @Test func noFormulasIsPlainText() {
        #expect(PDFFormulaPlaceholders.pieces(from: "訳文", formulaCount: 0) == [.text("訳文")])
    }

    @Test func aLoneTimesSignTravelsAsText() {
        let box = CGRect(x: 0, y: 0, width: 5, height: 6)
        let segments: [PDFTextSegment] = [.text("pairs of 3"), .formula(text: "×", bounds: box, baseline: 0),
                                          .text(" 3 filters and "), .formula(text: "dk", bounds: box, baseline: 0)]
        let (text, formulas) = PDFFormulaPlaceholders.source(for: segments)
        #expect(text == "pairs of 3× 3 filters and {v0}")
        #expect(formulas.count == 1)
    }

    @Test func plainSourceSpellsFormulasOut() {
        #expect(PDFFormulaPlaceholders.plainSource(for: segments) == "keys of dimension dk, values of dimension dv.")
    }
}

@Suite struct PDFPageListTests {
    @Test func parsesNumbersAndRanges() {
        #expect(PDFPageList.parse("1") == [0])
        #expect(PDFPageList.parse("1,3-5") == [0, 2, 3, 4])
        #expect(PDFPageList.parse(" 2 - 3 ") == [1, 2])
    }

    @Test func rejectsNonsense() {
        #expect(PDFPageList.parse("") == nil)
        #expect(PDFPageList.parse("0,abc,5-3") == nil)
    }
}
