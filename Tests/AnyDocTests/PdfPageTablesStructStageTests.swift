import Testing

@testable import AnyDoc

/// Stage 0 of the per-page cascade: the structure tree, and the coverage gate
/// that decides whether to believe it.
///
/// Both halves are pinned here because both were measured load-bearing
/// end-to-end in wave 113 — the stage by suppressing it (`tagged-table.pdf`
/// stops matching), the gate by widening it (`tagged-table-sparse.pdf` stops
/// matching). A test that only checks the happy path would pass with the gate
/// deleted.
@Suite struct PdfPageTablesStructStageTests {
    /// A tagged item at a deliberately **ragged** x, so no two rows share a
    /// column. The alignment heuristic cannot grid this; only the tagging can.
    private func item(_ text: String, row: Int, column: Int, mcid: Int) -> PdfLayoutItem {
        PdfLayoutItem(
            text: text, x: 100 + Float(column) * 100 + Float(row) * 37,
            y: 700 - Float(row) * 20, width: 20, fontSize: 10, fontName: "F1", mcid: mcid)
    }

    private func plain(_ text: String, _ index: Int) -> PdfLayoutItem {
        PdfLayoutItem(
            text: text, x: 100, y: 500 - Float(index) * 16, width: 200, fontSize: 10,
            fontName: "F1", mcid: nil)
    }

    /// Three rows of two ragged tagged cells, mcids in reading order.
    private func taggedGrid() -> (items: [PdfLayoutItem], table: PdfStructTable) {
        var items: [PdfLayoutItem] = []
        var rows: [PdfStructTableRow] = []
        var mcid = 0
        for row in 0..<3 {
            var cells: [PdfStructTableCell] = []
            for column in 0..<2 {
                items.append(item("r\(row)c\(column)", row: row, column: column, mcid: mcid))
                cells.append(PdfStructTableCell(isHeader: false, mcids: [(mcid: mcid, page: 1)]))
                mcid += 1
            }
            rows.append(PdfStructTableRow(cells: cells))
        }
        return (items, PdfStructTable(rows: rows))
    }

    @Test func aTaggedTableIsFoundWhereGeometryFindsNothing() {
        let (items, table) = taggedGrid()

        // The control: without the tagging, the ragged geometry grids for
        // nobody. This is what makes the assertion below mean something.
        let untagged = pdfDetectPageTables(items: items, rects: [], lines: [], baseSize: 10)
        #expect(untagged.tables.isEmpty)

        let tagged = pdfDetectPageTables(
            items: items, rects: [], lines: [], baseSize: 10, structTables: [table], page: 1)
        #expect(tagged.tables.count == 1)
        #expect(tagged.tables.first?.markdown.contains("|r0c0|r0c1|") == true)
        // Every cell is claimed, so none of them also reaches the prose.
        #expect(tagged.claimed == Set(0..<6))
    }

    @Test func aTaggedTableCoveringUnderHalfThePageIsDiscarded() {
        let (grid, table) = taggedGrid()
        // Six tagged items against ten untagged lines: 6/16 is 0.375, below
        // the reference's 0.5 gate, so the declaration is not believed.
        let items = grid + (0..<10).map { plain("Paragraph number \($0).", $0) }

        let result = pdfDetectPageTables(
            items: items, rects: [], lines: [], baseSize: 10, structTables: [table], page: 1)
        #expect(result.tables.isEmpty)
        #expect(result.claimed.isEmpty)
    }

    /// Right at the boundary: exactly half is *not* under half, so it stands.
    @Test func exactlyHalfCoverageIsBelieved() {
        let (grid, table) = taggedGrid()
        let items = grid + (0..<6).map { plain("Paragraph number \($0).", $0) }

        let result = pdfDetectPageTables(
            items: items, rects: [], lines: [], baseSize: 10, structTables: [table], page: 1)
        #expect(result.tables.count == 1)
    }

    /// A tagged table on another page contributes nothing to this one — the
    /// mcids would otherwise collide, since they restart at zero per page.
    @Test func aTableTaggedOnAnotherPageIsNotClaimedHere() {
        let (items, table) = taggedGrid()
        let result = pdfDetectPageTables(
            items: items, rects: [], lines: [], baseSize: 10, structTables: [table], page: 2)
        #expect(result.tables.isEmpty)
    }
}
