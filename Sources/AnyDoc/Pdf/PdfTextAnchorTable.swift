/// The text-anchor strategy, ported from `build_text_anchor_table` in
/// pdf-inspector's `tables/detect_lines.rs`.
///
/// This is the booktabs case: two or three rules, no vertical lines anywhere,
/// and columns that exist only in where the header's words begin. The header
/// row *is* the column definition, and everything below is assigned to the
/// nearest anchor.
///
/// That is a lot to infer from very little, so most of the function is
/// refusals. The shape it must not accept is multi-column prose bracketed by
/// decorative rules: its first baseline looks like a header, its text starts
/// look like anchors, and the result is a table of paragraphs. Several of the
/// gates below exist only to tell those apart, and they are deliberately loose
/// in different directions — a real ruled table may wrap its labels, so the
/// prose tests reject extremes and sustained concentrations rather than any
/// long cell.

/// A table inferred from the header's word starts, or `nil`.
func pdfBuildTextAnchorTable(
    items: [PdfLayoutItem], rules: [PdfHorizontalRule]
) -> PdfTable? {
    // A uniform grid of rules is ruled *paper*, and its baselines are not a
    // header.
    guard rules.count >= 2, !pdfRulesAreUniformGrid(rules) else { return nil }
    let rows = pdfCollectAnchoredRows(items: items, rules: rules)
    guard rows.count >= 2 else { return nil }

    // Anchors from the first row's item starts. Compared against the last
    // anchor *kept*, so a run of closely spaced words collapses to one.
    var anchors: [Float] = []
    for entry in rows[0].items {
        if anchors.last.map({ abs(entry.item.x - $0) > pdfRuleJoinGap }) ?? true {
            anchors.append(entry.item.x)
        }
    }
    // One anchor is not a table — but it may be the stacked-token shape.
    if anchors.count == 1 { return pdfBuildStackedTokenTable(rows: rows, rules: rules) }
    guard (2...25).contains(anchors.count), let lastAnchor = anchors.last,
        lastAnchor - anchors[0] >= 30
    else { return nil }

    // The header must describe every column. A row of numbers is weak
    // evidence of being a header, and a body item starting left of the first
    // anchor proves the inferred grid dropped a column outright.
    let numericHeaderCells = rows[0].items.filter { entry in
        let text = entry.item.text.rustTrim()
        return text.unicodeScalars.contains { $0 >= "0" && $0 <= "9" }
            && !text.unicodeScalars.contains { $0.properties.isAlphabetic }
    }.count
    let headerHasNoLetters = rows[0].items.allSatisfy { entry in
        !entry.item.text.unicodeScalars.contains { $0.properties.isAlphabetic }
    }
    let bodyStartsLeftOfHeader = rows.dropFirst().contains { row in
        row.items.contains { $0.item.x < anchors[0] - pdfRuleJoinGap }
    }
    if headerHasNoLetters || numericHeaderCells * 2 > rows[0].items.count
        || bodyStartsLeftOfHeader
    {
        return nil
    }

    if rules.count == 2 {
        // Only top and bottom rules. The one shape trustworthy at that little
        // evidence is a bounded response form: the header names both columns,
        // and every prompt row fills the leading column with a short phrase
        // and deliberately leaves the response column blank.
        let responseForm =
            rows.count >= 5 && anchors.count <= 4
            && rows.dropFirst().allSatisfy { row in
                !row.items.isEmpty && row.items.count < anchors.count
                    && row.items.allSatisfy {
                        $0.item.text.rustSplitWhitespace().count <= 4
                            && abs($0.item.x - anchors[0]) <= pdfRuleJoinGap
                    }
            }
        guard responseForm else { return nil }
    } else if anchors.count == 2 && (rules.count < 5 || rows.count > rules.count + 2) {
        // Two text columns bracketed by a few decorative rules are
        // indistinguishable from a two-column prose layout on geometry alone.
        // Only densely ruled forms — where the rule and row counts corroborate
        // each other — survive here. Wider tables have stronger anchor
        // evidence and are exempt.
        return nil
    }

    if anchors.count > 2 && rules.count > 3 {
        // Four or more full-width rules describe row structure, not a sparse
        // booktabs band. First-row anchors alone may start below the real
        // header and preempt a better hypothesis from a detector that can
        // also weigh rectangles or whitespace.
        return nil
    }

    var xMin = Float.infinity
    var xMax = -Float.infinity
    for rule in rules {
        xMin = min(xMin, rule.xMin)
        xMax = max(xMax, rule.xMax)
    }
    xMin = min(xMin, anchors[0])
    xMax = max(xMax, lastAnchor)
    guard xMax - xMin >= 50 else { return nil }

    // Column boundaries sit midway between neighbouring anchors.
    var columns = [xMin]
    columns.append(contentsOf: zip(anchors, anchors.dropFirst()).map { ($0 + $1) / 2 })
    columns.append(xMax)

    var cells = [[String]](
        repeating: [String](repeating: "", count: anchors.count), count: rows.count)
    var itemIndices: [Int] = []
    var wideItems = 0
    var measuredItems = 0
    for (rowIndex, row) in rows.enumerated() {
        for entry in row.items {
            // Nearest anchor by start position; ties go to the leftmost.
            var column = 0
            var bestDistance = Float.infinity
            for (index, anchor) in anchors.enumerated() {
                let distance = abs(anchor - entry.item.x)
                if distance < bestDistance {
                    bestDistance = distance
                    column = index
                }
            }
            let columnWidth = columns[column + 1] - columns[column]
            if columnWidth > 0 {
                measuredItems += 1
                // An item filling most of its column is a sign the anchors are
                // paragraph starts rather than column starts.
                if max(entry.item.width, 0) > columnWidth * 0.72 { wideItems += 1 }
            }
            if !cells[rowIndex][column].isEmpty { cells[rowIndex][column] += " " }
            cells[rowIndex][column] += entry.item.text.rustTrim()
            itemIndices.append(entry.index)
        }
    }
    itemIndices.sort()
    itemIndices = pdfDeduplicatedSorted(itemIndices)

    let occupiedRows = cells.filter { row in row.contains { !$0.isEmpty } }.count
    let occupiedColumns = (0..<anchors.count).filter { column in
        cells.contains { !$0[column].isEmpty }
    }.count
    guard occupiedRows >= 2, occupiedColumns >= 2 else { return nil }

    // Sparse rules around a full multi-column text region expose dozens of
    // paragraph baselines whose starts repeat at the column margins. What is
    // rejected is *sustained prose*, not height: a long table of short labels
    // and values stays valid however many rows it has.
    let bodyCells = cells.dropFirst().flatMap { $0 }.filter { !$0.isEmpty }
    let proseLikeBodyCells = bodyCells.filter { cell in
        let alphaWords = cell.rustSplitWhitespace().filter { word in
            word.unicodeScalars.contains { $0.properties.isAlphabetic }
        }.count
        return alphaWords >= 3 && cell.unicodeScalars.count >= 12
    }.count
    let sustainedSparseProse =
        rules.count <= 4 && rows.count > rules.count * 2 + 2 && !bodyCells.isEmpty
        && proseLikeBodyCells * 2 >= bodyCells.count
    if sustainedSparseProse
        || (anchors.count >= 3 && rows.count >= 4 && measuredItems > 0
            && wideItems * 3 >= measuredItems)
    {
        return nil
    }

    // A handful of long decorative rules can bracket a whole prose region, and
    // assigning the intervening paragraphs to its anchors produces very large
    // cells. Real ruled tables wrap their labels, so this guard is loose on
    // purpose: one extreme cell, or a sustained concentration of long ones.
    let nonEmptyCells = cells.flatMap { $0 }.filter { !$0.isEmpty }
    let longCells = nonEmptyCells.filter { $0.unicodeScalars.count > 100 }.count
    if nonEmptyCells.contains(where: { $0.unicodeScalars.count > 240 })
        || (longCells >= 2 && longCells * 5 >= nonEmptyCells.count)
    {
        return nil
    }

    return PdfTable(
        columns: columns, rows: rows.map(\.y), cells: cells, itemIndices: itemIndices)
}
