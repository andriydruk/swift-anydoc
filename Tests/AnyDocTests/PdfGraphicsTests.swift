import Testing

@testable import AnyDoc

/// The path walker's own behaviour, including the parts the differential
/// probe cannot see: the reference keeps `painted_rects` to itself for
/// underline detection, so it is pinned here.
@Suite struct PdfGraphicsTests {
    private func graphics(_ content: String) -> PdfPageGraphics {
        pdfExtractGraphics(pdfParseContentStream(Array(content.utf8)))
    }

    @Test func rectanglesAreRecordedWhetherOrNotTheyArePainted() {
        let result = graphics("10 20 30 40 re f 50 60 70 80 re W n")
        #expect(
            result.rectangles == [
                PdfRect(x: 10, y: 20, width: 30, height: 40),
                PdfRect(x: 50, y: 60, width: 70, height: 80),
            ])
        // Only the filled one put ink on the page. The clip-only rectangle
        // must never reach underline detection.
        #expect(result.paintedRectangles == [PdfRect(x: 10, y: 20, width: 30, height: 40)])
    }

    /// `n` discards the path, so a rectangle that only ever clipped is not
    /// confirmed even though it was seen.
    @Test func endPathDiscardsPendingRectangles() {
        let result = graphics("10 20 30 40 re n")
        #expect(result.rectangles.count == 1)
        #expect(result.paintedRectangles.isEmpty)
    }

    @Test func theTransformAppliesToRectanglesAndStrokes() {
        let result = graphics("q 2 0 0 2 10 20 cm 5 5 10 10 re f Q")
        #expect(result.rectangles == [PdfRect(x: 20, y: 30, width: 20, height: 20)])
    }

    @Test func strokedSegmentsBecomeLines() {
        let result = graphics("2 w 10 10 m 110 10 l S")
        #expect(result.lines.count == 1)
        let line = try! #require(result.lines.first)
        #expect(line.x1 == 10)
        #expect(line.x2 == 110)
        #expect(line.strokeWidth == 2)
    }

    /// Stroke width is measured perpendicular to the path, so an anisotropic
    /// transform widens a horizontal rule and a vertical one differently.
    @Test func strokeWidthFollowsThePerpendicular() {
        let horizontal = graphics("q 1 0 0 3 0 0 cm 2 w 0 0 m 100 0 l S Q")
        let vertical = graphics("q 1 0 0 3 0 0 cm 2 w 0 0 m 0 100 l S Q")
        #expect(try! #require(horizontal.lines.first).strokeWidth == 6)
        #expect(try! #require(vertical.lines.first).strokeWidth == 2)
    }

    /// `h` moves the closed subpath aside and `S` then drains an empty
    /// pending list, so a closed stroked subpath emits **no** lines. That is
    /// the reference's behaviour, confirmed against it, and is reproduced
    /// rather than corrected.
    @Test func aClosedSubpathStrokesNothing() {
        let open = graphics("0 0 m 100 0 l 100 100 l S")
        #expect(open.lines.count == 2)
        let closed = graphics("0 0 m 100 0 l 100 100 l h S")
        #expect(closed.lines.isEmpty, "the reference loses these too")
    }

    @Test func filledSubpathsYieldRectangles() {
        let result = graphics("100 700 m 300 700 l 300 720 l 100 720 l h f")
        #expect(result.filledRectangles == [PdfRect(x: 100, y: 700, width: 200, height: 20)])
        // A quadrilateral that is not axis-aligned is not a rectangle.
        let skewed = graphics("100 600 m 300 610 l 290 640 l 110 630 l h f")
        #expect(skewed.filledRectangles.isEmpty)
    }

    @Test func clipPathsAreKeptSeparately() {
        let result = graphics("100 700 m 300 700 l 300 720 l 100 720 l h W n")
        #expect(result.clipRectangles == [PdfRect(x: 100, y: 700, width: 200, height: 20)])
        #expect(result.filledRectangles.isEmpty)
        #expect(result.paintedRectangles.isEmpty)
    }

    // MARK: selection

    @Test func explicitRectanglesWinOutright() {
        var page = PdfPageGraphics()
        page.rectangles = [PdfRect(x: 1, y: 1, width: 10, height: 10)]
        page.filledRectangles = [PdfRect(x: 2, y: 2, width: 10, height: 10)]
        #expect(pdfSelectedRectangles(page) == page.rectangles)
    }

    /// Fills that clearly outnumber clips are the real content; the clips are
    /// section wrappers.
    @Test func fillsWinWhenTheyOutnumberClips() {
        var page = PdfPageGraphics()
        page.clipRectangles = [PdfRect(x: 0, y: 0, width: 100, height: 100)]
        page.filledRectangles = (0..<3).map {
            PdfRect(x: Float($0), y: 0, width: 10, height: 10)
        }
        #expect(pdfSelectedRectangles(page) == page.filledRectangles)
    }

    @Test func clipsWinWhenThereAreEnoughOfThem() {
        var page = PdfPageGraphics()
        page.clipRectangles = (0..<4).map {
            PdfRect(x: Float($0) * 20, y: 0, width: 10, height: 10)
        }
        #expect(pdfSelectedRectangles(page).count == 4)
    }

    /// Deduplication also sorts, so the survivors come back in coordinate
    /// order rather than document order.
    @Test func deduplicationCollapsesNearDuplicatesAndSorts() {
        let rectangles = [
            PdfRect(x: 50, y: 0, width: 10, height: 10),
            PdfRect(x: 10, y: 0, width: 10, height: 10),
            PdfRect(x: 10.2, y: 0, width: 10, height: 10),
        ]
        let deduped = pdfDedupRectangles(rectangles)
        #expect(deduped.count == 2)
        #expect(deduped.first?.x == 10)
        #expect(deduped.last?.x == 50)
    }
}
