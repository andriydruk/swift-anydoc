import Testing

@testable import AnyDoc

/// Gates of the cell-rect stripe strategy, pinned without the oracle.
@Suite struct PdfCellRectTableTests {
    /// A grid of drawn cell rectangles, `rows` × `columns`.
    private func grid(rows: Int, columns: Int, cellWidth: Float = 60, cellHeight: Float = 20)
        -> [(x: Float, y: Float, width: Float, height: Float)]
    {
        var rects: [(x: Float, y: Float, width: Float, height: Float)] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let x: Float = 100 + Float(column) * cellWidth
                let y: Float = 700 - Float(row) * cellHeight
                rects.append((x: x, y: y, width: cellWidth, height: cellHeight))
            }
        }
        return rects
    }

    /// One item near the top-left of each cell of that grid.
    private func fill(
        rows: Int, columns: Int, cellWidth: Float = 60, cellHeight: Float = 20,
        text: (Int, Int) -> String
    ) -> [PdfLayoutItem] {
        var items: [PdfLayoutItem] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let x: Float = 110 + Float(column) * cellWidth
                let y: Float = 705 - Float(row) * cellHeight
                items.append(
                    PdfLayoutItem(
                        text: text(row, column), x: x, y: y, width: 30, fontSize: 10,
                        fontName: "F1"))
            }
        }
        return items
    }

    @Test func aPlainGridBecomesATable() {
        let table = pdfDetectRowStripeTableFromCellRects(
            items: fill(rows: 3, columns: 3) { "v\($0)\($1)" }, groupRects: grid(rows: 3, columns: 3))
        #expect(table?.cells.count == 3)
        #expect(table?.columns.count == 3)
        #expect(table?.cells.first == ["v00", "v01", "v02"])
    }

    @Test func fewerThanSixRectanglesIsNotACluster() {
        // The strategy is a last resort, and refuses to guess from five cells.
        #expect(
            pdfDetectRowStripeTableFromCellRects(
                items: fill(rows: 1, columns: 5) { "v\($0)\($1)" },
                groupRects: grid(rows: 1, columns: 5)) == nil)
    }

    @Test func aSparseGridIsRejectedOnDensity() {
        // Nine cells drawn, two filled: under the quarter the gate demands.
        let items = [
            PdfLayoutItem(text: "a", x: 110, y: 705, width: 30, fontSize: 10, fontName: "F1"),
            PdfLayoutItem(text: "b", x: 110, y: 685, width: 30, fontSize: 10, fontName: "F1"),
        ]
        #expect(
            pdfDetectRowStripeTableFromCellRects(items: items, groupRects: grid(rows: 3, columns: 3))
                == nil)
    }

    @Test func aTallSkinnyGridIsDecoration() {
        // 25 rows against 2 columns: rectangles used for layout, not a table.
        #expect(
            pdfDetectRowStripeTableFromCellRects(
                items: fill(rows: 25, columns: 2) { "v\($0)\($1)" },
                groupRects: grid(rows: 25, columns: 2)) == nil)
    }

    @Test func theSameGridSurvivesAtFourColumns() {
        // The proportion gate needs *both* halves — height alone is not
        // evidence, since long four-column tables are ordinary.
        let table = pdfDetectRowStripeTableFromCellRects(
            items: fill(rows: 25, columns: 4) { "v\($0)\($1)" },
            groupRects: grid(rows: 25, columns: 4))
        #expect(table?.cells.count == 25)
    }

    @Test func aParagraphInAShortTableIsALayoutBackground() {
        // Over 500 bytes in one cell with fewer than four filled rows.
        let wall = String(repeating: "lorem ipsum dolor sit amet ", count: 25)
        var items = fill(rows: 3, columns: 3) { "v\($0)\($1)" }
        items.append(
            PdfLayoutItem(text: wall, x: 110, y: 665, width: 30, fontSize: 10, fontName: "F1"))
        #expect(
            pdfDetectRowStripeTableFromCellRects(items: items, groupRects: grid(rows: 3, columns: 3))
                == nil)
    }

    @Test func proseFillingEveryCellIsRejectedOnMeanLength() {
        // Every cell a sentence fragment: over 65 characters on average, and
        // no collapsed rows to explain it.
        let fragments = [
            "this is a description of the control and how it is applied in practice",
            "the value was set by hand and has not been reviewed since that time",
            "each of these items is a fragment of a sentence that wrapped in a frame",
        ]
        let items = fill(rows: 4, columns: 3) { fragments[($0 + $1) % 3] }
        #expect(
            pdfDetectRowStripeTableFromCellRects(items: items, groupRects: grid(rows: 4, columns: 3))
                == nil)
    }

    @Test func shortProseInWellDistributedColumnsSurvives() {
        // The same prose-word trigger fires, but the cells are short and every
        // column is populated — a real "label / value / note" table.
        let short = ["the total", "of each", "is set", "in use"]
        let items = fill(rows: 4, columns: 3) { short[($0 + $1) % 4] }
        let table = pdfDetectRowStripeTableFromCellRects(
            items: items, groupRects: grid(rows: 4, columns: 3))
        #expect(table != nil)
        #expect(table?.cells.count == 4)
    }

    @Test func dataThatIsNotProseSkipsTheContentGatesEntirely() {
        // Under a fifth of the cells hold a function word, so the whole prose
        // block is bypassed however long the cells are.
        let items = fill(rows: 4, columns: 3) { "reading-\($0)\($1)-\(String(repeating: "9", count: 60))" }
        #expect(
            pdfDetectRowStripeTableFromCellRects(items: items, groupRects: grid(rows: 4, columns: 3))
                != nil)
    }

    @Test func cellCentresAreReportedNotEdges() {
        // The table carries column and row *centres*, which is what the
        // downstream writer positions text against.
        let table = pdfDetectRowStripeTableFromCellRects(
            items: fill(rows: 3, columns: 3) { "v\($0)\($1)" }, groupRects: grid(rows: 3, columns: 3))
        // Cells are 60pt wide from x=100, so the centres sit at 130, 190, 250.
        #expect(table?.columns == [130, 190, 250])
        // Rows run down the page, so their centres descend.
        #expect(table?.rows == [710, 690, 670])
    }
}
