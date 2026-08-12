/// The dense-row anchor strategy, ported from `build_dense_row_anchor_table`
/// in pdf-inspector's `tables/detect_lines.rs`.
///
/// Multi-level booktabs headers put one or two spanning labels on the first
/// baselines and only expose every real column further down. Wave 37's
/// strategy reads the *first* row as the schema, so on those tables it
/// collapses the structure before a better hypothesis can be compared.
///
/// This is the deliberately strict alternative: instead of trusting the first
/// row, take the *widest* set of anchors any row exposes, then demand that at
/// least two rows independently reproduce three quarters of it — and that the
/// body actually looks like data, which here means numbers.

/// A table anchored on the densest row of a ruled band, or `nil`.
func pdfBuildDenseRowAnchorTable(
    items: [PdfLayoutItem],
    horizontals: [PdfHorizontalRule],
    verticals: [PdfVerticalRule]
) -> PdfTable? {
    let rules = pdfMergeHorizontalSegments(horizontals)
    guard rules.count >= 4, !pdfRulesAreUniformGrid(rules) else { return nil }

    // Distinct rule levels, top first. Compared against the last level *kept*,
    // as `dedup_by` does.
    var distinctRuleYs: [Float] = []
    for y in rules.map(\.y).sorted(by: >)
    where !(distinctRuleYs.last.map { abs(y - $0) <= pdfRuleYTolerance } ?? false) {
        distinctRuleYs.append(y)
    }

    // A page of stacked charts contributes one dense numeric row each. Those
    // must not be combined into a synthetic page-wide table, so a gap far
    // larger than the rest means the band is not contiguous.
    var ruleGaps = zip(distinctRuleYs, distinctRuleYs.dropFirst()).map { $0 - $1 }
    ruleGaps.sort()
    if !ruleGaps.isEmpty {
        let medianGap = ruleGaps[ruleGaps.count / 2]
        if medianGap > 0, let largestGap = ruleGaps.last, largestGap > medianGap * 2.5 {
            return nil
        }
    }

    // Four evenly spaced levels anywhere in the band is ruled paper, even if
    // the band as a whole is not uniform.
    let hasUniformRun = distinctRuleYs.count >= 4
        && (0...(distinctRuleYs.count - 4)).contains { start in
            let spacings = [
                distinctRuleYs[start] - distinctRuleYs[start + 1],
                distinctRuleYs[start + 1] - distinctRuleYs[start + 2],
                distinctRuleYs[start + 2] - distinctRuleYs[start + 3],
            ]
            let mean = spacings.reduce(0, +) / Float(spacings.count)
            guard mean > 0.1 else { return false }
            let variance =
                spacings.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(spacings.count)
            return variance.squareRoot() / mean < 0.02
        }
    if hasUniformRun { return nil }

    var xMin = Float.infinity
    var xMax = -Float.infinity
    for rule in rules {
        xMin = min(xMin, rule.xMin)
        xMax = max(xMax, rule.xMax)
    }
    let tableWidth = xMax - xMin
    guard tableWidth >= 100 else { return nil }
    guard let yTop = distinctRuleYs.first, let yBottom = distinctRuleYs.last else { return nil }

    // Vertical strokes elsewhere on the page are irrelevant, but *two* inside
    // this band mean the physical-grid hypotheses should own the region.
    let bandVerticalXs = verticals.filter {
        $0.x >= xMin - pdfRuleJoinGap && $0.x <= xMax + pdfRuleJoinGap
            && $0.yMax >= yBottom - pdfRuleYTolerance && $0.yMin <= yTop + pdfRuleYTolerance
    }.map(\.x)
    guard pdfSnapEdges(bandVerticalXs, tolerance: 3).count < 2 else { return nil }

    // Two rules must cross most of the table, or this is a stack of unrelated
    // short rules rather than a bounded region.
    let spanningRules = rules.filter { $0.xMax - $0.xMin >= tableWidth * 0.8 }.count
    guard spanningRules >= 2 else { return nil }

    let rows = pdfCollectAnchoredRows(items: items, rules: rules)
    guard (3...30).contains(rows.count) else { return nil }
    // Sparse page decorations around prose expose many aligned text starts,
    // but the rule levels do not corroborate that row schema.
    guard rows.count <= distinctRuleYs.count * 2 + 2 else { return nil }

    // The widest schema any row exposes — not the first row's, which on a
    // multi-level header is exactly the misleading one. `max_by_key` keeps the
    // *last* maximum, so the lowest such row wins a tie.
    var anchors: [Float] = []
    for row in rows {
        let candidate = pdfLogicalRowAnchors(row.items)
        if candidate.count >= anchors.count { anchors = candidate }
    }
    guard (4...25).contains(anchors.count), let lastAnchor = anchors.last,
        lastAnchor - anchors[0] >= tableWidth * 0.6
    else { return nil }

    // Two rows must independently reproduce three quarters of the schema. One
    // busy line inside a chart or a form is not evidence of a table.
    let denseThreshold = (anchors.count * 3 + 3) / 4
    let denseRows = rows.filter {
        pdfMatchedAnchorColumnCount($0.items, anchors: anchors) >= denseThreshold
    }.count
    guard denseRows >= 2 else { return nil }

    var columns = [min(xMin, anchors[0])]
    columns.append(contentsOf: zip(anchors, anchors.dropFirst()).map { ($0 + $1) / 2 })
    columns.append(max(xMax, lastAnchor))

    var cells = [[String]](
        repeating: [String](repeating: "", count: anchors.count), count: rows.count)
    var itemIndices: [Int] = []
    for (rowIndex, row) in rows.enumerated() {
        for entry in row.items {
            guard let column = pdfNearestAnchorColumn(entry.item, anchors: anchors) else {
                return nil
            }
            if !cells[rowIndex][column].isEmpty { cells[rowIndex][column] += " " }
            cells[rowIndex][column] += entry.item.text.rustTrim()
            itemIndices.append(entry.index)
        }
    }
    itemIndices.sort()
    itemIndices = pdfDeduplicatedSorted(itemIndices)

    // The body has to look like data. Prose bracketed by rules can pass every
    // geometric test above; what it does not have is numbers in a quarter of
    // its cells.
    let bodyCells = cells.dropFirst().flatMap { $0 }
    let numericCells = bodyCells.filter { cell in
        cell.unicodeScalars.contains { $0 >= "0" && $0 <= "9" }
    }.count
    let nonEmptyBodyCells = bodyCells.filter { !$0.isEmpty }.count
    guard numericCells >= min(anchors.count, 3),
        numericCells * 4 >= max(nonEmptyBodyCells, 1)
    else { return nil }

    return PdfTable(
        columns: columns, rows: rows.map(\.y), cells: cells, itemIndices: itemIndices)
}
