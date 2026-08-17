/// Rejecting a table that is really two columns of prose, ported from
/// `is_parallel_prose_table` in `markdown/mod.rs`.
///
/// A chart page often sets its commentary in two columns beside the figure.
/// Projected onto a grid, those columns look exactly like a two-column
/// table — every row has a left cell and a right cell, and every cell is
/// text. Gridding them interleaves two independent arguments line by line,
/// which is worse than either column alone.
///
/// **The test is deliberately narrow.** Disabling body-font detection for
/// the whole page would be simpler and would also throw away the real tables
/// that share a page with a chart. So this rejects a *candidate*, and only
/// on the evidence that its cells are prose fragments running in parallel
/// rather than values in rows.
///
/// The decisive signal is **cross-row continuation**: a cell that ends
/// mid-sentence and continues in the cell directly below it, in the same
/// column. A lowercase cell alone proves nothing — headerless tables use
/// sentence fragments as values all the time — but a sentence physically
/// broken across two grid rows is what independent prose columns produce and
/// a table does not.
func pdfIsParallelProseTable(_ table: PdfTable) -> Bool {
    // Only a data table of two or three columns and three-plus rows: a wider
    // grid is not what two prose columns project onto.
    guard table.kind == .data, (2...3).contains(table.columns.count), table.rows.count >= 3
    else { return false }

    var nonEmpty = 0
    var longProse = 0
    var rowsWithParallelProse = 0
    var occupiedRows = 0

    // A section heading swallowed into the grid is direct evidence that the
    // candidate is page prose rather than a table.
    let hasNumberedSectionHeading = table.cells.contains { row in
        row.contains { pdfLooksLikeNumberedSectionHeading($0) }
    }

    // A first row of short, filled cells is a header, and a headed candidate
    // is a real table however prose-like its body.
    let hasCompactHeader =
        table.cells.first(where: { row in row.contains { !$0.rustTrim().isEmpty } })
        .map { row -> Bool in
            let filled = row.filter { !$0.rustTrim().isEmpty }
            return filled.count >= 2
                && filled.allSatisfy {
                    $0.split(whereSeparator: \.isWhitespace).count <= 4
                        && $0.rustTrim().unicodeScalars.count <= 28
                }
        } ?? false

    for row in table.cells {
        var rowLongProse = 0
        var rowNonEmpty = 0
        for cell in row {
            let text = cell.rustTrim()
            if text.isEmpty { continue }
            nonEmpty += 1
            rowNonEmpty += 1
            let characters = text.unicodeScalars.count { !$0.properties.isWhitespace }
            let alphabetic = text.unicodeScalars.count { $0.properties.isAlphabetic }
            let words = text.split(whereSeparator: \.isWhitespace).count
            // Long, wordy and mostly letters: a sentence, not a value.
            if characters >= 28 && words >= 5 && alphabetic * 5 >= characters * 3 {
                longProse += 1
                rowLongProse += 1
            }
        }
        if rowLongProse >= 2 { rowsWithParallelProse += 1 }
        if rowNonEmpty > 0 { occupiedRows += 1 }
    }

    // Sentences broken across a physical row boundary, counted per column.
    var continuationFragments = 0
    var continuationColumns = [Bool](repeating: false, count: table.columns.count)
    for index in table.cells.indices.dropLast() {
        let previousRow = table.cells[index]
        let currentRow = table.cells[index + 1]
        for column in continuationColumns.indices {
            let previous = column < previousRow.count ? previousRow[column] : ""
            let current = column < currentRow.count ? currentRow[column] : ""
            if pdfIsCrossRowProseContinuation(previous, current) {
                continuationFragments += 1
                continuationColumns[column] = true
            }
        }
    }

    return !hasCompactHeader
        && nonEmpty >= 5
        // A fully populated grid argues *for* a real table: independent prose
        // columns break asynchronously and leave holes.
        && nonEmpty < table.cells.count * table.columns.count
        && longProse >= 4
        && longProse * 5 >= nonEmpty * 3
        // Parallel long text on at least half the occupied rows — or on one
        // row, if a section heading was swallowed too.
        && ((rowsWithParallelProse >= 2 && rowsWithParallelProse * 2 >= occupiedRows)
            || (rowsWithParallelProse >= 1 && hasNumberedSectionHeading))
        && continuationFragments >= 3
        && continuationColumns.count(where: { $0 }) >= 2
}
