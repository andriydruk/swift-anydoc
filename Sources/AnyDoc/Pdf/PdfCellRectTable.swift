/// The cell-rect stripe strategy, ported from
/// `detect_row_stripe_table_from_cell_rects` in pdf-inspector's
/// `tables/detect_rects.rs`.
///
/// This is the last resort among the rectangle strategies, and the one that
/// has to work hardest to avoid false positives. It runs when a cluster has
/// enough drawn cells to suggest a table but not enough regular geometry for
/// the grid builder, so both the rows and the columns may have to be inferred
/// — and a page frame full of wrapped prose produces exactly the same surface
/// signal as a real label/value table. Most of the function is therefore
/// gates: density, proportion, cell length, and finally a content-based prose
/// test that reads the cells' words.
///
/// The row-shaping ends live in `PdfCellRectRows.swift`; this is the middle.

/// English function words. A cell holding one of these is prose-shaped; when
/// a fifth of the cells are, the region is suspected of being a paragraph
/// rather than a table.
private let pdfProseWords: Set<String> = [
    "a", "an", "the", "of", "to", "is", "was", "are", "were", "be", "been", "in", "on",
    "at", "with", "for", "by", "as", "and", "or", "but", "this", "that", "these", "those",
    "from", "into", "has", "have", "had", "not", "don't", "doesn't", "it's", "its", "it",
    "i", "me", "my", "we", "our", "us", "you", "your", "they", "them", "their", "he",
    "she", "his", "her",
]

/// Prose-in-a-frame averages 70–100 characters per non-empty cell; a real
/// data table is usually under 30, and up to about 55 for a descriptive one.
private let pdfProseMeanCharThreshold = 65

/// A table from a cluster of drawn cell rectangles, or `nil` when the region
/// fails any of the gates.
func pdfDetectRowStripeTableFromCellRects(
    items: [PdfLayoutItem],
    groupRects: [(x: Float, y: Float, width: Float, height: Float)]
) -> PdfTable? {
    guard groupRects.count >= 6 else { return nil }
    guard let rowEdgesFromShape = pdfCellRectRowEdges(items: items, groupRects: groupRects)
    else { return nil }

    // A rectangle ten times the median height is a background, not a cell.
    let heights = groupRects.map(\.height).sorted()
    let medianHeight = heights[heights.count / 2]
    let contentRects = groupRects.filter { $0.height < medianHeight * 10 }
    guard !contentRects.isEmpty else { return nil }

    guard let xLeft = contentRects.map(\.x).min(),
        let xRight = contentRects.map({ $0.x + $0.width }).max()
    else { return nil }
    let yTop = rowEdgesFromShape[0]
    let yBottom = rowEdgesFromShape[rowEdgesFromShape.count - 1]

    let pageItems = items.filter {
        $0.y >= yBottom - 2 && $0.y <= yTop + 2 && $0.x >= xLeft - 5
            && $0.x + $0.width <= xRight + 5
    }
    guard !pageItems.isEmpty else { return nil }

    // Columns from where the text starts: midpoints between clusters, with
    // the outer edges pushed 5pt past the text.
    let columns = pdfClusterXPositions(pageItems, minimumThreshold: 15)
    var textColumnEdges: [Float]?
    if columns.count >= 2 {
        guard let minX = pageItems.map(\.x).min(),
            let maxRight = pageItems.map({ $0.x + $0.width }).max()
        else { return nil }
        var edges: [Float] = [minX - 5]
        for pair in zip(columns, columns.dropFirst()) { edges.append((pair.0 + pair.1) / 2) }
        edges.append(maxRight + 5)
        textColumnEdges = edges
    }

    // Columns from the drawn cell borders. Beyond 26 edges the rectangles are
    // decoration rather than a grid.
    var rectColumnEdges: [Float]?
    let snappedX = pdfSnapEdges(contentRects.flatMap { [$0.x, $0.x + $0.width] }, tolerance: 6)
        .sorted()
    if (3...26).contains(snappedX.count) { rectColumnEdges = snappedX }

    // Rect borders are ground truth when a header is centred and the body
    // left-aligned: text clustering drops the header-only cluster and merges
    // two data clusters, losing a column. But only when every rect column
    // actually holds text — decorative frames and cell-fill borders otherwise
    // split one logical column into several.
    var rectColumnsMatchText = false
    if let rectEdges = rectColumnEdges, rectEdges.count >= 4 {
        let rectColumnCount = rectEdges.count - 1
        var counts = [Int](repeating: 0, count: rectColumnCount)
        for item in pageItems {
            let centre = item.x + item.width / 2
            for column in 0..<rectColumnCount
            where centre >= rectEdges[column] - 2 && centre <= rectEdges[column + 1] + 2 {
                counts[column] += 1
                break
            }
        }
        rectColumnsMatchText = counts.allSatisfy { $0 >= 2 }
    }

    let columnEdges: [Float]
    let columnsFromText: Bool
    switch (rectColumnEdges, textColumnEdges) {
    case (.some(let rectEdges), _) where rectColumnsMatchText:
        (columnEdges, columnsFromText) = (rectEdges, false)
    case (.some(let rectEdges), .some(let textEdges)) where rectEdges.count <= textEdges.count:
        (columnEdges, columnsFromText) = (rectEdges, false)
    case (_, .some(let textEdges)):
        (columnEdges, columnsFromText) = (textEdges, true)
    case (.some(let rectEdges), .none):
        (columnEdges, columnsFromText) = (rectEdges, false)
    case (.none, .none):
        return nil
    }
    guard columnEdges.count >= 3 else { return nil }
    let columnCount = columnEdges.count - 1

    // Note the *whole* item list is assigned, not the region-filtered one —
    // the edges alone decide what falls inside.
    let assigned = pdfAssignItemsToGrid(
        items, columnEdges: columnEdges, rowEdges: rowEdgesFromShape)
    guard !assigned.itemIndices.isEmpty else { return nil }

    let collapsed = pdfCollapseMultilineDescriptionRows(
        cells: assigned.cells, rowEdges: rowEdgesFromShape, columnEdges: columnEdges)
    let cells = collapsed.cells
    let rowEdges = collapsed.rowEdges
    let hasWrappedDescriptionRows = collapsed.wrappedRows > 0

    let nonEmptyRows = cells.filter { row in row.contains { !$0.rustTrim().isEmpty } }.count
    guard nonEmptyRows >= 2 else { return nil }

    let rowCount = cells.count
    let totalCells = Float(columnCount * rowCount)
    let nonEmptyCells = cells.reduce(0) { $0 + $1.filter { !$0.rustTrim().isEmpty }.count }
    let density = totalCells > 0 ? Float(nonEmptyCells) / totalCells : 0
    guard density >= 0.25 else { return nil }

    // A wall of prose in one big rectangle: a layout background, not a table.
    // `len()` is bytes in the reference, so the bar is lower for non-ASCII.
    let maxCellLength = cells.flatMap { $0 }.map(\.utf8.count).max() ?? 0
    if maxCellLength > 500 && nonEmptyRows < 4 { return nil }

    // A 68×2 grid comes from decoration, not from a table.
    if rowCount > 20 && columnCount < 4 { return nil }

    if columnCount >= 2 {
        var proseCells = 0
        var counted = 0
        var totalCharacters = 0
        for row in cells {
            for cell in row {
                let trimmed = cell.rustTrim()
                if trimmed.isEmpty { continue }
                counted += 1
                totalCharacters += trimmed.unicodeScalars.count
                // Words are runs of ASCII letters and apostrophes. Split on
                // scalars rather than characters: the reference tests bytes,
                // so a letter carrying a combining mark is two word breaks to
                // it, not one letter (§2 gotcha 5).
                let lower = trimmed.asciiLowercased()
                var word = String.UnicodeScalarView()
                var hasProseWord = false
                for scalar in lower.unicodeScalars {
                    if (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
                        || scalar == "'"
                    {
                        word.append(scalar)
                    } else {
                        if pdfProseWords.contains(String(word)) { hasProseWord = true }
                        word = String.UnicodeScalarView()
                    }
                }
                if pdfProseWords.contains(String(word)) { hasProseWord = true }
                if hasProseWord { proseCells += 1 }
            }
        }

        if counted > 0 && proseCells * 5 >= counted {
            // Integer division, as in the reference.
            let meanCharacters = totalCharacters / counted
            // Long cells are the strongest prose signal, and override the
            // well-distributed relaxation below — unless the rows were
            // collapsed, which explains the length honestly.
            if meanCharacters > pdfProseMeanCharThreshold && !hasWrappedDescriptionRows {
                return nil
            }

            // Two columns inferred from text starts alone are not evidence
            // enough once the content reads as prose. A real two-column table
            // still passes when its scaffold came from drawn geometry.
            if columnsFromText && columnCount == 2 { return nil }

            // Three quarters of the columns holding two or more filled cells
            // admits a real "label / value / description" table while still
            // catching a paragraph split into many spurious columns.
            let filledColumns = (0..<columnCount).filter { column in
                cells.filter { row in
                    !(column < row.count ? row[column] : "").rustTrim().isEmpty
                }.count >= 2
            }.count
            guard filledColumns * 4 >= columnCount * 3 else { return nil }
        }
    }

    let columnCentres = (0..<columnCount).map { (columnEdges[$0] + columnEdges[$0 + 1]) / 2 }
    // The reference indexes `row_edges` here without checking, and gets away
    // with it: the only collapse bail-out that returns mismatched lengths is
    // the one leaving under two rows, which the non-empty-row gate above has
    // already rejected. The guard is therefore unreachable, and kept only so
    // a future change to either side cannot turn a mismatch into a crash.
    guard rowEdges.count >= rowCount + 1 else { return nil }
    let rowCentres = (0..<rowCount).map { (rowEdges[$0] + rowEdges[$0 + 1]) / 2 }

    return PdfTable(
        columns: columnCentres, rows: rowCentres, cells: cells,
        itemIndices: assigned.itemIndices)
}
