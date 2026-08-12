/// Two of the ruled-table strategies, ported from `build_stacked_token_table`,
/// `build_open_edge_grid_table_for_rules` and `build_open_edge_grid_tables` in
/// pdf-inspector's `tables/detect_lines.rs`.
///
/// An *open-edge* grid is the common scientific-paper shape: horizontal rules
/// above, below and under the header, vertical rules between the columns, and
/// nothing closing the left and right sides. The horizontals give the rows and
/// the verticals the interior column edges; the outer edges come from how far
/// the rules themselves run.
///
/// The stacked-token table is a much narrower shape that happens to look the
/// same to the rule detector — three rules around a single column of
/// underscore- or colon-bearing tokens — and would otherwise be built as a
/// one-column table full of noise.

/// A vertical rule: its x, and the y range it spans.
typealias PdfVerticalRule = (x: Float, yMin: Float, yMax: Float)

/// A key/value pair drawn as a stack of single tokens between three rules.
///
/// The signature is unusually specific because the shape is: exactly three
/// rules, at least five rows, every row a *single* item, and all of them
/// starting at the same x. Three quarters of the body must then be lone tokens
/// carrying an underscore or a colon — form-field names, in other words. The
/// result is one row of two cells: the first line as a label, everything below
/// it joined into one value.
func pdfBuildStackedTokenTable(
    rows: [PdfAnchoredRow], rules: [PdfHorizontalRule]
) -> PdfTable? {
    guard rules.count == 3, rows.count >= 5, rows.allSatisfy({ $0.items.count == 1 })
    else { return nil }

    let anchorX = rows[0].items[0].item.x
    guard rows.allSatisfy({ abs($0.items[0].item.x - anchorX) <= pdfRuleJoinGap })
    else { return nil }

    let body = rows.dropFirst()
    let tokenRows = body.filter { row in
        let text = row.items[0].item.text.rustTrim()
        return text.rustSplitWhitespace().count == 1
            && text.unicodeScalars.contains { $0 == "_" || $0 == ":" }
    }.count
    guard tokenRows * 4 >= body.count * 3 else { return nil }

    let header = rows[0].items[0].item.text.rustTrim()
    let value = body.map { $0.items[0].item.text.rustTrim() }.joined(separator: " ")

    var itemIndices = rows.flatMap { $0.items.map(\.index) }
    itemIndices.sort()
    itemIndices = pdfDeduplicatedSorted(itemIndices)

    var xMin = Float.infinity
    var xMax = -Float.infinity
    for rule in rules {
        xMin = min(xMin, rule.xMin)
        xMax = max(xMax, rule.xMax)
    }
    // The split sits at 35% of the span: a label column narrower than its
    // value, which is what a form field looks like.
    let split = xMin + (xMax - xMin) * 0.35
    return PdfTable(
        columns: [xMin, split, xMax], rows: [rows[0].y],
        cells: [[header, value]], itemIndices: itemIndices)
}

/// Sorted-unique, matching Rust's `sort_unstable` + `dedup`.
func pdfDeduplicatedSorted(_ values: [Int]) -> [Int] {
    var result: [Int] = []
    for value in values where result.last != value { result.append(value) }
    return result
}

/// An open-edge grid from one run of horizontal rules, or `nil`.
///
/// The columns come from vertical rules that span nearly the whole band — 80%
/// of its height — and sit strictly inside it. A vertical that stops short is
/// a cell divider or a decoration, not a column edge.
func pdfBuildOpenEdgeGridTableForRules(
    items: [PdfLayoutItem],
    logicalRules: [PdfHorizontalRule],
    rules: [PdfHorizontalRule],
    verticals: [PdfVerticalRule]
) -> PdfTable? {
    var xMin = Float.infinity
    var xMax = -Float.infinity
    var yTop = -Float.infinity
    var yBottom = Float.infinity
    for rule in rules {
        xMin = min(xMin, rule.xMin)
        xMax = max(xMax, rule.xMax)
        yTop = max(yTop, rule.y)
        yBottom = min(yBottom, rule.y)
    }
    let width = xMax - xMin
    let height = yTop - yBottom
    guard width >= 100, height >= 20 else { return nil }

    let scopedVerticalXs = verticals.filter {
        $0.x > xMin + pdfRuleJoinGap && $0.x < xMax - pdfRuleJoinGap
            && $0.yMin <= yBottom + pdfRuleYTolerance && $0.yMax >= yTop - pdfRuleYTolerance
            && $0.yMax - $0.yMin >= height * 0.8
    }.map(\.x)
    let interiorEdges = pdfSnapEdges(scopedVerticalXs, tolerance: 3)
    // At least one interior edge — a grid with none is just a ruled band — and
    // no more than 24, past which the verticals are hatching, not columns.
    guard (1...24).contains(interiorEdges.count) else { return nil }

    var columnEdges = [xMin]
    columnEdges.append(contentsOf: interiorEdges)
    columnEdges.append(xMax)

    var rowEdges = pdfSnapEdges(rules.map(\.y), tolerance: 3)
    rowEdges.sort(by: >)
    guard rowEdges.count >= 3 else { return nil }

    let assigned = pdfAssignItemsToGrid(items, columnEdges: columnEdges, rowEdges: rowEdges)
    let bodyCells = assigned.cells
    let columnCount = columnEdges.count - 1
    let occupiedRows = bodyCells.filter { row in row.contains { !$0.isEmpty } }.count
    let occupiedColumns = (0..<columnCount).filter { column in
        bodyCells.contains { column < $0.count && !$0[column].isEmpty }
    }.count
    // Every column must carry something. An open-edge grid infers its outer
    // edges from the rules, so an empty column means those edges are wrong.
    guard occupiedRows >= 2, occupiedColumns == columnCount else { return nil }

    // The header sits *above* the top rule, in a 30pt band synthesised as a
    // pair of rules so the same row collector can be reused.
    let headerBand = [
        PdfHorizontalRule(y: yTop + 30, xMin: xMin, xMax: xMax),
        PdfHorizontalRule(y: yTop + pdfRuleYTolerance, xMin: xMin, xMax: xMax),
    ]
    let headerRows = pdfCollectAnchoredRows(items: items, rules: headerBand)
    guard let headerY = headerRows.first?.y else { return nil }

    var headerCells = [String](repeating: "", count: columnCount)
    var headerIndices: [Int] = []
    for headerRow in headerRows {
        for entry in headerRow.items {
            let centreX = entry.item.x + entry.item.width / 2
            // A header item landing outside every column rejects the *whole*
            // table, not just that item — the reference's `?` on the search.
            guard
                let column = (0..<columnCount).first(where: {
                    centreX >= columnEdges[$0] && centreX <= columnEdges[$0 + 1]
                })
            else { return nil }
            if !headerCells[column].isEmpty { headerCells[column] += " " }
            headerCells[column] += entry.item.text.rustTrim()
            headerIndices.append(entry.index)
        }
    }

    // The first column may be an unlabelled row-header stub or a normal
    // labelled one. A fully populated header is the less distinctive case, so
    // it is only accepted when every logical rule in the band agrees on the
    // same span; mixed spans belong to the physical-grid detector instead.
    let mixedRuleSpanInBand = logicalRules.contains { rule in
        rule.y >= yBottom - pdfRuleYTolerance && rule.y <= yTop + pdfRuleYTolerance
            && rule.xMax >= xMin - pdfRuleJoinGap && rule.xMin <= xMax + pdfRuleJoinGap
            && !rules.contains(rule)
    }
    if headerCells.dropFirst().contains(where: \.isEmpty)
        || (!headerCells[0].isEmpty && mixedRuleSpanInBand)
    {
        return nil
    }

    var cells = [headerCells]
    cells.append(contentsOf: bodyCells)
    var itemIndices = assigned.itemIndices
    itemIndices.append(contentsOf: headerIndices)
    itemIndices.sort()
    itemIndices = pdfDeduplicatedSorted(itemIndices)

    // The header's own baseline leads, then every row edge but the last —
    // which was the bottom of the table, not the top of a row.
    var tableRows = [headerY]
    tableRows.append(contentsOf: rowEdges.dropLast())
    return PdfTable(
        columns: columnEdges, rows: tableRows, cells: cells, itemIndices: itemIndices)
}

/// Every open-edge grid on a page.
///
/// Segments are merged into logical rules, grouped by span, split where two
/// tables share endpoints, and each run of three or more rules is tried.
func pdfBuildOpenEdgeGridTables(
    items: [PdfLayoutItem],
    horizontals: [PdfHorizontalRule],
    verticals: [PdfVerticalRule]
) -> [PdfTable] {
    let logicalRules = pdfMergeHorizontalSegments(horizontals)
    return pdfGroupRulesBySpan(logicalRules)
        .flatMap { pdfSplitIndependentRuleRuns($0, items: items) }
        .filter { $0.count >= 3 }
        .compactMap {
            pdfBuildOpenEdgeGridTableForRules(
                items: items, logicalRules: logicalRules, rules: $0, verticals: verticals)
        }
}
