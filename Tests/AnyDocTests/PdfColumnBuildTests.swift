import Testing

@testable import AnyDoc

/// What the column arbiters are each deciding.
///
/// Every boundary here was read off the reference directly rather than
/// reasoned about — several of them sit where arithmetic on the constants
/// would not put them.
@Suite struct PdfColumnBuildTests {

    private func item(_ x: Float, _ y: Float, _ width: Float, _ text: String = "word")
        -> PdfLayoutItem
    {
        PdfLayoutItem(text: text, x: x, y: y, width: width, fontSize: 12, fontName: "F1")
    }

    /// A page of two text columns, 14 lines each.
    private func twoColumnPage(rightRows: Int = 14, rightOffset: Float = 0) -> [PdfLayoutItem] {
        var items: [PdfLayoutItem] = []
        for row in 0..<14 { items.append(item(40, 700 - Float(row) * 14, 220)) }
        for row in 0..<rightRows {
            items.append(item(330, 700 - rightOffset - Float(row) * 14, 220))
        }
        return items
    }

    private func build(
        _ valleys: [(lower: Int, upper: Int)], _ items: [PdfLayoutItem], centreAssign: Bool = true,
        minimumItems: Int = 10, minimumVerticalSpan: Float = 0.5, xMin: Float = 0,
        binWidth: Float = 2, xMax: Float = 612
    ) -> [PdfColumnRegion] {
        pdfValidateAndBuildColumns(
            valleys: valleys, items: items, xMin: xMin, binWidth: binWidth, xMax: xMax,
            minimumItems: minimumItems, minimumVerticalSpan: minimumVerticalSpan,
            centreAssign: centreAssign)
    }

    // MARK: - validate_and_build_columns

    @Test func aCleanTwoColumnPageSplitsAtTheGutterCentre() {
        let columns = build([(150, 155)], twoColumnPage())
        #expect(columns.count == 2)
        #expect(columns.first?.xMin == 0)
        #expect(columns.first?.xMax == 305)
        #expect(columns.last?.xMax == 612)
    }

    @Test func aPageThatFailsEveryTestIsStillOneColumn() {
        // The function never reports failure — the caller always receives a
        // usable region list, and a single full-width column is what "no
        // columns here" looks like.
        #expect(build([], twoColumnPage()).count == 1)
        #expect(build([(150, 155)], twoColumnPage(), minimumItems: 30).count == 1)
        #expect(build([], []) == [PdfColumnRegion(xMin: 0, xMax: 612)])
    }

    @Test func theDominantSideCarriesTheItemCount() {
        // 14 items on the larger side passes a bar of 14 and fails 15.
        #expect(build([(150, 155)], twoColumnPage(), minimumItems: 14).count == 2)
        #expect(build([(150, 155)], twoColumnPage(), minimumItems: 15).count == 1)
    }

    @Test func aSidebarNeedsOnlyThreeItemsOnItsThinSide() {
        // Asymmetric layouts are accepted, but three is the floor. Checked
        // with the overlap requirement lifted, since a three-item sidebar
        // cannot span much of the page's height.
        for rows in [0, 1, 2] {
            let columns = build(
                [(150, 155)], twoColumnPage(rightRows: rows), minimumVerticalSpan: 0)
            #expect(columns.count == 1, "\(rows) items should be rejected")
        }
        for rows in [3, 4] {
            let columns = build(
                [(150, 155)], twoColumnPage(rightRows: rows), minimumVerticalSpan: 0)
            #expect(columns.count == 2, "\(rows) items should be accepted")
        }
    }

    @Test func aColumnOfBulletsIsNotASecondColumn() {
        // The list-marker check looks at the *smaller* side, which is where
        // the bullets sit.
        var items = (0..<14).map { item(330, 700 - Float($0) * 14, 220) }
        items += (0..<10).map { item(40, 700 - Float($0) * 14, 6, "•") }
        #expect(build([(150, 155)], items).count == 1)
    }

    @Test func columnsMustRunAlongsideEachOther() {
        // Text above a figure and text below it produce a convincing gap and
        // are not columns. Vertical overlap is what tells them apart.
        #expect(build([(150, 155)], twoColumnPage(rightOffset: 0)).count == 2)
        #expect(build([(150, 155)], twoColumnPage(rightOffset: 175)).count == 1)
    }

    @Test func theGutterCentreIsMeasuredFromTheHistogramOrigin() {
        // Bins are relative to `xMin`, so both it and the bin width move the
        // boundary the columns are cut at.
        #expect(build([(150, 155)], twoColumnPage(), xMin: 40).first?.xMax == 345)
        #expect(build([(150, 155)], twoColumnPage(), binWidth: 1).first?.xMax == 152.5)
    }

    @Test func atMostThreeGuttersSurvive() {
        // Four columns is the ceiling, whatever the page proposes.
        var items: [PdfLayoutItem] = []
        for column in 0..<5 {
            for row in 0..<12 {
                items.append(item(15 + Float(column) * 115, 700 - Float(row) * 14, 90))
            }
        }
        let valleys = (0..<4).map { index -> (lower: Int, upper: Int) in
            ((15 + index * 115 + 105) / 2, (15 + index * 115 + 115) / 2)
        }
        let columns = build(valleys, items, minimumItems: 5)
        #expect(columns.count == 4)
        // And they come back in page order, not in the score order the
        // truncation sorted them into.
        #expect(zip(columns, columns.dropFirst()).allSatisfy { $0.xMax <= $1.xMin })
    }

    @Test func edgeAssignmentLeavesAStraddlingItemOnNeitherSide() {
        // The edge test is asymmetric on purpose: an item must *end* before
        // the gutter to be left of it and *begin* after it to be right, so
        // one lying across it is counted nowhere. It changes no verdict here
        // — which is the point, a single stray item should not.
        var items = twoColumnPage()
        items.append(item(280, 400, 60, "straddle"))
        #expect(build([(150, 155)], items, centreAssign: false).count == 2)
        #expect(build([(150, 155)], items, centreAssign: true).count == 2)
    }

    // MARK: - columns_have_prose

    private func lines(
        rows: Int = 12, x: Float = 30, width: Float = 200, perLine: Int = 1
    ) -> [PdfLayoutItem] {
        var items: [PdfLayoutItem] = []
        for row in 0..<rows {
            for column in 0..<perLine {
                items.append(item(x + Float(column) * 5, 700 - Float(row) * 14, width))
            }
        }
        return items
    }

    private let oneColumn = [PdfColumnRegion(xMin: 20, xMax: 300)]

    @Test func runningProseReadsAsProse() {
        #expect(pdfColumnsHaveProse(oneColumn, lines()))
    }

    @Test func aNarrowStripIsNotAColumn() {
        // A sidebar or a stray fragment is not a column. 120pt is the floor
        // and it is inclusive, so the rejection is at 119.
        #expect(!pdfColumnsHaveProse([PdfColumnRegion(xMin: 20, xMax: 139)], lines()))
        #expect(pdfColumnsHaveProse([PdfColumnRegion(xMin: 20, xMax: 140)], lines()))
        // Same boundary with items narrow enough to live there comfortably,
        // so the width gate is doing the work rather than the item count.
        let narrow = lines(width: 100)
        #expect(!pdfColumnsHaveProse([PdfColumnRegion(xMin: 20, xMax: 139)], narrow))
        #expect(pdfColumnsHaveProse([PdfColumnRegion(xMin: 20, xMax: 140)], narrow))
    }

    @Test func everyColumnMustPassNotJustOne() {
        // The first failure ends the question, so one bad column condemns a
        // page whose other column is perfect prose.
        let good = PdfColumnRegion(xMin: 20, xMax: 300)
        let narrow = PdfColumnRegion(xMin: 400, xMax: 460)
        #expect(pdfColumnsHaveProse([good], lines()))
        #expect(!pdfColumnsHaveProse([good, narrow], lines()))
    }

    @Test func eightLinesAreNeededToJudgeFrom() {
        #expect(!pdfColumnsHaveProse(oneColumn, lines(rows: 7)))
        #expect(pdfColumnsHaveProse(oneColumn, lines(rows: 8)))
    }

    @Test func enoughItemsIsNotEnoughLines() {
        // Eight items across four baselines fails, because the count is
        // re-checked after grouping. Both tests use the same constant and
        // the second is the one that means anything.
        var items: [PdfLayoutItem] = []
        for row in 0..<4 {
            items.append(item(30, 700 - Float(row) * 14, 200, "a"))
            items.append(item(240, 700 - Float(row) * 14, 50, "b"))
        }
        #expect(items.count == 8)
        #expect(!pdfColumnsHaveProse(oneColumn, items))
    }

    @Test func aFullLineReachesFortyFivePercentAcrossItsColumn() {
        // The column is 280pt, so the bar is exactly 126pt and inclusive.
        #expect(!pdfColumnsHaveProse(oneColumn, lines(width: 125)))
        #expect(pdfColumnsHaveProse(oneColumn, lines(width: 126)))
    }

    @Test func fortyPercentOfLinesMustBeFull() {
        // Out of twelve lines, five full is 0.417 and passes; four is 0.333
        // and does not.
        func mixed(_ full: Int) -> [PdfLayoutItem] {
            (0..<12).map { item(30, 700 - Float($0) * 14, $0 < full ? 200 : 20) }
        }
        #expect(!pdfColumnsHaveProse(oneColumn, mixed(4)))
        #expect(pdfColumnsHaveProse(oneColumn, mixed(5)))
    }

    @Test func manyItemsPerLineIsATableNotProse() {
        // Prose runs one to three items per line; a table has one per cell.
        // The lines are kept wide so the fill test cannot be what decides.
        #expect(pdfColumnsHaveProse(oneColumn, lines(width: 250, perLine: 3)))
        #expect(!pdfColumnsHaveProse(oneColumn, lines(width: 250, perLine: 4)))
    }

    @Test func noColumnsIsVacuouslyProse() {
        // Nothing to disprove, so the loop never runs.
        #expect(pdfColumnsHaveProse([], lines()))
        #expect(pdfColumnsHaveProse([], []))
    }
}
