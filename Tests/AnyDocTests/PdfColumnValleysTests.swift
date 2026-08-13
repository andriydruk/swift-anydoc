import Testing

@testable import AnyDoc

/// What the column-detection leaf tests are each defending against.
///
/// The probe pins these against the reference; these say what the answers
/// mean, and pin the boundaries the generated cases only brush.
@Suite struct PdfColumnValleysTests {

    // MARK: - helpers

    /// A justified two-column page: dense either side, a shallow dip between.
    private func twoColumns(
        bins: Int = 160, gutterAt: Int = 80, gutterWidth: Int = 5, peak: UInt32 = 60,
        floor: UInt32 = 0
    ) -> [UInt32] {
        (0..<bins).map { abs($0 - gutterAt) <= gutterWidth / 2 ? floor : peak }
    }

    private func valleys(
        _ histogram: [UInt32], binWidth: Float = 2, pageWidth: Float = 612, margin: Float = 50
    ) -> [(lower: Int, upper: Int)] {
        pdfFindRelativeValleys(
            histogram: histogram, binCount: histogram.count, binWidth: binWidth,
            pageWidth: pageWidth, marginThreshold: margin)
    }

    // MARK: - find_relative_valleys

    @Test func aJustifiedTwoColumnPageYieldsOneGutter() {
        // The case the whole function exists for: the histogram never reaches
        // zero, so absolute gutter detection finds nothing and this does.
        let found = valleys(twoColumns(floor: 10))
        #expect(found.count == 1)
        #expect(found.first.map { $0.lower == 78 && $0.upper == 83 } == true)
    }

    @Test func aCompletelyEmptyGutterIsPassedOver() {
        // `val < 1.0` skips it. That reads like a bug and is not: an empty
        // gutter is what the *absolute* detector finds, and this function is
        // only the fallback for the justified page that fills it. Finding
        // both would have the two detectors argue.
        #expect(valleys(twoColumns(floor: 0)).isEmpty)
        #expect(!valleys(twoColumns(floor: 1)).isEmpty)
    }

    @Test func theGutterIsReportedAsFiveBinsWhateverItsRealWidth() {
        // The return is a fixed ±2 bins around the deepest point, not the
        // measured extent of the dip — callers get a location, not a width.
        for width in [3, 5, 7, 9, 11] {
            let found = valleys(twoColumns(gutterWidth: width, floor: 4))
            #expect(found.count == 1, "width \(width)")
            #expect(found.first.map { $0.upper - $0.lower == 5 } == true, "width \(width)")
        }
    }

    @Test func tooFewBinsIsNotConsidered() {
        #expect(valleys([UInt32](repeating: 30, count: 9)).isEmpty)
        #expect(valleys([]).isEmpty)
    }

    @Test func aPageNarrowerThanTwoPeakWindowsFindsNothing() {
        // The scan runs from bin 25 to binCount-25, which is empty below 51
        // bins. Rust gets an empty range; Swift would trap on the reversed
        // one, so this pins the guard.
        for bins in [24, 49, 50] {
            let histogram = twoColumns(bins: bins, gutterAt: bins / 2, floor: 4)
            #expect(valleys(histogram).isEmpty, "bins \(bins)")
        }
        #expect(!valleys(twoColumns(bins: 60, gutterAt: 30, floor: 4)).isEmpty)
    }

    @Test func aFlatPageHasNoValley() {
        #expect(valleys([UInt32](repeating: 40, count: 160)).isEmpty)
    }

    @Test func aRaggedSingleColumnIsNotSplit() {
        // Text dense in the middle and falling away at both margins. Without
        // the peak-balance gate the margin drop-off reads as a gutter.
        let ragged = (0..<160).map { UInt32(max(0, 60 - abs($0 - 80))) }
        #expect(valleys(ragged).isEmpty)
    }

    @Test func bothFlankingPeaksMustBeDenseText() {
        // A dip between two thin peaks is whitespace between two words, not
        // a gutter between two columns.
        #expect(valleys(twoColumns(peak: 19, floor: 4)).isEmpty)
        #expect(!valleys(twoColumns(peak: 21, floor: 4)).isEmpty)
    }

    @Test func theFlankingPeaksMustBeComparable() {
        // A dense column beside a sparse one is a margin, not a gutter. The
        // bar is the smaller peak being at least 40% of the larger, and it is
        // inclusive. Note the drop has to start right at the gutter's edge:
        // the peaks are measured 25 bins either side, so a change further out
        // is not seen at all.
        func lopsided(_ right: UInt32) -> [UInt32] {
            var values = twoColumns(peak: 100, floor: 4)
            for index in 83..<160 { values[index] = right }
            return values
        }
        #expect(valleys(lopsided(39)).isEmpty)
        #expect(!valleys(lopsided(40)).isEmpty)
    }

    @Test func theValleyMustBeMuchLowerThanItsPeaks() {
        // Contrast is valley over the *smaller* peak, and must be under 0.60.
        // At peak 60 that puts the bar at a floor of 36.
        #expect(!valleys(twoColumns(floor: 30)).isEmpty)
        #expect(valleys(twoColumns(floor: 40)).isEmpty)
    }

    @Test func aDipInsideThePageMarginIsTheMargin() {
        // Measured in points via the bin width, so the same histogram passes
        // or fails depending on how wide a bin is.
        let histogram = twoColumns(gutterAt: 30, floor: 4)
        #expect(valleys(histogram, binWidth: 1, margin: 50).isEmpty)
        #expect(!valleys(histogram, binWidth: 2, margin: 50).isEmpty)
    }

    @Test func onlyTheDeepestGutterIsReturned() {
        // Three gutters of increasing depth: the function reports one, and it
        // is the one with the best contrast rather than the first found.
        var values = twoColumns(bins: 240, gutterAt: 60, floor: 20)
        for index in 118..<123 { values[index] = 5 }
        for index in 178..<183 { values[index] = 2 }
        let found = valleys(values)
        #expect(found.count == 1)
        #expect(found.first.map { $0.lower == 178 && $0.upper == 183 } == true)
    }

    @Test func gutterOfEqualDepthKeepsTheEarlierOne() {
        // Selection is `<`, not `<=`, at both the grouping and the final
        // choice — so a tie leaves the first one standing.
        var values = [UInt32](repeating: 60, count: 200)
        for index in 88..<93 { values[index] = 6 }
        for index in 140..<145 { values[index] = 6 }
        let found = valleys(values)
        #expect(found.count == 1)
        #expect(found.first.map { $0.lower == 88 } == true)
    }

    @Test func adjacentCandidatesFormOneGutterRatherThanSeveral() {
        // Two dips eight bins apart still describe one gutter, so the result
        // is one valley rather than two competing ones.
        var values = [UInt32](repeating: 60, count: 200)
        for index in 88..<93 { values[index] = 6 }
        for index in 96..<101 { values[index] = 6 }
        let found = valleys(values)
        #expect(found.count == 1)
        #expect(found.first.map { $0.upper - $0.lower == 5 } == true)
    }

    // MARK: - is_list_marker_column

    @Test func aColumnOfBulletsIsNotAColumn() {
        let bullets = (0..<10).map { _ in item(text: "•") }
        #expect(pdfIsListMarkerColumn(bullets))
    }

    @Test func fourFifthsIsTheBarForAMarkerColumn() {
        // A stray page number among the bullets must not rescue the split.
        func mixed(_ markers: Int) -> [PdfLayoutItem] {
            (0..<10).map { item(text: $0 < markers ? "•" : "text") }
        }
        #expect(!pdfIsListMarkerColumn(mixed(7)))
        #expect(pdfIsListMarkerColumn(mixed(8)))
    }

    @Test func aMarkerGluedToItsTextIsNotAMarker() {
        // The check is for a *standalone* glyph — the whole point is that the
        // markers sit in their own column.
        #expect(!pdfIsListMarkerColumn([item(text: "•item")]))
        #expect(pdfIsListMarkerColumn([item(text: " • ")]))
    }

    @Test func onlyTheTenListedGlyphsCount() {
        for marker in ["•", "●", "○", "◦", "▪", "▫", "◆", "◇", "■", "□"] {
            #expect(pdfIsListMarkerColumn([item(text: marker)]), "\(marker) should count")
        }
        // Near neighbours that real documents also use, but the reference
        // does not list.
        for other in ["-", "*", "·", "‣", "⁃"] {
            #expect(!pdfIsListMarkerColumn([item(text: other)]), "\(other) should not count")
        }
    }

    @Test func anEmptySideIsNotAMarkerColumn() {
        // Zero of zero would be a division by zero rather than 100%.
        #expect(!pdfIsListMarkerColumn([]))
    }

    // MARK: - spans_multiple_columns

    private func item(
        text: String = "T", x: Float = 0, y: Float = 700, width: Float = 0, fontSize: Float = 12
    ) -> PdfLayoutItem {
        PdfLayoutItem(text: text, x: x, y: y, width: width, fontSize: fontSize, fontName: "F1")
    }

    private let twoColumnRegions = [
        PdfColumnRegion(xMin: 0, xMax: 300), PdfColumnRegion(xMin: 320, xMax: 612),
    ]

    @Test func aFullWidthHeadingSpansBothColumns() {
        #expect(pdfSpansMultipleColumns(item(x: 0, width: 612), twoColumnRegions))
    }

    @Test func anItemInsideOneColumnDoesNotSpan() {
        #expect(!pdfSpansMultipleColumns(item(x: 10, width: 200), twoColumnRegions))
        #expect(!pdfSpansMultipleColumns(item(x: 330, width: 200), twoColumnRegions))
    }

    @Test func twentyPointsOfOverlapIsEnoughOnItsOwn() {
        // Against a 300pt column a tenth is 30pt, so between 20 and 30 the
        // absolute rule is the only one that fires.
        let columns = [PdfColumnRegion(xMin: 0, xMax: 280), PdfColumnRegion(xMin: 300, xMax: 612)]
        #expect(!pdfSpansMultipleColumns(item(x: 261, width: 60), columns))
        #expect(pdfSpansMultipleColumns(item(x: 259, width: 62), columns))
    }

    @Test func aTenthOfANarrowColumnIsEnoughBelowTwentyPoints() {
        // Against a 100pt column a tenth is 10pt, so the percentage rule
        // fires well before the absolute one could.
        let columns = [PdfColumnRegion(xMin: 0, xMax: 100), PdfColumnRegion(xMin: 110, xMax: 210)]
        #expect(!pdfSpansMultipleColumns(item(x: 91, width: 30), columns))
        #expect(pdfSpansMultipleColumns(item(x: 89, width: 32), columns))
    }

    @Test func anUnmeasuredWidthIsEstimatedFromTheText() {
        // Half the font size per character. Thirty characters at 12pt is
        // 180pt, which reaches from the first column into the second.
        let long = String(repeating: "A", count: 30)
        #expect(pdfSpansMultipleColumns(item(text: long, x: 200, width: 0), twoColumnRegions))
        #expect(!pdfSpansMultipleColumns(item(text: "T", x: 200, width: 0), twoColumnRegions))
    }

    @Test func fewerThanTwoColumnsCanNeverBeSpanned() {
        #expect(!pdfSpansMultipleColumns(item(x: 0, width: 612), []))
        #expect(!pdfSpansMultipleColumns(item(x: 0, width: 612), [twoColumnRegions[0]]))
    }

    // MARK: - is_page_number

    @Test func aStandaloneNumberInTheFooterIsAPageNumber() {
        #expect(pdfIsPageNumber(item(text: "7", y: 40)))
        #expect(pdfIsPageNumber(item(text: "1234", y: 760)))
        #expect(pdfIsPageNumber(item(text: " 12 ", y: 40)))
    }

    @Test func theBandsAreExclusiveAtTheirEdges() {
        // `y > 720 || y < 100`, so both boundary values are body text.
        #expect(!pdfIsPageNumber(item(text: "7", y: 100)))
        #expect(pdfIsPageNumber(item(text: "7", y: 99)))
        #expect(!pdfIsPageNumber(item(text: "7", y: 720)))
        #expect(pdfIsPageNumber(item(text: "7", y: 721)))
    }

    @Test func textInTheMiddleOfThePageIsNeverAPageNumber() {
        #expect(!pdfIsPageNumber(item(text: "7", y: 400)))
    }

    @Test func onlyOneToFourAsciiDigitsQualify() {
        #expect(!pdfIsPageNumber(item(text: "12345", y: 40)))
        #expect(!pdfIsPageNumber(item(text: "", y: 40)))
        #expect(!pdfIsPageNumber(item(text: "1a", y: 40)))
        #expect(!pdfIsPageNumber(item(text: "-1", y: 40)))
        #expect(!pdfIsPageNumber(item(text: "1.", y: 40)))
        #expect(!pdfIsPageNumber(item(text: "1 2", y: 40)))
    }

    @Test func nonAsciiDigitsDoNotQualify() {
        // `is_ascii_digit`, not `is_numeric` — a superscript one and a
        // fullwidth one are both rejected, and the fullwidth digit is also
        // over the four-*byte* limit.
        #expect(!pdfIsPageNumber(item(text: "¹", y: 40)))
        #expect(!pdfIsPageNumber(item(text: "１", y: 40)))
    }
}
