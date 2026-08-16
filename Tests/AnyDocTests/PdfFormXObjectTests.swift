import Testing

@testable import AnyDoc

/// Form XObjects inlined into the operation stream.
@Suite struct PdfFormXObjectTests {
    private func operation(_ name: String, _ operands: [PdfObject] = []) -> PdfOperation {
        PdfOperation(operator: name, operands: operands)
    }

    @Test func fontOperandsAreNamespaced() {
        // A `/F1` inside a form must not pick up the page's `/F1`, which
        // would silently apply the wrong glyph widths to every run.
        let renamed = pdfRenameFontOperands(
            [
                operation("Tf", [.name(Array("F1".utf8)), .integer(12)]),
                operation("Tj", [.name(Array("F1".utf8))]),
            ], namespace: "\u{1}X0")
        #expect(renamed[0].operands[0].asName == Array("\u{1}X0\u{1}F1".utf8))
        // Only `Tf` operands are rewritten — a name meaning something else
        // is left alone.
        #expect(renamed[1].operands[0].asName == Array("F1".utf8))
    }

    @Test func aFormNeverInheritsThePagesFonts() {
        // The specification says it should. The reference's `get_form_fonts`
        // returns nothing when a form declares no `/Resources` and never
        // consults the page, so those runs get no metrics and a zero
        // advance. Namespacing every name reproduces that.
        let renamed = pdfRenameFontOperands(
            [operation("Tf", [.name(Array("F1".utf8)), .integer(12)])],
            namespace: "\u{1}X0")
        #expect(renamed[0].operands[0].asName == Array("\u{1}X0\u{1}F1".utf8))
    }

    @Test func theNestingLimitIsFive() {
        // A form may invoke another; a document may make that a cycle.
        #expect(pdfMaxFormXObjectDepth == 5)
    }
}
