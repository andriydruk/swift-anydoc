import Testing

@testable import AnyDoc

/// Row alignment for tagged tables, pinned without the oracle.
@Suite struct PdfStructRowsTests {
    private func cell(
        _ text: String = "", items: [Int] = [], x: Float? = nil, y: Float? = nil
    ) -> PdfMatchedCell {
        PdfMatchedCell(text: text, itemIndices: items, x: x, y: y)
    }

    // MARK: position-based

    @Test func positionedCellsLandInTheColumnsTheyMatch() {
        let rows = [[cell("a", items: [0], x: 100, y: 700), cell("b", items: [1], x: 300, y: 700)]]
        let result = pdfAlignStructRows(rows, columnPositions: [100, 200, 300])
        #expect(result.cells == [["a", "", "b"]])
        #expect(result.itemIndices == [0, 1])
    }

    @Test func oneUnpositionedCellSendsTheWholeRowLeft() {
        // A partial set of positions would misplace the rest, so the row
        // fills from the left instead of trusting them.
        let rows = [[cell("a", items: [0], x: 100, y: 700), cell("b", items: [1], y: 700)]]
        #expect(pdfAlignStructRows(rows, columnPositions: [100, 200, 300]).cells == [["a", "b", ""]])
    }

    @Test func anEmptyButPositionedCellStillHoldsItsColumn() {
        // Otherwise every column after it would shift left.
        let rows = [[cell(x: 100, y: 700), cell("b", items: [1], x: 300, y: 700)]]
        #expect(pdfAlignStructRows(rows, columnPositions: [100, 200, 300]).cells == [["", "", "b"]])
    }

    @Test func aWhollyAbsentCellIsSkippedWithoutShiftingTheRest() {
        // No text, no items, no position — nothing to place. Dropping it does
        // not pull the following cell leftwards, because position still
        // decides where that one goes.
        let rows = [[cell(), cell("b", items: [1], x: 300, y: 700)]]
        #expect(pdfAlignStructRows(rows, columnPositions: [100, 200, 300]).cells == [["", "", "b"]])
    }

    @Test func twoCellsNeverShareAColumn() {
        // Both assignment paths yield strictly increasing indices — the
        // dynamic program by construction, and the fallback because it is the
        // identity — so the space-joining branch in the reference is
        // unreachable. Cells 5pt apart still land in separate columns.
        let rows = [[cell("a", items: [0], x: 100, y: 700), cell("b", items: [1], x: 105, y: 700)]]
        #expect(pdfAlignStructRows(rows, columnPositions: [100, 300]).cells == [["a", "b"]])
    }

    @Test func cellsPastTheColumnsLoseTheirItemsToo() {
        // The zip stops at the shorter side, so a dropped cell's items stay
        // unclaimed rather than being attributed to a cell never emitted.
        let rows = [[
            cell("a", items: [0], x: 100, y: 700), cell("b", items: [1], x: 200, y: 700),
            cell("c", items: [2], x: 300, y: 700),
        ]]
        let result = pdfAlignStructRows(rows, columnPositions: [100])
        #expect(result.cells == [["a"]])
        #expect(result.itemIndices == [0])
    }

    @Test func aRowTakesTheHighestBaselineItsCellsReport() {
        let rows = [[cell("a", items: [0], x: 100, y: 690), cell("b", items: [1], x: 200, y: 700)]]
        #expect(pdfAlignStructRows(rows, columnPositions: [100, 200]).rowPositions == [700])
    }

    @Test func aRowWithNoBaselineSitsAtZero() {
        let rows = [[cell("a", items: [0], x: 100), cell("b", items: [1], x: 200)]]
        #expect(pdfAlignStructRows(rows, columnPositions: [100, 200]).rowPositions == [0])
    }

    @Test func noColumnsProducesEmptyRows() {
        let rows = [[cell("a", items: [0], x: 100, y: 700)]]
        let result = pdfAlignStructRows(rows, columnPositions: [])
        #expect(result.cells == [[]])
        // Nothing was placed, so nothing is claimed.
        #expect(result.itemIndices.isEmpty)
    }

    // MARK: left-aligned

    @Test func leftAlignmentTruncatesAndPads() {
        let rows = [[cell("a", items: [0]), cell("b", items: [1]), cell("c", items: [2])]]
        #expect(pdfLeftAlignStructRows(rows, columnCount: 2).cells == [["a", "b"]])
        #expect(pdfLeftAlignStructRows(rows, columnCount: 4).cells == [["a", "b", "c", ""]])
    }

    @Test func leftAlignmentClaimsEveryItemEvenPastTheTruncation() {
        // The opposite of the positioned path, which drops them.
        let rows = [[cell("a", items: [0]), cell("b", items: [1]), cell("c", items: [2])]]
        #expect(pdfLeftAlignStructRows(rows, columnCount: 1).itemIndices == [0, 1, 2])
    }

    @Test func leftAlignmentKeepsCellsThePositionedPathWouldSkip() {
        // An entirely empty cell still occupies its slot here.
        let rows = [[cell(), cell("b", items: [1])]]
        #expect(pdfLeftAlignStructRows(rows, columnCount: 2).cells == [["", "b"]])
    }

    @Test func bothStrategiesAgreeOnRowBaselines() {
        let rows = [[cell("a", items: [0], x: 100, y: 690), cell("b", items: [1], x: 200, y: 700)]]
        #expect(
            pdfAlignStructRows(rows, columnPositions: [100, 200]).rowPositions
                == pdfLeftAlignStructRows(rows, columnCount: 2).rowPositions)
    }

    @Test func noRowsGiveNothing() {
        #expect(pdfAlignStructRows([], columnPositions: [100]).cells.isEmpty)
        #expect(pdfLeftAlignStructRows([], columnCount: 2).cells.isEmpty)
    }
}
