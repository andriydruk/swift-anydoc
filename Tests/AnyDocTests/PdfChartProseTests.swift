import Testing

@testable import AnyDoc

/// Inferring a prose gutter on a page whose charts hide it.
@Suite struct PdfChartProseTests {

    private func item(
        _ x: Float, _ y: Float, width: Float = 200,
        _ text: String = "a line of running prose text here"
    ) -> PdfLayoutItem {
        PdfLayoutItem(text: text, x: x, y: y, width: width, fontSize: 10, fontName: "F1")
    }

    /// Two columns of prose, the right one optionally slid down.
    private func columns(
        rows: Int = 8, rightX: Float = 320, step: Float = 14, width: Float = 200,
        offset: Float = 0, text: String = "a line of running prose text here"
    ) -> [PdfLayoutItem] {
        var out: [PdfLayoutItem] = []
        for row in 0..<rows {
            let y = 700 - Float(row) * step
            out.append(item(60, y, width: width, text))
            out.append(item(rightX, y - offset, width: width, text))
        }
        return out
    }

    // MARK: - chart_page_prose_column_split

    @Test func twoColumnsOfProseImplyAGutterBetweenThem() {
        // Midway between the columns' left edges, not between their bodies.
        #expect(pdfChartPageProseColumnSplit(columns()) == 190)
    }

    @Test func eachColumnNeedsSixProseRuns() {
        #expect(pdfChartPageProseColumnSplit(columns(rows: 5)) == nil)
        #expect(pdfChartPageProseColumnSplit(columns(rows: 6)) != nil)
    }

    @Test func theColumnsMustBeOneHundredAndTwentyPointsApart() {
        // Measured between left edges, and inclusive.
        #expect(pdfChartPageProseColumnSplit(columns(rightX: 179)) == nil)
        #expect(pdfChartPageProseColumnSplit(columns(rightX: 180)) == 120)
    }

    @Test func eachColumnMustRunSixtyPointsTall() {
        // Seven gaps at 8.5pt is 59.5 and fails; at 9pt it is 63 and passes.
        #expect(pdfChartPageProseColumnSplit(columns(step: 8.5)) == nil)
        #expect(pdfChartPageProseColumnSplit(columns(step: 9)) != nil)
    }

    @Test func theColumnsMustRunAlongsideEachOther() {
        // Two fifths of the shorter column. A column and a caption below it
        // are not side by side however close their left edges.
        #expect(pdfChartPageProseColumnSplit(columns(offset: 58)) != nil)
        #expect(pdfChartPageProseColumnSplit(columns(offset: 59)) == nil)
    }

    @Test func onlySubstantialProseVotes() {
        // Four words, 80pt wide, and more than half alphabetic — so axis
        // labels and figures cannot form a column.
        #expect(pdfChartPageProseColumnSplit(columns(width: 79)) == nil)
        #expect(pdfChartPageProseColumnSplit(columns(width: 80)) != nil)
        #expect(pdfChartPageProseColumnSplit(columns(text: "one two three")) == nil)
        #expect(pdfChartPageProseColumnSplit(columns(text: "12 34 56 78")) == nil)
    }

    @Test func exactlyTwoColumnsAreASplit() {
        // One is no split, and three is a table.
        var three: [PdfLayoutItem] = []
        for row in 0..<8 {
            let y = 700 - Float(row) * 14
            for x: Float in [60, 260, 460] { three.append(item(x, y, width: 150)) }
        }
        #expect(pdfChartPageProseColumnSplit(three) == nil)
        let one = (0..<12).map { item(60, 700 - Float($0) * 14) }
        #expect(pdfChartPageProseColumnSplit(one) == nil)
        #expect(pdfChartPageProseColumnSplit([]) == nil)
    }

    // MARK: - chart_spans_prose_split

    @Test func aChartMustCrossTheGutterOnBothSides() {
        // Forty points each way, so a chart confined to one column stays in
        // that column's order.
        let chart = PdfImageRegion(x0: 100, y0: 0, x1: 400, y1: 200)
        #expect(!pdfChartSpansProseSplit(chart, splitX: 139))
        #expect(pdfChartSpansProseSplit(chart, splitX: 140))
        #expect(pdfChartSpansProseSplit(chart, splitX: 360))
        #expect(!pdfChartSpansProseSplit(chart, splitX: 361))
    }

    @Test func theChartsCornersNeedNotBeOrdered() {
        let forward = PdfImageRegion(x0: 100, y0: 0, x1: 400, y1: 200)
        let reversed = PdfImageRegion(x0: 400, y0: 0, x1: 100, y1: 200)
        #expect(pdfChartSpansProseSplit(forward, splitX: 250))
        #expect(pdfChartSpansProseSplit(reversed, splitX: 250))
    }

    // MARK: - is_cross_row_prose_continuation

    @Test func anOpenClauseFollowedByLowercaseContinues() {
        #expect(pdfIsCrossRowProseContinuation("an open clause", "continues here"))
        #expect(!pdfIsCrossRowProseContinuation("a sentence.", "continues here"))
        #expect(!pdfIsCrossRowProseContinuation("an open clause", "Continues Here"))
    }

    @Test func closingQuotesAndBracketsAreStrippedFirst() {
        // `…said."` is closed, since the full stop is what matters.
        #expect(!pdfIsCrossRowProseContinuation("he said.\"", "continues here"))
        #expect(pdfIsCrossRowProseContinuation("he said\"", "continues here"))
        #expect(pdfIsCrossRowProseContinuation("bracket)", "continues here"))
    }

    @Test func aRowOfNothingButClosersIsNotOpen() {
        #expect(!pdfIsCrossRowProseContinuation("\".)]", "continues here"))
        #expect(!pdfIsCrossRowProseContinuation("", "continues here"))
        #expect(!pdfIsCrossRowProseContinuation("an open clause", ""))
    }

    @Test func theFirstAlphabeticCharacterDecidesTheContinuation() {
        // Leading digits and punctuation are skipped when looking for it.
        #expect(pdfIsCrossRowProseContinuation("open", "42 then words"))
        #expect(!pdfIsCrossRowProseContinuation("open", "42 Then Words"))
    }

    // MARK: - looks_like_numbered_section_heading

    @Test func aNumberedSectionHeadingIsRecognised() {
        #expect(pdfLooksLikeNumberedSectionHeading("1. Introduction To The Topic"))
        #expect(pdfLooksLikeNumberedSectionHeading("1.2.3.4. Deep Section Heading Here"))
        // Five groups is too deep.
        #expect(!pdfLooksLikeNumberedSectionHeading("1.2.3.4.5. Too Deep Here Now"))
    }

    @Test func theTitleMustBeThreeWordsBeginningWithACapital() {
        #expect(!pdfLooksLikeNumberedSectionHeading("1. Two Words"))
        #expect(pdfLooksLikeNumberedSectionHeading("1. Three Words Here"))
        #expect(!pdfLooksLikeNumberedSectionHeading("1. one two three"))
    }

    @Test func thePrefixMustBeDottedDigitGroups() {
        #expect(!pdfLooksLikeNumberedSectionHeading("a. Not A Number"))
        #expect(!pdfLooksLikeNumberedSectionHeading("1.a. Mixed Prefix Here"))
        #expect(!pdfLooksLikeNumberedSectionHeading("1000. Big Number Section"))
        #expect(pdfLooksLikeNumberedSectionHeading("999. Fine Number Section"))
    }

    // MARK: - merged_retry_skips_body_font

    @Test func onlyAColumnedPageWithoutChartsSkipsBodyFont() {
        #expect(pdfMergedRetrySkipsBodyFont(detectedColumns: true, hasChartRegions: false))
        #expect(!pdfMergedRetrySkipsBodyFont(detectedColumns: true, hasChartRegions: true))
        #expect(!pdfMergedRetrySkipsBodyFont(detectedColumns: false, hasChartRegions: false))
    }
}
