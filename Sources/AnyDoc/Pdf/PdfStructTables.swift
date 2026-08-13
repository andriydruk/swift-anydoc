/// Building tables from the structure tree, ported from
/// `detect_tables_from_struct_tree` and `legacy_column_positions` in
/// pdf-inspector's `tables/detect_struct.rs`.
///
/// This is the orchestrator for waves 48–51: it matches the tree's cells to
/// the page's text through marked-content ids, then builds *two* candidate
/// tables from the result and picks between them.
///
/// Nothing produces tables on a real document yet — `PdfLayoutItem.mcid` is
/// never set, because the extractor's `BDC`/`EMC` tracking is unported. The
/// detector is complete and verified against the reference; it is waiting on
/// that one input.

/// Column positions taken from the first row that can supply each column.
///
/// A fallback for `infer_column_positions`: crude, since it takes whichever
/// row happens to have a resolvable item, but it never fails. A column no row
/// can supply is left at zero rather than dropped, so the result always has
/// `columnCount` entries.
func pdfLegacyColumnPositions(
    pageRows: [PdfStructTableRow],
    mcidToItems: [Int: [Int]],
    items: [PdfLayoutItem],
    page: UInt32,
    columnCount: Int
) -> [Float] {
    var positions = [Float](repeating: 0, count: columnCount)
    for column in 0..<columnCount {
        for row in pageRows where column < row.cells.count {
            let xs = row.cells[column].mcids
                .filter { $0.page == page }
                .flatMap { mcidToItems[$0.mcid] ?? [] }
                .map { items[$0].x }
            if let x = xs.min() {
                positions[column] = x
                break
            }
        }
    }
    return positions
}

/// Tables for one page, built from the structure tree's table descriptors.
func pdfDetectTablesFromStructTree(
    items: [PdfLayoutItem], structTables: [PdfStructTable], page: UInt32
) -> [PdfTable] {
    if structTables.isEmpty { return [] }

    var mcidToItems: [Int: [Int]] = [:]
    for (index, item) in items.enumerated() {
        if let mcid = item.mcid { mcidToItems[mcid, default: []].append(index) }
    }

    var tables: [PdfTable] = []

    for structTable in structTables {
        // A table may span pages; only the rows with content here are ours.
        let pageRows = structTable.rows.filter { row in
            row.cells.contains { cell in cell.mcids.contains { $0.page == page } }
        }
        if pageRows.count < 2 { continue }

        let columnCount = pageRows.map(\.cells.count).max() ?? 0
        if columnCount < 2 { continue }

        var rawRows: [[PdfMatchedCell]] = []
        var totalCells = 0
        var matchedCells = 0

        for row in pageRows {
            var rowCells: [PdfMatchedCell] = []
            for cell in row.cells {
                totalCells += 1

                var cellItems: [(index: Int, item: PdfLayoutItem)] = []
                for reference in cell.mcids where reference.page == page {
                    for index in mcidToItems[reference.mcid] ?? [] {
                        cellItems.append((index, items[index]))
                    }
                }
                if !cellItems.isEmpty { matchedCells += 1 }

                // Down the page, then left to right — reading order within
                // the cell. Sorted stably, as the reference's sort is.
                cellItems.sort {
                    $0.item.y != $1.item.y
                        ? $0.item.y > $1.item.y
                        : ($0.item.x != $1.item.x ? $0.item.x < $1.item.x : $0.index < $1.index)
                }

                rowCells.append(
                    PdfMatchedCell(
                        text: cellItems.map(\.item.text).joined(separator: " "),
                        itemIndices: cellItems.map(\.index),
                        x: cellItems.map(\.item.x).min(),
                        y: cellItems.map(\.item.y).max()))
            }
            rawRows.append(rowCells)
        }

        // A structure tree can outlive the content it describes. Under a third
        // of cells resolving means it is stale, and the geometric detectors
        // will do better.
        let coverage = totalCells > 0 ? Float(matchedCells) / Float(totalCells) : 0
        if totalCells == 0 || coverage < 0.3 { continue }

        // A row missing a position for any column is ragged — the signal that
        // the tagging is incomplete.
        let hasRaggedRows = rawRows.contains { row in
            row.filter { $0.x != nil }.count < columnCount
        }
        // Unless the first row is already tagged as a header, in which case
        // nothing is missing and there is nothing to recover.
        let firstRowHasTaggedHeader = pageRows.first.map { row in
            row.cells.filter(\.isHeader).count * 2 >= row.cells.count
        } ?? false

        let fallbackPositions = pdfLegacyColumnPositions(
            pageRows: pageRows, mcidToItems: mcidToItems, items: items, page: page,
            columnCount: columnCount)

        let legacy = pdfLeftAlignStructRows(rawRows, columnCount: columnCount)
        let legacyTable = PdfTable(
            columns: fallbackPositions, rows: legacy.rowPositions, cells: legacy.cells,
            itemIndices: pdfDeduplicatedSorted(legacy.itemIndices.sorted()))

        let columnPositions = pdfInferColumnPositions(
            rowPositions: rawRows.map { $0.map(\.x) }, fallback: fallbackPositions,
            columnCount: columnCount)
        let aligned = pdfAlignStructRows(rawRows, columnPositions: columnPositions)
        var alignedTable = PdfTable(
            columns: columnPositions, rows: aligned.rowPositions, cells: aligned.cells,
            itemIndices: pdfDeduplicatedSorted(aligned.itemIndices.sorted()))

        let itemsBefore = alignedTable.itemIndices.count
        let rowsBefore = alignedTable.cells.count
        pdfRecoverUnclaimedHeaderRow(
            &alignedTable, items: items,
            hasRaggedRows: hasRaggedRows && !firstRowHasTaggedHeader)
        let recoveredHeader =
            alignedTable.itemIndices.count > itemsBefore || alignedTable.cells.count > rowsBefore

        // The position-aligned table is used **only** when a header was
        // actually recovered. Otherwise the plain left-aligned one wins — so
        // all the column inference above serves the header recovery rather
        // than the table's own layout. Reproduced as written; it reads like a
        // conservatism about trusting inferred positions when nothing
        // corroborates them.
        tables.append(recoveredHeader ? alignedTable : legacyTable)
    }

    return tables
}
