import Testing

@testable import AnyDoc

/// Annotations in the pipeline: form-field values are text, hyperlinks are
/// not.
@Suite struct PdfAnnotationPipelineTests {
    @Test func anAnnotationBecomesAWeightlessItem() {
        // Font size zero and no font name, as the reference sets them: these
        // are not glyphs anyone drew, and giving them a size would let them
        // vote in the document's body-size statistics and skew every
        // heading ratio measured against it.
        let item = pdfAnnotationLayoutItem(
            PdfAnnotationItem(
                text: "address.city: Lisbon", x: 100, y: 600, width: 200, height: 20,
                page: 1, kind: .formField))
        #expect(item.fontSize == 0)
        #expect(item.fontName.isEmpty)
        #expect(item.text == "address.city: Lisbon")
        #expect(item.height == 20)
    }

    @Test func aFieldValueCarriesItsQualifiedName() {
        // The name is qualified by its ancestors, so a field under a group
        // reads `address.city` — which is what makes the emitted line
        // meaningful without the form's structure.
        let item = pdfAnnotationLayoutItem(
            PdfAnnotationItem(
                text: "address.city: Lisbon", x: 0, y: 0, width: 0, height: 0, page: 1,
                kind: .formField))
        #expect(item.text.hasPrefix("address.city:"))
    }
}
