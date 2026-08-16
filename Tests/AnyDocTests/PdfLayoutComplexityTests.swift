import Testing

@testable import AnyDoc

/// Layout complexity, and the band filters it uses.
@Suite struct PdfLayoutComplexityTests {
    /// The band every test below uses: 100…300, so two hundred points wide
    /// and a 70% bar of 140.
    private func rects(_ specs: [(Float, Float)]) -> [Float] {
        pdfFilterRectsToBand(
            specs.map { PdfRect(x: $0.0, y: 10, width: $0.1, height: 10) },
            xLow: 100, xHigh: 300
        ).map(\.x)
    }

    @Test func aNarrowRectangleNeedsOnlyToTouchTheBand() {
        // Under 70% of the band's width, any overlap at all is enough.
        #expect(rects([(95, 20), (99, 20), (100, 20), (290, 20), (150, 100)]).count == 5)
        // No overlap, and the edge case where the overlap is exactly zero.
        #expect(rects([(50, 20)]).isEmpty)
        #expect(rects([(300, 20), (310, 20)]).isEmpty)
    }

    @Test func aWideRectangleMustBeMostlyInside() {
        // At or above 70% of the band, the rectangle needs 70% of *itself*
        // inside — so a page-spanning frame belongs to neither band.
        #expect(rects([(0, 400)]).isEmpty)
        #expect(rects([(0, 200)]).isEmpty)
        #expect(rects([(50, 200), (90, 200)]).count == 2)
        // Either side of the 140-point width that switches the rule.
        #expect(rects([(100, 139)]) == [100])
        #expect(rects([(100, 140)]) == [100])
        #expect(rects([(0, 141)]).isEmpty)
    }

    @Test func aNegativeWidthIsNormalisedFirst() {
        // Drawn right to left: 200 with width −50 spans 150…200.
        #expect(rects([(200, -50)]) == [200])
        #expect(rects([(350, -100)]) == [350])
    }

    @Test func aZeroWidthBandAdmitsNothing() {
        // Every overlap is zero, and no rectangle is narrower than nothing.
        let specs = [(Float(150), Float(20)), (100, 20), (0, 400)]
        #expect(
            pdfFilterRectsToBand(
                specs.map { PdfRect(x: $0.0, y: 10, width: $0.1, height: 10) },
                xLow: 100, xHigh: 100
            ).isEmpty)
    }

    @Test func lineSegmentsUseAPlainOverlapTest() {
        // No proportional rule here: a full-width rule is claimed by every
        // band it crosses. Both bounds are strict.
        let segments = [
            (Float(50), Float(90)), (50, 100), (50, 101), (100, 200), (299, 400),
            (300, 400), (301, 400), (400, 50), (150, 150),
        ].map { PdfLineSegment(x1: $0.0, y1: 10, x2: $0.1, y2: 20, strokeWidth: 1) }
        let kept = pdfFilterLinesToBand(segments, xLow: 100, xHigh: 300).map(\.x1)
        #expect(kept == [50, 100, 299, 400, 150])
    }

    // MARK: - complexity

    private func prose(page: Int, rows: Int, x: Float = 50, y: Float = 700)
        -> [PdfLayoutItem]
    {
        (0..<rows).map {
            PdfLayoutItem(
                text: "a line of ordinary running prose here \($0)", x: x,
                y: y - Float($0) * 14, width: 40, fontSize: 10, fontName: "F1")
        }
    }

    private func grid(page: Int, rows: Int, columns: Int, x: Float = 50) -> [PdfLayoutItem] {
        var items: [PdfLayoutItem] = []
        for row in 0..<rows {
            for column in 0..<columns {
                items.append(
                    PdfLayoutItem(
                        text: "cell \(row)\(column)", x: x + Float(column) * 90,
                        y: 700 - Float(row) * 20, width: 40, fontSize: 10, fontName: "F1"))
            }
        }
        return items
    }

    @Test func plainProseIsNotComplex() {
        let complexity = pdfLayoutComplexity(itemsByPage: [1: prose(page: 1, rows: 10)])
        #expect(complexity == PdfLayoutComplexity())
        #expect(!complexity.isComplex)
    }

    @Test func aGridReadsAsATablePage() {
        let complexity = pdfLayoutComplexity(itemsByPage: [1: grid(page: 1, rows: 6, columns: 4)])
        #expect(complexity.pagesWithTables == [1])
        #expect(complexity.isComplex)
    }

    @Test func twoBlocksOfProseReadAsColumns() {
        let complexity = pdfLayoutComplexity(
            itemsByPage: [1: prose(page: 1, rows: 12) + prose(page: 1, rows: 12, x: 400)])
        #expect(complexity.pagesWithTables.isEmpty)
        #expect(complexity.pagesWithColumns == [1])
    }

    @Test func pagesAreReportedIndividuallyAndInOrder() {
        let complexity = pdfLayoutComplexity(itemsByPage: [
            1: prose(page: 1, rows: 10),
            2: grid(page: 2, rows: 6, columns: 4),
            3: prose(page: 3, rows: 12) + prose(page: 3, rows: 12, x: 400),
        ])
        #expect(complexity.pagesWithTables == [2])
        #expect(complexity.pagesWithColumns == [2, 3])
    }

    @Test func tooFewItemsForAnyDetector() {
        #expect(pdfLayoutComplexity(itemsByPage: [1: grid(page: 1, rows: 2, columns: 2)])
            == PdfLayoutComplexity())
        #expect(pdfLayoutComplexity(itemsByPage: [:]) == PdfLayoutComplexity())
    }
}
