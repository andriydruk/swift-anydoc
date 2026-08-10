/// Building a table from a cluster of drawn rectangles, ported from
/// `try_build_grid` and `propagate_merged_cells` in pdf-inspector's
/// `tables/detect_rects.rs`.
///
/// Wave 23 worked out which rectangles belong together; this decides whether
/// that cluster is actually a *grid*. The rectangles' own edges become the
/// column and row boundaries, and then a long series of tests asks whether
/// the result looks like a table or like a form's scattered field boxes.
///
/// The tests are cumulative and mostly negative, which is the same shape as
/// the heuristic strategy: evidence for a table is easy to manufacture, so
/// most of the code is about refusing.

/// Why a cluster did not become a table.
enum PdfGridResult: Equatable {
    case ok(PdfTable)
    /// Structurally a grid, but too few rows carried content — usually
    /// because merged-cell propagation collapsed the text upward. The caller
    /// retries differently rather than giving up.
    case fewNonEmptyRows
    /// Not a grid: bad dimensions, too sparse, or a bad column.
    case failed
}

/// Edges within this distance are the same edge, and a rectangle within it
/// counts as covering a cell.
private let pdfGridEdgeTolerance: Float = 6.0

/// A form with scattered field boxes yields a huge sparse grid. Statistical
/// lookup tables legitimately reach twenty-odd columns, so the cap is 25.
private let pdfGridMaxColumns = 25

/// Build a table from a rectangle cluster, or say why not.
///
/// `skipRects` marks rectangles excluded from *column* edges — a page
/// background contributes page-boundary edges that would manufacture empty
/// margin columns — though they still count for row edges and cell coverage.
///
/// `strict` is the retry mode used after page backgrounds are removed: it
/// demands more content before believing the result.
func pdfTryBuildGrid(
    items: [PdfLayoutItem],
    groupRects: [(x: Float, y: Float, width: Float, height: Float)],
    skipRects: [Bool],
    strict: Bool
) -> PdfGridResult {
    var xEdges: [Float] = []
    var yEdges: [Float] = []
    for (index, rect) in groupRects.enumerated() {
        if index < skipRects.count, !skipRects[index] {
            xEdges.append(rect.x)
            xEdges.append(rect.x + rect.width)
        }
        yEdges.append(rect.y)
        yEdges.append(rect.y + rect.height)
    }

    let snappedX = pdfSnapEdges(xEdges, tolerance: pdfGridEdgeTolerance)
    let snappedY = pdfSnapEdges(yEdges, tolerance: pdfGridEdgeTolerance)
    // Three column edges give two columns; four row edges give three rows —
    // the row bar is deliberately higher, because two rows of ruling is as
    // often a header underline as a table.
    guard snappedX.count >= 3, snappedY.count >= 4 else { return .failed }

    let columnEdges = snappedX.sorted()
    let rowEdges = snappedY.sorted(by: >)
    let columnCount = columnEdges.count - 1
    let rowCount = rowEdges.count - 1
    guard columnCount >= 2, rowCount >= 2, columnCount <= pdfGridMaxColumns else {
        return .failed
    }

    // The edges could come from anywhere; a real grid has rectangles that
    // actually cover its cells.
    var filled = 0
    for row in 0..<rowCount {
        let top = rowEdges[row]
        let bottom = rowEdges[row + 1]
        for column in 0..<columnCount {
            let left = columnEdges[column]
            let right = columnEdges[column + 1]
            let covered = groupRects.contains { rect in
                rect.x <= left + pdfGridEdgeTolerance
                    && rect.x + rect.width >= right - pdfGridEdgeTolerance
                    && rect.y <= top + pdfGridEdgeTolerance
                    && rect.y + rect.height >= bottom - pdfGridEdgeTolerance
            }
            if covered { filled += 1 }
        }
    }
    let totalCells = Float(columnCount * rowCount)
    guard Float(filled) / totalCells >= 0.3 else { return .failed }

    var (cells, itemIndices) = pdfAssignItemsToGrid(
        items, columnEdges: columnEdges, rowEdges: rowEdges)

    // A rectangle spanning several rows is a merged cell. Not attempted on
    // wide tables, where a spanning rectangle is usually row-group shading
    // rather than a real merge.
    if columnCount <= 10 {
        pdfPropagateMergedCells(
            &cells, columnEdges: columnEdges, rowEdges: rowEdges,
            groupRects: groupRects, skipRects: skipRects)
    }

    let columns = (0..<columnCount).map { (columnEdges[$0] + columnEdges[$0 + 1]) / 2 }
    let rows = (0..<rowCount).map { (rowEdges[$0] + rowEdges[$0 + 1]) / 2 }

    guard !itemIndices.isEmpty else { return .failed }

    let nonEmptyRows = cells.count(where: { row in row.contains { !$0.rustTrim().isEmpty } })
    let minimumRows = strict ? rowCount / 2 : 2
    // Distinguished from `.failed` because the caller can retry: the text may
    // have been collapsed upward by merged-cell propagation.
    guard nonEmptyRows >= minimumRows else { return .fewNonEmptyRows }

    let nonEmptyCells = cells.flatMap { $0 }.count(where: { !$0.rustTrim().isEmpty })
    guard Float(nonEmptyCells) / totalCells >= (strict ? 0.40 : 0.25) else { return .failed }

    // A very long cell in strict mode means a paragraph was swept into the
    // grid rather than a table being found.
    if strict {
        let longest = cells.flatMap { $0 }.map(\.utf8.count).max() ?? 0
        if longest > 200 { return .failed }
    }

    // Rectangle edges can reach past the text. Empty *outer* columns are
    // trimmed; an empty *interior* column means the grid is wrong.
    let firstFilled = (0..<columnCount).first { column in
        cells.contains { column < $0.count && !$0[column].rustTrim().isEmpty }
    }
    let lastFilled = (0..<columnCount).reversed().first { column in
        cells.contains { column < $0.count && !$0[column].rustTrim().isEmpty }
    }
    guard let firstColumn = firstFilled, let lastColumn = lastFilled, lastColumn > firstColumn
    else { return .failed }

    for column in firstColumn...lastColumn {
        let hasContent = cells.contains { column < $0.count && !$0[column].rustTrim().isEmpty }
        if !hasContent { return .failed }
    }

    if firstColumn > 0 || lastColumn < columnCount - 1 {
        return .ok(
            PdfTable(
                columns: Array(columns[firstColumn...lastColumn]), rows: rows,
                cells: cells.map { Array($0[firstColumn...lastColumn]) },
                itemIndices: itemIndices))
    }
    return .ok(
        PdfTable(columns: columns, rows: rows, cells: cells, itemIndices: itemIndices))
}

/// Gather the text of a vertically merged cell into its first row.
///
/// A rectangle spanning several grid rows — a label covering a group of
/// sub-rows — leaves its text in whichever sub-row it happened to sit in.
/// Collecting it into the first and clearing the rest lets the table
/// formatter's continuation merging collapse the group correctly.
func pdfPropagateMergedCells(
    _ cells: inout [[String]],
    columnEdges: [Float],
    rowEdges: [Float],
    groupRects: [(x: Float, y: Float, width: Float, height: Float)],
    skipRects: [Bool]
) {
    guard columnEdges.count >= 2, rowEdges.count >= 2 else { return }
    let columnCount = columnEdges.count - 1
    let rowCount = rowEdges.count - 1

    for column in 0..<columnCount {
        for (index, rect) in groupRects.enumerated() {
            // A page background spans every row and would collapse the whole
            // column into its first cell.
            if index < skipRects.count, skipRects[index] { continue }
            // The rectangle has to cover this column.
            if rect.x > columnEdges[column] + pdfGridEdgeTolerance
                || rect.x + rect.width < columnEdges[column + 1] - pdfGridEdgeTolerance
            {
                continue
            }

            // Genuine *overlap* is required, not mere tolerance slack. A
            // rectangle whose top exactly meets a row's bottom lies entirely
            // below that row, yet a bounds-with-slack test would call it a
            // span — cascading unrelated rows into one merged cell.
            func spans(_ row: Int) -> Bool {
                let top = rowEdges[row]
                let bottom = rowEdges[row + 1]
                let overlap = max(min(top, rect.y + rect.height) - max(bottom, rect.y), 0)
                return overlap > pdfGridEdgeTolerance
            }
            guard let first = (0..<rowCount).first(where: spans),
                let last = (0..<rowCount).reversed().first(where: spans),
                last > first
            else { continue }

            var combined = ""
            for row in first...last where column < cells[row].count {
                let text = cells[row][column].rustTrim()
                if text.isEmpty { continue }
                if !combined.isEmpty { combined += " " }
                combined += text
            }
            if column < cells[first].count { cells[first][column] = combined }
            for row in (first + 1)...last where column < cells[row].count {
                cells[row][column] = ""
            }
        }
    }
}
