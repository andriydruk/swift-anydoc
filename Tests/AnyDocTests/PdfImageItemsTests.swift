import Testing

@testable import AnyDoc

/// Image placeholders and the box they carry.
///
/// The corpus checks these end to end — six documents whose item dumps match
/// the reference's, including one whose image is nested inside a Form
/// XObject. These pin the geometry, which a corpus of upright images cannot.
@Suite struct PdfImageItemsTests {
    /// A `Do` paints the **unit square** through the current transform, so
    /// the box is those four corners transformed and bounded.
    @Test func anUprightImageTakesItsScaleAndOffset() {
        let box = pdfImageBoundingBox((400, 0, 0, 300, 72, 500))
        #expect(box.x == 72)
        #expect(box.y == 500)
        #expect(box.width == 400)
        #expect(box.height == 300)
    }

    /// A negative scale is how a producer flips an image, and it is common.
    /// Taking two corners instead of four would give a negative width here.
    @Test func aFlippedImageStillHasAPositiveBox() {
        let box = pdfImageBoundingBox((-400, 0, 0, -300, 472, 800))
        #expect(box.x == 72)
        #expect(box.y == 500)
        #expect(box.width == 400)
        #expect(box.height == 300)
    }

    /// A rotation puts no corner at the box's corner, which is the case that
    /// makes the four-corner bound necessary rather than tidy.
    @Test func aRotatedImageIsBoundedByItsExtremes() {
        // 90°: (x,y) → (-y, x), scaled by 200 and 100.
        let box = pdfImageBoundingBox((0, 200, -100, 0, 300, 400))
        #expect(box.x == 200)
        #expect(box.y == 400)
        #expect(box.width == 100)
        #expect(box.height == 200)
    }

    /// A degenerate transform gives a zero box rather than a negative or
    /// infinite one — a malformed document must not poison the layout.
    @Test func aCollapsedTransformGivesAnEmptyBox() {
        let box = pdfImageBoundingBox((0, 0, 0, 0, 100, 200))
        #expect(box.width == 0)
        #expect(box.height == 0)
        #expect(box.x == 100)
        #expect(box.y == 200)
    }

    /// The placeholder's text is the reference's `[Image: Name]` form, which
    /// its Markdown emitter recognises and strips when rendering figures.
    @Test func thePlaceholderNamesTheXObject() {
        let operations = pdfParseContentStream(
            Array("q 400 0 0 300 72 500 cm /Im0 Do Q\n".utf8))
        let runs = pdfExtractTextRuns(
            operations, imageNames: [Array("Im0".utf8)], metrics: { _ in nil }) { _, _ in "" }
        #expect(runs.count == 1)
        #expect(runs.first?.text == "[Image: Im0]")
        #expect(runs.first?.isImage == true)
        #expect(runs.first?.fontSize == 0)
        #expect(runs.first?.width == 400)
        #expect(runs.first?.height == 300)
    }

    /// A `Do` naming something that is not a declared image produces
    /// nothing. Without the check a form left un-inlined, or a typo in a
    /// content stream, would become a phantom figure.
    @Test func anUndeclaredNameDrawsNothing() {
        let operations = pdfParseContentStream(
            Array("q 400 0 0 300 72 500 cm /Missing Do Q\n".utf8))
        let runs = pdfExtractTextRuns(
            operations, imageNames: [Array("Im0".utf8)], metrics: { _ in nil }) { _, _ in "" }
        #expect(runs.isEmpty)
    }
}
