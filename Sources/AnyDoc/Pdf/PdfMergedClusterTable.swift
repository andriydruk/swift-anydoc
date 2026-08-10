/// The last-resort rect strategy, ported from `detect_merged_cluster_table`
/// in pdf-inspector's `tables/detect_rects.rs`.
///
/// This is what runs when the clusters have been merged back together and no
/// individual one formed a grid. It takes rows from every rectangle's y-edges
/// and columns from where the text starts — the same halves-from-different-
/// places approach as the row-stripe strategy, but without requiring the
/// stripe shape first.
///
/// Being the loosest strategy of all, it carries the strictest gates: 40%
/// content, no empty column *anywhere* (not merely no empty interior one, as
/// grid building allows), and the same dominant-prose guard the stripe path
/// uses.
func pdfDetectMergedClusterTable(
    items: [PdfLayoutItem],
    allRects: [(x: Float, y: Float, width: Float, height: Float)]
) -> PdfTable? {
    let rowEdges = pdfSnapEdges(allRects.flatMap { [$0.y, $0.y + $0.height] }, tolerance: 6)
        .sorted(by: >)
    guard rowEdges.count >= 4 else { return nil }

    let top = rowEdges[0]
    let bottom = rowEdges[rowEdges.count - 1]
    guard let left = allRects.map(\.x).min(),
        let right = allRects.map({ $0.x + $0.width }).max()
    else { return nil }

    let inside = items.filter { item in
        item.y >= bottom - 2 && item.y <= top + 2 && item.x >= left - 5
            && item.x + item.width <= right + 5
    }
    guard !inside.isEmpty else { return nil }

    let columns = pdfClusterXPositions(inside, minimumThreshold: 15)
    guard columns.count >= 2 else { return nil }

    guard let minX = inside.map(\.x).min(),
        let maxRight = inside.map({ $0.x + $0.width }).max()
    else { return nil }
    var columnEdges: [Float] = [minX - 5]
    for (a, b) in zip(columns, columns.dropFirst()) { columnEdges.append((a + b) / 2) }
    columnEdges.append(maxRight + 5)

    let columnCount = columnEdges.count - 1
    let rowCount = rowEdges.count - 1

    let (cells, itemIndices) = pdfAssignItemsToGrid(
        items, columnEdges: columnEdges, rowEdges: rowEdges)
    guard !itemIndices.isEmpty else { return nil }

    let nonEmptyRows = cells.count(where: { row in row.contains { !$0.rustTrim().isEmpty } })
    guard nonEmptyRows >= 2 else { return nil }

    let totalCells = Float(columnCount * rowCount)
    let nonEmptyCells = cells.flatMap { $0 }.count(where: { !$0.rustTrim().isEmpty })
    guard Float(nonEmptyCells) / totalCells >= 0.40 else { return nil }

    // A layout background produces "cells" holding paragraphs. A multi-row
    // key/value table may legitimately have one long descriptive column, so
    // only narrow-row layouts are rejected on length.
    let longest = cells.flatMap { $0 }.map(\.utf8.count).max() ?? 0
    if longest > 500, nonEmptyRows < 4 { return nil }
    guard !pdfHasDominantProseCell(cells) else { return nil }

    // Every column must carry something. Grid building tolerates empty outer
    // columns and trims them; here an empty column anywhere is fatal, because
    // there is no rectangle geometry backing the column positions at all —
    // they came from the text, so an empty one means the clustering was wrong.
    for column in 0..<columnCount {
        let hasContent = cells.contains { column < $0.count && !$0[column].rustTrim().isEmpty }
        if !hasContent { return nil }
    }

    let columnCentres = (0..<columnCount).map { (columnEdges[$0] + columnEdges[$0 + 1]) / 2 }
    let rowCentres = (0..<rowCount).map { (rowEdges[$0] + rowEdges[$0 + 1]) / 2 }
    return PdfTable(
        columns: columnCentres, rows: rowCentres, cells: cells, itemIndices: itemIndices)
}
