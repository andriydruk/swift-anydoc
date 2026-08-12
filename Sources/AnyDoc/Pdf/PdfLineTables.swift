/// The line-based table orchestrator, ported from
/// `detect_tables_from_lines_inner` and its two public entry points in
/// pdf-inspector's `tables/detect_lines.rs`.
///
/// This is what runs the six strategies waves 21–39 built. It classifies the
/// page's strokes into horizontal and vertical rules, offers the sparse
/// strategies their chance, and otherwise falls through to the legacy path:
/// snap the rule coordinates into a grid, assign the text, and put the result
/// up against whatever the sparse strategies produced.
///
/// The interesting structure is the middle. When text-anchor tables are
/// accepted, the function *recurses on the rest of the page* — with the
/// accepted bands' graphics removed and sparse inference switched off — so a
/// physical grid elsewhere is still found without an inferred header reaching
/// into a band that has already been claimed.

/// Strokes shorter than this are tick marks and decoration.
private let pdfMinimumRuleLength: Float = 20

/// How far off axis a stroke may be and still count as a rule: two degrees,
/// as a slope.
private let pdfRuleAngleTolerance: Float = 0.034_920_77

/// Tables from a page's stroked lines.
func pdfDetectTablesFromLines(items: [PdfLayoutItem], lines: [PdfLineSegment]) -> [PdfTable] {
    pdfDetectTablesFromLinesInner(
        items: items, lines: lines, allowTextAnchors: true, allowAlternatives: true)
}

/// Tables whose cell grid is backed by explicit vector geometry.
///
/// Region-level callers need physical cell boundaries for crop boxes, so
/// columns inferred from sparse rules are deliberately excluded.
func pdfDetectVectorGridTablesFromLines(
    items: [PdfLayoutItem], lines: [PdfLineSegment]
) -> [PdfTable] {
    pdfDetectTablesFromLinesInner(
        items: items, lines: lines, allowTextAnchors: false, allowAlternatives: false)
}

/// Split a page's strokes into horizontal and vertical rules.
///
/// Diagonals are ignored entirely, and a stroke under 20pt is decoration. The
/// axis test is a slope comparison rather than an angle, which is why a
/// near-zero `dx` is excluded before dividing by it.
func pdfClassifyRuleLines(
    _ lines: [PdfLineSegment]
) -> (horizontals: [PdfHorizontalRule], verticals: [PdfVerticalRule]) {
    var horizontals: [PdfHorizontalRule] = []
    var verticals: [PdfVerticalRule] = []
    for line in lines {
        let dx = abs(line.x2 - line.x1)
        let dy = abs(line.y2 - line.y1)
        let length = (dx * dx + dy * dy).squareRoot()
        if length < pdfMinimumRuleLength { continue }

        if dx > 0.01 && dy / dx <= pdfRuleAngleTolerance {
            horizontals.append(
                PdfHorizontalRule(
                    y: (line.y1 + line.y2) / 2, xMin: min(line.x1, line.x2),
                    xMax: max(line.x1, line.x2)))
        } else if dy > 0.01 && dx / dy <= pdfRuleAngleTolerance {
            verticals.append(
                (
                    x: (line.x1 + line.x2) / 2, yMin: min(line.y1, line.y2),
                    yMax: max(line.y1, line.y2)
                ))
        }
    }
    return (horizontals, verticals)
}

func pdfDetectTablesFromLinesInner(
    items: [PdfLayoutItem],
    lines: [PdfLineSegment],
    allowTextAnchors: Bool,
    allowAlternatives: Bool
) -> [PdfTable] {
    guard !lines.isEmpty else { return [] }
    let (horizontals, verticals) = pdfClassifyRuleLines(lines)
    guard horizontals.count >= 2 else { return [] }

    var alternatives: [PdfTable] = []
    if allowAlternatives {
        if let dense = pdfBuildDenseRowAnchorTable(
            items: items, horizontals: horizontals, verticals: verticals)
        {
            alternatives.append(dense)
        }
        alternatives.append(
            contentsOf: pdfBuildOpenEdgeGridTables(
                items: items, horizontals: horizontals, verticals: verticals))
    }

    // Booktabs and response forms draw horizontal rules only, and those rules
    // describe *bands* rather than cell boundaries. They get their chance
    // before the legacy path, which would otherwise collapse two adjacent
    // tables into one grid.
    if allowTextAnchors {
        let anchorBands = pdfDetectTextAnchorRuleTables(
            items: items, horizontals: horizontals, verticals: verticals, pathLines: lines)
        if !anchorBands.isEmpty {
            // Sparse-rule and physical-grid tables coexist on real pages. Drop
            // only the graphics belonging to the accepted bands, then look at
            // what is left — without recursing back into sparse inference.
            let remainingLines = lines.filter { line in
                !anchorBands.contains { pdfLineOverlapsTextAnchorBand(line, band: $0) }
            }
            let anchorTables = anchorBands.map(\.table)

            // Two readings of the remainder: geometry only, and geometry plus
            // the dense and open-edge alternatives. The geometry-only result
            // is kept as a fallback because an inferred header can otherwise
            // reach into an adjacent accepted band and displace a valid grid.
            let vectorTables = pdfDetectTablesFromLinesInner(
                items: items, lines: remainingLines, allowTextAnchors: false,
                allowAlternatives: false)
            var inferredTables = pdfDetectTablesFromLinesInner(
                items: items, lines: remainingLines, allowTextAnchors: false,
                allowAlternatives: true)
            inferredTables.removeAll { table in
                anchorTables.contains { pdfTablesShareItems(table, $0) }
            }
            let remainingTables = pdfCombineNonOverlappingTables(inferredTables, vectorTables)

            // A page-wide alternative swallowing two already-independent
            // sparse tables is a synthetic merge, not a better hypothesis. One
            // that replaces a single band, or sits elsewhere entirely, is
            // still allowed to compete.
            alternatives.removeAll { pdfOverlapsMultipleTables($0, anchorTables) }
            let competing = anchorTables + alternatives
            return pdfCombineNonOverlappingTables(
                pdfSelectNonOverlappingHypotheses(competing), remainingTables)
        }
    }

    guard horizontals.count >= 3 else {
        return pdfSelectTableHypothesis(legacy: [], alternatives: alternatives)
    }

    // With no drawn verticals, the column edges may still be recoverable from
    // where the horizontal segments break. Catalogue and finding-aid layouts
    // draw one segment per cell and no dividers at all.
    let implicitColumnEdges: [Float]? =
        verticals.count < 2 ? pdfDeriveColumnsFromHorizontalSegments(horizontals) : nil
    if verticals.count < 2 && implicitColumnEdges == nil {
        return pdfSelectTableHypothesis(legacy: [], alternatives: alternatives)
    }
    let columnsFromSegments = implicitColumnEdges != nil

    let rowEdges = pdfSnapEdges(horizontals.map(\.y), tolerance: 3)
    let columnEdges = implicitColumnEdges ?? pdfSnapEdges(verticals.map(\.x), tolerance: 3)

    // Two columns and two rows at minimum: a single column of horizontal
    // lines is a set of separator rules, not a table.
    guard rowEdges.count >= 3, columnEdges.count >= 3 else {
        return pdfSelectTableHypothesis(legacy: [], alternatives: alternatives)
    }
    // Past twenty columns it is a diagram.
    guard columnEdges.count <= 21, rowEdges.count <= 80 else {
        return pdfSelectTableHypothesis(legacy: [], alternatives: alternatives)
    }

    let tableXMin = columnEdges.first ?? 0
    let tableXMax = columnEdges.last ?? 0
    let tableWidth = tableXMax - tableXMin
    guard tableWidth >= 50 else {
        return pdfSelectTableHypothesis(legacy: [], alternatives: alternatives)
    }
    let tableYMin = rowEdges.first ?? 0
    let tableYMax = rowEdges.last ?? 0
    let tableHeight = abs(tableYMax - tableYMin)
    guard tableHeight >= 20 else {
        return pdfSelectTableHypothesis(legacy: [], alternatives: alternatives)
    }

    // A decorative page border has four edges and nothing inside. Real
    // full-page tables — ledgers, financial reports — span the same paper but
    // carry many internal rules, so the test is on the *line count*, not the
    // size.
    if tableWidth > 500 && tableHeight > 700 && horizontals.count <= 4 && verticals.count <= 4 {
        return pdfSelectTableHypothesis(legacy: [], alternatives: alternatives)
    }

    // Three rules crossing half the table is the ideal; six crossing a
    // seventh of it will do, which is what column-level separators look like.
    let spanningHorizontals = horizontals.filter { $0.xMax - $0.xMin > tableWidth * 0.5 }.count
    let partialHorizontals = horizontals.filter { $0.xMax - $0.xMin > tableWidth * 0.15 }.count
    if spanningHorizontals < 3 && partialHorizontals < 6 {
        return pdfSelectTableHypothesis(legacy: [], alternatives: alternatives)
    }

    // The same test for verticals, skipped entirely when the columns came
    // from segment endpoints — there are no verticals to validate, and the
    // consistency check inside that derivation is the equivalent guard.
    if !columnsFromSegments {
        let spanning = verticals.filter { $0.yMax - $0.yMin > tableHeight * 0.3 }.count
        let partial = verticals.filter { $0.yMax - $0.yMin > tableHeight * 0.10 }.count
        if spanning < 2 && partial < 4 {
            return pdfSelectTableHypothesis(legacy: [], alternatives: alternatives)
        }
    }

    let rowEdgesDescending = rowEdges.sorted(by: >)
    let assigned = pdfAssignItemsToGrid(
        items, columnEdges: columnEdges, rowEdges: rowEdgesDescending)
    let cells = assigned.cells

    let nonEmptyRows = cells.filter { row in row.contains { !$0.isEmpty } }.count
    guard nonEmptyRows >= 2 else {
        return pdfSelectTableHypothesis(legacy: [], alternatives: alternatives)
    }

    let gridColumnCount = cells.first?.count ?? 0
    let totalCells = cells.count * gridColumnCount
    if totalCells > 0 {
        let filledCells = cells.reduce(0) { $0 + $1.filter { !$0.isEmpty }.count }
        if Float(filledCells) / Float(totalCells) < 0.15 {
            return pdfSelectTableHypothesis(legacy: [], alternatives: alternatives)
        }
    }

    // A chart concentrates its text on one axis; a table spreads it out.
    let columnsWithContent = (0..<gridColumnCount).filter { column in
        cells.contains { row in column < row.count && !row[column].isEmpty }
    }.count
    guard columnsWithContent >= 2 else {
        return pdfSelectTableHypothesis(legacy: [], alternatives: alternatives)
    }

    // A grid that captures a fifth of the page's text is a table; one that
    // captures less is a chart on a page of prose, catching only its labels.
    if !items.isEmpty {
        if Float(assigned.itemIndices.count) / Float(items.count) < 0.20 {
            return pdfSelectTableHypothesis(legacy: [], alternatives: alternatives)
        }
    }

    // Chart gridlines are evenly spaced; real tables have variable row
    // heights. The bar is tight because spreadsheet exports are uniform to
    // within a few percent and must not be caught.
    if rowEdgesDescending.count >= 5 {
        let spacings = zip(rowEdgesDescending, rowEdgesDescending.dropFirst()).map { abs($0 - $1) }
        let mean = spacings.reduce(0, +) / Float(spacings.count)
        if mean > 0.1 {
            let variance =
                spacings.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(spacings.count)
            if variance.squareRoot() / mean < 0.02 {
                return pdfSelectTableHypothesis(legacy: [], alternatives: alternatives)
            }
        }
    }

    let columnCount = columnEdges.count - 1
    let rowCount = rowEdgesDescending.count - 1
    guard rowCount >= 2, columnCount >= 2 else {
        return pdfSelectTableHypothesis(legacy: [], alternatives: alternatives)
    }

    return pdfSelectTableHypothesis(
        legacy: [
            PdfTable(
                columns: columnEdges, rows: Array(rowEdgesDescending.prefix(rowCount)),
                cells: cells, itemIndices: assigned.itemIndices)
        ],
        alternatives: alternatives)
}
