/// Building a table from shaded row bands, ported from
/// `detect_row_stripe_table` and its helpers in pdf-inspector's
/// `tables/detect_rects.rs`.
///
/// Alternating row shading defeats grid detection outright: every stripe
/// shares an x position and width, so the edges give one column. But the
/// stripes carry perfectly good *row* boundaries, so this strategy takes rows
/// from the rectangles and columns from where the text starts.
///
/// That makes it the loosest of the rect strategies — the geometry supplies
/// only half the grid — so most of the file is the validation that follows.

/// Columns come from where text *starts*, clustered at least this far apart.
/// Lower than the heuristic path's 25pt floor: the rectangles have already
/// established this is a table, so narrow columns should stay separate.
private let pdfStripeColumnMinThreshold: Float = 15

/// Cluster x positions into columns.
///
/// Only where text *starts* counts. An item whose left edge hugs the previous
/// item's right edge on the same line is a continuation — a style boundary, a
/// script change, an underline split — and feeding its start position in
/// fabricates a phantom column in the middle of a cell.
func pdfClusterXPositions(_ items: [PdfLayoutItem], minimumThreshold: Float) -> [Float] {
    let sorted = items.sorted { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x }

    var starts: [Float] = []
    for (index, item) in sorted.enumerated() {
        var isContinuation = false
        if index > 0 {
            let previous = sorted[index - 1]
            let gap = item.x - (previous.x + previous.width)
            // A style split leaves runs that *touch*; a real cell boundary
            // keeps a visible gap even in the tightest table. The negative
            // bound matters too: text overhanging from the next cell overlaps
            // by far more than italic kerning ever does, and must still open
            // its own column.
            isContinuation =
                abs(previous.y - item.y) <= 2 && gap < 2 && gap > -4 && item.x >= previous.x
        }
        if !isContinuation { starts.append(item.x) }
    }
    starts.sort()
    guard let first = starts.first, let last = starts.last else { return [] }

    let range = last - first
    let averageGap = starts.count > 1 ? range / Float(starts.count - 1) : 60
    let threshold = min(max(averageGap, minimumThreshold), 50)

    var columns: [Float] = []
    var cluster: [Float] = [starts[0]]
    for x in starts.dropFirst() {
        let centre = cluster.reduce(0, +) / Float(cluster.count)
        if x - centre > threshold {
            columns.append(centre)
            cluster = [x]
        } else {
            cluster.append(x)
        }
    }
    if !cluster.isEmpty { columns.append(cluster.reduce(0, +) / Float(cluster.count)) }

    let minimumPerColumn = max(items.count / max(columns.count, 1) / 4, 2)
    return columns.filter { column in
        items.count(where: { abs($0.x - column) < threshold }) >= minimumPerColumn
    }
}

/// Whether one cell holds a paragraph and most of the table's words.
///
/// A chart's drawing rectangles can pass the stripe shape test, and the
/// resulting "table" then swallows the page's prose. Sixty words in a single
/// cell *and* a third of everything is the signature.
///
/// There is deliberately no small-table exemption. A short table whose one
/// long cell dominates its word count is indistinguishable by content from a
/// phantom grid over body text, and the costs are asymmetric: rejecting a real
/// table degrades it to readable prose, while accepting a phantom scrambles
/// the page into interleaved cells.
func pdfHasDominantProseCell(_ cells: [[String]]) -> Bool {
    var total = 0
    var largest = 0
    for row in cells {
        for cell in row {
            let words = cell.rustSplitWhitespace().count
            total += words
            largest = max(largest, words)
        }
    }
    return largest >= 60 && largest * 3 >= total
}

/// Whether a two-column result is really an outline of prose: a sparse label
/// column beside a dense column of sentences.
///
/// This is what a section-heading sidebar over body text looks like once
/// gridded — most rows have nothing in the label column and a long run of
/// words in the other.
func pdfRowStripeIsSparseProseOutline(_ cells: [[String]]) -> Bool {
    guard let columnCount = cells.first?.count, columnCount == 2, cells.count >= 4 else {
        return false
    }
    let nonEmptyRows = cells.count(where: { row in row.contains { !$0.rustTrim().isEmpty } })
    guard nonEmptyRows >= 4 else { return false }

    var counts = [0, 0]
    for row in cells {
        for (index, cell) in row.enumerated() where index < 2 && !cell.rustTrim().isEmpty {
            counts[index] += 1
        }
    }
    let sparse = counts[0] <= counts[1] ? 0 : 1
    let dense = 1 - sparse
    // The label column must be genuinely sparse and the other genuinely full.
    guard counts[sparse] * 2 < nonEmptyRows, counts[dense] * 3 >= nonEmptyRows * 2 else {
        return false
    }

    let blankLabelRows = cells.count(where: {
        $0[sparse].rustTrim().isEmpty && !$0[dense].rustTrim().isEmpty
    })
    guard blankLabelRows * 2 >= nonEmptyRows else { return false }

    // And the dense column must read as sentences, not values.
    let longCells = cells.count(where: { $0[dense].rustSplitWhitespace().count >= 6 })
    return longCells * 2 >= counts[dense]
}

/// Build a table from a row-stripe cluster, or reject it.
func pdfDetectRowStripeTable(
    items: [PdfLayoutItem],
    groupRects: [(x: Float, y: Float, width: Float, height: Float)]
) -> PdfTable? {
    guard pdfIsRowStripePattern(groupRects) else { return nil }

    let rowEdges = pdfSnapEdges(groupRects.flatMap { [$0.y, $0.y + $0.height] }, tolerance: 6)
        .sorted(by: >)
    guard rowEdges.count >= 4 else { return nil }

    let top = rowEdges[0]
    let bottom = rowEdges[rowEdges.count - 1]
    guard let left = groupRects.map(\.x).min(),
        let right = groupRects.map({ $0.x + $0.width }).max()
    else { return nil }

    // Only the text inside the striped band belongs to this table.
    let inside = items.enumerated().filter { _, item in
        item.y >= bottom - 2 && item.y <= top + 2 && item.x >= left - 5
            && item.x + item.width <= right + 5
    }
    guard !inside.isEmpty else { return nil }
    let insideItems = inside.map(\.element)

    let columns = pdfClusterXPositions(insideItems, minimumThreshold: pdfStripeColumnMinThreshold)
    guard columns.count >= 2 else { return nil }

    // Column *centres* become *edges*: the midpoints between them, bounded by
    // the text's own extent.
    guard let minX = insideItems.map(\.x).min(),
        let maxRight = insideItems.map({ $0.x + $0.width }).max()
    else { return nil }
    var columnEdges: [Float] = [minX - 5]
    for (a, b) in zip(columns, columns.dropFirst()) { columnEdges.append((a + b) / 2) }
    columnEdges.append(maxRight + 5)

    var columnCount = columnEdges.count - 1
    let rowCount = rowEdges.count - 1

    let (built, itemIndices) = pdfAssignItemsToGrid(
        items, columnEdges: columnEdges, rowEdges: rowEdges)
    var cells = built
    guard !itemIndices.isEmpty else { return nil }

    let nonEmptyRows = cells.count(where: { row in row.contains { !$0.rustTrim().isEmpty } })
    guard nonEmptyRows >= 2 else { return nil }

    let totalCells = Float(columnCount * rowCount)
    let nonEmptyCells = cells.flatMap { $0 }.count(where: { !$0.rustTrim().isEmpty })
    guard Float(nonEmptyCells) / totalCells >= 0.40 else { return nil }

    // A layout background — a sidebar, a header band — produces "cells"
    // holding paragraphs. A wide table may legitimately have a description
    // column, so the allowance scales, and a table with four filled rows has
    // earned the benefit of the doubt on every other gate.
    let longest = cells.flatMap { $0 }.map(\.utf8.count).max() ?? 0
    let allowed = columnCount >= 3 ? 2000 : 500
    if longest > allowed, nonEmptyRows < 4 { return nil }

    let firstFilled = (0..<columnCount).first { column in
        cells.contains { column < $0.count && !$0[column].rustTrim().isEmpty }
    }
    let lastFilled = (0..<columnCount).reversed().first { column in
        cells.contains { column < $0.count && !$0[column].rustTrim().isEmpty }
    }
    guard let firstColumn = firstFilled, let lastColumn = lastFilled, lastColumn > firstColumn
    else { return nil }
    for column in firstColumn...lastColumn {
        let hasContent = cells.contains { column < $0.count && !$0[column].rustTrim().isEmpty }
        if !hasContent { return nil }
    }
    if firstColumn > 0 || lastColumn < columnCount - 1 {
        columnEdges = Array(columnEdges[firstColumn...(lastColumn + 1)])
        cells = cells.map { Array($0[firstColumn...lastColumn]) }
        columnCount = columnEdges.count - 1
    }

    guard !pdfRowStripeIsSparseProseOutline(cells) else { return nil }
    guard !pdfHasDominantProseCell(cells) else { return nil }

    let columnCentres = (0..<columnCount).map { (columnEdges[$0] + columnEdges[$0 + 1]) / 2 }
    let rowCentres = (0..<rowCount).map { (rowEdges[$0] + rowEdges[$0 + 1]) / 2 }
    return PdfTable(
        columns: columnCentres, rows: rowCentres, cells: cells, itemIndices: itemIndices)
}
