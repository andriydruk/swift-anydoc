/// Stage 3 of the per-page cascade: building a table from rectangles that
/// refused to grid, ported from `try_build_rect_guided_table` and
/// `split_merged_numbers` in `tables/mod.rs`.
///
/// The other rect detector wants a **grid** — rows and columns of cells it
/// can read off directly. A calendar does not give it one: the day boxes are
/// there, but the month has ragged first and last weeks, holidays draw no
/// box at all, and a legend sits off to the side. So the grid detector
/// declines and the layout falls through to the alignment heuristic, which
/// reads a calendar as prose.
///
/// This stage takes the weaker signal the rects still carry — their **x
/// positions** — as column boundaries, and derives the rows from the text
/// alone. It is deliberately narrow: five columns minimum, and one row must
/// end up with five non-empty cells, or it returns nothing and the heuristic
/// gets its turn as before.

/// Build a table from a hint cluster's rectangles, or return nothing.
///
/// - Parameters:
///   - items: the text inside the hint region, in page order.
///   - clusterRects: the rectangles the hint was built from. Only their `x`
///     is read — the widths and heights are what failed to grid.
func pdfBuildRectGuidedTable(
    items: [PdfLayoutItem], clusterRects: [(x: Float, y: Float, width: Float, height: Float)]
) -> PdfTable? {
    if items.isEmpty || clusterRects.isEmpty { return nil }

    // 1. Column boundaries from the rect x positions, deduplicated within
    //    2pt — two boxes a hair apart are one column drawn twice.
    var columns: [Float] = []
    for x in clusterRects.map(\.x).sorted() {
        if let last = columns.last, (x - last).magnitude <= 2.0 { continue }
        columns.append(x)
    }
    // Below five columns this is not the layout this stage is for, and
    // guessing at a three-column one would take work from the heuristic.
    if columns.count < 5 { return nil }

    // 1b. Fill the gaps. A holiday draws no box, so its column is missing
    //     from the rects entirely — but the days on either side still need
    //     to land in different cells. A gap wider than 1.5× the median
    //     spacing is subdivided evenly to put the column back.
    if columns.count >= 2 {
        let spacings = zip(columns.dropFirst(), columns).map { $0 - $1 }.sorted()
        let median = spacings[spacings.count / 2]
        let threshold = median * 1.5

        var filled: [Float] = [columns[0]]
        for index in 1..<columns.count {
            let gap = columns[index] - columns[index - 1]
            if gap > threshold {
                let count = Int((gap / median).rounded())
                if count >= 2 {
                    let step = gap / Float(count)
                    for step_index in 1..<count {
                        filled.append(columns[index - 1] + Float(step_index) * step)
                    }
                }
            }
            filled.append(columns[index])
        }
        columns = filled
    }

    // 2. Split the merged runs. A week of day numbers is often drawn as one
    //    text item, `10 11 12 13 14`, and left whole it fills a single cell
    //    and empties four.
    var expanded: [(item: PdfLayoutItem, origin: Int)] = []
    for (index, item) in items.enumerated() {
        for split in pdfSplitMergedNumbers(item, columns: columns) {
            expanded.append((split, index))
        }
    }

    // 3. Row boundaries from the item y positions, deduplicated within 5pt.
    //    Descending, because PDF space grows upwards and a table reads down.
    var rows: [Float] = []
    for y in expanded.map(\.item.y).sorted(by: >) {
        if let last = rows.last, (last - y).magnitude <= 5.0 { continue }
        rows.append(y)
    }
    if rows.isEmpty { return nil }

    // 4. Drop each item into its cell.
    var cells = [[String]](repeating: [String](repeating: "", count: columns.count), count: rows.count)
    var used: [Int] = []

    // A legend beside the table would otherwise be swept into the last
    // column, so anything more than one and a half column-widths past the
    // rightmost boundary is left for the prose.
    let spacing =
        columns.count >= 2
        ? (columns[columns.count - 1] - columns[0]) / Float(columns.count - 1) : 20.0
    let maximumX = columns[columns.count - 1] + spacing * 1.5

    for (item, origin) in expanded {
        if item.x > maximumX { continue }
        let row = rows.firstIndex { (($0 - item.y)).magnitude <= 5.0 }
        // The rightmost boundary at or left of the item. The 4pt slack
        // catches an annotation like "Memorial Day" that a producer sets
        // just before its column starts.
        let column = columns.lastIndex { item.x >= $0 - 4.0 }
        guard let row, let column else { continue }
        if !cells[row][column].isEmpty { cells[row][column] += " " }
        cells[row][column] += item.text.trimmedForRectGuidedCell()
        used.append(origin)
    }

    // 5. A tilde leader from a legend bleeding in from the right takes the
    //    rest of its cell with it.
    for row in cells.indices {
        for column in cells[row].indices {
            let cell = cells[row][column]
            if let leader = cell.firstRangeOfTildeLeader() {
                cells[row][column] = String(cell[cell.startIndex..<leader])
                    .trimmedTrailingForRectGuidedCell()
            }
        }
    }

    // 6. One row has to actually look like a table row. Five non-empty
    //    cells is the bar; below it this was a cluster of boxes with text
    //    near them, which is not the same thing.
    let bestFill = cells.map { $0.filter { !$0.isEmpty }.count }.max() ?? 0
    if bestFill < 5 { return nil }

    var seen = Set<Int>()
    let indices = used.sorted().filter { seen.insert($0).inserted }
    return PdfTable(columns: columns, rows: rows, cells: cells, itemIndices: indices)
}

/// Split a run of day numbers into one item per column.
///
/// `10 11 12 13 14` drawn as a single item is five cells' worth of text in
/// one place. Only **leading** numeric tokens split: what follows them is an
/// annotation — `25 Christmas Day` — and belongs with the last number rather
/// than in a column of its own.
func pdfSplitMergedNumbers(_ item: PdfLayoutItem, columns: [Float]) -> [PdfLayoutItem] {
    let tokens = item.text.split(whereSeparator: \.isWhitespace)
    if tokens.count <= 1 { return [item] }

    let leadingNumeric = tokens.prefix { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
        .count
    // With no number in front there is nothing to distribute across columns.
    if leadingNumeric == 0 { return [item] }

    let tokenWidth = item.width / Float(tokens.count)
    var result: [PdfLayoutItem] = []

    // The column the item starts in — the rightmost boundary at or left of
    // it. `lastIndex` rather than `firstIndex` so an item sitting between
    // two boundaries does not overshoot into the one on its right.
    let startColumn = columns.lastIndex { $0 <= item.x + 2.0 } ?? 0

    for (offset, token) in tokens.prefix(leadingNumeric).enumerated() {
        let columnIndex = startColumn + offset
        let snappedX: Float
        if columnIndex < columns.count {
            snappedX = columns[columnIndex]
        } else {
            // Past the last boundary: place the token where its own width
            // puts it, then snap back to a boundary if one is at or left.
            let rawX = item.x + Float(offset) * tokenWidth + tokenWidth / 2.0
            snappedX = columns.last(where: { $0 <= rawX + 2.0 }) ?? rawX
        }
        var split = item
        split.text = String(token)
        split.x = snappedX
        split.width = tokenWidth
        result.append(split)
    }

    // The trailing words become one annotation item, at the last number's
    // column — an annotation names the day beside it, so that is where it
    // reads.
    if leadingNumeric < tokens.count {
        var annotation = item
        annotation.text = tokens[leadingNumeric...].joined(separator: " ")
        annotation.x = result.last?.x ?? item.x
        annotation.width = tokenWidth
        result.append(annotation)
    }
    return result
}


extension String {
    /// Rust's `trim`, which is Unicode whitespace on both ends.
    fileprivate func trimmedForRectGuidedCell() -> String {
        var view = Substring(self)
        while let first = view.first, first.isWhitespace { view = view.dropFirst() }
        while let last = view.last, last.isWhitespace { view = view.dropLast() }
        return String(view)
    }

    /// Rust's `trim_end`.
    fileprivate func trimmedTrailingForRectGuidedCell() -> String {
        var view = Substring(self)
        while let last = view.last, last.isWhitespace { view = view.dropLast() }
        return String(view)
    }

    /// Where a `~~~` leader starts, if anywhere — `String.range(of:)` without
    /// the Foundation the package does without.
    fileprivate func firstRangeOfTildeLeader() -> String.Index? {
        var index = startIndex
        while index < endIndex {
            if self[index] == "~" {
                var probe = index
                var run = 0
                while probe < endIndex, self[probe] == "~", run < 3 {
                    run += 1
                    probe = self.index(after: probe)
                }
                if run == 3 { return index }
            }
            index = self.index(after: index)
        }
        return nil
    }
}
