import Testing

@testable import AnyDoc

/// Behaviour of the cell-rect row-shaping stages, pinned without the oracle.
@Suite struct PdfCellRectRowsTests {
    private func item(_ text: String, _ x: Float, _ y: Float, width: Float = 30, size: Float = 10)
        -> PdfLayoutItem
    {
        PdfLayoutItem(text: text, x: x, y: y, width: width, fontSize: size, fontName: "F1")
    }

    // MARK: row edges

    @Test func rectEdgesWinWhenThereAreEnoughOfThem() {
        // Three stacked bands give six raw edges, four of which survive
        // snapping at 6pt — enough to bound rows without touching the text.
        let rects = [
            (x: Float(50), y: Float(700), width: Float(200), height: Float(20)),
            (x: 50, y: 670, width: 200, height: 20),
            (x: 50, y: 640, width: 200, height: 20),
        ]
        let edges = pdfCellRectRowEdges(items: [], groupRects: rects)
        #expect(edges == [720, 700, 690, 670, 660, 640])
    }

    @Test func textSuppliesTheRowsWhenTheRectsCannot() {
        // One band: two edges only, so the rows come from four baselines
        // clustered at 8pt (0.8 × the 10pt median height).
        let rects = [(x: Float(50), y: Float(600), width: Float(200), height: Float(120))]
        let items = [
            item("a", 60, 700), item("b", 120, 700),
            item("c", 60, 660), item("d", 120, 660),
        ]
        let edges = pdfCellRectRowEdges(items: items, groupRects: rects)
        // Each cluster centre becomes a one-glyph-tall row.
        #expect(edges == [705, 695, 665, 655])
    }

    @Test func tooLittleTextInTheRegionIsNotATable() {
        let rects = [(x: Float(50), y: Float(600), width: Float(200), height: Float(120))]
        let items = [item("a", 60, 700), item("b", 120, 700), item("c", 60, 660)]
        #expect(pdfCellRectRowEdges(items: items, groupRects: rects) == nil)
    }

    @Test func textOutsideTheRectExtentIsIgnored() {
        // The x bound comes from the rectangles, so an item to the right of
        // them does not count — leaving three, one short of the minimum.
        let rects = [(x: Float(50), y: Float(600), width: Float(200), height: Float(120))]
        let items = [
            item("a", 60, 700), item("b", 120, 700), item("c", 60, 660),
            item("far", 900, 660),
        ]
        #expect(pdfCellRectRowEdges(items: items, groupRects: rects) == nil)
    }

    @Test func oneTextRowIsNotEnoughStructure() {
        // Four items on a single baseline produce one cluster, hence two
        // edges — below the four the fallback demands.
        let rects = [(x: Float(50), y: Float(600), width: Float(200), height: Float(120))]
        let items = (0..<4).map { item("c\($0)", 60 + Float($0) * 30, 700) }
        #expect(pdfCellRectRowEdges(items: items, groupRects: rects) == nil)
    }

    // MARK: collapsing

    private let wideEdges: [Float] = [50, 100, 400]
    private let threeColumnEdges: [Float] = [50, 100, 150, 400]

    @Test func wrappedDescriptionLinesJoinTheRowAbove() {
        let cells = [
            ["1", "", "opens the file"],
            ["", "", "and closes it again"],
            ["2", "", "second entry"],
        ]
        let result = pdfCollapseMultilineDescriptionRows(
            cells: cells, rowEdges: [700, 690, 680, 670], columnEdges: threeColumnEdges)
        #expect(result.cells == [["1", "", "opens the file and closes it again"], ["2", "", "second entry"]])
        #expect(result.rowEdges == [700, 680, 670])
        #expect(result.wrappedRows == 1)
    }

    @Test func headerContinuationsMergeButDoNotRelaxTheProseCheck() {
        // Short first-column text under a populated header row is a wrapped
        // header, not a wrapped description — so it merges, yet reports zero.
        let cells = [
            ["Controls", "ref", "Description of the control"],
            ["Version", "", ""],
            ["1", "", "a body row"],
        ]
        let result = pdfCollapseMultilineDescriptionRows(
            cells: cells, rowEdges: [700, 690, 680, 670], columnEdges: threeColumnEdges)
        #expect(result.cells.first?.first == "Controls Version")
        #expect(result.cells.count == 2)
        #expect(result.wrappedRows == 0)
    }

    @Test func aDescriptionColumnOnTheLeftIsRefused() {
        // The widest column is column 0, so there is no label column in front
        // of it and no safe way to find where a visual row starts.
        let cells = [
            ["a wide first column", "x", "y"],
            ["", "", ""],
            ["another", "p", "q"],
        ]
        let edges: [Float] = [50, 400, 420, 440]
        let result = pdfCollapseMultilineDescriptionRows(
            cells: cells, rowEdges: [700, 690, 680, 670], columnEdges: edges)
        #expect(result.cells == cells)
        #expect(result.wrappedRows == 0)
    }

    @Test func aNarrowDescriptionColumnIsRefused() {
        // Widest, but under 35% of the table — no column dominates enough to
        // be read as the description.
        let cells = [["1", "a", "b"], ["", "", "c"], ["2", "d", "e"]]
        let edges: [Float] = [50, 150, 260, 350]
        let result = pdfCollapseMultilineDescriptionRows(
            cells: cells, rowEdges: [700, 690, 680, 670], columnEdges: edges)
        #expect(result.wrappedRows == 0)
        #expect(result.cells == cells)
    }

    @Test func fewerThanTwoLabelledRowsIsRefused() {
        let cells = [["1", "", "only label"], ["", "", "wrap"], ["", "", "wrap again"]]
        let result = pdfCollapseMultilineDescriptionRows(
            cells: cells, rowEdges: [700, 690, 680, 670], columnEdges: threeColumnEdges)
        #expect(result.cells == cells)
    }

    @Test func twoColumnTablesAreLeftAlone() {
        // The shape needs three columns, so a label/description pair — which
        // is exactly what wrapped prose in a frame looks like — never merges.
        let cells = [["1", "opens the file"], ["", "and closes it"], ["2", "second"]]
        let result = pdfCollapseMultilineDescriptionRows(
            cells: cells, rowEdges: [700, 690, 680, 670], columnEdges: wideEdges)
        #expect(result.cells == cells)
        #expect(result.wrappedRows == 0)
    }

    @Test func mismatchedEdgeCountsAreLeftAlone() {
        let cells = [["1", "", "a"], ["", "", "b"], ["2", "", "c"]]
        let result = pdfCollapseMultilineDescriptionRows(
            cells: cells, rowEdges: [700, 690], columnEdges: threeColumnEdges)
        #expect(result.cells == cells)
        #expect(result.rowEdges == [700, 690])
    }

    @Test func collapsingBelowTwoRowsReturnsTheOriginalEdges() {
        // A wrapped header followed by a wrapped description leaves a single
        // row. The reference then returns the *reshaped* cells with the
        // *original* edges, which no longer agree in length; the caller
        // rejects the table on its own two-row gate immediately afterwards.
        //
        // Reaching this at all takes a header continuation, because that is
        // the only merge that still counts as a labelled row — and two
        // labelled rows are required before any merging happens.
        let cells = [
            ["Controls", "ref", "Description"],
            ["Version", "", ""],
            ["", "", "wrapped text"],
        ]
        let rowEdges: [Float] = [700, 690, 680, 670]
        let result = pdfCollapseMultilineDescriptionRows(
            cells: cells, rowEdges: rowEdges, columnEdges: threeColumnEdges)
        #expect(result.cells.count == 1)
        #expect(result.rowEdges == rowEdges)
        #expect(result.wrappedRows == 0)
    }
}
