import Testing

@testable import AnyDoc

/// The struct-tree table orchestrator, pinned without the oracle.
@Suite struct PdfStructTablesTests {
    private func cell(_ mcids: [(Int, UInt32)], header: Bool = false) -> PdfStructTableCell {
        PdfStructTableCell(isHeader: header, mcids: mcids.map { (mcid: $0.0, page: $0.1) })
    }

    private func item(_ text: String, _ x: Float, _ y: Float, mcid: Int?) -> PdfLayoutItem {
        PdfLayoutItem(
            text: text, x: x, y: y, width: 20, fontSize: 10, fontName: "F1", mcid: mcid)
    }

    /// A `rows` × `columns` tagged table numbering its mcids in reading order.
    private func grid(rows: Int, columns: Int, page: UInt32 = 1, headerFirst: Bool = false)
        -> PdfStructTable
    {
        var mcid = 0
        var built: [PdfStructTableRow] = []
        for row in 0..<rows {
            var cells: [PdfStructTableCell] = []
            for _ in 0..<columns {
                cells.append(cell([(mcid, page)], header: headerFirst && row == 0))
                mcid += 1
            }
            built.append(PdfStructTableRow(cells: cells))
        }
        return PdfStructTable(rows: built)
    }

    private func gridItems(rows: Int, columns: Int, skip: Set<Int> = []) -> [PdfLayoutItem] {
        var mcid = 0
        var items: [PdfLayoutItem] = []
        for row in 0..<rows {
            for column in 0..<columns {
                if !skip.contains(mcid) {
                    items.append(
                        item(
                            "v\(row)\(column)", 100 + Float(column) * 100,
                            700 - Float(row) * 20, mcid: mcid))
                }
                mcid += 1
            }
        }
        return items
    }

    private func detect(_ items: [PdfLayoutItem], _ tables: [PdfStructTable]) -> [PdfTable] {
        pdfDetectTablesFromStructTree(items: items, structTables: tables, page: 1)
    }

    @Test func aCleanTaggedTableIsBuilt() {
        let tables = detect(gridItems(rows: 3, columns: 3), [grid(rows: 3, columns: 3)])
        #expect(tables.count == 1)
        #expect(tables[0].cells.count == 3)
        #expect(tables[0].cells[0] == ["v00", "v01", "v02"])
    }

    @Test func noStructTablesMeansNoWork() {
        #expect(detect(gridItems(rows: 3, columns: 3), []).isEmpty)
    }

    @Test func aSingleRowOnThePageIsNotATable() {
        #expect(detect(gridItems(rows: 1, columns: 3), [grid(rows: 1, columns: 3)]).isEmpty)
    }

    @Test func aSingleColumnIsNotATable() {
        #expect(detect(gridItems(rows: 3, columns: 1), [grid(rows: 3, columns: 1)]).isEmpty)
    }

    @Test func rowsBelongingToAnotherPageAreFilteredOut() {
        // The table spans pages; only the rows with content here are ours.
        #expect(detect(gridItems(rows: 3, columns: 3), [grid(rows: 3, columns: 3, page: 2)])
            .isEmpty)
    }

    @Test func aStaleStructureTreeIsRejected() {
        // Under a third of cells resolving means the tree outlived the
        // content it describes, and the geometric detectors will do better.
        let skip = Set(1...8)
        #expect(detect(gridItems(rows: 3, columns: 3, skip: skip), [grid(rows: 3, columns: 3)])
            .isEmpty)
        // Four of nine resolving is over the line.
        #expect(
            !detect(gridItems(rows: 3, columns: 3, skip: [0, 1, 2, 3, 4]),
                [grid(rows: 3, columns: 3)]
            ).isEmpty)
    }

    @Test func cellsWithSeveralMarkedContentIdsReadDownThenAcross() {
        let table = PdfStructTable(rows: [
            PdfStructTableRow(cells: [cell([(0, 1), (1, 1)]), cell([(2, 1)])]),
            PdfStructTableRow(cells: [cell([(3, 1)]), cell([(4, 1)])]),
        ])
        let items = [
            item("top", 100, 700, mcid: 0), item("bottom", 100, 690, mcid: 1),
            item("b", 200, 700, mcid: 2), item("c", 100, 680, mcid: 3),
            item("d", 200, 680, mcid: 4),
        ]
        #expect(detect(items, [table])[0].cells[0][0] == "top bottom")
    }

    @Test func itemsWithNoMarkedContentIdAreInvisibleToIt() {
        let items = [item("loose", 100, 700, mcid: nil)] + gridItems(rows: 2, columns: 2)
        let tables = detect(items, [grid(rows: 2, columns: 2)])
        #expect(tables.count == 1)
        #expect(!tables[0].cells.flatMap { $0 }.contains("loose"))
    }

    // MARK: which candidate wins

    @Test func withoutARecoveredHeaderTheLeftAlignedTableWins() {
        // The surprising part: all the column inference above serves the
        // header recovery, not the table's own layout. With nothing recovered
        // the plain left-aligned candidate is the one returned, and its
        // columns are the crude first-row-that-can-supply-one positions.
        let tables = detect(gridItems(rows: 3, columns: 3), [grid(rows: 3, columns: 3)])
        #expect(tables[0].columns == [100, 200, 300])
        #expect(tables[0].cells.count == 3)
    }

    @Test func aRecoveredHeaderSwitchesToTheAlignedTable() {
        // A ragged row plus loose text above it: the header is recovered, and
        // that is what promotes the aligned candidate.
        var items = gridItems(rows: 3, columns: 3, skip: [4])
        items += [
            item("H0", 100, 715, mcid: nil), item("H1", 200, 715, mcid: nil),
            item("H2", 300, 715, mcid: nil),
        ]
        let tables = detect(items, [grid(rows: 3, columns: 3)])
        #expect(tables[0].cells.count == 4)
        #expect(tables[0].cells[0] == ["H0", "H1", "H2"])
    }

    @Test func anAlreadyTaggedHeaderBlocksTheRecovery() {
        // Nothing is missing, so the loose text above stays where it is.
        var items = gridItems(rows: 3, columns: 3, skip: [4])
        items += [
            item("H0", 100, 715, mcid: nil), item("H1", 200, 715, mcid: nil),
            item("H2", 300, 715, mcid: nil),
        ]
        let tables = detect(items, [grid(rows: 3, columns: 3, headerFirst: true)])
        #expect(tables[0].cells.count == 3)
    }
}
