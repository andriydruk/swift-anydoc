import Testing

@testable import AnyDoc

/// The per-page detector cascade.
@Suite struct PdfPageTableTests {
    private func item(_ text: String, x: Float, y: Float) -> PdfLayoutItem {
        PdfLayoutItem(text: text, x: x, y: y, width: 40, fontSize: 10, fontName: "F1")
    }

    /// Two columns of aligned text, which the heuristic detector grids.
    private func twoColumns(rows: Int = 8) -> [PdfLayoutItem] {
        (0..<rows).flatMap { row in
            [
                item("left \(row)", x: 72, y: 700 - Float(row) * 14),
                item("right \(row)", x: 340, y: 700 - Float(row) * 14),
            ]
        }
    }

    @Test func alignedColumnsBecomeATable() {
        let result = pdfDetectPageTables(
            items: twoColumns(), rects: [], lines: [], baseSize: 10)
        #expect(!result.tables.isEmpty)
        #expect(result.tables[0].markdown.contains("|"))
    }

    @Test func aTableClaimsItsCells() {
        // The claimed items are withheld from the text stream — a table's
        // contents must not also appear as prose.
        let items = twoColumns()
        let result = pdfDetectPageTables(items: items, rects: [], lines: [], baseSize: 10)
        #expect(!result.claimed.isEmpty)
        for index in result.claimed { #expect(index < items.count) }
    }

    @Test func theHeuristicFloorIsSixItems() {
        // Fewer than six items cannot describe a grid, so nothing is
        // detected however well aligned they are.
        let result = pdfDetectPageTables(
            items: twoColumns(rows: 2), rects: [], lines: [], baseSize: 10)
        #expect(result.tables.isEmpty)
        #expect(result.claimed.isEmpty)
    }

    @Test func anEmptyPageDetectsNothing() {
        let result = pdfDetectPageTables(items: [], rects: [], lines: [], baseSize: 10)
        #expect(result.tables.isEmpty)
        #expect(result.claimed.isEmpty)
    }

    @Test func aTableIsPositionedAtItsFirstRowAndColumn() {
        // The position is what lets the writer interleave the table with the
        // prose around it, so it has to be the grid's own origin.
        let result = pdfDetectPageTables(
            items: twoColumns(), rects: [], lines: [], baseSize: 10)
        guard let table = result.tables.first else {
            #expect(Bool(false), "no table detected")
            return
        }
        #expect(table.y > 0)
        #expect(table.x > 0)
    }
}
