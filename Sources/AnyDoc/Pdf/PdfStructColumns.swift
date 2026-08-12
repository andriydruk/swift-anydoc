/// Column inference for tagged tables, ported from `infer_column_positions`
/// and `align_positions_to_columns` in pdf-inspector's
/// `tables/detect_struct.rs`.
///
/// The structure tree says which cells exist and how they group into rows, but
/// nothing about where the columns sit — that has to come from where the cells
/// were actually drawn. And rows disagree: a row may be short because cells
/// were merged, or because the tagging is ragged, so the columns cannot simply
/// be read off the first row.

/// Two x positions within this distance are the same column.
private let pdfSameColumnTolerance: Float = 18

/// Where the columns of a tagged table sit.
///
/// The widest row — the one exposing the most positions — supplies the
/// anchors, since it is the row least likely to be missing a column. Anything
/// still missing is filled from the other rows' positions in ascending order,
/// then from the caller's fallback, and finally by repeating the last anchor
/// so the result always has `columnCount` entries.
///
/// That final padding is what lets the caller index by column without
/// bounds-checking, at the cost of several columns claiming the same x.
func pdfInferColumnPositions(
    rowPositions: [[Float?]], fallback: [Float], columnCount: Int
) -> [Float] {
    // `max_by_key` keeps the *last* maximum, so the lowest row wins a tie.
    var anchors: [Float] = []
    var bestCount = -1
    for row in rowPositions {
        let count = row.compactMap { $0 }.count
        if count >= bestCount {
            bestCount = count
            anchors = row.compactMap { $0 }
        }
    }

    if anchors.count > columnCount { anchors = Array(anchors.prefix(columnCount)) }

    // Every position any row exposed, smallest first, so filling proceeds
    // left to right across the page.
    let additional = rowPositions.flatMap { $0.compactMap { $0 } }.sorted()
    for x in additional {
        if anchors.count >= columnCount { break }
        if anchors.allSatisfy({ abs(x - $0) > pdfSameColumnTolerance }) {
            anchors.append(x)
            anchors.sort()
        }
    }

    if anchors.count < columnCount {
        for x in fallback {
            if anchors.count >= columnCount { break }
            if anchors.allSatisfy({ abs(x - $0) > pdfSameColumnTolerance }) {
                anchors.append(x)
                anchors.sort()
            }
        }
    }

    // Reached only when nothing was taken from the fallback either — which,
    // since the fill above runs first, means the fallback was empty or
    // `columnCount` was zero. In the latter case the fallback is returned
    // untouched, whatever its length.
    if anchors.isEmpty { return fallback }

    while anchors.count < columnCount, let last = anchors.last { anchors.append(last) }
    return anchors
}

/// Assign a row's cells to columns, keeping their order and minimising total
/// displacement.
///
/// A short row is the interesting case: three cells against five columns could
/// be columns 0–2, or 0/2/4, or any other increasing choice. This picks the
/// assignment with the least total distance by dynamic programming, which is
/// what keeps a ragged row's cells under the headings they belong to rather
/// than packed against the left edge.
///
/// When there are at least as many cells as columns the alignment is trivially
/// the identity — the reference does not attempt to choose among them.
func pdfAlignPositionsToColumns(cellXs: [Float], columns: [Float]) -> [Int] {
    if cellXs.isEmpty || columns.isEmpty { return [] }
    if cellXs.count >= columns.count { return Array(0..<min(cellXs.count, columns.count)) }

    // `cost[i][j]` is the least total displacement placing the first `i` cells
    // among the first `j` columns.
    var cost = [[Float]](
        repeating: [Float](repeating: .infinity, count: columns.count + 1),
        count: cellXs.count + 1)
    var taken = [[Bool]](
        repeating: [Bool](repeating: false, count: columns.count + 1),
        count: cellXs.count + 1)
    for index in cost[0].indices { cost[0][index] = 0 }

    for i in 1...cellXs.count {
        for j in 1...columns.count {
            let skipCost = cost[i][j - 1]
            let takeCost = cost[i - 1][j - 1] + abs(cellXs[i - 1] - columns[j - 1])
            // Ties take the column rather than skipping it. Since `j` is
            // filled left to right, the *last* equal cost wins, so a cell
            // exactly between two columns lands in the right-hand one.
            if takeCost <= skipCost {
                cost[i][j] = takeCost
                taken[i][j] = true
            } else {
                cost[i][j] = skipCost
            }
        }
    }

    var assignments: [Int] = []
    var i = cellXs.count
    var j = columns.count
    while i > 0 && j > 0 {
        if taken[i][j] {
            assignments.append(j - 1)
            i -= 1
            j -= 1
        } else {
            j -= 1
        }
    }
    // Walked backwards, so the result is reversed. Note it can be shorter than
    // the cell count when the walk runs out of columns first.
    return assignments.reversed()
}
