/// The two row-shaping stages of the cell-rect stripe strategy, ported from
/// `detect_row_stripe_table_from_cell_rects` and
/// `collapse_multiline_description_rows` in pdf-inspector's
/// `tables/detect_rects.rs`.
///
/// The strategy itself is 473 lines and is being ported across two waves.
/// These two stages bracket it — one decides where the rows *start*, the other
/// fixes them up after the cells are filled — and each is a self-contained,
/// separately verifiable function. Nothing calls the strategy until the middle
/// lands.
///
/// The stage answers one question: where are the rows? Usually the
/// rectangles say — their y-edges *are* the boundaries. But cell backgrounds
/// with variable heights, or decoration fills, can leave too few distinct
/// edges to bound even two rows, and then the rows have to come from the text
/// instead, clustered by baseline.

/// Row edges for a cell-rect cluster, top first, or `nil` when neither the
/// rectangles nor the text yield enough structure.
///
/// The text fallback clusters baselines at four fifths of the median glyph
/// height, then turns each cluster *centre* into a pair of edges half a
/// glyph-height either side — so the rows it invents are one line tall,
/// which is what a cell-background table's rows are.
func pdfCellRectRowEdges(
    items: [PdfLayoutItem],
    groupRects: [(x: Float, y: Float, width: Float, height: Float)]
) -> [Float]? {
    let yEdges = pdfSnapEdges(
        groupRects.flatMap { [$0.y, $0.y + $0.height] }, tolerance: 6)

    // Four edges bound three rows — enough to be a table.
    if yEdges.count >= 4 { return yEdges.sorted(by: >) }

    // Otherwise scope by the rectangles' extent and read the rows off the
    // text. Note the reference takes its y bounds from the *snapped* edge
    // list, which may hold one or two values here, and its x bounds from the
    // rectangles — mixed sources, reproduced as written.
    let yMin = yEdges.first ?? 0
    let yMax = yEdges.last ?? 0
    let xMin = groupRects.map(\.x).min() ?? 0
    let xMax = groupRects.map { $0.x + $0.width }.max() ?? 0

    let regionItems = items.filter {
        $0.y >= yMin - 5 && $0.y <= yMax + 5 && $0.x >= xMin - 5 && $0.x <= xMax + 5
    }
    guard regionItems.count >= 4 else { return nil }

    // An item's height is its font size, as the extractor sets it.
    let heights = regionItems.map(\.fontSize).sorted()
    let medianHeight = heights[heights.count / 2]

    let ys = regionItems.map(\.y).sorted(by: >)
    let threshold = medianHeight * 0.8
    var edges: [Float] = []
    var sum = ys[0]
    var count: Float = 1
    for y in ys.dropFirst() {
        if abs(sum / count - y) > threshold {
            let centre = sum / count
            edges.append(centre + medianHeight * 0.5)
            edges.append(centre - medianHeight * 0.5)
            sum = y
            count = 1
        } else {
            sum += y
            count += 1
        }
    }
    let centre = sum / count
    edges.append(centre + medianHeight * 0.5)
    edges.append(centre - medianHeight * 0.5)

    let snapped = pdfSnapEdges(edges, tolerance: 3).sorted(by: >)
    return snapped.count >= 4 ? snapped : nil
}

/// Merge wrapped description lines back into the data row they belong to.
///
/// Some Word exports draw enough rectangle geometry to prove a table is there
/// but expose one y band per wrapped *line* rather than per row. The shape
/// that can be repaired safely is narrow: a row-label column on the left, one
/// much wider description column, and continuation bands that carry text only
/// in that wide column. Anything looser is left alone, so framed prose still
/// meets the strategy's prose guards rather than being tidied into a table.
///
/// Returns the reshaped cells, the matching row edges, and how many of the
/// merges were *description* continuations — the caller uses that count alone
/// to relax its prose check, since a header continuation says nothing about
/// whether the content is prose.
func pdfCollapseMultilineDescriptionRows(
    cells: [[String]], rowEdges: [Float], columnEdges: [Float]
) -> (cells: [[String]], rowEdges: [Float], wrappedRows: Int) {
    let rowCount = cells.count
    let columnCount = columnEdges.count >= 1 ? columnEdges.count - 1 : 0
    guard rowCount >= 3, columnCount >= 3, rowEdges.count == rowCount + 1 else {
        return (cells, rowEdges, 0)
    }

    let tableWidth = columnEdges[columnCount] - columnEdges[0]
    guard tableWidth > 0 else { return (cells, rowEdges, 0) }

    // The widest column is the description. `max_by` keeps the *last* maximum
    // on a tie, so a table of equal-width columns nominates its rightmost —
    // which the `description_col == 0` guard below then cannot reject.
    var descriptionColumn = 0
    var descriptionWidth = columnEdges[1] - columnEdges[0]
    for column in 1..<columnCount {
        let width = columnEdges[column + 1] - columnEdges[column]
        if width >= descriptionWidth {
            descriptionColumn = column
            descriptionWidth = width
        }
    }

    // A preceding row-label column is what makes "one populated wide column"
    // mean anything. Without it — a prose frame split into text-start columns
    // — there is no reliable way to tell where a visual row begins.
    guard descriptionColumn != 0, descriptionWidth >= tableWidth * 0.35 else {
        return (cells, rowEdges, 0)
    }

    func hasLeftLabel(_ row: [String]) -> Bool {
        row.prefix(descriptionColumn).contains { !$0.rustTrim().isEmpty }
    }
    guard cells.filter(hasLeftLabel).count >= 2 else { return (cells, rowEdges, 0) }

    var mergedRows = 0
    var wrappedDescriptionRows = 0
    var newCells: [[String]] = []
    var newEdges: [Float] = [rowEdges[0]]

    for (rowIndex, row) in cells.enumerated() {
        let descriptionText = (descriptionColumn < row.count ? row[descriptionColumn] : "")
            .rustTrim()
        let leftLabel = hasLeftLabel(row)
        let otherNonEmpty = row.enumerated()
            .filter { $0.offset != descriptionColumn && !$0.element.rustTrim().isEmpty }
            .count

        // A wrapped continuation carries description text and nothing else:
        // the label cell of the visual row spans the whole wrapped block, so
        // every band after the first finds it empty.
        let isDescriptionContinuation =
            rowIndex > 0 && !descriptionText.isEmpty && !leftLabel && otherNonEmpty == 0
            && !newCells.isEmpty

        // Headers wrap differently — "Controls" over "Version" in the first
        // column while the rest of the labels sit on the first band. Short
        // text, first column only, and a previous row that already looks like
        // a header row.
        let onlyFirstColumn = row.enumerated().allSatisfy {
            $0.offset == 0 || $0.element.rustTrim().isEmpty
        }
        let isHeaderContinuation =
            rowIndex > 0 && onlyFirstColumn
            && (row.first.map {
                !$0.rustTrim().isEmpty && $0.rustTrim().unicodeScalars.count <= 24
            } ?? false)
            && !newCells.isEmpty
            && (newCells.last.map { $0.filter { !$0.rustTrim().isEmpty }.count >= 2 } ?? false)

        if isDescriptionContinuation || isHeaderContinuation {
            if !newCells.isEmpty {
                for (column, cell) in row.enumerated() {
                    let text = cell.rustTrim()
                    if text.isEmpty { continue }
                    guard column < newCells[newCells.count - 1].count else { continue }
                    if !newCells[newCells.count - 1][column].rustTrim().isEmpty {
                        newCells[newCells.count - 1][column] += " "
                    }
                    newCells[newCells.count - 1][column] += text
                }
            }
            mergedRows += 1
            if isDescriptionContinuation { wrappedDescriptionRows += 1 }
        } else {
            if !newCells.isEmpty { newEdges.append(rowEdges[rowIndex]) }
            newCells.append(row)
        }
    }
    newEdges.append(rowEdges[rowEdges.count - 1])

    // The bail-out returns the *reshaped* cells with the *original* edges. If
    // it fires because merging left fewer than two rows, the two disagree in
    // length — reproduced as written, and harmless in practice because the
    // caller's own two-non-empty-row gate rejects that table immediately after.
    if mergedRows == 0 || newCells.count < 2 || newEdges.count != newCells.count + 1 {
        return (newCells, rowEdges, 0)
    }
    return (newCells, newEdges, wrappedDescriptionRows)
}
