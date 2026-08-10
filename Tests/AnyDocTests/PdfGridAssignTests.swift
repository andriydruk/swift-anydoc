import Testing

@testable import AnyDoc

/// Filling a detected grid with text.
@Suite struct PdfGridAssignTests {
    private func item(_ text: String, x: Float, y: Float, width: Float = 40) -> PdfLayoutItem {
        PdfLayoutItem(text: text, x: x, y: y, width: width, fontSize: 10, fontName: "F1")
    }

    /// Edges bound cells, so `n` edges give `n - 1` columns — unlike the
    /// heuristic path, where columns are positions.
    @Test func edgesBoundCellsRatherThanNamingThem() {
        let (cells, indices) = pdfAssignItemsToGrid(
            [
                item("a", x: 110, y: 710), item("b", x: 210, y: 710),
                item("c", x: 110, y: 690), item("d", x: 210, y: 690),
            ],
            columnEdges: [100, 200, 300], rowEdges: [720, 700, 680])
        #expect(cells == [["a", "b"], ["c", "d"]])
        #expect(indices == [0, 1, 2, 3])
    }

    /// An item outside every cell is simply not the table's.
    @Test func itemsOutsideTheGridAreDropped() {
        let (cells, indices) = pdfAssignItemsToGrid(
            [item("in", x: 110, y: 710), item("out", x: 500, y: 710), item("low", x: 110, y: 400)],
            columnEdges: [100, 200], rowEdges: [720, 700])
        #expect(cells == [["in"]])
        #expect(indices == [0])
    }

    /// Horizontally an item is placed by its centre, so one straddling a
    /// border goes to the side its middle falls on.
    @Test func horizontalPlacementUsesTheCentre() {
        let (cells, _) = pdfAssignItemsToGrid(
            [item("x", x: 180, y: 710, width: 40)],
            columnEdges: [100, 200, 300], rowEdges: [720, 700])
        // Centre is 200, which the slack puts in the first cell.
        #expect(cells[0][0] == "x")
    }

    /// Vertically it is placed by its *baseline*, not its centre, so a tall
    /// glyph does not migrate into the row above.
    @Test func verticalPlacementUsesTheBaseline() {
        var tall = item("tall", x: 110, y: 690)
        tall.fontSize = 40
        let (cells, _) = pdfAssignItemsToGrid(
            [tall], columnEdges: [100, 200], rowEdges: [720, 700, 680])
        #expect(cells[0][0].isEmpty)
        #expect(cells[1][0] == "tall")
    }

    /// Within a cell, items read down the page then left to right.
    @Test func aCellReadsInItsOwnOrder() {
        let (cells, _) = pdfAssignItemsToGrid(
            [
                item("second", x: 110, y: 690), item("right", x: 200, y: 710),
                item("left", x: 110, y: 710),
            ],
            columnEdges: [100, 300], rowEdges: [720, 680])
        #expect(cells[0][0] == "left right second")
    }

    /// Joining fragments with spaces puts one wherever the producer broke the
    /// run; a break beside a bracket reads wrong and is closed up.
    @Test func spacesInsideBracketsAreClosed() {
        #expect(pdfRemoveInnerDelimiterSpaces("a ( b )") == "a (b)")
        #expect(pdfRemoveInnerDelimiterSpaces("x [ 1 ] y") == "x [1] y")
        #expect(pdfRemoveInnerDelimiterSpaces("{ z }") == "{z}")
        // Only the inner side: the space before an opening bracket stays.
        #expect(pdfRemoveInnerDelimiterSpaces("a (b)") == "a (b)")
        #expect(pdfRemoveInnerDelimiterSpaces("no brackets") == "no brackets")
    }

    @Test func tooFewEdgesBoundNothing() {
        let (cells, indices) = pdfAssignItemsToGrid(
            [item("x", x: 110, y: 710)], columnEdges: [100], rowEdges: [720])
        #expect(cells.isEmpty)
        #expect(indices.isEmpty)
    }
}
