import Testing

@testable import AnyDoc

/// What the reading-order leaves each measure.
@Suite struct PdfReadingOrderTests {

    private func item(_ x: Float, _ y: Float, _ width: Float, _ text: String = "run")
        -> PdfLayoutItem
    {
        PdfLayoutItem(text: text, x: x, y: y, width: width, fontSize: 12, fontName: "F1")
    }

    private let prose = "a sentence of genuine running prose"

    // MARK: - page_x_bounds

    @Test func boundsCoverTextAndImagesAlike() {
        let bounds = pdfPageXBounds(
            [item(100, 700, 50)], [PdfImageRegion(x0: 400, y0: 0, x1: 500, y1: 100)])
        #expect(bounds?.xMin == 100)
        #expect(bounds?.xMax == 500)
    }

    @Test func anImagesCornersAreNotAssumedOrdered() {
        // Both corners are consulted for each end, so a region written
        // right-to-left measures the same as one written left-to-right.
        let forward = pdfPageXBounds([], [PdfImageRegion(x0: 100, y0: 0, x1: 300, y1: 50)])
        let reversed = pdfPageXBounds([], [PdfImageRegion(x0: 300, y0: 0, x1: 100, y1: 50)])
        #expect(forward?.xMin == 100 && forward?.xMax == 300)
        #expect(reversed?.xMin == 100 && reversed?.xMax == 300)
    }

    @Test func nothingToMeasureGivesNoBounds() {
        // An empty page folds to infinities, which the finite check rejects
        // rather than letting them propagate into arithmetic downstream.
        #expect(pdfPageXBounds([], []) == nil)
    }

    @Test func aDegenerateExtentIsRejected() {
        // A single zero-width run has xMax equal to xMin, and the bound has
        // to be strictly greater.
        #expect(pdfPageXBounds([item(20, 700, 0, "")], []) == nil)
        #expect(pdfPageXBounds([item(20, 700, 10, "")], []) != nil)
    }

    // MARK: - group_rows

    @Test func runsSharingABaselineFormOneRow() {
        let rows = pdfGroupRows([item(200, 700, 50, "c"), item(20, 700, 50, "a")])
        #expect(rows.count == 1)
        // And are ordered left to right within it.
        #expect(rows.first?.items.map(\.x) == [20, 200])
    }

    @Test func theRowBaselineIsARunningMean() {
        // Unlike the line grouper of wave 66, the row's y moves as runs join
        // — so the tolerance is measured against a shifting point.
        let rows = pdfGroupRows([item(20, 700, 50), item(80, 698, 50)])
        #expect(rows.count == 1)
        #expect(rows.first?.y == 699)
    }

    @Test func aMovingBaselineLetsARowChainPastItsTolerance() {
        // Eight runs rising half a point each span 3.5pt in total — past the
        // 3pt tolerance — yet stay one row, because each is compared against
        // the mean so far rather than against the first. The mean lags, so
        // this buys extra reach but not unlimited reach: at one point a step
        // the row breaks in two.
        func rising(_ step: Float) -> [PdfLayoutItem] {
            (0..<8).map { item(20 + Float($0) * 40, 700 - Float($0) * step, 30) }
        }
        #expect(pdfGroupRows(rising(0.5)).count == 1)
        #expect(pdfGroupRows(rising(1)).count == 2)
        // The tolerance is inclusive, so an exact 3pt step still pairs runs
        // up rather than separating all eight.
        #expect(pdfGroupRows(rising(3)).count == 4)
        #expect(pdfGroupRows(rising(3.1)).count == 8)
    }

    @Test func separateBaselinesStayApart() {
        let rows = pdfGroupRows((0..<6).map { item(20, 700 - Float($0) * 14, 50) })
        #expect(rows.count == 6)
    }

    @Test func noItemsMakeNoRows() {
        #expect(pdfGroupRows([]).isEmpty)
    }

    // MARK: - side_is_prose

    @Test func threeWordsAndTenLettersReadAsProse() {
        #expect(pdfSideIsProse([item(0, 0, 0, prose)]))
        #expect(!pdfSideIsProse([item(0, 0, 0, "ab cd")]))
        // Three words but only nine letters.
        #expect(!pdfSideIsProse([item(0, 0, 0, "abc def ghi")]))
        #expect(pdfSideIsProse([item(0, 0, 0, "abcd defg hij")]))
    }

    @Test func runsAreJoinedWithASpaceBeforeCounting() {
        // So three runs of one word each are three words, not one.
        let split = [item(0, 0, 0, "abcd"), item(0, 0, 0, "defg"), item(0, 0, 0, "hij")]
        #expect(pdfSideIsProse(split))
    }

    @Test func tenCjkCharactersStandInForThreeWords() {
        // CJK is set without spaces, so a whole sentence counts as one word
        // and would never reach the word bar. The letter bar still applies,
        // and CJK characters are alphabetic, so they satisfy both.
        let twelve = String(repeating: "日本語", count: 4)
        #expect(pdfSideIsProse([item(0, 0, 0, twelve)]))
        // Six characters is under the CJK bar and under the word bar.
        #expect(!pdfSideIsProse([item(0, 0, 0, "日本語日本語")]))
    }

    @Test func nothingIsNotProse() {
        #expect(!pdfSideIsProse([]))
    }

    // MARK: - aligned_row_split

    private func row(_ items: [PdfLayoutItem]) -> PdfRow {
        pdfGroupRows(items).first ?? PdfRow(y: 0, items: [])
    }

    @Test func aRowSplitsAtItsWidestQualifyingGap() {
        let split = pdfAlignedRowSplit(
            row([item(100, 700, 100, prose), item(240, 700, 100, prose)]),
            xMin: 0, xMax: 600)
        #expect(split == 220)
    }

    @Test func theGutterMustBeAtLeastEightPoints() {
        func gapped(_ gap: Float) -> Float? {
            pdfAlignedRowSplit(
                row([item(100, 700, 100, prose), item(200 + gap, 700, 100, prose)]),
                xMin: 0, xMax: 600)
        }
        #expect(gapped(6) == nil)
        #expect(gapped(8) != nil)
    }

    @Test func theSplitMustFallInTheMiddleHalfOfThePage() {
        // Outside 25%–75% it is a margin, not a column break.
        func atLeft(_ x: Float) -> Float? {
            pdfAlignedRowSplit(
                row([item(x, 700, 60, prose), item(x + 100, 700, 60, prose)]),
                xMin: 0, xMax: 600)
        }
        #expect(atLeft(0) == nil)  // split at 80, under 150
        #expect(atLeft(200) != nil)  // split at 280
        #expect(atLeft(460) == nil)  // split at 540, over 450
    }

    @Test func bothSidesMustReadAsProse() {
        let oneSided = row([item(100, 700, 100, prose), item(240, 700, 100, "ab cd")])
        #expect(pdfAlignedRowSplit(oneSided, xMin: 0, xMax: 600) == nil)
    }

    @Test func theSidesAreTheWholeRowNotJustTheAdjacentPair() {
        // Four runs splitting two-and-two: each side is judged on both of
        // its runs, so a pair too short on its own still qualifies.
        let four = row([
            item(20, 700, 80, prose), item(110, 700, 80, prose),
            item(320, 700, 80, prose), item(410, 700, 80, prose),
        ])
        #expect(pdfAlignedRowSplit(four, xMin: 0, xMax: 600) != nil)
    }

    @Test func aRowOfOneRunNeverSplits() {
        #expect(pdfAlignedRowSplit(row([item(100, 700, 100, prose)]), xMin: 0, xMax: 600) == nil)
        #expect(pdfAlignedRowSplit(PdfRow(y: 0, items: []), xMin: 0, xMax: 600) == nil)
    }
}
