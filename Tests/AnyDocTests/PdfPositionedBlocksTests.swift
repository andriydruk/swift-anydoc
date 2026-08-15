import Testing

@testable import AnyDoc

/// Tables and images placed back into the reading order.
@Suite struct PdfPositionedBlocksTests {
    /// A page whose chart spans y 300…400 with prose columns split at x 300.
    /// The pad widens the band to 292…408.
    private let order = PdfChartProseOrder(splitX: 300, chartRegion: (0, 300, 600, 400))

    private func block(y: Float, x: Float, chart: Bool = true) -> PdfPositionedMarkdown {
        PdfPositionedMarkdown(y: y, x: x, markdown: "md", chartOrder: chart ? order : nil)
    }

    private func textLine(y: Float, xs: [Float] = []) -> PdfTextLine {
        PdfTextLine(
            items: xs.map {
                PdfLayoutItem(text: "t", x: $0, y: y, width: 10, fontSize: 10, fontName: "F1")
            }, y: y)
    }

    // MARK: - chart_stream_position

    @Test func theBandIsPaddedByEightOnEachSide() {
        // 408 is still the band; 409 is above it. 292 is still the band; 291
        // is below.
        #expect(pdfChartStreamPosition(y: 409, x: 0, claimedByChart: false, order: order).zone == 0)
        #expect(pdfChartStreamPosition(y: 408, x: 0, claimedByChart: false, order: order).zone == 1)
        #expect(pdfChartStreamPosition(y: 292, x: 0, claimedByChart: false, order: order).zone == 1)
        #expect(pdfChartStreamPosition(y: 291, x: 0, claimedByChart: false, order: order).zone == 2)
    }

    @Test func theColumnSplitIsStrict() {
        // Outside the band, x below the split is the left column.
        #expect(
            pdfChartStreamPosition(y: 500, x: 299, claimedByChart: false, order: order).column == 0)
        #expect(
            pdfChartStreamPosition(y: 500, x: 300, claimedByChart: false, order: order).column == 1)
    }

    @Test func theBandItselfHasNoColumns() {
        // A full-width chart spans both columns, so everything in the band
        // is column zero whatever its x.
        for x in [Float(0), 299, 300, 600] {
            let position = pdfChartStreamPosition(
                y: 350, x: x, claimedByChart: false, order: order)
            #expect(position == (1, 0), "x \(x)")
        }
    }

    @Test func beingClaimedByTheChartOverridesGeometry() {
        // A run belonging to the chart is in the band wherever it sits.
        for y in [Float(500), 200] {
            let position = pdfChartStreamPosition(
                y: y, x: 600, claimedByChart: true, order: order)
            #expect(position == (1, 0), "y \(y)")
        }
    }

    @Test func anUpsideDownBandIsNormalised() {
        let flipped = PdfChartProseOrder(splitX: 300, chartRegion: (0, 400, 600, 300))
        #expect(
            pdfChartStreamPosition(y: 350, x: 0, claimedByChart: false, order: flipped)
                == (1, 0))
    }

    // MARK: - positioned_block_precedes_line

    @Test func withoutAChartOrderTheComparisonIsBareBaseline() {
        #expect(pdfPositionedBlockPrecedesLine(block(y: 700, x: 20, chart: false), textLine(y: 600)))
        #expect(
            !pdfPositionedBlockPrecedesLine(block(y: 600, x: 20, chart: false), textLine(y: 700)))
        // Strictly greater, so an equal baseline does not precede.
        #expect(
            !pdfPositionedBlockPrecedesLine(block(y: 700, x: 20, chart: false), textLine(y: 700)))
    }

    @Test func theStreamPositionOutranksTheBaseline() {
        // A block below the chart cannot precede a line above it, however
        // the baselines compare — and this is the whole point of the type.
        #expect(!pdfPositionedBlockPrecedesLine(block(y: 200, x: 20), textLine(y: 500, xs: [20])))
        #expect(pdfPositionedBlockPrecedesLine(block(y: 500, x: 20), textLine(y: 200, xs: [20])))
        // Within one zone the left column leads the right.
        #expect(pdfPositionedBlockPrecedesLine(block(y: 500, x: 20), textLine(y: 500, xs: [400])))
        #expect(!pdfPositionedBlockPrecedesLine(block(y: 500, x: 400), textLine(y: 500, xs: [20])))
    }

    @Test func aLineWithNoItemsReadsAsTheLeftColumn() {
        // No items means x zero, which puts the line left of any split.
        #expect(!pdfPositionedBlockPrecedesLine(block(y: 500, x: 400), textLine(y: 500)))
    }

    // MARK: - positioned_blocks_for_page

    private func shape(_ blocks: [PdfPositionedBlockRef]) -> [String] {
        blocks.map { "\($0.kind == .table ? "T" : "I")\($0.index)" }
    }

    @Test func ordinaryPagesKeepTablesThenImagesInDetectionOrder() {
        // Geometry is ignored entirely off a chart page: the image at 900 is
        // the highest block and still comes last.
        let result = pdfPositionedBlocksForPage(
            tables: [block(y: 100, x: 20, chart: false), block(y: 700, x: 20, chart: false)],
            images: [block(y: 400, x: 20, chart: false), block(y: 900, x: 20, chart: false)])
        #expect(shape(result) == ["T0", "T1", "I0", "I1"])
    }

    @Test func aChartPageOrdersByStreamPosition() {
        // T1 is above the chart, I0 is inside it, T0 is below.
        let result = pdfPositionedBlocksForPage(
            tables: [block(y: 200, x: 20), block(y: 500, x: 20)],
            images: [block(y: 350, x: 20)])
        #expect(shape(result) == ["T1", "I0", "T0"])
    }

    @Test func equalPositionsFallBackToDescendingBaselineThenX() {
        let result = pdfPositionedBlocksForPage(
            tables: [block(y: 500, x: 400), block(y: 500, x: 20)], images: [])
        #expect(shape(result) == ["T1", "T0"])
    }

    @Test func oneOrdinaryBlockDropsThePairToTheLegacyOrder() {
        // The image is higher on the page and carries no chart order, so the
        // comparison never reaches the stream logic and the table leads.
        let result = pdfPositionedBlocksForPage(
            tables: [block(y: 200, x: 20)], images: [block(y: 500, x: 20, chart: false)])
        #expect(shape(result) == ["T0", "I0"])
    }

    @Test func anEmptyPageSortsToNothing() {
        #expect(pdfPositionedBlocksForPage(tables: [], images: []).isEmpty)
    }
}
