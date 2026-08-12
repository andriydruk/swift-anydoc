import Testing

@testable import AnyDoc

/// The line-table orchestrator: stroke classification, the legacy grid path,
/// and the recursion that lets a sparse table and a drawn one share a page.
@Suite struct PdfLineTablesTests {
    private func line(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) -> PdfLineSegment {
        PdfLineSegment(x1: x1, y1: y1, x2: x2, y2: y2, strokeWidth: 1)
    }

    private func item(_ text: String, _ x: Float, _ y: Float, width: Float = 40)
        -> PdfLayoutItem
    {
        PdfLayoutItem(text: text, x: x, y: y, width: width, fontSize: 10, fontName: "F1")
    }

    /// A drawn grid: `rows + 1` horizontals and `columns + 1` verticals.
    private func gridLines(
        rows: Int, columns: Int, x0: Float = 100, y0: Float = 700, cellWidth: Float = 100,
        cellHeight: Float = 25
    ) -> [PdfLineSegment] {
        var lines: [PdfLineSegment] = []
        for row in 0...rows {
            let y = y0 - Float(row) * cellHeight
            lines.append(line(x0, y, x0 + Float(columns) * cellWidth, y))
        }
        for column in 0...columns {
            let x = x0 + Float(column) * cellWidth
            lines.append(line(x, y0, x, y0 - Float(rows) * cellHeight))
        }
        return lines
    }

    private func gridItems(
        rows: Int, columns: Int, x0: Float = 100, y0: Float = 700, cellWidth: Float = 100,
        cellHeight: Float = 25
    ) -> [PdfLayoutItem] {
        var items: [PdfLayoutItem] = []
        for row in 0..<rows {
            for column in 0..<columns {
                items.append(
                    item(
                        "v\(row)\(column)", x0 + Float(column) * cellWidth + 10,
                        y0 - Float(row) * cellHeight - 15))
            }
        }
        return items
    }

    // MARK: classification

    @Test func strokesAreSplitByAxisAndLength() {
        let classified = pdfClassifyRuleLines([
            line(100, 700, 400, 700),  // horizontal
            line(100, 700, 100, 400),  // vertical
            line(100, 700, 400, 400),  // diagonal, ignored
            line(100, 700, 115, 700),  // 15pt, decoration
        ])
        #expect(classified.horizontals.count == 1)
        #expect(classified.verticals.count == 1)
        #expect(classified.horizontals.first?.y == 700)
        #expect(classified.verticals.first?.x == 100)
    }

    @Test func theAxisTestIsTwoDegrees() {
        // Over 300pt, two degrees is about 10.5pt of rise.
        #expect(pdfClassifyRuleLines([line(100, 700, 400, 710)]).horizontals.count == 1)
        #expect(pdfClassifyRuleLines([line(100, 700, 400, 730)]).horizontals.isEmpty)
    }

    @Test func aRuleTakesTheMeanOfItsEndpoints() {
        // A slightly sloped rule is recorded at its midpoint height.
        let classified = pdfClassifyRuleLines([line(100, 700, 400, 706)])
        #expect(classified.horizontals.first?.y == 703)
        #expect(classified.horizontals.first?.xMin == 100)
        #expect(classified.horizontals.first?.xMax == 400)
    }

    // MARK: the legacy grid path

    @Test func aDrawnGridBecomesATable() {
        let tables = pdfDetectTablesFromLines(
            items: gridItems(rows: 3, columns: 3), lines: gridLines(rows: 3, columns: 3))
        #expect(tables.count == 1)
        #expect(tables.first?.cells.count == 3)
        #expect(tables.first?.cells.first == ["v00", "v01", "v02"])
    }

    @Test func aPageWithNoLinesHasNoTables() {
        #expect(pdfDetectTablesFromLines(items: [item("a", 110, 690)], lines: []).isEmpty)
    }

    @Test func aBareFrameIsDecorationHoweverLargeThePage() {
        // Letter-sized, but only three rules and three sides. The gate keys
        // on the line count, so a real full-page ledger is unaffected.
        let frame = [
            line(50, 780, 560, 780), line(50, 420, 560, 420), line(50, 60, 560, 60),
            line(50, 780, 50, 60), line(300, 780, 300, 60), line(560, 780, 560, 60),
        ]
        let items = [
            item("a", 110, 700), item("b", 300, 700), item("c", 110, 300),
            item("d", 300, 300),
        ]
        #expect(pdfDetectTablesFromLines(items: items, lines: frame).isEmpty)
    }

    @Test func evenlySpacedRowsAreChartGridlines() {
        #expect(
            pdfDetectTablesFromLines(
                items: gridItems(rows: 6, columns: 3, cellHeight: 30),
                lines: gridLines(rows: 6, columns: 3, cellHeight: 30)
            ).isEmpty)
    }

    @Test func aGridCapturingLittleOfThePageIsAChart() {
        // The grid is sound, but forty lines of prose sit outside it.
        var items = gridItems(rows: 3, columns: 3)
        items += (0..<40).map { item("prose line \($0)", 50, 200 - Float($0) * 12, width: 200) }
        #expect(pdfDetectTablesFromLines(items: items, lines: gridLines(rows: 3, columns: 3)).isEmpty)
    }

    @Test func textInOneColumnOnlyIsNotATable() {
        let items = (0..<3).map { item("a\($0)", 110, 700 - Float($0) * 25 - 15) }
        #expect(pdfDetectTablesFromLines(items: items, lines: gridLines(rows: 3, columns: 3)).isEmpty)
    }

    @Test func aGridNarrowerThanFiftyPointsIsRefused() {
        #expect(
            pdfDetectTablesFromLines(
                items: gridItems(rows: 3, columns: 2, cellWidth: 20),
                lines: gridLines(rows: 3, columns: 2, cellWidth: 20)
            ).isEmpty)
    }

    // MARK: the sparse path and its recursion

    private var booktabs: (lines: [PdfLineSegment], items: [PdfLayoutItem]) {
        let lines = [
            line(100, 760, 500, 760), line(100, 740, 500, 740), line(100, 700, 500, 700),
        ]
        let items = [
            item("Name", 110, 750), item("Count", 250, 750), item("Share", 390, 750),
            item("alpha", 110, 730), item("12", 250, 730, width: 20),
            item("5%", 390, 730, width: 20),
            item("beta", 110, 715), item("34", 250, 715, width: 20),
            item("9%", 390, 715, width: 20),
        ]
        return (lines, items)
    }

    @Test func horizontalRulesAloneReachTheSparseStrategies() {
        let (lines, items) = booktabs
        let tables = pdfDetectTablesFromLines(items: items, lines: lines)
        #expect(tables.count == 1)
        #expect(tables.first?.cells.first == ["Name", "Count", "Share"])
    }

    @Test func aSparseTableAndADrawnGridCanShareAPage() {
        // This is what the recursion exists for: the booktabs band is claimed,
        // its graphics removed, and the grid below is still found.
        let (bandLines, bandItems) = booktabs
        let lines = bandLines + gridLines(rows: 3, columns: 3, y0: 600)
        let items = bandItems + gridItems(rows: 3, columns: 3, y0: 600)
        let tables = pdfDetectTablesFromLines(items: items, lines: lines)
        #expect(tables.count == 2)
        // Ordered down the page.
        #expect(tables.first?.cells.first == ["Name", "Count", "Share"])
        #expect(tables.last?.cells.first == ["v00", "v01", "v02"])
    }

    @Test func theVectorOnlyEntryPointRefusesInferredColumns() {
        // Region callers need physical cell boundaries, so a booktabs band
        // yields nothing here even though the full entry point accepts it.
        let (lines, items) = booktabs
        #expect(pdfDetectTablesFromLines(items: items, lines: lines).count == 1)
        #expect(pdfDetectVectorGridTablesFromLines(items: items, lines: lines).isEmpty)
    }

    @Test func theVectorOnlyEntryPointStillFindsDrawnGrids() {
        let tables = pdfDetectVectorGridTablesFromLines(
            items: gridItems(rows: 3, columns: 3), lines: gridLines(rows: 3, columns: 3))
        #expect(tables.count == 1)
    }
}
