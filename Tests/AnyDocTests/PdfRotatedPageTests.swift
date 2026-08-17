import Testing

@testable import AnyDoc

/// Squaring up a page whose text is drawn sideways.
///
/// `rotated-text-page.pdf` covers it end to end — without the correction the
/// page's lines run together with no spaces at all. These pin the vote, the
/// axis mapping, and the width estimate, none of which one document
/// separates.
@Suite struct PdfRotatedPageTests {
    private func item(_ text: String, x: Float, y: Float, rotated: Bool, width: Float = 0)
        -> PdfLayoutItem
    {
        var built = PdfLayoutItem(
            text: text, x: x, y: y, width: width, fontSize: 12, fontName: "F1")
        built.isRotated = rotated
        return built
    }

    /// A page is rotated only when about two thirds of its text is. Swapping
    /// on a minority would scramble the majority.
    @Test func theVoteNeedsATwoThirdsMajority() {
        let rotated = { (count: Int, total: Int) -> Bool in
            var items = (0..<count).map { self.item("a", x: Float($0), y: 0, rotated: true) }
            items += (0..<(total - count)).map {
                self.item("b", x: Float($0), y: 0, rotated: false)
            }
            return pdfPageTextIsRotated(items)
        }
        #expect(rotated(6, 6))
        #expect(rotated(4, 6))  // exactly two thirds
        #expect(!rotated(3, 6))
        #expect(!rotated(1, 6))
    }

    /// One run is no evidence about a page.
    @Test func aSingleItemIsNeverEnough() {
        #expect(!pdfPageTextIsRotated([item("a", x: 0, y: 0, rotated: true)]))
        #expect(!pdfPageTextIsRotated([]))
    }

    /// Increasing device x is visually *down*, so it becomes negated y — the
    /// layout engine sorts by descending y and must see the visual top first.
    @Test func theAxesSwapWithXNegated() {
        var items = [item("a", x: 100, y: 300, rotated: true, width: 20)]
        pdfCorrectRotatedItems(&items)
        #expect(items[0].x == 300)
        #expect(items[0].y == -100)
        // A measured width is left alone.
        #expect(items[0].width == 20)
    }

    /// Rotated text loses its width — the advance runs along an axis that
    /// now points down — and without a width the word joiner has no gap to
    /// reason about, so a page's lines run together with no spaces. That is
    /// exactly what the corpus document shows.
    @Test func aLostWidthIsEstimatedFromTheText() {
        var items = [item("Hello", x: 0, y: 0, rotated: true, width: 0)]
        pdfCorrectRotatedItems(&items)
        #expect(items[0].width == 5 * 12 * 0.5)
    }

    /// A rectangle's anchor corner moves when the box turns, so the far edge
    /// is what maps — and the extents exchange places.
    @Test func rectanglesTakeTheirFarEdge() {
        var rects = [PdfRect(x: 100, y: 300, width: 40, height: 10)]
        pdfCorrectRotatedRects(&rects)
        #expect(rects[0].x == 300)
        #expect(rects[0].y == -140)
        #expect(rects[0].width == 10)
        #expect(rects[0].height == 40)
    }

    /// A negative width is still a real extent, so the far edge uses its
    /// magnitude rather than adding a negative number.
    @Test func aBackwardsRectangleStillMapsForwards() {
        var rects = [PdfRect(x: 100, y: 300, width: -40, height: 10)]
        pdfCorrectRotatedRects(&rects)
        #expect(rects[0].y == -140)
    }

    /// A segment is two points and needs no extent bookkeeping.
    @Test func segmentsMapBothEndpoints() {
        var lines = [PdfLineSegment(x1: 10, y1: 20, x2: 30, y2: 40, strokeWidth: 1)]
        pdfCorrectRotatedLines(&lines)
        #expect(lines[0].x1 == 20)
        #expect(lines[0].y1 == -10)
        #expect(lines[0].x2 == 40)
        #expect(lines[0].y2 == -30)
    }
}
