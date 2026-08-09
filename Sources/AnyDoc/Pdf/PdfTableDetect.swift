/// Heuristic table detection, ported from `detect_table_in_region` and its
/// validators in pdf-inspector's `tables/detect_heuristic.rs`.
///
/// This is the strategy for a table with no ruling at all: the only evidence
/// is that the text lines up. That evidence is weak, so the reference spends
/// far more code rejecting than accepting — eight validations after the grid
/// is built, each one a different way a page of prose can look like a table
/// from a distance.
///
/// The first pass over the grid is not a validation at all but a trim:
/// `pdfFirstTableRow` walks down from the top discarding form metadata,
/// spanning super-headers and sparse preamble until it reaches something that
/// is really the table. That turned out to fire on most regions, not just
/// forms — deferring it left every row count one too high.

/// A region with fewer than this many columns is not a table; more than this
/// and the clustering has fragmented something else.
private let pdfMinimumTableColumns = 2
private let pdfMaximumTableColumns = 25
private let pdfMinimumTableRows = 2
private let pdfMaximumTableRows = 200

/// How far an item may sit from a column and still count as aligned to it.
private func pdfAlignmentTolerance(_ mode: PdfTableDetectionMode) -> Float {
    switch mode {
    case .smallFont: return 40
    case .bodyFont: return 30
    }
}

/// The fraction of items that must align to a column for a region to be a
/// table. Body-font candidates need more, because they include prose.
private func pdfMinimumAlignment(_ mode: PdfTableDetectionMode) -> Float {
    switch mode {
    case .smallFont: return 0.5
    case .bodyFont: return 0.7
    }
}

/// What fraction of items sit on a column boundary.
func pdfColumnAlignment(
    _ items: [PdfLayoutItem], _ columns: [Float], _ mode: PdfTableDetectionMode
) -> Float {
    guard !items.isEmpty else { return 0 }
    let tolerance = pdfAlignmentTolerance(mode)
    let aligned = items.count(where: { item in
        columns.contains { abs(item.x - $0) < tolerance }
    })
    return Float(aligned) / Float(items.count)
}

/// Build a table from a region's items, or reject the region.
///
/// `items` are paired with their indices in the page's item list, so the
/// caller can tell which items a detected table consumed.
func pdfDetectTableInRegion(
    _ items: [(index: Int, item: PdfLayoutItem)], mode: PdfTableDetectionMode = .smallFont
) -> PdfTable? {
    let plain = items.map(\.item)

    let columns = pdfFindColumnBoundaries(plain, mode: mode)
    guard columns.count >= pdfMinimumTableColumns, columns.count <= pdfMaximumTableColumns
    else { return nil }

    var rows = pdfFindRowBoundaries(plain)
    guard rows.count >= pdfMinimumTableRows else { return nil }

    guard pdfColumnAlignment(plain, columns, mode) >= pdfMinimumAlignment(mode) else { return nil }

    // Collect the items falling in each cell, then join each cell's own.
    var cellItems = Array(
        repeating: Array(repeating: [PdfLayoutItem](), count: columns.count), count: rows.count)
    var itemIndices: [Int] = []
    for (index, item) in items {
        guard let column = pdfFindColumnIndex(columns, item.x),
            let row = pdfFindRowIndex(rows, item.y)
        else { continue }
        cellItems[row][column].append(item)
        itemIndices.append(index)
    }

    // The trim decision is made on cells joined in *arrival* order, because
    // the reference runs it before it sorts each cell's items by x. The two
    // orders join differently, so using the sorted cells here trims a
    // different row.
    let firstRow = pdfFirstTableRow(cellItems.map { $0.map(pdfJoinCellItems) })

    var cells = cellItems.map { row in
        row.map { pdfJoinCellItems($0.sorted { $0.x < $1.x }) }
    }
    if firstRow > 0 {
        // An item on a trimmed row is no longer the table's.
        let trimmedYs = rows.prefix(firstRow)
        itemIndices = items.filter { entry in
            itemIndices.contains(entry.index)
                && !trimmedYs.contains(where: { abs(entry.item.y - $0) < 15 })
        }.map(\.index)
        cells = Array(cells.dropFirst(firstRow))
        rows = Array(rows.dropFirst(firstRow))
    }

    // A narrow contents listing legitimately leaves its leftmost column
    // sparse — only top-level chapters land there — and trips both the
    // first-column and paragraph tests below. Wide ones are excluded because
    // the flat-list renderer assumes one entry per row.
    let isNarrowToc = columns.count <= 5 && pdfIsTableOfContents(cells)

    // 1. Some rows must carry a first column. A quarter is enough, because a
    //    wrapped cell's continuation leaves it empty.
    let rowsWithFirstColumn = cells.count(where: { !($0.first ?? "").isEmpty })
    guard rowsWithFirstColumn >= rows.count / 4 || isNarrowToc else { return nil }

    // 2. A real table fills more than one column on many of its rows.
    let rowsWithSeveralColumns = cells.count(where: { $0.count(where: { !$0.isEmpty }) >= 2 })
    let severalColumnsThreshold: Int
    switch mode {
    case .smallFont: severalColumnsThreshold = max(rows.count / 3, 1)
    case .bodyFont: severalColumnsThreshold = max(rows.count / 2, 1)
    }
    guard rowsWithSeveralColumns >= severalColumnsThreshold else { return nil }

    // 3. Too many rows means something that is not a table was misread.
    guard rows.count <= pdfMaximumTableRows else { return nil }

    // 4. A table averages more than one and a half filled cells per row.
    let totalFilled = cells.map { $0.count(where: { !$0.isEmpty }) }.reduce(0, +)
    guard Float(totalFilled) / Float(rows.count) >= 1.5 else { return nil }

    // 5-9. The shapes that align like a table and are not one.
    guard !pdfIsKeyValueLayout(cells) else { return nil }
    guard pdfHasConsistentColumns(cells) else { return nil }
    guard pdfHasTableLikeContent(cells, mode) else { return nil }
    guard !pdfIsParagraphContent(cells) || isNarrowToc else { return nil }
    guard !pdfIsInlineLeaderIndex(cells) else { return nil }

    return PdfTable(columns: columns, rows: rows, cells: cells, itemIndices: itemIndices)
}

// MARK: - the validators

/// Whether the grid is a label-and-value list rather than a table: mostly two
/// filled columns, the first often a label ending in a colon or set in caps.
func pdfIsKeyValueLayout(_ cells: [[String]]) -> Bool {
    guard let first = cells.first else { return false }
    let columnCount = first.count

    var labelLike = 0
    var twoOrFewer = 0
    for row in cells {
        if row.count(where: { !$0.isEmpty }) <= 2 { twoOrFewer += 1 }
        let firstCell = row.first.map { $0.rustTrim() } ?? ""
        if firstCell.hasSuffix(":")
            || (firstCell.utf8.count > 3
                && firstCell.unicodeScalars.allSatisfy {
                    $0.properties.isUppercase || $0.properties.isWhitespace || $0 == "("
                        || $0 == ")"
                })
        {
            labelLike += 1
        }
    }
    let total = Float(cells.count)
    return Float(twoOrFewer) / total > 0.7 && Float(labelLike) / total > 0.5 && columnCount <= 6
}

/// Whether rows agree on how many columns they fill, which real tables do.
func pdfHasConsistentColumns(_ cells: [[String]]) -> Bool {
    // Too few rows to judge.
    guard cells.count >= 3, let first = cells.first else { return true }

    let filledCounts = cells.map { $0.count(where: { !$0.isEmpty }) }
    var frequency: [Int: Int] = [:]
    for count in filledCounts { frequency[count, default: 0] += 1 }
    // Ties go to the higher column count, so the result is deterministic.
    let mostCommon =
        frequency.max(by: { ($0.value, $0.key) < ($1.value, $1.key) })?.key ?? 0

    // A very wide table has inherently variable fill, so it gets a wider
    // tolerance and a lower bar.
    let columnCount = first.count
    let tolerance = columnCount > 15 ? columnCount / 4 : 2
    let consistent = filledCounts.count(where: {
        $0 >= mostCommon - tolerance && $0 <= mostCommon + tolerance
    })
    let minimumRatio: Float = columnCount > 15 ? 0.25 : 0.40
    return Float(consistent) / Float(cells.count) > minimumRatio
}

/// Whether the body rows carry the kind of short, coded content tables hold.
///
/// Bypassed for three or more columns: a text-only table — a category list, a
/// programme of study — is legitimate once it has passed the structural
/// tests, and demanding numbers would reject it.
func pdfHasTableLikeContent(_ cells: [[String]], _ mode: PdfTableDetectionMode) -> Bool {
    var dataLike = 0
    var total = 0
    for row in cells.dropFirst() {
        for cell in row {
            let trimmed = cell.rustTrim()
            if trimmed.isEmpty { continue }
            total += 1
            if pdfLooksLikeTableData(trimmed) { dataLike += 1 }
        }
    }
    guard total > 0 else { return false }

    let fraction = Float(dataLike) / Float(total)
    let columnCount = cells.first?.count ?? 0
    let minimum: Float
    switch mode {
    case .smallFont: minimum = 0.2
    case .bodyFont: minimum = 0.3
    }
    if fraction > minimum || columnCount >= 3 { return true }

    // A two-column body-font grid of short cells is a definition list, not
    // paragraph text.
    if columnCount == 2, case .bodyFont = mode {
        let lengths = cells.dropFirst().flatMap { $0 }.map { $0.rustTrim() }
            .filter { !$0.isEmpty }.map(\.utf8.count)
        if !lengths.isEmpty { return lengths.reduce(0, +) / lengths.count <= 25 }
    }
    return false
}

/// Whether a cell holds the sort of value a table does — a number, a date, a
/// part code, a measurement, a package designation.
func pdfLooksLikeTableData(_ text: String) -> Bool {
    let trimmed = text.rustTrim()
    guard !trimmed.isEmpty else { return false }
    if pdfLooksLikeNumber(trimmed) { return true }

    let scalars = Array(trimmed.unicodeScalars)
    let digits = scalars.count(where: { $0 >= "0" && $0 <= "9" })
    let hasDigit = digits > 0

    // A date: mostly digits with slashes or dashes.
    if trimmed.utf8.count <= 10, digits >= 4,
        trimmed.contains("/") || trimmed.contains("-"),
        scalars.allSatisfy({ ($0 >= "0" && $0 <= "9") || $0 == "/" || $0 == "-" })
    {
        return true
    }
    // A part number or model code: short, alphanumeric, carrying a digit.
    if trimmed.utf8.count <= 10, hasDigit,
        scalars.allSatisfy({ $0.properties.isAlphabetic || ($0 >= "0" && $0 <= "9") })
    {
        return true
    }
    // A measurement with a unit.
    let hasUnit =
        trimmed.contains("°") || trimmed.contains("V") || trimmed.contains("A")
        || trimmed.contains("Hz") || trimmed.contains("mA") || trimmed.contains("µ")
        || trimmed.contains("pin") || trimmed.contains("MHz") || trimmed.contains("kHz")
    if hasDigit, hasUnit { return true }
    // A package designation.
    if trimmed.contains("("), trimmed.contains(")"), hasDigit { return true }
    // A temperature range.
    if trimmed.contains("°C") || trimmed.contains("°F"), trimmed.contains("to") { return true }
    return false
}

/// Whether the text is a number in any of the forms a table writes them.
func pdfLooksLikeNumber(_ text: String) -> Bool {
    let trimmed = text.rustTrim()
    guard !trimmed.isEmpty else { return false }
    var sawDigit = false
    for scalar in trimmed.unicodeScalars {
        if scalar >= "0", scalar <= "9" {
            sawDigit = true
        } else if scalar != ".", scalar != ",", scalar != "-", scalar != "+" {
            return false
        }
    }
    return sawDigit
}

/// Whether the grid is really paragraph text spread across a false grid.
///
/// The signals are what multi-column prose produces and a table does not: a
/// word broken at a hyphen where a column boundary fell, a mostly-empty grid
/// over many rows, letterspaced display text, and long sentence fragments.
func pdfIsParagraphContent(_ cells: [[String]]) -> Bool {
    guard let first = cells.first else { return false }
    let totalCells = cells.count * first.count
    guard totalCells > 0 else { return false }

    let filled = cells.flatMap { $0 }.map { $0.rustTrim() }.filter { !$0.isEmpty }
    let totalFilled = filled.count
    guard totalFilled >= 4 else { return false }

    let emptyRatio = 1 - Float(totalFilled) / Float(totalCells)

    // A hyphen after a letter at a cell's end is a word broken across what
    // the detector took for a column boundary. Real cells almost never end
    // that way, so even a few are decisive.
    let hyphenBreaks = filled.count(where: { cell in
        guard cell.hasSuffix("-"), cell.utf8.count > 1 else { return false }
        return cell.unicodeScalars.dropLast().last?.properties.isAlphabetic == true
    })
    if Float(hyphenBreaks) / Float(totalFilled) > 0.03 { return true }

    if emptyRatio > 0.55, cells.count > 10 { return true }

    // Letterspaced display text is never table data. Nine characters, so a
    // short code does not match.
    let letterSpaced = filled.count(where: { cell in
        let characters = Array(cell)
        guard characters.count >= 9 else { return false }
        for window in 0...(characters.count - 4) {
            let w = characters[window..<(window + 4)].map { $0 }
            let alternates =
                (w[0].isLetter && w[1] == " " && w[2].isLetter && w[3] == " ")
                || (w[0] == " " && w[1].isLetter && w[2] == " " && w[3].isLetter)
            if !alternates { return false }
        }
        return true
    })
    if letterSpaced > 0, Float(letterSpaced) / Float(totalFilled) > 0.08 { return true }

    let longCells = filled.count(where: { $0.utf8.count > 60 })
    let longRatio = Float(longCells) / Float(totalFilled)
    let averageLength =
        Float(filled.map(\.utf8.count).reduce(0, +)) / Float(totalFilled)
    if averageLength > 40, longRatio > 0.2 { return true }
    return longRatio > 0.3
}


/// The first row that is really the table's, skipping what sits above it.
///
/// A region often opens with form metadata (`Name:`, `Date:`), a spanning
/// super-header whose cells repeat, or simply sparse preamble. Using any of
/// those as the header row produces duplicate column names and shifts every
/// row by one.
func pdfFirstTableRow(_ cells: [[String]]) -> Int {
    guard let first = cells.first else { return 0 }
    let columnCount = first.count
    guard columnCount > 0 else { return 0 }

    /// Whether a cell reads as a form label.
    func isFormCell(_ text: String) -> Bool {
        let trimmed = text.rustTrim()
        return (trimmed.hasSuffix(":") && trimmed.utf8.count > 1)
            || (trimmed.contains(": ") && !pdfLooksLikeNumber(trimmed))
    }

    for (index, row) in cells.enumerated() {
        let filled = row.filter { !$0.rustTrim().isEmpty }
        let fillRatio = Float(filled.count) / Float(columnCount)

        // Form rows are skipped whatever their density, so long as the form
        // cells dominate or the row is sparse.
        let formCells = filled.count(where: isFormCell)
        if formCells > 0, formCells * 2 >= filled.count || fillRatio < 0.3 { continue }

        let hasData = filled.count(where: { pdfLooksLikeNumber($0.rustTrim()) }) >= 2

        // A spanning super-header repeats its cells. Skip it only when
        // something below is a better header.
        if filled.count >= 2, !hasData {
            var counts: [String: Int] = [:]
            for cell in filled { counts[cell.rustTrim(), default: 0] += 1 }
            if counts.values.contains(where: { $0 >= 2 }) {
                let betterBelow = cells.dropFirst(index + 1).prefix(3).contains { next in
                    let nextFilled = next.count(where: { !$0.rustTrim().isEmpty })
                    let nextNumeric = next.count(where: { pdfLooksLikeNumber($0.rustTrim()) })
                    return Float(nextFilled) / Float(columnCount) >= 0.4 || nextNumeric >= 2
                }
                if betterBelow { continue }
            }
        }

        if hasData { return index }
        // A dense row with no form pattern is the header.
        if fillRatio >= 0.4 { return index }
        // A very sparse opening row is metadata.
        if fillRatio < 0.3 { continue }

        // Moderately sparse: it starts the table only if what follows is
        // dense or numeric, and is not itself a form row.
        if index + 1 < cells.count {
            let next = cells[index + 1]
            let nextFilled = next.count(where: { !$0.rustTrim().isEmpty })
            let nextNumeric = next.count(where: { pdfLooksLikeNumber($0.rustTrim()) })
            let nextHasForm = next.contains(where: isFormCell)
            if (Float(nextFilled) / Float(columnCount) >= 0.4 || nextNumeric >= 2), !nextHasForm {
                return index
            }
        }
    }
    return 0
}

/// Consolidate each line's fragments before table detection looks at them.
///
/// A near-cousin of `pdfMergeTextItems`, and deliberately not the same
/// function: this one is what the *table* path runs, and its rules are
/// simpler. It uses raw widths rather than the word-spacing-capped ones, has
/// a single fixed space threshold instead of the punctuation and
/// lowercase-pair cases, ignores the tracked-run floor entirely, and does
/// **not** break at style boundaries — a bold label merges into the plain
/// text beside it, because a cell's styling does not matter to the grid.
///
/// The index map records which original items went into each merged one, so
/// a detected table can still say which items it consumed.
func pdfMergeAdjacentItems(
    _ items: [PdfLayoutItem]
) -> (merged: [PdfLayoutItem], indexMap: [[Int]]) {
    guard !items.isEmpty else { return ([], []) }

    // Group by baseline in first-seen order, then order the lines down the
    // page and each line left to right.
    var groups: [(y: Float, entries: [(index: Int, item: PdfLayoutItem)])] = []
    for (index, item) in items.enumerated() {
        if let position = groups.firstIndex(where: { abs(item.y - $0.y) < 5 }) {
            groups[position].entries.append((index, item))
        } else {
            groups.append((item.y, [(index, item)]))
        }
    }
    for position in groups.indices {
        groups[position].entries.sort { $0.item.x < $1.item.x }
    }
    groups.sort { $0.y > $1.y }

    var merged: [PdfLayoutItem] = []
    var indexMap: [[Int]] = []
    for group in groups {
        let line = group.entries
        var index = 0
        while index < line.count {
            let first = line[index].item
            var text = first.text
            // The raw width, not the capped one — this path does not undo
            // word-spacing inflation.
            var endX = first.x + first.width
            var indices = [line[index].index]
            let maximumGap = first.fontSize * 0.5

            var next = index + 1
            while next < line.count {
                let candidate = line[next].item
                if abs(candidate.fontSize - first.fontSize) > first.fontSize * 0.20 { break }
                let gap = candidate.x - endX
                // Past this is the next column; far behind it is a different
                // column overlapping.
                if gap > maximumGap { break }
                if gap < -first.fontSize * 0.5 { break }
                // Within a word the glyphs touch; between words there is a
                // visible gap.
                if gap > first.fontSize * 0.08 { text += " " }
                text += candidate.text
                endX = candidate.x + candidate.width
                indices.append(line[next].index)
                next += 1
            }

            var joined = first
            joined.text = text
            joined.width = endX - first.x
            merged.append(joined)
            indexMap.append(indices)
            index = next
        }
    }
    return (merged, indexMap)
}

/// The vertical bands that might hold a small-font table.
///
/// Nothing structural here: candidates are simply clustered by baseline, and
/// a run of four or more with no gap wider than 30pt is a band worth looking
/// at. The band is padded by 5pt so the first and last rows are not clipped.
func pdfFindTableRegions(_ items: [PdfLayoutItem]) -> [(yMin: Float, yMax: Float)] {
    let ys = items.map(\.y).sorted()
    guard let first = ys.first else { return [] }

    var regions: [(Float, Float)] = []
    var start = first
    var end = first
    var count = 1
    for y in ys.dropFirst() {
        if y - end > 30 {
            if count >= 4 { regions.append((start - 5, end + 5)) }
            start = y
            end = y
            count = 1
        } else {
            end = y
            count += 1
        }
    }
    if count >= 4 { regions.append((start - 5, end + 5)) }
    return regions
}

/// The bands that might hold a *body-font* table, found on structure rather
/// than density.
///
/// Body-sized candidates include all the page's prose, so proximity alone
/// proves nothing. A row qualifies only if its x positions form two or more
/// clusters, and a run of qualifying rows becomes a region only if their
/// column positions agree across rows — which is precisely what separates a
/// table from paragraph text, where word positions vary line to line.
func pdfFindTableRegionsStrict(
    _ items: [PdfLayoutItem]
) -> [(yMin: Float, yMax: Float, xMin: Float, xMax: Float)] {
    guard !items.isEmpty else { return [] }

    // Rows, in first-seen order.
    var rowGroups: [(y: Float, xs: [Float])] = []
    for item in items {
        if let index = rowGroups.firstIndex(where: { abs(item.y - $0.y) < 8 }) {
            rowGroups[index].xs.append(item.x)
        } else {
            rowGroups.append((item.y, [item.x]))
        }
    }

    // A row qualifies when its x positions fall into two or more clusters.
    var qualifying: [(y: Float, starts: [Float])] = []
    for group in rowGroups {
        let sorted = group.xs.sorted()
        guard let first = sorted.first else { continue }
        var starts: [Float] = [first]
        var last = first
        for x in sorted.dropFirst() where x - last > 20 {
            starts.append(x)
            last = x
        }
        if starts.count >= 2 { qualifying.append((group.y, starts)) }
    }
    guard qualifying.count >= 3 else { return [] }

    qualifying.sort { $0.y < $1.y }

    // A wrapped cell spaces the qualifying rows further apart, so the gap
    // that ends a run is taken from the rows themselves.
    let gaps = zip(qualifying, qualifying.dropFirst()).map { abs($1.y - $0.y) }.sorted()
    let maximumGap = gaps.isEmpty ? 25 : max(gaps[gaps.count / 2] * 3, 25)

    var candidates: [[(y: Float, starts: [Float])]] = []
    var current = [qualifying[0]]
    for row in qualifying.dropFirst() {
        if row.y - (current.last?.y ?? row.y) > maximumGap {
            if current.count >= 3 { candidates.append(current) }
            current = [row]
        } else {
            current.append(row)
        }
    }
    if current.count >= 3 { candidates.append(current) }

    // Every pair of rows in a candidate votes on whether their columns line
    // up; the region survives if they agree half the time.
    var regions: [(Float, Float, Float, Float)] = []
    for rows in candidates {
        var totalScore: Float = 0
        var pairs: Float = 0
        for i in 0..<rows.count {
            for j in (i + 1)..<rows.count {
                let a = rows[i].starts
                let b = rows[j].starts
                let matchesA = a.count(where: { x in b.contains { abs(x - $0) < 10 } })
                let matchesB = b.count(where: { x in a.contains { abs(x - $0) < 10 } })
                let longest = max(a.count, b.count)
                if longest > 0 {
                    totalScore += Float(matchesA + matchesB) / Float(2 * longest)
                    pairs += 1
                }
            }
        }
        let average = pairs > 0 ? totalScore / pairs : 0
        guard average >= 0.5 else { continue }

        let allStarts = rows.flatMap(\.starts)
        guard let yMin = rows.first?.y, let yMax = rows.last?.y,
            let xMin = allStarts.min(), let xMax = allStarts.max()
        else { continue }
        // The x bounds are generous on the right, where a wrapped cell's
        // continuation runs past the last column start.
        regions.append((yMin - 5, yMax + 5, xMin - 15, xMax + 50))
    }
    return regions
}

/// Prepend a header row taken from body-sized text just above the table.
///
/// A small-font table's header is very often set at the body size, which puts
/// it outside the small-font candidate set entirely — the detector never saw
/// it. So once a table is found, the band immediately above it is searched
/// for a row of larger text that maps onto the columns already established.
///
/// "Immediately" is measured from the table's own row spacing, up to twice
/// it, bounded to 10–40pt.
func pdfRecoverHeaderRow(
    _ table: inout PdfTable, allItems: [PdfLayoutItem], smallFontThreshold: Float
) {
    guard let firstRowY = table.rows.first, !table.columns.isEmpty else { return }

    let gapLimit: Float
    if table.rows.count >= 2 {
        let average =
            (table.rows[0] - table.rows[table.rows.count - 1]) / Float(table.rows.count - 1)
        gapLimit = min(max(average * 2, 10), 40)
    } else {
        gapLimit = 30
    }

    let candidates = allItems.enumerated().filter { _, item in
        item.fontSize > smallFontThreshold && item.y > firstRowY
            && item.y <= firstRowY + gapLimit
    }
    guard !candidates.isEmpty else { return }

    // Group by baseline, highest first, and take the group nearest the table.
    var groups: [(y: Float, entries: [(offset: Int, element: PdfLayoutItem)])] = []
    for entry in candidates.sorted(by: { $0.element.y > $1.element.y }) {
        if let index = groups.firstIndex(where: { abs(entry.element.y - $0.y) < 5 }) {
            groups[index].entries.append(entry)
        } else {
            groups.append((entry.element.y, [entry]))
        }
    }
    guard let header = groups.last else { return }

    var cells = [String](repeating: "", count: table.columns.count)
    var mapped = 0
    var indices: [Int] = []
    for entry in header.entries {
        guard let column = pdfFindColumnIndex(table.columns, entry.element.x) else { continue }
        let text = entry.element.text.rustTrim()
        if text.isEmpty { continue }
        if !cells[column].isEmpty { cells[column] += " " }
        cells[column] += text
        mapped += 1
        indices.append(entry.offset)
    }

    // Two populated columns is the least that reads as a header rather than
    // a stray caption.
    let populated = cells.count(where: { !$0.isEmpty })
    guard populated >= 2, mapped >= 2 else { return }

    table.rows.insert(header.y, at: 0)
    table.cells.insert(cells, at: 0)
    table.itemIndices += indices
}

/// Prepend a column of row labels sitting to the left of a numeric table.
///
/// A table of nothing but figures usually has names down its left edge, and
/// those names are often set differently enough that the column clustering
/// dropped them. When the table is narrow, tall and overwhelmingly numeric,
/// the unclaimed items to its left at each row's baseline are recovered as a
/// label column.
func pdfTryAddLabelColumn(
    _ table: inout PdfTable,
    candidates: [(index: Int, item: PdfLayoutItem)],
    claimed: Set<Int>,
    yMin: Float,
    yMax: Float
) {
    guard (2...3).contains(table.columns.count), table.rows.count >= 5 else { return }

    // Overwhelmingly numeric: at least seven cells in ten are mostly figures
    // and the punctuation that goes with money.
    let symbols = Set(",.-+%€$£¥()".unicodeScalars)
    let nonEmpty = table.cells.flatMap { $0 }.filter { !$0.rustTrim().isEmpty }
    guard !nonEmpty.isEmpty else { return }
    let numeric = nonEmpty.count(where: { cell in
        let text = cell.rustTrim()
        let total = text.unicodeScalars.count
        guard total > 0 else { return false }
        let dataChars = text.unicodeScalars.count(where: {
            ($0 >= "0" && $0 <= "9") || symbols.contains($0)
        })
        return Float(dataChars) / Float(total) >= 0.6
    })
    guard Float(numeric) / Float(nonEmpty.count) >= 0.7 else { return }

    let tableLeft = table.columns.first ?? .greatestFiniteMagnitude
    var perRow: [[(index: Int, item: PdfLayoutItem)]] = []
    var found = 0
    for rowY in table.rows {
        let labels = candidates.filter { entry in
            !claimed.contains(entry.index) && !table.itemIndices.contains(entry.index)
                && abs(entry.item.y - rowY) < 5 && entry.item.x < tableLeft - 10
                && entry.item.y >= yMin && entry.item.y <= yMax
        }.sorted { $0.item.x < $1.item.x }
        if !labels.isEmpty { found += 1 }
        perRow.append(labels)
    }
    // Two rows in five must have a label, or this is not a column.
    guard found >= table.rows.count * 2 / 5 else { return }

    let labelX = perRow.flatMap { $0 }.map(\.item.x).min() ?? 0
    table.columns.insert(labelX, at: 0)
    for (row, labels) in perRow.enumerated() where row < table.cells.count {
        table.cells[row].insert(labels.map(\.item.text).joined(separator: " "), at: 0)
        table.itemIndices += labels.map(\.index)
    }
}

/// Detect the heuristic tables on one page.
///
/// Two passes, and the order matters. The first looks for text *smaller* than
/// the body, which is the classic table signal and needs only density to find
/// its regions. The second looks at body-sized text, where being near other
/// text proves nothing, so it demands structural evidence and only considers
/// items the first pass did not already claim.
///
/// `skipBodyFont` turns the second pass off, which the reference does on
/// multi-column pages where it produces false positives.
func pdfDetectTables(
    _ items: [PdfLayoutItem], baseFontSize: Float, skipBodyFont: Bool = false
) -> [PdfTable] {
    guard items.count >= 6 else { return [] }

    // Fragments into words, then consolidated financial rows into columns.
    let (merged, mergeMap) = pdfMergeAdjacentItems(items)
    let (processed, expandMap) = pdfExpandConsolidatedItems(merged)

    var tables: [PdfTable] = []
    var claimed: Set<Int> = []

    // Pass 1: smaller than the body text.
    let smallFontThreshold = baseFontSize * 0.90
    let smallCandidates = processed.enumerated()
        .filter { $0.element.fontSize <= smallFontThreshold && $0.element.fontSize >= 6 }
        .map { (index: $0.offset, item: $0.element) }

    if smallCandidates.count >= 6 {
        for region in pdfFindTableRegions(smallCandidates.map(\.item)) {
            let regionItems = smallCandidates.filter {
                $0.item.y >= region.yMin && $0.item.y <= region.yMax
            }
            guard regionItems.count >= 6 else { continue }
            guard var table = pdfDetectTableInRegion(regionItems, mode: .smallFont) else {
                continue
            }
            // A small-font table's header is usually set at the body size, so
            // it was never a candidate; and a numeric table's row labels
            // often sit outside the clustering.
            pdfRecoverHeaderRow(
                &table, allItems: processed, smallFontThreshold: smallFontThreshold)
            pdfTryAddLabelColumn(
                &table, candidates: smallCandidates, claimed: claimed,
                yMin: region.yMin, yMax: region.yMax)
            claimed.formUnion(table.itemIndices)
            tables.append(table)
        }
    }

    // Pass 2: body-sized, over what pass 1 left behind.
    if !skipBodyFont {
        let low = baseFontSize * 0.85
        let high = baseFontSize * 1.05
        let bodyCandidates = processed.enumerated()
            .filter {
                !claimed.contains($0.offset) && $0.element.fontSize >= low
                    && $0.element.fontSize <= high && $0.element.fontSize >= 6
            }
            .map { (index: $0.offset, item: $0.element) }

        if bodyCandidates.count >= 6 {
            for region in pdfFindTableRegionsStrict(bodyCandidates.map(\.item)) {
                // The strict x bounds would cut off a wrapped cell's
                // continuation, so only the y bounds scope the region.
                let regionItems = bodyCandidates.filter {
                    $0.item.y >= region.yMin && $0.item.y <= region.yMax
                }
                guard regionItems.count >= 6 else { continue }
                if let table = pdfDetectTableInRegion(regionItems, mode: .bodyFont) {
                    tables.append(table)
                }
            }
        }
    }

    // Map the indices back through both pre-passes to the caller's items.
    for index in tables.indices {
        var original: Set<Int> = []
        for expanded in tables[index].itemIndices where expanded < expandMap.count {
            let mergedIndex = expandMap[expanded]
            if mergedIndex < mergeMap.count { original.formUnion(mergeMap[mergedIndex]) }
        }
        tables[index].itemIndices = original.sorted()
    }
    return tables
}
