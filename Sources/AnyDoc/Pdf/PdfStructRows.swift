/// Turning tagged table rows into a rectangular grid, ported from
/// `align_struct_rows` and `left_align_struct_rows` in pdf-inspector's
/// `tables/detect_struct.rs`.
///
/// The structure tree gives rows of varying length. A Markdown table needs
/// every row the same width, so each has to be placed into a fixed set of
/// columns — and there are two ways to do that, depending on whether the cells
/// were positioned at all.

/// A cell recovered from the structure tree, before it has a column.
struct PdfMatchedCell {
    var text: String = ""
    /// Indices into the page's text items, carried so the caller can mark
    /// them consumed.
    var itemIndices: [Int] = []
    var x: Float?
    var y: Float?
}

/// One row's worth of output.
struct PdfAlignedRows: Equatable {
    var cells: [[String]]
    /// Each row's baseline: the *highest* y any of its cells reported, since
    /// a row sits at the top of its tallest cell.
    var rowPositions: [Float]
    var itemIndices: [Int]
}

/// Place cells into columns by position.
///
/// A cell counts as present if it has text, items, or a position — an empty
/// but positioned cell still occupies a column, which is what keeps the
/// columns after it from shifting left.
///
/// Positions are only trusted when *every* present cell has one. A row where
/// some cells were never positioned falls back to filling from the left,
/// because a partial set of positions would misplace the rest.
func pdfAlignStructRows(
    _ rawRows: [[PdfMatchedCell]], columnPositions: [Float]
) -> PdfAlignedRows {
    var cells: [[String]] = []
    var rowPositions: [Float] = []
    var itemIndices: [Int] = []

    for row in rawRows {
        let present = row.filter { !$0.itemIndices.isEmpty || !$0.text.isEmpty || $0.x != nil }
        let cellXs = present.compactMap(\.x)
        let assignments =
            cellXs.count == present.count
            ? pdfAlignPositionsToColumns(cellXs: cellXs, columns: columnPositions)
            : Array(0..<min(present.count, columnPositions.count))

        var rowCells = [String](repeating: "", count: columnPositions.count)
        // The zip stops at the shorter side. When the alignment ran out of
        // columns, the trailing cells are dropped *and so are their item
        // indices* — so those items stay unclaimed rather than being silently
        // attributed to a cell that was never emitted.
        for (cell, column) in zip(present, assignments) {
            if !cell.text.isEmpty {
                // Unreachable in practice: both assignment paths give
                // strictly increasing indices — the dynamic program by
                // construction, the fallback because it is the identity — so
                // no column is ever written twice. Kept because the reference
                // has it, and a future change to either path would need it.
                if !rowCells[column].isEmpty { rowCells[column] += " " }
                rowCells[column] += cell.text
            }
            itemIndices.append(contentsOf: cell.itemIndices)
        }

        cells.append(rowCells)
        rowPositions.append(row.compactMap(\.y).max() ?? 0)
    }

    return PdfAlignedRows(cells: cells, rowPositions: rowPositions, itemIndices: itemIndices)
}

/// Place cells into columns by order alone, padding or truncating to width.
///
/// Used when the positions are not trustworthy. Note this keeps *every* cell
/// of the row, including ones the position-based path would have treated as
/// absent, and claims every item index even from cells past the truncation
/// point — the opposite of the other strategy on both counts.
func pdfLeftAlignStructRows(
    _ rawRows: [[PdfMatchedCell]], columnCount: Int
) -> PdfAlignedRows {
    var cells: [[String]] = []
    var rowPositions: [Float] = []
    var itemIndices: [Int] = []

    for row in rawRows {
        var rowCells = row.map(\.text)
        if rowCells.count > columnCount { rowCells = Array(rowCells.prefix(columnCount)) }
        while rowCells.count < columnCount { rowCells.append("") }
        cells.append(rowCells)

        itemIndices.append(contentsOf: row.flatMap(\.itemIndices))
        rowPositions.append(row.compactMap(\.y).max() ?? 0)
    }

    return PdfAlignedRows(cells: cells, rowPositions: rowPositions, itemIndices: itemIndices)
}
